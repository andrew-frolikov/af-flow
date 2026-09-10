#!/bin/bash
# Builds the AF Flow audio-tap probe twice: once with AF Flow's real sandbox
# entitlements, once without. Same source, same signing identity, so any
# difference in the result is attributable to the sandbox and nothing else.
#
# Deliberately built outside the Xcode project. The shipping app is not touched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Build output goes OUTSIDE the repo. An app bundle inside the repo is the trap
# that cost Andrew five hours of dead hotkey (ledger 20 and 21), and the cheapest
# way never to reason about it again is to put no bundle there at all.
OUT="${TMPDIR:-/tmp}/afflow-audiotap-probe"
# Set AF_FLOW_SIGN_IDENTITY to your own signing identity.
# `security find-identity -v -p codesigning` lists what this Mac has.
IDENTITY="${AF_FLOW_SIGN_IDENTITY:-Apple Development}"

build_variant() {
    local variant="$1"        # sandboxed | unsandboxed
    # A SCRATCH identity, not the product's. This probe must ask for audio
    # capture, which is the one thing the canon rule says a throwaway must never
    # do (docs/design/af-flow-system-list-names.md section B), and it has no way
    # around it: the question it answers is whether the SANDBOX blocks the tap,
    # so it cannot run inside the sandboxed app or the test host. So it takes the
    # rule's second belt instead. On 2026-08-25 the earlier version of this
    # script, which used `com.frolikov.afflow.tapprobe.$variant` and called
    # itself "AF Flow audio tap probe ($variant)", had left two permanent rows
    # in Andrew's privacy settings holding GRANTED audio capture for bundles
    # that no longer existed, both wearing his product's name.
    local bundle_id="com.frolikov.scratch.audiotap.$variant"
    local app="$OUT/$variant/AudioTapProbe.app"

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"

    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>AudioTapProbe</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle_id</string>
	<key>CFBundleName</key>
	<string>scratch-audiotap-$variant</string>
	<key>CFBundleDisplayName</key>
	<string>scratch-audiotap-$variant</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.4</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>A scratch build is checking whether the App Sandbox blocks system audio capture. Audio only; this never captures your screen.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>A scratch build is checking system audio capture.</string>
</dict>
</plist>
PLIST

    # The sandboxed variant carries AF Flow's real entitlements, so it is
    # constrained exactly as the shipping app is.
    if [ "$variant" = "sandboxed" ]; then
        cat > "$OUT/$variant/probe.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
ENT
    else
        cat > "$OUT/$variant/probe.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
ENT
    fi

    swiftc -O \
        -target arm64-apple-macos14.4 \
        -o "$app/Contents/MacOS/AudioTapProbe" \
        "$HERE/main.swift"

    codesign --force \
        --sign "$IDENTITY" \
        --entitlements "$OUT/$variant/probe.entitlements" \
        --options runtime \
        "$app" >/dev/null 2>&1

    echo "built: $app"
    codesign -d --entitlements - "$app" 2>/dev/null | grep -q "app-sandbox" \
        && echo "       sandbox: ON" \
        || echo "       sandbox: OFF"
}

mkdir -p "$OUT/sandboxed" "$OUT/unsandboxed"
build_variant sandboxed
build_variant unsandboxed
