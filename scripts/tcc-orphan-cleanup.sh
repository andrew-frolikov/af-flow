#!/bin/bash
# Remove the permanent System Settings rows left behind by deleted probe bundles.
#
# WHY THIS EXISTS. On 2026-08-25 Andrew opened Privacy and Security > Input
# Monitoring and found "AF Flow" listed more than once. Part of that was the
# test host wearing the app's name, fixed in Info.plist. The rest was SEVEN
# bundles that no longer exist: `.axprobe`, `.renamecheck`, `.snapcheck`,
# `.vcheck`, `.vsnap`, `.tapprobe.sandboxed`, `.tapprobe.unsandboxed`. Each was
# built by a past session to verify something, each asked macOS for a
# permission, each earned a permanent row, and each was then deleted. The rows
# stayed, and seven of them still hold GRANTED microphone or audio-capture
# access. Anyone who later builds a bundle carrying one of those identifiers
# inherits a granted microphone with no prompt. That is the reason to clean
# them, beyond the two "AF Flow" lines he actually saw.
#
# THE CATCH, AND THE METHOD. `tccutil reset ListenEvent <id>` fails outright
# with `No such bundle identifier ... OSStatus -10814`, because tccutil resolves
# the identifier through LaunchServices and the bundle is gone. So this builds a
# minimal stub carrying the orphan's identifier, resets, and deletes the stub.
#
# Measured on 2026-08-25, because the first two attempts failed: the stub must
# live somewhere LaunchServices will look it up. A stub under $TMPDIR registers
# without error and tccutil still cannot resolve it. `~/Applications` works.
# No password is needed, not even for the rows in the system database.
#
# THE STUB IS THE ONE SANCTIONED EXCEPTION to the canon rule this incident
# produced (`docs/design/af-flow-system-list-names.md` section B): a throwaway
# bundle never carries the product's identifier. This one must, because the
# identifier IS the thing being removed. It is safe because it inverts both
# halves of the danger. It requests NO permission, so it can earn no new row.
# And its display name is `scratch-tcc-reset`, so for the seconds it exists it
# neither wears the product's name nor sorts beside it in any list.
#
# Read-only rehearsal:  scripts/tcc-orphan-cleanup.sh
# Actually clean:       scripts/tcc-orphan-cleanup.sh --apply
set -uo pipefail

SYSTEM_DB="/Library/Application Support/com.apple.TCC/TCC.db"
USER_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STUB="$HOME/Applications/afflow-tcc-scratch.app"
STALE_FILE=""

# One trap, installed before anything is created rather than inside the branch
# that creates it. The stub carries a family bundle identifier and lives in a
# directory Andrew browses, so an `exit`, a Ctrl-C or a `set -u` error part way
# through would leave a REGISTERED bundle behind, which is precisely the
# orphaned LaunchServices record this script exists to remove.
cleanup_scratch() {
    [ -n "${STALE_FILE:-}" ] && rm -f "$STALE_FILE"
    if [ -d "$STUB" ]; then
        "$LSREGISTER" -u "$STUB" >/dev/null 2>&1
        rm -rf "$STUB"
    fi
    return 0
}
trap cleanup_scratch EXIT INT TERM
FAMILY="com.frolikov.afflow"

# The two identifiers that are ALIVE. His dictation depends on both: TCC keys on
# the identifier, so resetting either would silently revoke a grant he had to
# give by hand, and the Input Monitoring one is what makes the hotkey work at
# all.
#
# THIS LIST IS CONSULTED IN THREE PLACES, and it has to be all three. Review on
# 2026-08-25 found the comment here claiming it was checked everywhere while the
# LaunchServices loop at the bottom never called `is_live` at all, which would
# have unregistered the live app the first time a DerivedData purge made its
# path vanish. The three: the classification at the top, a re-check inside the
# reset loop, and the python filter that builds the stale-record list.
#
# `com.frolikov.afflow.tests` and `com.frolikov.afflow.cleanup-model-probe` are
# also built by this project but are NOT here on purpose. Neither is an app
# bundle, so neither registers with LaunchServices or can request a permission.
# If either ever turns up in a database, treating it as an orphan is right.
LIVE_IDS=("com.frolikov.afflow" "com.frolikov.afflow.testhost")

APPLY=0
case "${1:-}" in
    "")        : ;;
    "--apply") APPLY=1 ;;
    *)
        # A script that resets real permissions must not treat `--aply` as a
        # rehearsal. Silence would look exactly like "it ran and found nothing".
        echo "REFUSING TO RUN: unrecognised argument '$1'." >&2
        echo "Usage: $0 [--apply]" >&2
        exit 2
        ;;
esac

is_live() {
    local candidate="$1" live
    for live in "${LIVE_IDS[@]}"; do
        [ "$candidate" = "$live" ] && return 0
    done
    return 1
}

# An unreadable database is NOT an empty one. Reading these needs Full Disk
# Access for whatever is running this script, and a missing grant returns the
# same empty result as a clean machine. Reporting "nothing to clean" in that
# case would be the project's oldest failure shape wearing a new face, so this
# refuses to run instead.
probe_db() {
    local db="$1" label="$2"
    if [ ! -f "$db" ]; then
        echo "REFUSING TO RUN: no $label TCC database at $db" >&2
        exit 3
    fi
    if ! sqlite3 "$db" "select count(*) from access;" >/dev/null 2>&1; then
        echo "REFUSING TO RUN: cannot read the $label TCC database." >&2
        echo "  $db" >&2
        echo "This needs Full Disk Access. Without it an unreadable database" >&2
        echo "looks exactly like a clean one, and this script would report" >&2
        echo "success having checked nothing." >&2
        exit 4
    fi
}

rows_for() {   # db -> "client|service" lines for the whole family
    sqlite3 "$1" \
        "select client || '|' || service from access \
         where client = '${FAMILY}' or client like '${FAMILY}.%';" 2>/dev/null
}

probe_db "$SYSTEM_DB" "system"
probe_db "$USER_DB" "user"

# macOS ships bash 3.2, where `set -u` treats "${array[@]}" on an EMPTY array as
# an unbound variable and aborts. Every expansion below therefore uses the
# `${a[@]+"${a[@]}"}` form. Found on 2026-08-25 by running this script on a
# machine it had already cleaned: it worked while there was something to do and
# died the moment there was not, which is the worst possible way round.
ORPHAN_ROWS=()
LIVE_ROWS=()
while IFS= read -r row; do
    [ -z "$row" ] && continue
    client="${row%%|*}"
    if is_live "$client"; then LIVE_ROWS+=("$row"); else ORPHAN_ROWS+=("$row"); fi
done < <( { rows_for "$SYSTEM_DB"; rows_for "$USER_DB"; } | sort -u )

echo "Live rows, left alone (${#LIVE_ROWS[@]}):"
for row in ${LIVE_ROWS[@]+"${LIVE_ROWS[@]}"}; do echo "  keep    ${row/|/  }"; done
echo
echo "Orphan rows (${#ORPHAN_ROWS[@]}):"
for row in ${ORPHAN_ROWS[@]+"${ORPHAN_ROWS[@]}"}; do echo "  reset   ${row/|/  }"; done
echo

if [ "${#ORPHAN_ROWS[@]}" -eq 0 ]; then
    echo "Nothing to clean."
else
    if [ "$APPLY" -ne 1 ]; then
        echo "REHEARSAL ONLY. Nothing was changed. Re-run with --apply."
    else
        mkdir -p "$HOME/Applications"
        for row in ${ORPHAN_ROWS[@]+"${ORPHAN_ROWS[@]}"}; do
            client="${row%%|*}"
            service="${row##*|}"
            service="${service#kTCCService}"

            # Checked per row, not once at the top. A table read at the start of
            # a loop is a table that can be wrong by the end of it.
            if is_live "$client"; then
                echo "REFUSING: $client is live." >&2
                exit 5
            fi

            rm -rf "$STUB"
            mkdir -p "$STUB/Contents/MacOS"
            cat > "$STUB/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Stub</string>
	<key>CFBundleIdentifier</key><string>$client</string>
	<key>CFBundleName</key><string>scratch-tcc-reset</string>
	<key>CFBundleDisplayName</key><string>scratch-tcc-reset</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST
            # No usage-description key of any kind, deliberately: a bundle that
            # cannot ask for a permission cannot be granted one, and cannot earn
            # the permanent row this script exists to delete.
            printf '#!/bin/sh\nexit 0\n' > "$STUB/Contents/MacOS/Stub"
            chmod +x "$STUB/Contents/MacOS/Stub"
            "$LSREGISTER" -f "$STUB" >/dev/null 2>&1

            if tccutil reset "$service" "$client" >/dev/null 2>&1; then
                echo "  reset   $client  $service"
            else
                echo "  FAILED  $client  $service" >&2
            fi
        done
        "$LSREGISTER" -u "$STUB" >/dev/null 2>&1
        rm -rf "$STUB"
    fi
fi

# LaunchServices is the second half of the same disease, and it is the half he
# can SEE. TCC.db stores only the identifier; the name on the row in System
# Settings is resolved through LaunchServices. Every deleted probe left an LS
# record behind carrying `name: AF Flow`, pointing at a build directory that no
# longer exists. Those records are also why tccutil could not resolve the
# identifiers in the first place.
echo
echo "LaunchServices records for the family whose bundle is gone from disk:"
# LIVE identifiers are excluded HERE, not only in the reset loop above.
#
# Review on 2026-08-25 found this loop had no live-id guard while the comment at
# the top of the file claimed the list was "checked on every single identifier
# before anything touches it". It was true of the reset loop and false of this
# one. The scenario is ordinary rather than exotic: the app's only registered
# path is inside DerivedData, so a Shift-Cmd-K or a DerivedData purge makes that
# path vanish while the identifier and its Input Monitoring grant are still
# live. The checker would then go red, print this script as the remedy, and this
# loop would unregister the LIVE app. That is the -10814 state described at the
# top of this file, self-inflicted: System Settings resolves a row's name and
# icon through the same record.
#
# A live identifier whose bundle moved wants a REBUILD or a re-register, never
# an unregister, so it is reported and skipped.
#
# `os.stat` rather than `os.path.exists`, for the same reason the checker uses
# it: `exists` returns False for "permission denied" as well as for "not there",
# and unregistering on an ambiguous answer is the one mistake this loop cannot
# take back. NUL-separated so a path containing a tab or a newline cannot split
# into a corrupted record and hand `lsregister -u` an empty string.
# Through a temp FILE, not through `$( )`. Bash command substitution discards
# NUL bytes silently, so the NUL-separated records this emits arrived as one
# undelimited blob, `read -d ''` never found a separator, and the loop below ran
# ZERO times while printing nothing at all. Caught on 2026-08-25 by staging a
# live identifier at a missing bundle and watching the checker report it while
# this script said nothing. A separator the shell deletes is worse than the tab
# it replaced.
STALE_FILE="$(mktemp -t afflow-stale)"
"$LSREGISTER" -dump 2>/dev/null | python3 -c '
import os, re, sys

APP = "com.frolikov.afflow"
LIVE = {APP, APP + ".testhost"}

blocks = re.split(r"^-{60,}$", sys.stdin.read(), flags=re.M)
for block in blocks:
    identifier = re.search(r"^identifier:\s+(\S+)", block, re.M)
    path = re.search(r"^path:\s+(.*?)\s+\(0x[0-9a-f]+\)\s*$", block, re.M)
    if not identifier or not path:
        continue
    identifier, path = identifier.group(1), path.group(1)
    if identifier != APP and not identifier.startswith(APP + "."):
        continue
    try:
        os.stat(path)
        continue          # the bundle is there; nothing to clean
    except FileNotFoundError:
        pass
    except OSError:
        sys.stdout.write("unreadable\t" + identifier + "\t" + path + "\0")
        continue
    state = "live" if identifier in LIVE else "orphan"
    sys.stdout.write(state + "\t" + identifier + "\t" + path + "\0")
' > "$STALE_FILE"
if [ ! -s "$STALE_FILE" ]; then
    echo "  none"
else
    while IFS=$'\t' read -r -d '' state identifier path; do
        [ -z "$identifier" ] || [ -z "$path" ] && continue
        case "$state" in
            live)
                echo "  KEPT, live identifier at a missing bundle: $identifier  $path" >&2
                echo "        Rebuild or re-register it. Unregistering the app's only" >&2
                echo "        record is what makes tccutil unable to resolve it." >&2
                ;;
            unreadable)
                echo "  KEPT, could not tell whether the bundle exists: $identifier  $path" >&2
                ;;
            orphan)
                if [ "$APPLY" -eq 1 ]; then
                    "$LSREGISTER" -u "$path" >/dev/null 2>&1
                    echo "  unregistered  $identifier  $path"
                else
                    echo "  would unregister  $identifier  $path"
                fi
                ;;
        esac
    done < "$STALE_FILE"
fi
rm -f "$STALE_FILE"
STALE_FILE=""

# Verified against the databases rather than against the exit codes above. A
# tccutil that prints success and changes nothing is exactly the kind of claim
# this project has been burned by.
echo
echo "Verification, read back from both databases:"
REMAINING=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    client="${row%%|*}"
    if is_live "$client"; then
        echo "  ok       ${row/|/  }"
    else
        echo "  ORPHAN   ${row/|/  }" >&2
        REMAINING=$((REMAINING + 1))
    fi
done < <( { rows_for "$SYSTEM_DB"; rows_for "$USER_DB"; } | sort -u )

if [ "$APPLY" -eq 1 ] && [ "$REMAINING" -ne 0 ]; then
    echo
    echo "EXITING NON-ZERO: $REMAINING orphan row(s) survived the reset." >&2
    exit 6
fi
exit 0
