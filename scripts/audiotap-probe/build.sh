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
IDENTITY="Apple Development: andriy.frolikov@gmail.com (A75XPSV5W4)"

build_variant() {
    local variant="$1"        # sandboxed | unsandboxed
    local bundle_id="com.frolikov.afflow.tapprobe.$variant"
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
	<string>AF Flow audio tap probe ($variant)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.4</string>
	<key>LSBackgroundOnly</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>AF Flow is checking whether it can transcribe the other participants in a meeting. Audio only; this never captures your screen.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>AF Flow is checking system audio capture.</string>
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
