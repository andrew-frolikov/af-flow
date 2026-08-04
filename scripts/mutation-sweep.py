#!/usr/bin/env python3
"""Break the dictation path on purpose and see whether the suite notices.

WHY. The suite is 703 tests and green, and that number has repeatedly meant
nothing. In one week it missed a language prior that never ran, a cleanup model
repeating its whole answer, ten hotkey presses that did nothing, and two audio
loss bugs introduced while fixing audio loss. Worse than missing them, it
ASSERTED some of them: a test pinned 22 seconds of the far side's speech being
deleted as correct, a helper test passed while the window bug was live, and ten
tests passed on a repeat fix that was never wired up. On 2026-08-03, two of six
tests written that morning passed with the bug still installed, and six whole
test FILES turned out never to have run at all.

So the question is not "do the tests pass" but "which of them are load-bearing".
The only way to answer it is to install a defect and watch.

WHAT IT DOES. Each mutation below is a hand-written, plausible bug on the
dictation path, chosen so it is guaranteed to compile. For each: apply, run the
full suite, revert, record whether any test failed.

  KILLED    at least one test failed. Something is guarding that line.
  SURVIVED  the whole suite passed with the bug installed. Nothing guards it.

A SURVIVED result is not automatically a missing test. Some lines genuinely do
not warrant one. It is a list of places where a real defect would ship silently,
which is a different and more useful thing than a coverage percentage.

SAFETY. Refuses to run on a dirty tree, because it cannot safely revert what it
cannot distinguish from its own edits. Restores via `git checkout` after every
mutation and again in a finally, so an interrupt cannot leave a bug in the tree.
"""

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (id, relative path, exact source to find, replacement, what bug this imitates)
MUTATIONS = [
    ("lang-both-boundary", "GhostPepper/Transcription/ModelManager.swift",
     'return english * englishPrior >= russian * russianPrior ? "en" : "ru"',
     'return english * englishPrior > russian * russianPrior ? "en" : "ru"',
     "a tie between the two priors now resolves to Russian instead of English"),

    ("lang-one-scored-unreachable", "GhostPepper/Transcription/ModelManager.swift",
     "if english != nil || russian != nil {",
     "if english != nil && russian != nil {",
     "the one-scored path stops running, which is the ORIGINAL 2026-08-02 bug"),

    ("lang-ignore-the-winner", "GhostPepper/Transcription/ModelManager.swift",
     'return english != nil ? "en" : "ru"',
     'return "en"',
     "his Russian is always decoded as English"),

    ("silence-gate-100x", "GhostPepper/Transcription/ModelManager.swift",
     "nonisolated static let silenceRMSThreshold: Float = 0.001",
     "nonisolated static let silenceRMSThreshold: Float = 0.1",
     "quiet but real speech is discarded as silence"),

    ("silence-gate-inverted", "GhostPepper/Transcription/ModelManager.swift",
     "return (sumOfSquares / Float(samples.count)).squareRoot() < silenceRMSThreshold",
     "return (sumOfSquares / Float(samples.count)).squareRoot() > silenceRMSThreshold",
     "only silence is transcribed, and speech is dropped"),

    ("repeat-guard-inverted", "GhostPepper/Cleanup/TextCleaner.swift",
     "guard text.count >= repetitionCheckMinimumCharacters else { return output }",
     "guard text.count <= repetitionCheckMinimumCharacters else { return output }",
     "the duplicate-answer guard runs only on short text, so the 2026-08-02 double paste returns"),

    ("comma-restore-inverted", "GhostPepper/Cleanup/TextCleaner.swift",
     'guard cleaned.filter({ $0 == "," }).count < spoken.filter({ $0 == "," }).count else {',
     'guard cleaned.filter({ $0 == "," }).count > spoken.filter({ $0 == "," }).count else {',
     "commas are restored only when the cleanup ADDED them, so his stripped commas stay stripped"),

    ("census-positive-count", "GhostPepper/Transcription/ModelManager.swift",
     "let positive = probabilities.values.filter { $0 > 0 }.count",
     "let positive = 0",
     "the census always reports log probabilities, hiding a change in the model's output"),

    ("meeting-name-app-first", "GhostPepper/Meeting/MeetingDetector.swift",
     'return "\\(formatter.string(from: date)) \\(appName)"',
     'return "\\(appName) \\(formatter.string(from: date))"',
     "meeting files go back to sorting by app name instead of time"),

    ("lab-wipe-on-decode-error", "GhostPepper/Lab/TranscriptionLabStore.swift",
     "            quarantineUnreadableFile(at: indexURL)\n            return []",
     "            resetStoredArchive()\n            return []",
     "a corrupt index deletes his whole dictation archive again"),
]


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, **kw)


def tree_is_clean():
    return run(["git", "status", "--porcelain"]).stdout.strip() == ""


def suite_failures():
    """Returns (ran, failures, names). ran=False if the build broke.

    `names` is the authority, not `failures`. Counts come from whichever
    "Executed N tests" line happened to be largest, and on 2026-08-03 that
    produced a FALSE SURVIVED: `repeat-guard-inverted` was reported as
    uncaught while running that mutation by hand failed two tests immediately.
    A harness that under-reports coverage is worse than none, because it sends
    you writing tests that already exist.
    """
    out = run(["./scripts/run-tests.sh"], timeout=3600).stdout
    totals = re.findall(r"Executed (\d+) tests, with (\d+) failure", out)
    if not totals:
        return False, 0, []
    # The LARGEST executed-count line is the whole-suite total; take its failure
    # count from the same line rather than maxing the two independently.
    ran, failures = max(((int(a), int(b)) for a, b in totals), key=lambda t: t[0])
    names = sorted(set(re.findall(r"Test Case '-\[(\S+) (\S+)\]' failed", out)))
    return ran, failures, ["%s.%s" % n for n in names]


def main():
    if not tree_is_clean():
        print("refusing to run: the working tree is dirty.")
        print("This applies and reverts source edits with `git checkout`, so it")
        print("cannot tell your changes from its own. Commit or stash first.")
        return 1

    print("mutation-sweep")
    print("=" * 14)
    print("baseline: running the suite unmodified")
    baseline_ran, baseline, baseline_names = suite_failures()
    if not baseline_ran:
        print("the suite did not run. Is AF Flow open?")
        return 1
    print("  %d tests, %d pre-existing failure(s): %s"
          % (baseline_ran, baseline, ", ".join(baseline_names) or "none"))
    print()

    # An optional name filter, so a suspect result can be re-checked without
    # paying for the whole sweep again.
    wanted = set(sys.argv[1:])
    selected = [m for m in MUTATIONS if not wanted or m[0] in wanted]
    if wanted:
        print("running %d of %d mutations: %s"
              % (len(selected), len(MUTATIONS), ", ".join(m[0] for m in selected)))
        print()

    killed, survived, broken = [], [], []
    try:
        for index, (name, path, old, new, why) in enumerate(selected, 1):
            full = os.path.join(REPO, path)
            source = open(full, encoding="utf-8").read()
            if old not in source:
                print("[%d/%d] %-28s SKIPPED, the target text is gone"
                      % (index, len(selected), name))
                broken.append((name, "target text not found; the code moved"))
                continue

            open(full, "w", encoding="utf-8").write(source.replace(old, new, 1))
            # Confirm the edit is actually on disk before spending a build on it.
            # A write that silently did nothing would look exactly like a test
            # gap, which is the most expensive way for this tool to be wrong.
            if new not in open(full, encoding="utf-8").read():
                run(["git", "checkout", "--", path])
                print("[%d/%d] %-28s NOT APPLIED, skipping" % (index, len(selected), name), flush=True)
                broken.append((name, "the mutation did not reach the file"))
                continue

            try:
                ran, failures, names = suite_failures()
            finally:
                run(["git", "checkout", "--", path])

            new_names = [n for n in names if n not in baseline_names]

            if not ran:
                print("[%d/%d] %-28s DID NOT COMPILE" % (index, len(selected), name), flush=True)
                broken.append((name, "the mutation does not build"))
            elif new_names:
                # A test that did not fail at baseline and fails now is the only
                # evidence that counts. Immune to a flaky pre-existing failure
                # flipping, which a bare count comparison is not.
                print("[%d/%d] %-28s KILLED by %d test(s)"
                      % (index, len(selected), name, len(new_names)), flush=True)
                killed.append((name, why, new_names))
            elif ran != baseline_ran:
                # Fewer or more tests executed than at baseline, so the two runs
                # are not comparable and "nothing new failed" proves nothing. A
                # trap takes the whole bundle down and xcodebuild then reports a
                # total for a subset, with nothing saying so.
                print("[%d/%d] %-28s UNRELIABLE, ran %d vs baseline %d"
                      % (index, len(selected), name, ran, baseline_ran), flush=True)
                broken.append((name, "ran %d tests against a baseline of %d" % (ran, baseline_ran)))
            else:
                print("[%d/%d] %-28s *** SURVIVED ***" % (index, len(selected), name), flush=True)
                survived.append((name, why))
    finally:
        for _, path, _, _, _ in selected:
            run(["git", "checkout", "--", path])

    print()
    print("## SURVIVED: a real defect here would ship silently (%d)" % len(survived))
    for name, why in survived:
        print("  %s" % name)
        print("      %s" % why)
    print()
    print("## KILLED: something is guarding this (%d)" % len(killed))
    for name, _why, names in killed:
        print("  %-28s %s" % (name, ", ".join(names[:3]) + ("..." if len(names) > 3 else "")))
    if broken:
        print()
        print("## COULD NOT BE TESTED (%d)" % len(broken))
        for name, reason in broken:
            print("  %-28s %s" % (name, reason))
    print()
    total = len(killed) + len(survived)
    if total:
        print("RESULT: %d of %d mutations caught (%d%%)"
              % (len(killed), total, round(100.0 * len(killed) / total)))
    # Informational: a survivor is a finding to read, not a build break.
    return 0


if __name__ == "__main__":
    sys.exit(main())
