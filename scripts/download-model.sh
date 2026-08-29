#!/bin/bash
# Fetch a pinned model straight to disk, so the APP never needs the network.
#
# WHY THIS EXISTS. Until 2026-08-29 adding a model meant a four-step dance:
# put `com.apple.security.network.client` back in the entitlements, build,
# let the app download, take the entitlement out again, build again. That
# procedure worked and was still a defect, because it is a written instruction
# standing between Andrew and a state where his dictation app can open a
# socket. Any step skipped, any session that forgets the last two, and the app
# ships with the network back. Instructions are not controls.
#
# So the capability moved out of the app for good. The app has no network
# entitlement, the build refuses to carry one, and models arrive here instead:
# curl, a checksum, and a folder this script will not write outside of.
#
# WHAT IT COVERS. The GGUF cleanup models, which are declared in
# `TextCleanupManager.swift` with a pinned revision URL, a SHA-256 and an exact
# byte count. The catalogue is READ FROM THAT FILE by scripts/model_catalogue.py,
# never copied, for the same reason scripts/af_paths.py reads the data folder
# name out of the Swift rather than repeating it.
#
# WHAT IT DOES NOT COVER, stated rather than implied. The speech models are
# fetched by WhisperKit and FluidAudio from their own repositories, and those
# publish no checksum this project could pin. A script whose entire contract is
# "verify the checksum before it counts as downloaded" cannot honestly claim
# them. They are already cached on this Mac. If a NEW speech model is ever
# needed, that is a real piece of work, not a flag on this script, and it must
# not be done by handing the app the network back.
#
# Usage:
#   scripts/download-model.sh --list                  what is pinned, and what is on disk
#   scripts/download-model.sh --verify                check every file already there
#   scripts/download-model.sh <name>                  fetch one (a unique part of the name)
#   scripts/download-model.sh --all-missing           fetch everything not yet on disk
#   scripts/download-model.sh --force <name>          re-fetch even if a file is there
#
# Exit codes: 0 ok, 1 a download or a check failed, 2 the catalogue is unreadable.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

CATALOGUE="scripts/model_catalogue.py"
FORCE=0
ACTION=""
TARGET=""

die() { printf '%s\n' "$*" >&2; exit 1; }

# The destination is asked for, never spelled. `af_paths.py` reads the folder
# name out of AppSupportDirectory.swift, which is the one place allowed to
# decide it; the 2026-08-25 rename orphaned 1.18 GB of models exactly because
# two call sites spelled it themselves.
resolve_models_dir() {
    if [ -n "${AF_FLOW_MODELS_DIR:-}" ]; then
        printf '%s' "$AF_FLOW_MODELS_DIR"
        return 0
    fi
    local base
    base="$(python3 scripts/af_paths.py --print app)" || return 2
    printf '%s/models' "$base"
}

# Containment. `realpath` the parent and the target and demand one is under the
# other, so a catalogue entry carrying a `../` or an absolute path cannot write
# outside the models folder. The catalogue reader refuses those too; this is the
# second lock, because the whole point of this script is that a model download
# can no longer reach anywhere it likes.
assert_inside() {
    local dir="$1" file="$2" real_dir real_parent
    real_dir="$(cd "$dir" && pwd -P)" || die "cannot resolve $dir"
    real_parent="$(cd "$(dirname "$file")" && pwd -P)" || die "cannot resolve $(dirname "$file")"
    case "$real_parent" in
        "$real_dir") : ;;
        *) die "REFUSED: $file resolves to $real_parent, which is outside $real_dir" ;;
    esac
    case "$(basename "$file")" in
        ""|"."|"..") die "REFUSED: $file has no plain file name" ;;
    esac
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Reports, rather than returns: the caller wants to print the reason.
check_file() {
    local path="$1" want_sha="$2" want_bytes="$3" actual_sha actual_bytes
    [ -f "$path" ] || { echo "missing"; return 1; }
    actual_bytes="$(wc -c < "$path" | tr -d ' ')"
    if [ "$actual_bytes" != "$want_bytes" ]; then
        echo "wrong size: $actual_bytes bytes, expected $want_bytes"
        return 1
    fi
    actual_sha="$(sha_of "$path")"
    if [ "$actual_sha" != "$want_sha" ]; then
        echo "wrong checksum: $actual_sha"
        return 1
    fi
    echo "ok"
    return 0
}

fetch_one() {
    local name="$1" models_dir="$2"
    local json file url sha bytes dest tmp verdict

    json="$(python3 "$CATALOGUE" --name "$name")" || die "no single model matches '$name'. Try --list."
    file="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["fileName"])')"
    url="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')"
    sha="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["expectedSHA256"])')"
    bytes="$(printf '%s' "$json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["expectedByteCount"])')"

    mkdir -p "$models_dir" || die "cannot create $models_dir"
    dest="$models_dir/$file"
    assert_inside "$models_dir" "$dest"

    if [ -f "$dest" ]; then
        verdict="$(check_file "$dest" "$sha" "$bytes")"
        if [ "$verdict" = "ok" ]; then
            if [ "$FORCE" -eq 0 ]; then
                echo "  $file: already here and verified, nothing to do"
                return 0
            fi
            echo "  $file: already verified, re-fetching because --force"
        else
            if [ "$FORCE" -eq 0 ]; then
                echo "  $file: ON DISK BUT WRONG ($verdict)" >&2
                echo "  Not overwriting it. Re-run with --force to replace it." >&2
                return 1
            fi
            echo "  $file: on disk but wrong ($verdict), replacing because --force"
        fi
    fi

    echo "  $file: fetching $(( bytes / 1024 / 1024 )) MB"
    echo "     from $url"
    tmp="$(mktemp "$dest.partial.XXXXXX")" || die "cannot make a temp file beside $dest"
    # The partial never carries the real name, so an interrupted run cannot
    # leave something the app would try to load.
    trap 'rm -f "$tmp"' EXIT
    if ! curl -fL --progress-bar -o "$tmp" "$url"; then
        rm -f "$tmp"; trap - EXIT
        echo "  $file: DOWNLOAD FAILED" >&2
        return 1
    fi

    verdict="$(check_file "$tmp" "$sha" "$bytes")"
    if [ "$verdict" != "ok" ]; then
        rm -f "$tmp"; trap - EXIT
        echo "  $file: REFUSED, what arrived is not what is pinned ($verdict)" >&2
        echo "  Nothing was written. The pinned hash is $sha" >&2
        return 1
    fi

    # Codex, 2026-08-29: there is no `set -e` here on purpose (a failed check
    # must be reported, not abort the run), which meant a failing chmod or mv
    # was ignored and the fetch reported success over a destination that was
    # missing or half written. Both are checked, and the partial is kept for
    # diagnosis rather than silently dropped.
    if ! chmod 600 "$tmp"; then
        echo "  $file: could not set permissions on the download; left at $tmp" >&2
        trap - EXIT
        return 1
    fi
    if ! mv "$tmp" "$dest"; then
        echo "  $file: VERIFIED BUT NOT INSTALLED, the move to $dest failed" >&2
        echo "  The verified file is still at $tmp" >&2
        trap - EXIT
        return 1
    fi
    trap - EXIT
    # Prove the install rather than assume it: the bytes that matter are the
    # ones now at the destination, not the ones that were in the temp file.
    verdict="$(check_file "$dest" "$sha" "$bytes")"
    if [ "$verdict" != "ok" ]; then
        echo "  $file: INSTALLED BUT DOES NOT VERIFY IN PLACE ($verdict)" >&2
        return 1
    fi
    echo "  $file: verified against its pinned SHA-256 and installed"
    return 0
}

# ------------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --list) ACTION="list" ;;
        --verify) ACTION="verify" ;;
        --all-missing) ACTION="all" ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *) ACTION="one"; TARGET="$1" ;;
    esac
    shift
done
[ -n "$ACTION" ] || { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

MODELS_DIR="$(resolve_models_dir)" || die "could not resolve the models folder"
python3 "$CATALOGUE" >/dev/null || exit 2

echo "Pinned models for AF Flow"
echo "========================="
echo "  folder: $MODELS_DIR"
echo ""

status=0
case "$ACTION" in
    list|verify)
        while IFS=$'\t' read -r file sha bytes display; do
            verdict="$(check_file "$MODELS_DIR/$file" "$sha" "$bytes")"
            printf '  %-42s %-10s %s\n' "$file" "$verdict" "$display"
            [ "$verdict" = "ok" ] || [ "$ACTION" = "list" ] || status=1
        done < <(python3 -c '
import json, subprocess, sys
models = json.loads(subprocess.run([sys.executable, "scripts/model_catalogue.py", "--json"],
                                   capture_output=True, text=True, check=True).stdout)
for m in models:
    print("\t".join([m["fileName"], m["expectedSHA256"], str(m["expectedByteCount"]), m["displayName"]]))
')
        ;;
    one)
        fetch_one "$TARGET" "$MODELS_DIR" || status=1
        ;;
    all)
        while IFS=$'\t' read -r file sha bytes display; do
            if [ "$(check_file "$MODELS_DIR/$file" "$sha" "$bytes")" = "ok" ]; then
                echo "  $file: already here and verified"
                continue
            fi
            fetch_one "$file" "$MODELS_DIR" || status=1
        done < <(python3 -c '
import json, subprocess, sys
models = json.loads(subprocess.run([sys.executable, "scripts/model_catalogue.py", "--json"],
                                   capture_output=True, text=True, check=True).stdout)
for m in models:
    print("\t".join([m["fileName"], m["expectedSHA256"], str(m["expectedByteCount"]), m["displayName"]]))
')
        ;;
esac

echo ""
if [ "$status" -eq 0 ]; then
    echo "RESULT: clean"
else
    echo "RESULT: something did not verify. The app cannot fetch it for you: it has no network entitlement, on purpose."
fi
exit "$status"
