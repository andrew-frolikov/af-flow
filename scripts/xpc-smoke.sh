#!/bin/bash
# Does the embedded XPC service really hold network access its host lacks?
#
# THIS IS THE SPIKE, KEPT. On 2026-09-06 a throwaway host proved that an
# embedded XPC service signed with `com.apple.security.network.client` fetches
# over a socket its sandboxed, network-denied host cannot open. The whole of
# Phase 4 rests on that, so it is a script that runs against the REAL bundle
# rather than a memory of a result.
#
# THE CONTROL IS THE POINT. The host's own fetch must FAIL. A run where both
# the host and the service succeed proves nothing: it means the sandbox was not
# applied, and the service's success is then unremarkable. So this script fails
# when the control succeeds, which is the opposite of how a smoke test usually
# reads and is the reason it is written down here.
#
# Local HTTP only. Nothing here talks to the internet, and no LuLu rule is
# earned by a connection to 127.0.0.1.
set -u
cd "$(dirname "$0")/.." || exit 2
REPO="$(pwd -P)"
PORT="${AF_FLOW_SMOKE_PORT:-8765}"
WORK="$(mktemp -d /tmp/af-flow-xpc-smoke.XXXXXX)"
APP_SOURCE="$REPO/build/app-derived/Build/Products/Debug/AF Flow.app"
IDENTITY="${AF_FLOW_SMOKE_IDENTITY:-Apple Development: andriy.frolikov@gmail.com (A75XPSV5W4)}"
fail=0

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    # Unregister before deleting: building and running registers the bundle,
    # and deleting it first strands a live record, which is the 2026-08-26
    # ordering failure release-build.sh already carries a comment about.
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [ -d "${APP:-}" ] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1
    [ -n "${SMOKE_ID:-}" ] && rm -rf "$HOME/Library/Containers/$SMOKE_ID"
    rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
bad() { say "FAIL  $*"; fail=1; }

title="Does the embedded service hold network access its host lacks"
say "$title"
say "$(printf '%.0s=' $(seq ${#title}))"

if [ ! -d "$APP_SOURCE" ]; then
    say "COULD NOT CHECK: no debug build at $APP_SOURCE"
    say "Build it first: AF_FLOW_APP_BUILD=1 ./scripts/run-tests.sh"
    exit 2
fi

# A 1 MB body, served from localhost.
mkdir -p "$WORK/www"
dd if=/dev/urandom of="$WORK/www/payload.bin" bs=1024 count=1024 2>/dev/null
EXPECTED_HASH=$(shasum -a 256 "$WORK/www/payload.bin" | cut -d' ' -f1)
# Started WITHOUT a subshell so $! is python's own pid. With a subshell the
# trap killed the shell and left the server listening, and the next run then
# failed on a port that was already answering.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null   # else the shell prints "Terminated" over the result
for _ in $(seq 20); do
    curl -fsS "http://127.0.0.1:$PORT/payload.bin" -o /dev/null 2>/dev/null && break
    sleep 0.25
done
curl -fsS "http://127.0.0.1:$PORT/payload.bin" -o /dev/null 2>/dev/null || {
    say "COULD NOT CHECK: the local server never answered on port $PORT"; exit 2
}
say "ok    local server serving 1 MB on 127.0.0.1:$PORT"

# The client BECOMES the copy's main executable, because two things are true
# and only the second one is obvious. An Application-type XPC service is found
# through its host BUNDLE, so the client has to live inside one. And the App
# Sandbox is applied to the bundle's CFBundleExecutable, so an extra binary
# dropped beside it runs UNSANDBOXED: the first version of this script did
# exactly that, and its control fetch succeeded, which is the script correctly
# refusing to certify a run that proved nothing.
APP="$WORK/AF Flow.app"
cp -R "$APP_SOURCE" "$APP" || { say "COULD NOT CHECK: could not copy the app"; exit 2; }
MAIN_EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$MAIN_EXECUTABLE" ] || { say "COULD NOT CHECK: the app copy has no CFBundleExecutable"; exit 2; }
# ITS OWN IDENTITY, never his app's. A second live bundle carrying
# `com.frolikov.afflow` is the 2026-07-26 failure that took his Input
# Monitoring grant and killed dictation for five hours; `run-tests.sh` gives the
# test host its own id for the same reason. This one is unregistered and its
# container is deleted when the script exits.
SMOKE_ID="com.frolikov.afflow.xpcsmoke"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SMOKE_ID" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || { say "COULD NOT CHECK: could not give the copy its own identity"; exit 2; }
# Copied to `main.swift`: Swift allows top-level statements only in a file
# with that name, and the client is deliberately a top-level script.
mkdir -p "$WORK/client"
cp "$REPO/scripts/xpc-smoke-client.swift" "$WORK/client/main.swift"
swiftc -O -o "$APP/Contents/MacOS/$MAIN_EXECUTABLE" \
    "$REPO/AFFlow/ModelDownload/ModelDownloadProtocol.swift" \
    "$WORK/client/main.swift" 2>"$WORK/build.log" || {
    say "COULD NOT CHECK: the smoke client did not compile"; sed -n 1,10p "$WORK/build.log"; exit 2
}

# Sign inner-first, the same order release-build.sh uses, and give the client
# the APP's entitlements so the control is the app's real sandbox.
codesign --force --options runtime --entitlements "$REPO/AFFlowModels/AFFlowModels.entitlements" \
    --sign "$IDENTITY" "$APP/Contents/XPCServices/AF Flow Models.xpc" 2>>"$WORK/sign.log" || {
    say "COULD NOT CHECK: could not sign the service"; tail -2 "$WORK/sign.log"; exit 2
}
codesign --force --options runtime --entitlements "$REPO/AFFlow/AFFlow.entitlements" \
    --sign "$IDENTITY" "$APP" 2>>"$WORK/sign.log" || {
    say "COULD NOT CHECK: could not sign the app copy"; tail -2 "$WORK/sign.log"; exit 2
}
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "network.client"; then
    bad "the host copy carries network.client, so the control below proves nothing"
fi
say "ok    signed: service with its own entitlements, host with the app's"

OUT="$WORK/client.out"
"$APP/Contents/MacOS/$MAIN_EXECUTABLE" "http://127.0.0.1:$PORT/payload.bin" >"$OUT" 2>&1
sed 's/^/      /' "$OUT"
# The client names its own destination, inside its container: a sandboxed
# process cannot open a file anywhere else, which is the mechanism under test.
DEST=$(sed -n 's/^destination //p' "$OUT" | head -1)

grep -q "^control denied" "$OUT" \
    && say "ok    the host itself was denied by the kernel (the control held)" \
    || bad "the host's own fetch was NOT denied; the sandbox did not apply and nothing below counts"

grep -q "^service wrote 1048576$" "$OUT" \
    && say "ok    the service fetched 1048576 bytes into the passed descriptor" \
    || bad "the service did not write the expected byte count"

if [ -n "$DEST" ] && [ -f "$DEST" ]; then
    GOT=$(shasum -a 256 "$DEST" | cut -d' ' -f1)
    [ "$GOT" = "$EXPECTED_HASH" ] \
        && say "ok    the destination hash matches what was served" \
        || bad "the destination hash is $GOT, expected $EXPECTED_HASH"
else
    bad "no destination file was produced"
fi

# ---- and again as a RESUME, which is the case nothing else exercises --------
#
# `python3 -m http.server` IGNORES `Range` and answers 200 with the whole body.
# Verified, not assumed, on 2026-09-07. That is precisely the server the service
# has to notice: appending a whole body after bytes already in the file
# produces a corrupt, oversized partial. The service truncates instead, so the
# destination must end up byte-identical to the served file even though it
# started with 64 bytes of junk in it.
OUT2="$WORK/client-resume.out"
"$APP/Contents/MacOS/$MAIN_EXECUTABLE" "http://127.0.0.1:$PORT/payload.bin" 64 >"$OUT2" 2>&1
sed 's/^/      /' "$OUT2"
DEST2=$(sed -n 's/^destination //p' "$OUT2" | head -1)
grep -q "^resuming from 64$" "$OUT2" \
    || bad "the resume case did not start from the 64 bytes staged in the file"
grep -q "^service wrote 1048576$" "$OUT2" \
    || bad "the service did not report writing the whole body after truncating"
if [ -n "$DEST2" ] && [ -f "$DEST2" ]; then
    GOT2=$(shasum -a 256 "$DEST2" | cut -d' ' -f1)
    [ "$GOT2" = "$EXPECTED_HASH" ] \
        && say "ok    a server that IGNORES Range still produces the right bytes" \
        || bad "resuming against a Range-ignoring server corrupted the file (got $GOT2)"
else
    bad "the resume case produced no file"
fi

# THE BUILD THIS RAN AGAINST IS A SECOND CLAIMANT. `build/app-derived` holds a
# bundle carrying `com.frolikov.afflow`, and while it exists his Input
# Monitoring grant can attach to it instead of to the app he launches: the
# 2026-07-26 failure, and `run-tests.sh` exits 9 rather than let it stand. So
# the reminder is here, next to the thing that needed the build.
if [ -d "$REPO/build/app-derived" ]; then
    say ""
    say "note  build/app-derived still claims com.frolikov.afflow. Before the suite:"
    say "      LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    say "      \"\$LSR\" -u \"$REPO/build/app-derived/Build/Products/Debug/AF Flow.app\" && rm -rf \"$REPO/build/app-derived\""
fi

say ""
if [ "$fail" -eq 0 ]; then
    say "RESULT: clean"
else
    say "RESULT: the service does not do what Phase 4 assumes"
fi
exit "$fail"
