#!/bin/bash
# Makes Andrew's already-downloaded cleanup models visible to the test host.
#
# WHY THIS IS NEEDED. App-hosted unit tests run under their own sandbox container,
# `com.frolikov.afflow.testhost`, NOT the app's. `TextCleanupManager.modelsDirectory`
# resolves through `.applicationSupportDirectory`, so inside the test host it points
# at an empty directory, and every model-backed eval reports "not downloaded" and
# SKIPS. On 2026-08-21 that skip came back as `EXIT=0` from a run that measured
# nothing at all, which is this project's signature failure.
#
# The alternative the suite used before was to download the weights again, which is
# ledger item 24 and cost 3.8 GB in the test-host container.
#
# HARD LINKS, NOT COPIES. Same volume, same inodes, zero extra bytes. Deleting a link
# here can never delete his model: it drops the link count and nothing else. Models
# are replaced by download-to-temp-then-move, never written in place, so the app and
# the test host cannot corrupt each other's view.
set -euo pipefail

APP="$HOME/Library/Containers/com.frolikov.afflow/Data/Library/Application Support/AFFlow/models"
HOST="$HOME/Library/Containers/com.frolikov.afflow.testhost/Data/Library/Application Support/AFFlow/models"

if [ ! -d "$APP" ]; then
    echo "no models to link: $APP does not exist" >&2
    exit 1
fi

mkdir -p "$HOST"
linked=0
for model in "$APP"/*.gguf; do
    [ -e "$model" ] || continue
    name="$(basename "$model")"
    target="$HOST/$name"
    if [ -e "$target" ]; then
        # Same inode already? Then there is nothing to do and nothing to warn about.
        if [ "$(stat -f %i "$model")" = "$(stat -f %i "$target")" ]; then
            echo "already linked: $name"
            continue
        fi
        echo "present but a different file, leaving alone: $name"
        continue
    fi
    ln "$model" "$target"
    linked=$((linked + 1))
    echo "linked: $name"
done
echo "$linked model(s) linked into the test-host container. No bytes were copied."
