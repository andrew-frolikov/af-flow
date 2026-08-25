#!/usr/bin/env bash
# Rebuild the public source snapshot of AF Flow from this repository's HEAD.
#
# WHY THIS IS A SCRIPT. The public copy is a SUBSET of this repo with private
# material removed, and "removed" has to mean the same thing every time. Done by
# hand it drifts: one rebuild forgets voice-observations.md, the next leaks an
# absolute path, and nothing tells anyone. A leak is also not reversible, because
# a public repository can be cloned the moment it exists.
#
# The snapshot has NO history. It is a single commit of the current tree, so this
# repo's journal, which contains real dictation samples, never leaves the Mac.
#
#   scripts/build-public-snapshot.sh [destination]
#
# Default destination is ../af-flow-public. The destination is REBUILT: its
# working tree and its git history are replaced.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DST="${1:-$(dirname "$SRC")/af-flow-public}"

cd "$SRC"
if [ -n "$(git status --porcelain)" ]; then
    echo "refusing: $SRC has uncommitted changes, so HEAD is not what you are looking at" >&2
    exit 1
fi

echo "==> source $SRC at $(git rev-parse --short HEAD) on $(git branch --show-current)"
echo "==> destination $DST"

rm -rf "$DST"
mkdir -p "$DST"
git archive HEAD | tar -x -C "$DST"

cd "$DST"

# 1. Private material. The journals hold his real dictation; the contract and
#    state files describe how he works, not how the app works.
rm -rf .scratch .claude .handoff
rm -f CLAUDE.md LOOP.md STATE.md PROGRESS.md HANDOVER.md TESTS.md \
      cleanup-prompt-v1.md voice-observations.md PRIVACY_AUDIT.md \
      docs/pre-deploy-privacy-security.md

# 2. Tooling that enforces his working process, or reads his personal sources.
#    Each of these depends on a file removed above, so shipping them would ship
#    a script that cannot run.
rm -f scripts/banned-symbol-sweep.sh scripts/state-check.py \
      scripts/spec-provenance-check.py scripts/session-start.sh \
      scripts/extract_granola.py scripts/add-incumbent-transcripts.py \
      scripts/build-verdict-page.py scripts/build-reference-worksheet.py \
      scripts/build-public-snapshot.sh

# 3. His identity and absolute paths, which are fine in a private repo and are
#    not fine in a public one. Defaults are dropped, not replaced with someone
#    else's values.
python3 - <<'PY'
import pathlib, re
p = pathlib.Path("scripts/audiotap-probe/build.sh")
if p.exists():
    t = p.read_text()
    t = re.sub(
        r'IDENTITY="Apple Development:[^"]*"',
        '# Set AF_FLOW_SIGN_IDENTITY to your own signing identity.\n'
        '# `security find-identity -v -p codesigning` lists what this Mac has.\n'
        'IDENTITY="${AF_FLOW_SIGN_IDENTITY:-Apple Development}"',
        t)
    p.write_text(t)

for name in ("scripts/render-af-flow-icon.swift", "scripts/render-af-flow-menubar-marks.swift"):
    p = pathlib.Path(name)
    if not p.exists(): continue
    t = p.read_text()
    t = re.sub(r'let brand = "/Users/[^"]*"',
               'let brand = ProcessInfo.processInfo.environment["AF_FLOW_BRAND_DIR"] ?? "brand"',
               t)
    p.write_text(t)

for name in ("docs/design/af-flow-visual-system.md", "docs/design/af-flow-home-hero.md"):
    p = pathlib.Path(name)
    if not p.exists(): continue
    t = p.read_text()
    t = re.sub(r'`/Users/[^`]*brand-visual\.md`',
               "the author's private brand canon, which is not part of this repository", t)
    t = re.sub(r'from `/Users/[^`]*`', 'from the brand asset directory', t)
    p.write_text(t)
PY

# 4. The public front matter. LICENSE and THIRD-PARTY-NOTICES come across from
#    the source repo unchanged, because attribution is a licence condition.
cat > README.md <<'EOF'
# AF Flow

A fully local macOS dictation app. Hold a key, speak, release, and cleaned-up
text is on your clipboard ready to paste into whatever you are working in.

Speech recognition and text cleanup both run on your own Mac. No account, no
API key, no telemetry, nothing sent anywhere for processing.

## What this is, and what it is not

This was built for one person, in English and Russian, and it is shared as
source because it may be useful to someone else, not because it is a product.

Read this part before you spend an evening on it:

- **There is no download.** No signed build, no `.dmg`, no installer. Shipping a
  ready-to-run Mac app requires a paid Apple Developer membership, and this
  project does not have one. You build it yourself in Xcode.
- **It is tuned to one voice.** The cleanup model is prompted for a native
  Russian and Ukrainian speaker writing in English, and it is deliberately
  conservative about "correcting" that register. Your results will differ.
- **Languages are English and Russian only.** Not a limitation of the engine, a
  deliberate setting: unrestricted language detection made mixed speech worse.
- **Meetings are rough.** Dictation is the finished part. The meeting capture
  and summarisation subsystem works but has known open defects.

## Requirements

- macOS 14.0 or later, Apple Silicon.
- Xcode 16 or later.
- About 4 GB of disk for models, downloaded on first use.

## Build

```
open AFFlow.xcodeproj
```

Press Cmd+R. Or from the terminal:

```
xcodebuild -project AFFlow.xcodeproj -scheme AFFlow build
```

On first launch macOS asks for Microphone access. Grant it. The first time you
select a speech model, it downloads once from Hugging Face and is checked
against a known hash before use. After that it runs from the local cache, and
dictation works with Wi-Fi switched off.

## How it works

| Stage | What runs |
|---|---|
| Speech to text | WhisperKit, on device |
| Cleanup | a small local LLM through LLM.swift, on device |
| Delivery | the cleaned text goes to your clipboard, and you press Cmd+V |

Delivery is deliberate. AF Flow does not insert text into the focused field for
you, so you decide where it lands and nothing can paste into the wrong window.

## Known limitations of the sandbox

AF Flow runs inside the macOS App Sandbox, which is a real boundary on an app
that has your microphone. The cost is that Accessibility APIs are unavailable
to it: they return `AXError -25204` on every query, on every build, no matter
what permissions you grant.

Four things are therefore broken by design and no permission grant will fix
them. This is documented rather than hidden, because the app used to send its
own author into System Settings three times for nothing:

- learning from what you edit after pasting
- ending a meeting automatically based on window state
- naming a meeting from the window title
- the stale permission warning

Removing the sandbox would restore all four. That is a considered trade, not an
oversight.

## Privacy

See [PRIVACY.md](PRIVACY.md).

## Licence

MIT. AF Flow began as a fork, and the upstream author's copyright travels with
it: see [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## Support

None. This is published as source, as is. Issues may go unread.
EOF

cat > PRIVACY.md <<'EOF'
# Privacy

AF Flow is a fully local macOS dictation app. This file states the privacy
posture in plain terms, including the part that has not been verified.

## What holds

- **Fully local processing.** Speech to text (WhisperKit) and text cleanup (a
  local LLM through LLM.swift) both run on device. No audio and no text is sent
  anywhere to be processed.
- **Nothing to log in to.** AF Flow has no account, and no live code path asks
  you for a key, a token or a password. See "The dead code" below, which states
  this precisely rather than as a slogan.
- **No auto updater.** The updater the upstream project shipped is gone: the
  package dependency, the code and the update feed keys were all removed.
- **No screen recording.** The code path that could have requested Screen
  Recording permission was removed, and the built app links no screen capture
  framework.
- **No telemetry.** No analytics and no crash reporting SDK is present.
- **Model downloads are one time and hash verified.** The first time you select
  a speech or cleanup model it downloads once from Hugging Face and is checked
  against a known hash before use. After that it runs from the local cache.

## The dead code, stated plainly

The repository still contains cloud integration code inherited from the
upstream project it was forked from: a Google Calendar client, a Granola
importer, an Airtable importer, an Anthropic API provider, a web page reader,
and a Keychain helper that could store a secret for them.

None of it is wired up. The rule this project holds itself to is not "the code
is absent", it is **no live code path constructs a cloud client**, and that is
checked mechanically on every change in the private working repository. Two of
those files are referenced from live code and both references were verified: the
Google Calendar mention is a comment explaining the removal, and the one Granola
function called is a pure local dictionary parser that performs no network
access.

The files are scheduled for deletion. Until then this is the honest statement:
dead code that cannot run, not an absence.

## What has not been verified

**Network egress has not been measured.** The intended check is to run a
default-deny firewall such as LuLu, confirm that only the model host is
contacted during the one-time download, and confirm that dictation still works
completely with Wi-Fi switched off.

Until that has been run, "fully local" describes the code, not a measured
result. Treat it accordingly. Anyone is welcome to run the check and report
what they find.

## Where your data sits

Meeting audio, when the meeting subsystem is used, is written to Application
Support with a 7 day retention. Dictation history is appended to a local log.
Both stay on your Mac. Neither is uploaded and neither is encrypted at rest
beyond whatever FileVault gives you, so turn FileVault on.
EOF

# 5. Refuse to finish if anything private survived. A snapshot that leaks is
#    worse than no snapshot, so this is a gate, not a warning.
python3 - <<'PY'
import os, pathlib, re, sys

private = re.compile(r'andriy\.frolikov|andriifrolikov|A75XPSV5W4|/Users/andrii|AndrewFrolikov OS')
leaks = []
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d != ".git"]
    for f in files:
        p = os.path.join(root, f)
        if pathlib.Path(p).suffix in {".png", ".jpg", ".mp4", ".ttf"}:
            continue
        try:
            t = pathlib.Path(p).read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        for i, line in enumerate(t.splitlines(), 1):
            if private.search(line):
                leaks.append(f"{p}:{i}: {line.strip()[:110]}")

for name in ("PROGRESS.md", "voice-observations.md", "CLAUDE.md", "STATE.md"):
    if pathlib.Path(name).exists():
        leaks.append(f"private file survived: {name}")
if pathlib.Path("testimonials").exists():
    leaks.append("private file survived: testimonials/")

if leaks:
    print("SNAPSHOT REFUSED, private material present:", file=sys.stderr)
    for l in leaks:
        print("  " + l, file=sys.stderr)
    sys.exit(1)
print("gate: no personal identifiers, no private files")
PY

git init -q
git add -A
git -c user.name="Andrew Frolikov" -c user.email="andriy.frolikov@gmail.com" \
    commit -q -m "AF Flow: public source snapshot

A fully local macOS dictation app, published as source only.

No history is carried over from the private working repository, which
holds real dictation samples and a personal build journal."

echo "==> snapshot built: $(git rev-list --count HEAD) commit, $(git ls-files | wc -l | tr -d ' ') files"
