#!/bin/bash
# Measures fabrication in meeting summaries, using the SAME checker the test suite
# uses. Compiles GhostPepperTests/SummaryFabrication.swift directly, so no Xcode
# build and no model load is needed: this reads summaries that already exist.
#
# Usage:  ./scripts/summary-fabrication-report.sh <dir-of-meeting-notes> [more dirs]
#         AF_FLOW_MEETING_NOTES=<dir> ./scripts/summary-fabrication-report.sh
#
# THE OUTPUT CONTAINS ANDREW'S REAL MEETING CONTENT. Do not redirect it into the
# repository; write it to a scratch directory outside the tree.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# swiftc only allows top-level code in a file called main.swift, and the driver
# has to live in scripts/ under its own name to be findable. Copy, do not rename.
cp "$REPO/scripts/summary-fabrication-main.swift" "$WORK/main.swift"

swiftc -O "$REPO/GhostPepperTests/SummaryFabrication.swift" "$WORK/main.swift" -o "$WORK/report"

"$WORK/report" "$@"
