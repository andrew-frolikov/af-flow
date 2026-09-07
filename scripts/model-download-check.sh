#!/bin/bash
# Does a REAL pinned file arrive from the REAL internet through the REAL
# service, and do its bytes match the hash the catalogue pins?
#
# WHAT THIS DOES NOT DO, said plainly because the first version of this header
# claimed it: there is no negative case here. That the hash check REJECTS bad
# bytes is proved in `ModelDownloaderTests`, where a tampered body is staged
# and the mismatch is seen. This script proves the positive path over the real
# network, which no unit test can.
#
# `xpc-smoke.sh` proves the mechanism against localhost. This proves the whole
# path once: HTTPS to huggingface.co, the pinned URL from
# `SpeechModelPins.swift`, the service's entitlement doing real work, and the
# destination-side SHA-256. It fetches the SMALLEST pinned file in the
# catalogue, a few hundred bytes, because the claim is about the path and not
# about bandwidth.
#
# IT WILL EARN A LULU PROMPT the first time, for `com.frolikov.afflow.models`.
# That prompt is expected: it is the one rule `lulu-rule-check.py` allows for
# the family while the downloader ships (open item 3, decided 2026-08-30). If
# nobody answers it the fetch times out and this reports that honestly rather
# than calling a blocked connection a failed hash.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
WORK="$(mktemp -d /tmp/af-flow-model-check.XXXXXX)"
APP_SOURCE="$REPO/build/app-derived/Build/Products/Debug/AF Flow.app"
IDENTITY="${AF_FLOW_SMOKE_IDENTITY:-Apple Development: andriy.frolikov@gmail.com (A75XPSV5W4)}"
SMOKE_ID="com.frolikov.afflow.xpcsmoke"
fail=0

cleanup() {
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [ -d "${APP:-}" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1
    rm -rf "$HOME/Library/Containers/$SMOKE_ID" "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
bad() { say "FAIL  $*"; fail=1; }

title="Does a real pinned model file arrive and verify"
say "$title"
say "$(printf '%.0s=' $(seq ${#title}))"

[ -d "$APP_SOURCE" ] || {
    say "COULD NOT CHECK: no debug build at $APP_SOURCE"
    say "Build it first: AF_FLOW_APP_BUILD=1 ./scripts/run-tests.sh"
    exit 2
}

# The smallest pin in the generated catalogue, read from the file rather than
# named here, so this cannot drift from what the app would actually fetch.
read -r REL URL SHA SIZE <<EOF
$(python3 - <<'PY'
import re
s = open("AFFlow/Transcription/SpeechModelPins.swift").read()
pins = re.findall(
    r'PinnedFile\(relativePath: "([^"]+)",\s*\n\s*url: URL\(string: "([^"]+)"\)!,'
    r'\s*\n\s*sha256: "([^"]+)",\s*\n\s*byteCount: (\d+)\)', s)
if not pins:
    raise SystemExit("no pins found in SpeechModelPins.swift")
rel, url, sha, size = min(pins, key=lambda p: int(p[3]))
print(rel, url, sha, size)
PY
)
EOF
[ -n "${URL:-}" ] || { say "COULD NOT CHECK: could not read a pin from SpeechModelPins.swift"; exit 2; }
say "ok    smallest pin: $SIZE bytes, $(basename "$REL")"

APP="$WORK/AF Flow.app"
cp -R "$APP_SOURCE" "$APP" || { say "COULD NOT CHECK: could not copy the app"; exit 2; }
MAIN_EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$APP/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$APP/Contents/Info.plist" >/dev/null
mkdir -p "$WORK/client"
cp "$REPO/scripts/xpc-smoke-client.swift" "$WORK/client/main.swift"
swiftc -O -o "$APP/Contents/MacOS/$MAIN_EXECUTABLE" \
    "$REPO/AFFlow/ModelDownload/ModelDownloadProtocol.swift" \
    "$WORK/client/main.swift" 2>"$WORK/build.log" \
    || { say "COULD NOT CHECK: the client did not compile"; sed -n 1,8p "$WORK/build.log"; exit 2; }
codesign --force --options runtime --entitlements "$REPO/AFFlowModels/AFFlowModels.entitlements" \
    --sign "$IDENTITY" "$APP/Contents/XPCServices/AF Flow Models.xpc" >/dev/null 2>&1 \
    || { say "COULD NOT CHECK: could not sign the service"; exit 2; }
codesign --force --options runtime --entitlements "$REPO/AFFlow/AFFlow.entitlements" \
    --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
    || { say "COULD NOT CHECK: could not sign the app copy"; exit 2; }

OUT="$WORK/client.out"
"$APP/Contents/MacOS/$MAIN_EXECUTABLE" "$URL" >"$OUT" 2>&1
sed 's/^/      /' "$OUT"
DEST=$(sed -n 's/^destination //p' "$OUT" | head -1)

# THE PAIR IS THE PROOF, not either half. A sandboxed process is refused DNS as
# well as sockets, so its error is a lookup failure (NSURLErrorDomain -1003)
# rather than EPERM, and that on its own is indistinguishable from being
# offline. What rules that out is the service reaching the SAME host seconds
# later: one process failed and one succeeded, in one run, against one name.
grep -q "^control denied" "$OUT" \
    && say "ok    the host's own fetch failed ($(sed -n 's/^control denied: //p' "$OUT"))" \
    || bad "the host's own fetch SUCCEEDED, so the sandbox did not apply and nothing below counts"

if grep -q "^service timed out\|^service connection invalidated" "$OUT"; then
    say "COULD NOT CHECK: the service never answered. A LuLu prompt for"
    say "  $SMOKE_ID or com.frolikov.afflow.models may be waiting on screen."
    exit 2
fi

if grep -q "^service wrote $SIZE$" "$OUT"; then
    say "ok    and the service reached that same host and fetched $SIZE bytes over HTTPS"
else
    bad "the service did not write the pinned byte count"
fi

if [ -n "$DEST" ] && [ -f "$DEST" ]; then
    GOT=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
    [ "$GOT" = "$SHA" ] \
        && say "ok    the bytes match the pinned SHA-256, checked where they landed" \
        || bad "the destination hash is $GOT, the catalogue pins $SHA"
else
    bad "no destination file was produced"
fi

say ""
if [ "$fail" -eq 0 ]; then
    say "RESULT: clean"
else
    say "RESULT: the pinned download path does not work end to end"
fi
exit "$fail"
