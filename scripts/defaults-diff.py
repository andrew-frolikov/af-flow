#!/usr/bin/env python3
"""Compare the defaults stored on Andrew's machine against the defaults in code.

WHY THIS EXISTS. Ledger item 7 says `speechModel` has no migration, so once the
key exists a new default can never reach him. That is not one key, it is a
CLASS: this app calls `registerDefaults` exactly zero times, so every default
lives as a fallback at its read site (`@AppStorage("k") var x = someDefault`, or
`... ?? someDefault`). A fallback is only consulted when the key is ABSENT. The
moment a key is written once, the value in the code stops being a default and
becomes dead text, and every later improvement to it is invisible to him and
invisible to the tests, which start from an empty domain.

It cuts both ways, and that is the point of printing rather than fixing. The
hotkey lesson of 2026-08-02: his stored Globe-plus-Left-Control binding
disagreed with the spec because it encoded a constraint the spec was written
without, and "correcting" it broke his dictation. So a disagreement here is
evidence, not drift. Some of these know something the code does not.

WHAT IT CANNOT DO, stated so nobody reads more into the output than is there:

- It is a regex over source, not a compile. A default that is an expression
  (`TextCleaner.defaultPrompt`) cannot be evaluated here and is reported as
  UNKNOWN rather than guessed at.
- It only sees keys reachable by these patterns. A key built at runtime by
  string interpolation is invisible to it.
- "Stored but unread" can be a key read only through a pattern this misses. It
  is a prompt to look, not a verdict.
"""

import os
import plistlib
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(REPO, "AFFlow")
BUNDLE_ID = "com.frolikov.afflow"
PLIST = os.path.expanduser(
    "~/Library/Containers/%s/Data/Library/Preferences/%s.plist" % (BUNDLE_ID, BUNDLE_ID)
)

# THE KEY IS NOT ALWAYS A LITERAL ANY MORE. On 2026-08-30
# `meetingTranscriptEnabled` became `@AppStorage(MeetingsVisibility.defaultsKey)`
# so that one file spells the v1 scope gate, and this scanner, which only
# matched a quoted string, silently stopped seeing the key: the report went from
# "1 frozen" to "0 frozen" with nothing saying a key had been dropped. The same
# indirection this file already resolves for `forKey:` is now resolved here.
APPSTORAGE = re.compile(
    r'@AppStorage\(\s*(?:"(?P<literal>[^"]+)"|(?:\w+\.)?(?P<const>\w*[Kk]ey))\s*\)\s*'
    r'(?:private\s+)?var\s+\w+\s*:\s*(?P<type>[\w\[\]\.<>?]+)\s*=\s*(?P<default>.+?)\s*(?:\{|$)',
    re.MULTILINE,
)
# `static let fooKey = "actualKey"` so `forKey: Self.fooKey` can be resolved.
KEY_CONST = re.compile(r'(?:static\s+)?(?:private\s+)?let\s+(\w*[Kk]ey)\s*(?::\s*String\s*)?=\s*"([^"]+)"')
FOR_KEY_LITERAL = re.compile(r'forKey:\s*"([^"]+)"')
FOR_KEY_CONST = re.compile(r'forKey:\s*(?:Self\.|\w+\.)?(\w*[Kk]ey)\b')

LITERAL = re.compile(r'^(true|false|-?\d+(?:\.\d+)?|"[^"]*")$')


def swift_files():
    for dirpath, _, names in os.walk(SOURCE_DIR):
        for name in sorted(names):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def scan_source():
    """Returns (declared, referenced, constants, all_declarations)."""
    declared, referenced, constants, all_declarations = {}, set(), {}, {}
    pending = []
    for path in swift_files():
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        for name, value in KEY_CONST.findall(text):
            constants[name] = value
        for match in APPSTORAGE.finditer(text):
            default = match.group("default")
            where = "%s:%d" % (
                os.path.relpath(path, REPO),
                text[: match.start()].count("\n") + 1,
            )
            key = match.group("literal")
            if key is None:
                # The constant may live in a file scanned later, so this is
                # resolved in the second pass below rather than dropped.
                pending.append((match.group("const"), default.strip(), where))
                continue
            declared.setdefault(key, (default.strip(), where))
            all_declarations.setdefault(key, []).append((default.strip(), where))
            referenced.add(key)
        referenced.update(FOR_KEY_LITERAL.findall(text))
        for name in FOR_KEY_CONST.findall(text):
            if name in constants:
                referenced.add(constants[name])
    # A constant may be defined after its use; resolve once more.
    for path in swift_files():
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        for name in FOR_KEY_CONST.findall(text):
            if name in constants:
                referenced.add(constants[name])

    # Unresolvable is not "absent". A constant this cannot resolve means the
    # scan does not know what key that declaration writes, and reporting the
    # rest as if it were the whole picture is how the report went from 1 frozen
    # to 0 frozen without anyone noticing.
    for name, default, where in pending:
        if name not in constants:
            print("WARNING: %s declares @AppStorage(%s) and that constant could "
                  "not be resolved, so its key is missing from everything below."
                  % (where, name))
            continue
        key = constants[name]
        declared.setdefault(key, (default, where))
        all_declarations.setdefault(key, []).append((default, where))
        referenced.add(key)
    return declared, referenced, constants, all_declarations


def stored_values():
    if os.path.exists(PLIST):
        try:
            with open(PLIST, "rb") as handle:
                return plistlib.load(handle), PLIST
        except Exception:
            pass
    # Fall back to `defaults export`, which also sees values the cfprefsd
    # daemon has not yet flushed to disk.
    try:
        out = subprocess.run(
            ["defaults", "export", BUNDLE_ID, "-"],
            capture_output=True, timeout=20,
        )
        if out.returncode == 0 and out.stdout.strip():
            return plistlib.loads(out.stdout), "defaults export %s" % BUNDLE_ID
    except Exception:
        pass
    return None, None


def render(value, limit=58):
    text = repr(value)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def literal_matches(default_src, stored):
    """True/False when comparable, None when the default is an expression."""
    if not LITERAL.match(default_src):
        return None
    if default_src in ("true", "false"):
        return stored == (default_src == "true")
    if default_src.startswith('"'):
        return stored == default_src[1:-1]
    try:
        return abs(float(stored) - float(default_src)) < 1e-9
    except (TypeError, ValueError):
        return False


def main():
    declared, referenced, _, all_declarations = scan_source()
    stored, source = stored_values()

    print("defaults-diff")
    print("=" * 13)
    print("code: %d @AppStorage defaults, %d keys referenced in %s" % (
        len(declared), len(referenced), os.path.relpath(SOURCE_DIR, REPO)))
    if stored is None:
        # Source-only mode. The CONFLICT check below needs no machine state, and
        # it is the only thing here that can fail a build, so a machine without
        # the app installed still gets the check that matters.
        print("disk: no stored defaults found; running the source-only checks")
        stored = {}
    else:
        print("disk: %d keys, from %s" % (len(stored), source))
    print()

    frozen, agreeing, unknown = [], [], []
    for key, (default_src, where) in sorted(declared.items()):
        if key not in stored:
            continue
        verdict = literal_matches(default_src, stored[key])
        if verdict is None:
            unknown.append((key, default_src, stored[key], where))
        elif verdict:
            agreeing.append(key)
        else:
            frozen.append((key, default_src, stored[key], where))

    # A key declared twice with DIFFERENT defaults is an unambiguous bug: which
    # one applies depends on which view happens to initialise first while the key
    # is absent. This project has already shipped one (meetingSummaryPrompt,
    # fixed 2026-07-29 with a migration), so it is worth a standing check.
    conflicts = {k: v for k, v in all_declarations.items()
                 if len({d for d, _ in v}) > 1}
    print("## CONFLICTING DEFAULTS for one key (%d)" % len(conflicts))
    print("   Which applies depends on which view initialises first. Always a bug.")
    if conflicts:
        for key, decls in sorted(conflicts.items()):
            print("  %s" % key)
            for default_src, where in decls:
                print("      %-40s %s" % (render(default_src, 40), where))
    else:
        print("  none")
    print()

    print("## FROZEN: stored value differs from the code's default")
    print("   Each is a setting where changing the default in code can never reach him.")
    print("   Some of these are HIS choice and must not be touched. Ask before 'fixing'.")
    print()
    if frozen:
        for key, default_src, value, where in frozen:
            print("  %-34s code=%-22s his=%s" % (key, render(default_src, 22), render(value)))
            print("  %-34s %s" % ("", where))
    else:
        print("  none")
    print()

    print("## UNKNOWN: the code default is an expression, so it cannot be compared here")
    if unknown:
        for key, default_src, value, where in unknown:
            print("  %-34s code=%-22s his=%s" % (key, render(default_src, 22), render(value)))
    else:
        print("  none")
    print()

    orphans = sorted(k for k in stored if k not in referenced and not k.startswith("NS")
                     and not k.startswith("Apple") and not k.startswith("com.apple"))
    print("## STORED BUT NOT FOUND IN SOURCE (%d)" % len(orphans))
    print("   A prompt to look, not a verdict: a key built at runtime is invisible here.")
    for key in orphans:
        print("  %-40s %s" % (key, render(stored[key], 40)))
    print()

    never = sorted(k for k in declared if k not in stored)
    print("## DECLARED IN CODE, NEVER WRITTEN (%d)" % len(never))
    print("   These still get the code default, so a change to it DOES reach him.")
    print("  " + (", ".join(never) if never else "none"))
    print()
    print("agreeing with the code default: %d" % len(agreeing))
    print()
    print("RESULT: %d frozen, %d unknown, %d orphaned, %d conflicting"
          % (len(frozen), len(unknown), len(orphans), len(conflicts)))
    # Only a conflict is unambiguously wrong. A frozen value is often HIS choice,
    # so this must not fail a build over one.
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main())
