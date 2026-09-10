#!/usr/bin/env python3
"""Generate AFFlow/Transcription/SpeechModelPins.swift from the Hugging Face Hub.

WHY THIS EXISTS. WhisperKit fetches a model by NAME and publishes no checksum,
so the speech models were the one thing this project downloaded on trust. The
launch plan's open item 2 says the helper must not ship unpinned downloads, and
this is how they get pinned.

WHAT COSTS A DOWNLOAD AND WHAT DOES NOT. The Hub's tree API returns, for every
LFS file, an `lfs.oid` that IS the SHA-256 of the content, so the big weights
are pinned without fetching a byte. The remaining files (metadata.json,
model.mil, config.json and the tokenizer files, tens of MB per variant) are
stored in git, whose oid is a SHA-1, so they are downloaded ONCE here and
hashed. That is the whole network cost of running this script.

REVISIONS ARE COMMITS, NEVER BRANCHES. Every URL is `/resolve/<commit sha>/`,
the same discipline `TextCleanupManager.cleanupModels` already uses. A branch
name would let the bytes move under a pinned hash and break every download at
once, silently, on a friend's Mac.

WHICH VARIANTS. Read from `QualityTier.swift` rather than listed here: the
ladder decides what ships, and a second list is how the two drift apart. The
tokenizer repo is WhisperKit's own mapping and cannot be derived from the
catalogue, so it is spelled out below with the reason.

REFUSES rather than writing a half-pinned file: any file without a 64-hex
digest and a positive size stops the run before the Swift file is touched.

Usage:  python3 scripts/speech-model-pins.py [--out PATH] [--variant NAME ...]
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

HUB = "https://huggingface.co"
COREML_REPO = "argmaxinc/whisperkit-coreml"
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# WhisperKit keeps a model in TWO places: the Core ML files it compiles against
# under `argmaxinc/whisperkit-coreml/<variant>`, and the tokenizer from the
# ORIGINAL OpenAI repo under `openai/<repo>`. The tokenizer lands at exactly the
# repo's own path, which is what his live cache shows.
#
# THE TRAP, and it cost a release-gate fix on 2026-09-06 and a broken Starter
# load on 2026-09-10: `cachePathComponents` is NOT the tokenizer folder. It once
# was, for tiny, small and small.en, while naming the Core ML folder for turbo,
# and the loader handed that mixed field to WhisperKit. Since 2026-09-10 it
# names the Core ML folder for every WhisperKit model. The tokenizer destination
# is derived from the repo name below, never from that field.
TOKENIZER_REPO = {
    "openai_whisper-small": "openai/whisper-small",
    "openai_whisper-small.en": "openai/whisper-small.en",
    "openai_whisper-tiny.en": "openai/whisper-tiny.en",
    "openai_whisper-large-v3-v20240930_turbo_632MB": "openai/whisper-large-v3",
    "openai_whisper-large-v3_turbo_954MB": "openai/whisper-large-v3",
}
TOKENIZER_FILES = ("config.json", "tokenizer.json", "tokenizer_config.json")

TIMEOUT = 120
DEFAULT_OUT = os.path.join(REPO_ROOT, "AFFlow/Transcription/SpeechModelPins.swift")


class Refused(Exception):
    """Something is not pinnable. Nothing is written."""


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "af-flow-pin-generator"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read()


def head_commit(repo):
    return json.loads(get(f"{HUB}/api/models/{repo}"))["sha"]


def tree(repo, revision, path=""):
    url = f"{HUB}/api/models/{repo}/tree/{revision}/{path}?recursive=true"
    return [entry for entry in json.loads(get(url)) if entry["type"] == "file"]


def ladder_variants():
    """The speech models the ladder ships, read from QualityTier.swift.

    Returns [(variant name, Core ML folder)]. The second value is the
    catalogue's `cachePathComponents`, carried only so the generator can assert
    the pins fill the folder the app loads from; it is NOT the tokenizer
    destination. Same resolution `release-build.sh` does.
    """
    quality = open(os.path.join(REPO_ROOT, "AFFlow/QualityTier.swift")).read()
    catalog = open(os.path.join(REPO_ROOT, "AFFlow/Transcription/SpeechModelCatalog.swift")).read()
    symbols = re.findall(r"(?:starter|full)SpeechModelID\s*=\s*SpeechModelCatalog\.(\w+)\.id", quality)
    if len(symbols) != 2:
        raise Refused(f"QualityTier.swift named {len(symbols)} speech symbols, expected 2")
    found = []
    for symbol in symbols:
        block = re.search(r"static let " + symbol + r" = SpeechModelDescriptor\((.*?)\n    \)", catalog, re.S)
        if not block:
            raise Refused(f"SpeechModelCatalog.swift has no descriptor for {symbol}")
        name = re.search(r'\bname:\s*"([^"]+)"', block.group(1))
        cache = re.search(r"cachePathComponents:\s*\[([^\]]*)\]", block.group(1))
        if not name or not cache:
            raise Refused(f"{symbol} has no name or no cachePathComponents")
        folder = "/".join(part.strip().strip('"') for part in cache.group(1).split(","))
        found.append((name.group(1), folder))
    return found


# What may appear in a path this script turns into a URL and into a Swift string
# literal. Everything else is REFUSED rather than escaped, because the set of
# characters a model file legitimately uses is small and known: a `#` or `?`
# would silently truncate the fetched path (a 404 at install time, not here),
# and a quote or backslash would produce a Swift file that does not compile.
# Independent review, 2026-09-07.
SAFE_PATH = re.compile(r"^[A-Za-z0-9._/-]+$")


def pinned(repo, revision, hub_path, entry, relative):
    for label, value in (("hub path", hub_path), ("destination", relative)):
        if not SAFE_PATH.match(value):
            raise Refused(
                f"{label} {value!r} holds a character this generator will not "
                f"put in a URL or a Swift literal. Widen SAFE_PATH deliberately "
                f"if the Hub has started using it.")
    url = f"{HUB}/{repo}/resolve/{revision}/{urllib.parse.quote(hub_path)}"
    lfs = entry.get("lfs") or {}
    digest = lfs.get("oid")
    if not digest:
        # Stored in git: its oid is a SHA-1, so the bytes have to be seen.
        digest = hashlib.sha256(get(url)).hexdigest()
    size = int(entry.get("size") or 0)
    if len(digest) != 64 or not re.fullmatch(r"[0-9a-f]{64}", digest) or size <= 0:
        raise Refused(f"{hub_path}: digest {digest!r}, size {size}. Not pinnable.")
    return {"relativePath": relative, "url": url, "sha256": digest, "byteCount": size}


def collect(variants):
    revisions = {COREML_REPO: head_commit(COREML_REPO)}
    files = {}
    for variant, cache_folder in variants:
        repo = TOKENIZER_REPO.get(variant)
        if not repo:
            raise Refused(f"no tokenizer repo recorded for {variant}; add it to TOKENIZER_REPO")
        revisions.setdefault(repo, head_commit(repo))
        pins = []
        entries = tree(COREML_REPO, revisions[COREML_REPO], variant)
        if not entries:
            raise Refused(f"{COREML_REPO} has no files under {variant}")
        for entry in entries:
            pins.append(pinned(COREML_REPO, revisions[COREML_REPO], entry["path"], entry,
                               f"whisper-models/models/argmaxinc/whisperkit-coreml/{entry['path']}"))
        tokenizer_entries = {e["path"]: e for e in tree(repo, revisions[repo])}
        for name in TOKENIZER_FILES:
            if name not in tokenizer_entries:
                raise Refused(f"{repo} has no {name}")
            # The tokenizer lands at the REPO's own path, never at
            # `cachePathComponents`: see the note on TOKENIZER_REPO.
            pins.append(pinned(repo, revisions[repo], name, tokenizer_entries[name],
                               f"whisper-models/models/{repo}/{name}"))
        # `cachePathComponents` must name exactly this variant's Core ML folder,
        # the one the loader hands WhisperKit. Equality, not coverage: every
        # Core ML pin is generated under that path, so a coverage check could
        # never fail, and the tokenizer folder is covered too, which is the
        # mixed meaning that broke the Starter load on 2026-09-10.
        expected_folder = f"argmaxinc/whisperkit-coreml/{variant}"
        if cache_folder != expected_folder:
            raise Refused(f"{variant}: cachePathComponents is {cache_folder}, expected {expected_folder}")
        # Two files landing at one path would silently drop one of them.
        seen = {}
        for pin in pins:
            if pin["relativePath"] in seen:
                raise Refused(f"two files both land at {pin['relativePath']}")
            seen[pin["relativePath"]] = True
        files[variant] = pins
        total = sum(pin["byteCount"] for pin in pins)
        print(f"  {variant}: {len(pins)} files, {total / 1e6:.0f} MB", file=sys.stderr)
    return revisions, files


def render(revisions, files):
    out = ["// GENERATED by scripts/speech-model-pins.py. Do not edit by hand;",
           "// re-run the script, which reads the ladder from QualityTier.swift.",
           "//",
           "// Every URL names a COMMIT, so the bytes behind a pinned hash cannot move.",
           "// LFS digests come from the Hub's tree API; the plain files were downloaded",
           "// once and hashed, because git stores a SHA-1 and this needs a SHA-256.",
           "import Foundation",
           "",
           "enum SpeechModelPins {",
           "    static let hubRevisions: [String: String] = ["]
    for repo, revision in sorted(revisions.items()):
        out.append(f'        "{repo}": "{revision}",')
    out += ["    ]", "", "    static let files: [String: [PinnedFile]] = ["]
    for variant in sorted(files):
        out.append(f'        "{variant}": [')
        for pin in files[variant]:
            out.append(f'            PinnedFile(relativePath: "{pin["relativePath"]}",')
            out.append(f'                       url: URL(string: "{pin["url"]}")!,')
            out.append(f'                       sha256: "{pin["sha256"]}",')
            out.append(f'                       byteCount: {pin["byteCount"]}),')
        out.append("        ],")
    out += ["    ]", "}", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--variant", action="append",
                        help="pin this variant instead of the ladder's (repeatable, for testing)")
    args = parser.parse_args()
    try:
        if args.variant:
            # Testing path: no cache-test folder is known, so the coverage
            # assertion is satisfied by the Core ML folder itself. It REFUSES
            # to write the real file, because a one-variant run replacing the
            # ladder's pins is a half-pinned catalogue that only the Swift
            # tests would catch. Independent review, 2026-09-07.
            if os.path.abspath(args.out) == os.path.abspath(DEFAULT_OUT):
                raise Refused("--variant is for testing and will not overwrite "
                              f"{DEFAULT_OUT}. Pass --out somewhere else.")
            variants = [(name, f"argmaxinc/whisperkit-coreml/{name}") for name in args.variant]
        else:
            variants = ladder_variants()
        print(f"pinning {len(variants)} variant(s) from {HUB}", file=sys.stderr)
        revisions, files = collect(variants)
    except Refused as error:
        sys.stderr.write(f"REFUSED: {error}\nNothing was written.\n")
        return 3
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError, ValueError) as error:
        sys.stderr.write(f"COULD NOT READ THE HUB: {error}\nNothing was written.\n")
        return 2
    with open(args.out, "w") as handle:
        handle.write(render(revisions, files))
    print(f"wrote {args.out}", file=sys.stderr)
    for repo, revision in sorted(revisions.items()):
        print(f"  {repo} @ {revision}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
