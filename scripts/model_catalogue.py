#!/usr/bin/env python3
"""The downloadable model catalogue, read from the app's own source.

WHY THIS EXISTS. The same reason `af_paths.py` reads the folder name out of
`AppSupportDirectory.swift` rather than repeating it: a second copy of a URL
and a hash is a second thing to update, and the copy that does not get updated
is the one that downloads the wrong file and passes its own check.

So this parses `TextCleanupManager.swift`, which is where Andrew's cleanup
models are declared with a pinned revision URL, a SHA-256 and an exact byte
count. Nothing here hardcodes a model. A model added in Swift appears here on
the next run; a hash changed in Swift changes here too.

Only hash-pinned models are listed. The speech models are fetched by WhisperKit
and FluidAudio from their own repositories, with no checksum published that
this project could pin, so a downloader whose whole contract is "verify the
checksum" cannot honestly claim to cover them. That gap is stated rather than
papered over: see `download-model.sh --help`.

Exit codes for the CLI: 0 ok, 2 the source could not be read or parsed.
"""

import argparse
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Overridable ONLY so the selftest can stage a catalogue that must be refused:
# a file name that climbs out of the models folder, a hash that is not a hash.
# A downloader whose refusals have never been seen is a downloader that has
# never refused. Nothing in the repo sets this.
SOURCE_OF_TRUTH = os.environ.get(
    "AF_FLOW_MODEL_CATALOGUE_SOURCE",
    os.path.join(REPO_ROOT, "AFFlow", "Cleanup", "TextCleanupManager.swift"),
)

# The folder the app loads GGUF cleanup models from, named in exactly one place
# in Swift: `AppSupportDirectory.url.appendingPathComponent("models")`.
MODELS_SUBFOLDER = "models"


class CatalogueUnreadable(RuntimeError):
    """The Swift source could not be read or did not declare what was expected."""


def _source():
    try:
        with open(SOURCE_OF_TRUTH, encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:
        raise CatalogueUnreadable(f"cannot read {SOURCE_OF_TRUTH}: {exc}")


def models():
    """Every hash-pinned model declared in Swift, as a list of dicts."""
    source = _source()
    out = []
    # Each descriptor is a `CleanupModelDescriptor(...)` literal. Fields are
    # pulled by name rather than by position, so reordering them in Swift does
    # not silently pair a name with another model's hash.
    for block in re.findall(r"CleanupModelDescriptor\((.*?)\n    \)", source, re.S):
        fields = {}
        for name in ("displayName", "fileName", "url", "expectedSHA256"):
            match = re.search(rf'{name}:\s*"([^"]+)"', block)
            if match:
                fields[name] = match.group(1)
        size = re.search(r"expectedByteCount:\s*([0-9_]+)", block)
        if size:
            fields["expectedByteCount"] = int(size.group(1).replace("_", ""))
        required = {"fileName", "url", "expectedSHA256", "expectedByteCount"}
        if required <= set(fields):
            out.append(fields)
        elif fields:
            # Codex, 2026-08-29: a descriptor that stopped using a literal for
            # one field (`expectedSHA256: compactModelHash`) was silently
            # dropped, and as long as another descriptor parsed, --list and
            # --verify reported clean while ignoring that model entirely. A
            # catalogue this cannot fully read is an unreadable catalogue.
            raise CatalogueUnreadable(
                "a CleanupModelDescriptor was only partly parsed, so a pinned "
                f"model would be silently ignored. Parsed {sorted(fields)}, "
                f"missing {sorted(required - set(fields))}. Fix this parser "
                "before trusting any download."
            )

    if not out:
        raise CatalogueUnreadable(
            f"{SOURCE_OF_TRUTH} declared no CleanupModelDescriptor this parser "
            "recognises. The Swift shape changed; fix this before trusting a download."
        )
    for model in out:
        if not re.fullmatch(r"[0-9a-f]{64}", model["expectedSHA256"]):
            raise CatalogueUnreadable(
                f"{model['fileName']} has a SHA-256 that is not 64 hex characters, "
                "so nothing downloaded for it could be verified."
            )
        # A file name is joined onto the models folder. Anything that could
        # climb out of it is a defect in the SOURCE, caught here rather than
        # after it has written somewhere it should not.
        name = model["fileName"]
        if os.path.basename(name) != name or name in (".", ".."):
            raise CatalogueUnreadable(
                f"{name!r} is not a plain file name, so it could write outside "
                "the models folder."
            )
    return out


def find(needle):
    """Match on file name, or a unique case-insensitive substring of it."""
    catalogue = models()
    for model in catalogue:
        if model["fileName"] == needle:
            return model
    hits = [m for m in catalogue if needle.lower() in m["fileName"].lower()]
    if len(hits) == 1:
        return hits[0]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="the whole catalogue as JSON")
    parser.add_argument("--field", help="print one field of --name")
    parser.add_argument("--name", help="a file name, or a unique part of one")
    args = parser.parse_args()
    try:
        if args.name:
            model = find(args.name)
            if model is None:
                sys.stderr.write(f"model_catalogue: no single model matches {args.name!r}\n")
                return 1
            print(model[args.field] if args.field else json.dumps(model, indent=2))
            return 0
        if args.json:
            print(json.dumps(models(), indent=2))
            return 0
        for model in models():
            gib = model["expectedByteCount"] / (1024 ** 3)
            print(f"{model['fileName']}  {gib:.2f} GiB  {model['displayName']}")
    except CatalogueUnreadable as exc:
        sys.stderr.write(f"model_catalogue: {exc}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
