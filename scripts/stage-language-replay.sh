#!/bin/zsh
# Stages his dictation archive and the whisper model into the TEST HOST's own
# container, so LanguageReplayTests can read them.
#
# The test host is sandboxed into a separate container and cannot read his real
# archive, which is why this exists rather than the test just opening the files.
# Everything here is a COPY: his archive is never written to.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$(python3 "$HERE/af_paths.py" --print app)"
TH="$(python3 "$HERE/af_paths.py" --print testhost)"
LAB="$(python3 "$HERE/af_paths.py" --print app --find transcription-lab)"
WHISPER="$(python3 "$HERE/af_paths.py" --print app --find whisper-models)"
MODEL="openai_whisper-large-v3-v20240930_turbo_632MB"

[ -d "$LAB" ] || { echo "no dictation archive at $LAB"; exit 1; }

mkdir -p "$TH/replay/audio" "$TH/whisper-models/models/argmaxinc/whisperkit-coreml"
cp "$LAB/transcription-lab-index.json" "$TH/replay/"
cp "$LAB/audio/"*.wav "$TH/replay/audio/" 2>/dev/null || true
rsync -a "$WHISPER/models/argmaxinc/whisperkit-coreml/$MODEL" \
         "$TH/whisper-models/models/argmaxinc/whisperkit-coreml/"

echo "staged $(ls "$TH/replay/audio" | wc -l | tr -d ' ') recordings and the $MODEL model"
echo
echo "now run, with AF Flow quit:"
echo "  TEST_RUNNER_AF_FLOW_LANGUAGE_REPLAY=1 ./scripts/run-tests.sh -only-testing:AFFlowTests/LanguageReplayTests"
echo "  (the TEST_RUNNER_ prefix is required; xcodebuild strips it. Without it the test SKIPS and still reports success.)"
echo "then:"
echo "  python3 scripts/language-replay.py"
