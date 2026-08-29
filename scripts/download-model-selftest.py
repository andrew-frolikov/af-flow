#!/usr/bin/env python3
"""Stage each state `download-model.sh` must distinguish, and watch it react.

The point of that script is that it REFUSES: a hash that does not match, a file
name that climbs out of the models folder, a good file it would otherwise
clobber. A refusal that has never been seen is not a refusal, so each one is
staged here against the real script, with a synthesised catalogue and a
`file://` URL so nothing has to be fetched over the network.

Exit 0 all states distinguished, 1 otherwise.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "download-model.sh")

results = []


def check(label, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if detail and not condition:
        print("        " + str(detail).replace("\n", "\n        "))
    return bool(condition)


def swift_catalogue(path, entries):
    """A stand-in for TextCleanupManager.swift holding only what the parser reads."""
    blocks = []
    for e in entries:
        blocks.append(f'''    static let m{len(blocks)} = CleanupModelDescriptor(
        kind: .k,
        displayName: "{e['display']}",
        sizeDescription: "~1 KB",
        fileName: "{e['file']}",
        url: "{e['url']}",
        expectedSHA256: "{e['sha']}",
        expectedByteCount: {e['bytes']},
        maxTokenCount: 4096,
        recommendation: nil
    )''')
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("class TextCleanupManager {\n" + "\n\n".join(blocks) + "\n}\n")


def run(models_dir, catalogue, *args):
    env = dict(os.environ,
               AF_FLOW_MODELS_DIR=models_dir,
               AF_FLOW_MODEL_CATALOGUE_SOURCE=catalogue)
    return subprocess.run(["bash", SCRIPT, *args], cwd=REPO, env=env,
                          capture_output=True, text=True)


def main():
    work = tempfile.mkdtemp(prefix="af-flow-download-selftest-")
    try:
        if not check("0. the script under test exists", os.path.exists(SCRIPT)):
            return 1

        payload = b"a pinned model file, for testing only\n" * 7
        digest = hashlib.sha256(payload).hexdigest()
        source = os.path.join(work, "upstream.gguf")
        with open(source, "wb") as handle:
            handle.write(payload)

        models_dir = os.path.join(work, "models")
        os.makedirs(models_dir)
        good = os.path.join(work, "good.swift")
        swift_catalogue(good, [{
            "display": "Test Model", "file": "Test-Model.gguf",
            "url": "file://" + source, "sha": digest, "bytes": len(payload),
        }])

        # 1. The happy path: fetched, verified, installed under the right name.
        proc = run(models_dir, good, "Test-Model")
        landed = os.path.join(models_dir, "Test-Model.gguf")
        check("1. a matching download is installed, exit 0",
              proc.returncode == 0, proc.stdout + proc.stderr)
        check("1. the file landed in the models folder", os.path.exists(landed))
        if os.path.exists(landed):
            check("1. the installed bytes are the pinned bytes",
                  hashlib.sha256(open(landed, "rb").read()).hexdigest() == digest)
        check("1. it says it verified against the pinned hash",
              "verified" in proc.stdout, proc.stdout)

        # 2. Already present and correct: does not re-fetch.
        stamp = os.stat(landed).st_mtime_ns
        proc = run(models_dir, good, "Test-Model")
        check("2. an already-verified file is left alone, exit 0", proc.returncode == 0)
        check("2. it was not rewritten", os.stat(landed).st_mtime_ns == stamp)

        # 3. A WRONG HASH must be refused, and must leave nothing behind. This
        #    is the guarantee the whole script exists for.
        bad = os.path.join(work, "bad.swift")
        swift_catalogue(bad, [{
            "display": "Tampered", "file": "Tampered.gguf",
            "url": "file://" + source, "sha": "0" * 64, "bytes": len(payload),
        }])
        proc = run(models_dir, bad, "Tampered")
        check("3. a hash that does not match -> exit 1",
              proc.returncode == 1, proc.stdout + proc.stderr)
        check("3. nothing was written when the hash did not match",
              not os.path.exists(os.path.join(models_dir, "Tampered.gguf")))
        leftovers = [f for f in os.listdir(models_dir) if "partial" in f]
        check("3. no partial file was left behind", not leftovers, str(leftovers))
        check("3. the refusal names the pinned hash",
              "0000" in (proc.stdout + proc.stderr), proc.stdout + proc.stderr)

        # 4. A byte count that does not match is refused too, even if nothing
        #    else looks wrong. Two independent checks, not one.
        wrongsize = os.path.join(work, "wrongsize.swift")
        swift_catalogue(wrongsize, [{
            "display": "Short", "file": "Short.gguf",
            "url": "file://" + source, "sha": digest, "bytes": len(payload) + 1,
        }])
        proc = run(models_dir, wrongsize, "Short")
        check("4. a byte count that does not match -> exit 1", proc.returncode == 1,
              proc.stdout + proc.stderr)
        check("4. nothing was written when the size did not match",
              not os.path.exists(os.path.join(models_dir, "Short.gguf")))

        # 5. CONTAINMENT. A catalogue entry that climbs out of the folder is
        #    refused by the catalogue reader, before any network call.
        escape = os.path.join(work, "escape.swift")
        swift_catalogue(escape, [{
            "display": "Escape", "file": "../escaped.gguf",
            "url": "file://" + source, "sha": digest, "bytes": len(payload),
        }])
        proc = run(models_dir, escape, "escaped")
        check("5. a file name climbing out of the folder -> exit 2",
              proc.returncode == 2, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("5. nothing was written outside the models folder",
              not os.path.exists(os.path.join(work, "escaped.gguf")))

        absolute = os.path.join(work, "absolute.swift")
        swift_catalogue(absolute, [{
            "display": "Absolute", "file": "/tmp/af-flow-escaped.gguf",
            "url": "file://" + source, "sha": digest, "bytes": len(payload),
        }])
        proc = run(models_dir, absolute, "escaped")
        check("5. an absolute path in the catalogue -> exit 2", proc.returncode == 2,
              f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("5. it did not write to that absolute path",
              not os.path.exists("/tmp/af-flow-escaped.gguf"))

        # 6. A file on disk that is WRONG is not silently overwritten, and is
        #    not silently accepted either.
        with open(landed, "wb") as handle:
            handle.write(b"corrupted on disk")
        proc = run(models_dir, good, "Test-Model")
        check("6. a corrupt file on disk -> exit 1, not a silent refetch",
              proc.returncode == 1, proc.stdout + proc.stderr)
        check("6. the corrupt file was NOT overwritten without --force",
              open(landed, "rb").read() == b"corrupted on disk")
        proc = run(models_dir, good, "--force", "Test-Model")
        check("7. --force replaces a corrupt file, exit 0", proc.returncode == 0,
              proc.stdout + proc.stderr)
        check("7. the replacement is the pinned content",
              hashlib.sha256(open(landed, "rb").read()).hexdigest() == digest)

        # 8. --verify reports, and goes red when something is wrong.
        proc = run(models_dir, good, "--verify")
        check("8. --verify is clean when the file is right", proc.returncode == 0,
              proc.stdout)
        os.unlink(landed)
        proc = run(models_dir, good, "--verify")
        check("8. --verify goes red when a file is missing", proc.returncode == 1,
              proc.stdout)

        # 9. An unparseable catalogue is its own answer, never "nothing pinned".
        broken = os.path.join(work, "broken.swift")
        with open(broken, "w", encoding="utf-8") as handle:
            handle.write("class TextCleanupManager { }\n")
        proc = run(models_dir, broken, "--list")
        check("9. a catalogue that declares nothing -> exit 2, not 0",
              proc.returncode == 2, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")

        # 10. A name matching two models is ambiguous, so it is refused rather
        #     than guessed at.
        two = os.path.join(work, "two.swift")
        swift_catalogue(two, [
            {"display": "A", "file": "Model-A.gguf", "url": "file://" + source,
             "sha": digest, "bytes": len(payload)},
            {"display": "B", "file": "Model-B.gguf", "url": "file://" + source,
             "sha": digest, "bytes": len(payload)},
        ])
        proc = run(models_dir, two, "Model")
        check("10. an ambiguous name is refused, not guessed", proc.returncode == 1,
              proc.stdout + proc.stderr)

        # 11. A descriptor that is only PARTLY parseable must fail the whole
        #     catalogue. Silently skipping it makes --verify report clean about
        #     a model it never looked at.
        partial = os.path.join(work, "partial.swift")
        with open(partial, "w", encoding="utf-8") as handle:
            handle.write("""class TextCleanupManager {
    static let good = CleanupModelDescriptor(
        kind: .k,
        displayName: "Good",
        sizeDescription: "~1 KB",
        fileName: "Good.gguf",
        url: "file://%s",
        expectedSHA256: "%s",
        expectedByteCount: %d,
        maxTokenCount: 4096,
        recommendation: nil
    )

    static let hidden = CleanupModelDescriptor(
        kind: .k,
        displayName: "Hidden",
        sizeDescription: "~1 KB",
        fileName: "Hidden.gguf",
        url: "file://%s",
        expectedSHA256: hiddenModelHash,
        expectedByteCount: %d,
        maxTokenCount: 4096,
        recommendation: nil
    )
}
""" % (source, digest, len(payload), source, len(payload)))
        proc = run(models_dir, partial, "--list")
        check("11. a half-parsed descriptor fails the catalogue -> exit 2",
              proc.returncode == 2, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("11. it does not quietly list only the model it could read",
              "Good.gguf" not in proc.stdout, proc.stdout)

        # 12. Verified, but the install did not land: must not report success.
        blocked = os.path.join(models_dir, "Test-Model.gguf")
        if os.path.exists(blocked):
            os.unlink(blocked)
        os.makedirs(blocked)  # mv onto a directory cannot produce the file
        proc = run(models_dir, good, "Test-Model")
        check("12. a file that verifies but does not install -> exit 1",
              proc.returncode == 1, f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}")
        check("12. it does not claim the model was installed",
              "and installed" not in proc.stdout, proc.stdout)

        print()
        print("ALL STATES DISTINGUISHED" if all(results)
              else "SOME STATES NOT DISTINGUISHED")
        return 0 if all(results) else 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
