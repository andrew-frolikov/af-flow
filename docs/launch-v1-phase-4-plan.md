# Phase 4: the model downloader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Full tier's models reach `<App Support>` on a friend's Mac through an XPC service that holds the only network entitlement in the bundle, with every byte hash-pinned and verified where it lands, while the main app stays kernel-denied forever.

**Architecture:** `Contents/XPCServices/AF Flow Models.xpc` (bundle id `com.frolikov.afflow.models`, App Sandbox + `network.client`, nothing else) streams one URL at a time into a file descriptor the app opens in its own container and passes over `NSXPCConnection`; the app verifies SHA-256 and byte count at the destination and deletes a mismatch. The spike of 2026-09-06 proved the mechanism on this Mac (host EPERM, service 200, bytes read back). Speech models are pinned per FILE at a fixed Hub revision, the same discipline `TextCleanupManager.cleanupModels` already applies to the cleanup GGUFs, and both catalogues are read by the same downloader through one `PinnedFile` shape.

**Tech Stack:** Swift 5, Foundation `URLSession` (delegate-based, resumable via `Range`), `NSXPCConnection`, `CryptoKit.SHA256`, XCTest; Python 3.9 for the catalogue and the pin-generation script; `scripts/release-build.sh` for the bundle.

## Global Constraints

- The main app NEVER regains `com.apple.security.network.client` (launch plan, hard rules). `bundle-boundary-check.py` and `banned-symbol-sweep.sh` already refuse it; they stay green throughout.
- The service's entitlements are EXACTLY `com.apple.security.app-sandbox` and `com.apple.security.network.client` (open items doc, 4D).
- Bundle id `com.frolikov.afflow.models`, `CFBundleName` and `CFBundleDisplayName` both "AF Flow Models" (CLAUDE.md hard rule 11; `lulu_rules.HELPER_ID`).
- No xcodegen on this machine: `project.pbxproj` is the truth and `project.yml` describes it; `build-config-check.py` refuses the two to disagree. Every target change edits BOTH.
- One description of where a model lives: the app's (`AppSupportDirectory`, `ModelManager.whisperModelsDirectory`, `TextCleanupManager` `models/`). The downloader writes to paths the app computes, never to paths it computes itself.
- Verify at the DESTINATION, never at the source (`download-model.sh` lesson, `StarterModelInstaller`).
- Every guarantee has a test seen failing first. Codex reviews each task; if Codex is at its limit, a Claude reviewer that did not write the code, recorded in PROGRESS.md.
- Tests need AF Flow quit; run `./scripts/run-tests.sh -only-testing:AFFlowTests/<Class>` per task and the full suite before each commit. Expected full-suite baseline: 1082 tests, 3 known failures (`AnthropicProviderSSETests`, `IndexEntryFileTests`, `MeetingQAToolsTests`), plus the `PostPasteLearningCoordinatorTests` flake (ledger 27).

---

## File structure

| File | Responsibility |
|---|---|
| `AFFlow/Models/PinnedFile.swift` (create) | The one shape both catalogues produce: relative destination path, URL, SHA-256, byte count. |
| `AFFlow/Transcription/SpeechModelPins.swift` (create, GENERATED) | Per-file pins for each WhisperKit variant and its tokenizer repo, at a fixed Hub revision. Written by `scripts/speech-model-pins.py`, never by hand. |
| `scripts/speech-model-pins.py` (create) | Reads the Hub tree API at a pinned revision, takes LFS SHA-256s as given, downloads the few plain files once to hash them, and emits `SpeechModelPins.swift`. Refuses to emit if any file lacks a hash. |
| `AFFlow/Transcription/SpeechModelCatalog.swift` (modify) | Each WhisperKit descriptor gains `hubRevision` and `tokenizerRepo`, and a `pinnedFiles` accessor that joins the pins. |
| `AFFlow/Cleanup/TextCleanupManager.swift` (modify, small) | `LocalCleanupModelDescriptor.pinnedFile` accessor. |
| `AFFlow/ModelDownload/ModelDownloadProtocol.swift` (create) | The `@objc` XPC protocol, shared by app and service. |
| `AFFlowModels/main.swift` (create) | The service: listener, one `fetch(url, into:, resumingFrom:, reply:)`, progress callbacks, nothing else. |
| `AFFlowModels/Info.plist`, `AFFlowModels/AFFlowModels.entitlements` (create) | Identity and the two entitlements. |
| `AFFlow/ModelDownload/ModelDownloader.swift` (create) | App side: opens the destination, drives the service, verifies at the destination, resumes partial files, reports progress. |
| `AFFlow/ModelDownload/TierInstaller.swift` (create) | Turns a `QualityTier` into the list of `PinnedFile`s not yet present, runs them through `ModelDownloader`, and reports "stayed on Starter because …". |
| `AFFlowTests/PinnedFileTests.swift`, `ModelDownloaderTests.swift`, `TierInstallerTests.swift` (create) | Tests. The service is tested through a `Fetching` protocol with a fake; the real service is exercised once by `scripts/xpc-smoke.sh` against a local HTTP server. |
| `scripts/xpc-smoke.sh` (create) | Builds, signs, runs the REAL service inside the REAL app bundle against `python3 -m http.server`, asserts host EPERM and service 200. The spike, kept. |
| `scripts/release-build.sh` (modify) | Signs the service before the app; `bundle-boundary-check.py` gains the service's expected entitlements. |
| `scripts/lulu-rule-check.py` | Already expects the helper's rule while it ships (done 2026-09-06). No change. |
| `project.yml`, `AFFlow.xcodeproj/project.pbxproj` (modify) | New target `AFFlowModels`, type `xpc-service`, embedded in `AFFlow`. |

Not in this plan (later phases): the Settings retry UI beyond one button, onboarding's model screen (Phase 5), the Home card (Phase 6).

---

### Task 1: `PinnedFile`, and both catalogues speaking it

**Files:**
- Create: `AFFlow/Models/PinnedFile.swift`
- Modify: `AFFlow/Cleanup/TextCleanupManager.swift` (add one computed property on `LocalCleanupModelDescriptor`)
- Test: `AFFlowTests/PinnedFileTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct PinnedFile: Equatable, Hashable {
      let relativePath: String   // relative to AppSupportDirectory.url, e.g. "models/Qwen3.5-0.8B-Q4_K_M.gguf"
      let url: URL
      let sha256: String         // 64 lowercase hex
      let byteCount: Int64
      var destination: URL { AppSupportDirectory.url.appendingPathComponent(relativePath) }
  }
  extension LocalCleanupModelDescriptor { var pinnedFile: PinnedFile { get } }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AFFlow

final class PinnedFileTests: XCTestCase {
    /// Both catalogues must produce the SAME shape, so the downloader has one
    /// code path and one verification. The cleanup catalogue already carries
    /// URL, hash and size; this pins the mapping into `models/<fileName>`,
    /// which is where `StarterModelInstaller.pinnedExpectations()` and
    /// `TextCleanupManager` both look.
    func testEveryCleanupModelBecomesAPinnedFileUnderModels() {
        for descriptor in TextCleanupManager.cleanupModels {
            let pin = descriptor.pinnedFile
            XCTAssertEqual(pin.relativePath, "models/" + descriptor.fileName)
            XCTAssertEqual(pin.sha256, descriptor.expectedSHA256.lowercased())
            XCTAssertEqual(pin.byteCount, descriptor.expectedByteCount)
            XCTAssertEqual(pin.url.absoluteString, descriptor.url)
            XCTAssertEqual(pin.sha256.count, 64, "\(descriptor.fileName) has a hash that is not 64 hex characters")
        }
    }

    func testDestinationIsUnderAppSupport() {
        let pin = PinnedFile(relativePath: "models/x.gguf", url: URL(string: "https://example.invalid/x")!,
                             sha256: String(repeating: "a", count: 64), byteCount: 1)
        XCTAssertEqual(pin.destination, AppSupportDirectory.url.appendingPathComponent("models/x.gguf"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/PinnedFileTests`
Expected: build failure, `cannot find type 'PinnedFile'`.

- [ ] **Step 3: Write minimal implementation**

`AFFlow/Models/PinnedFile.swift`:
```swift
import Foundation

/// One downloadable file, pinned. Both catalogues produce this and the
/// downloader consumes only this, so there is ONE verification path and one
/// place that says where a file lands: `relativePath` under
/// `AppSupportDirectory.url`, the same root `StarterModelInstaller` mirrors.
struct PinnedFile: Equatable, Hashable {
    let relativePath: String
    let url: URL
    let sha256: String
    let byteCount: Int64

    var destination: URL { AppSupportDirectory.url.appendingPathComponent(relativePath) }
}
```

In `TextCleanupManager.swift`, after the `LocalCleanupModelDescriptor` definition:
```swift
extension LocalCleanupModelDescriptor {
    /// The cleanup catalogue already pins URL, SHA-256 and byte count; this is
    /// the same fact in the shape the downloader reads.
    var pinnedFile: PinnedFile {
        PinnedFile(relativePath: "models/" + fileName,
                   url: URL(string: url)!,
                   sha256: expectedSHA256.lowercased(),
                   byteCount: expectedByteCount)
    }
}
```
Add `AFFlow/Models/PinnedFile.swift` and the test file to the pbxproj (`test-registration-check.py` refuses an unregistered test file). Register by copying the `StarterModelInstaller.swift` entries from commit 4560b47's pbxproj diff and changing the names and UUIDs.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/PinnedFileTests`
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add AFFlow/Models/PinnedFile.swift AFFlow/Cleanup/TextCleanupManager.swift AFFlowTests/PinnedFileTests.swift AFFlow.xcodeproj/project.pbxproj
git commit -m "PinnedFile: one shape for every downloadable byte, produced by the cleanup catalogue first"
```

---

### Task 2: speech-model pins, generated from the Hub at a fixed revision (open item 2)

**Files:**
- Create: `scripts/speech-model-pins.py`
- Create: `AFFlow/Transcription/SpeechModelPins.swift` (generated)
- Modify: `AFFlow/Transcription/SpeechModelCatalog.swift`
- Test: `AFFlowTests/SpeechModelPinsTests.swift`

**Interfaces:**
- Consumes: `PinnedFile` (Task 1).
- Produces:
  ```swift
  enum SpeechModelPins {
      static let hubRevisions: [String: String]        // repo -> commit sha, e.g. "argmaxinc/whisperkit-coreml": "<40 hex>"
      static let files: [String: [PinnedFile]]         // key: descriptor.name (e.g. "openai_whisper-small") -> every file, both folders
  }
  extension SpeechModelDescriptor { var pinnedFiles: [PinnedFile]? { get } }   // nil for FluidAudio/SpeechAnalyzer backends
  ```

**Facts checked 2026-09-07.** `GET https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/<variant>?recursive=true` lists every file; LFS entries carry `lfs.oid`, which IS the SHA-256 of the content. For turbo-632: 22 files, 646 MB, 12 with an LFS SHA-256, 10 plain (`metadata.json`, `model.mil`, `config.json`, `generation_config.json`, about 30 MB in total) whose `oid` is a git SHA-1 and must be downloaded once to hash. The tokenizer lives in a second repo, `openai/whisper-small` for small and `openai/whisper-large-v3` for turbo: `config.json`, `tokenizer.json`, `tokenizer_config.json`, all plain. Download URLs are `https://huggingface.co/<repo>/resolve/<revision>/<path>`; pinning `<revision>` to a commit SHA (from `GET /api/models/<repo>` field `sha`) makes the URL immutable, exactly as the cleanup catalogue already does.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AFFlow

final class SpeechModelPinsTests: XCTestCase {
    /// Every WhisperKit rung on the quality ladder has a complete pin set:
    /// the Core ML folder AND the tokenizer folder (WhisperKit needs both and
    /// `ModelManager.modelIsCached` tests the tokenizer one), every hash 64 hex,
    /// every path under `whisper-models/models/`, no duplicates.
    func testEveryLadderSpeechModelIsFullyPinned() throws {
        for id in [QualityTier.starterSpeechModelID, QualityTier.fullSpeechModelID] {
            let descriptor = try XCTUnwrap(SpeechModelCatalog.model(named: id))
            let pins = try XCTUnwrap(descriptor.pinnedFiles, "\(id) has no pins")
            XCTAssertFalse(pins.isEmpty)
            let paths = Set(pins.map(\.relativePath))
            XCTAssertEqual(paths.count, pins.count, "duplicate paths in \(id)")
            for pin in pins {
                XCTAssertTrue(pin.relativePath.hasPrefix("whisper-models/models/"), pin.relativePath)
                XCTAssertEqual(pin.sha256.count, 64, pin.relativePath)
                XCTAssertNil(pin.sha256.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted), pin.relativePath)
                XCTAssertGreaterThan(pin.byteCount, 0, pin.relativePath)
                XCTAssertTrue(pin.url.absoluteString.contains("/resolve/"), "not an immutable resolve URL: \(pin.url)")
            }
            let coreML = "whisper-models/models/argmaxinc/whisperkit-coreml/\(descriptor.name)/"
            let tokenizer = "whisper-models/models/" + descriptor.cachePathComponents.joined(separator: "/") + "/"
            XCTAssertTrue(pins.contains { $0.relativePath.hasPrefix(coreML) }, "no Core ML files for \(id)")
            XCTAssertTrue(pins.contains { $0.relativePath == tokenizer + "tokenizer.json" }, "no tokenizer for \(id)")
        }
    }

    /// The generated file must name a full commit SHA per repo: a branch name
    /// would let the bytes change under a pinned hash and fail every download.
    func testRevisionsAreCommitHashesNotBranches() {
        for (repo, revision) in SpeechModelPins.hubRevisions {
            XCTAssertEqual(revision.count, 40, "\(repo) is pinned to '\(revision)', not a commit")
        }
    }

    func testNonWhisperKitBackendsHaveNoPins() {
        for descriptor in SpeechModelCatalog.all where descriptor.backend != .whisperKit {
            XCTAssertNil(descriptor.pinnedFiles, descriptor.name)
        }
    }
}
```
If `SpeechModelCatalog.all` does not exist, use the existing collection at `SpeechModelCatalog.swift:149` (the array that contains `whisperSmallMultilingual`); read its name from the file rather than guessing.

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/SpeechModelPinsTests`
Expected: build failure, `cannot find 'SpeechModelPins'`.

- [ ] **Step 3: Write the generator**

`scripts/speech-model-pins.py`:
```python
#!/usr/bin/env python3
"""Generate AFFlow/Transcription/SpeechModelPins.swift from the Hugging Face Hub.

WHY GENERATED. WhisperKit fetches models by NAME with no checksum, so the
launch plan's open item 2 was "the helper must not ship unpinned downloads".
The Hub's tree API returns the SHA-256 of every LFS file (its `lfs.oid`), so
the big weights are pinned without downloading them. The handful of plain
files (metadata.json, model.mil, config.json, tokenizer files, about 30 MB per
variant) carry only a git SHA-1 and are downloaded ONCE here to be hashed.

REVISIONS ARE COMMITS. Every URL is `/resolve/<commit sha>/`, immutable, like
`TextCleanupManager.cleanupModels`. A branch name would let the bytes move
under the hash and fail every download.

Refuses to write the Swift file if any file lacks a hash or size. Network:
this script is the ONE place in the repo that talks to the Hub, from the
developer's machine, never from the app.

Usage: python3 scripts/speech-model-pins.py [--out AFFlow/Transcription/SpeechModelPins.swift]
"""
import argparse, hashlib, json, os, sys, urllib.request

HUB = "https://huggingface.co"
COREML_REPO = "argmaxinc/whisperkit-coreml"
# descriptor.name -> (tokenizer repo, tokenizer cache folder under whisper-models/models)
VARIANTS = {
    "openai_whisper-small": ("openai/whisper-small", "openai/whisper-small"),
    "openai_whisper-large-v3-v20240930_turbo_632MB": ("openai/whisper-large-v3", "openai/whisper-large-v3"),
}
TOKENIZER_FILES = ("config.json", "tokenizer.json", "tokenizer_config.json")

def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()

def head_commit(repo):
    return json.loads(get(f"{HUB}/api/models/{repo}"))["sha"]

def tree(repo, revision, path=""):
    url = f"{HUB}/api/models/{repo}/tree/{revision}/{path}?recursive=true"
    return [e for e in json.loads(get(url)) if e["type"] == "file"]

def sha256_of(url):
    h = hashlib.sha256(); h.update(get(url)); return h.hexdigest()

def pin(repo, revision, hub_path, entry, relative):
    url = f"{HUB}/{repo}/resolve/{revision}/{hub_path}"
    lfs = entry.get("lfs")
    digest = lfs["oid"] if lfs else sha256_of(url)
    size = int(entry["size"])
    if len(digest) != 64 or size <= 0:
        sys.exit(f"REFUSED: {hub_path} has no usable hash or size")
    return {"relativePath": relative, "url": url, "sha256": digest, "byteCount": size}

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="AFFlow/Transcription/SpeechModelPins.swift")
    args = ap.parse_args()
    revisions = {COREML_REPO: head_commit(COREML_REPO)}
    files = {}
    for variant, (tok_repo, tok_folder) in VARIANTS.items():
        revisions.setdefault(tok_repo, head_commit(tok_repo))
        pins = []
        for e in tree(COREML_REPO, revisions[COREML_REPO], variant):
            pins.append(pin(COREML_REPO, revisions[COREML_REPO], e["path"],
                            e, f"whisper-models/models/argmaxinc/whisperkit-coreml/{e['path']}"))
        tok_entries = {e["path"]: e for e in tree(tok_repo, revisions[tok_repo])}
        for name in TOKENIZER_FILES:
            if name not in tok_entries:
                sys.exit(f"REFUSED: {tok_repo} has no {name}")
            pins.append(pin(tok_repo, revisions[tok_repo], name, tok_entries[name],
                            f"whisper-models/models/{tok_folder}/{name}"))
        files[variant] = pins
        print(f"{variant}: {len(pins)} files, {sum(p['byteCount'] for p in pins)/1e6:.0f} MB", file=sys.stderr)
    with open(args.out, "w") as out:
        out.write("// GENERATED by scripts/speech-model-pins.py. Do not edit; re-run the script.\n")
        out.write("import Foundation\n\nenum SpeechModelPins {\n")
        out.write("    static let hubRevisions: [String: String] = [\n")
        for repo, rev in sorted(revisions.items()):
            out.write(f'        "{repo}": "{rev}",\n')
        out.write("    ]\n\n    static let files: [String: [PinnedFile]] = [\n")
        for variant, pins in files.items():
            out.write(f'        "{variant}": [\n')
            for p in pins:
                out.write(f'            PinnedFile(relativePath: "{p["relativePath"]}", url: URL(string: "{p["url"]}")!, '
                          f'sha256: "{p["sha256"]}", byteCount: {p["byteCount"]}),\n')
            out.write("        ],\n")
        out.write("    ]\n}\n")
    print(f"wrote {args.out}", file=sys.stderr)

if __name__ == "__main__":
    main()
```
Run it: `python3 scripts/speech-model-pins.py`. Expected stderr: two `... files, ... MB` lines and `wrote AFFlow/Transcription/SpeechModelPins.swift`. Record both commit SHAs in PROGRESS.md.

In `SpeechModelCatalog.swift`, add:
```swift
extension SpeechModelDescriptor {
    /// Every file this model needs, pinned, or nil for backends the helper
    /// does not download (FluidAudio and SpeechAnalyzer fetch their own).
    var pinnedFiles: [PinnedFile]? {
        guard backend == .whisperKit else { return nil }
        return SpeechModelPins.files[name]
    }
}
```
Register `SpeechModelPins.swift` and the test file in the pbxproj.

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/SpeechModelPinsTests`
Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 5: See the generator refuse.** Temporarily change `if len(digest) != 64` to `if False` in a COPY of the script under the scratchpad, point it at a variant name that does not exist, confirm it exits non-zero with `REFUSED`. Delete the copy. (A generator that writes a half-pinned file on a bad day is the defect this task exists to prevent.)

- [ ] **Step 6: Commit**

```bash
git add scripts/speech-model-pins.py AFFlow/Transcription/SpeechModelPins.swift AFFlow/Transcription/SpeechModelCatalog.swift AFFlowTests/SpeechModelPinsTests.swift AFFlow.xcodeproj/project.pbxproj
git commit -m "Speech models pinned per file at a fixed Hub revision (open item 2)"
```

---

### Task 3: the XPC protocol and the service target

**Files:**
- Create: `AFFlow/ModelDownload/ModelDownloadProtocol.swift` (compiled into BOTH targets)
- Create: `AFFlowModels/main.swift`, `AFFlowModels/Info.plist`, `AFFlowModels/AFFlowModels.entitlements`
- Modify: `project.yml`, `AFFlow.xcodeproj/project.pbxproj`
- Create: `scripts/xpc-smoke.sh`

**Interfaces:**
- Produces:
  ```swift
  @objc protocol ModelDownloadServiceProtocol {
      /// Streams `urlString` into `handle`, starting at byte `offset` (sent as
      /// a Range header; 0 means from the start). `progress` is called with
      /// bytes written so far, at most a few times a second. `reply` carries
      /// total bytes written by this call and an error string, or nil.
      func fetch(_ urlString: String, into handle: FileHandle, resumingFrom offset: Int64,
                 reply: @escaping (Int64, String?) -> Void)
  }
  @objc protocol ModelDownloadProgressProtocol {   // exported by the APP for callbacks
      func wrote(bytes: Int64, of url: String)
  }
  let modelDownloadServiceName = "com.frolikov.afflow.models"
  ```

- [ ] **Step 1: The protocol file**

```swift
import Foundation

let modelDownloadServiceName = "com.frolikov.afflow.models"

/// What the service does, and ALL it does: bytes from one URL into one
/// descriptor the app opened. It never chooses a URL, never opens a file,
/// never verifies a hash. Verification belongs to the side that owns the
/// destination (`ModelDownloader`), the `download-model.sh` lesson.
@objc protocol ModelDownloadServiceProtocol {
    func fetch(_ urlString: String, into handle: FileHandle, resumingFrom offset: Int64,
               reply: @escaping (Int64, String?) -> Void)
}

/// Exported by the app so the service can report progress.
@objc protocol ModelDownloadProgressProtocol {
    func wrote(bytes: Int64, of url: String)
}
```

- [ ] **Step 2: The service**

`AFFlowModels/main.swift`:
```swift
import Foundation

/// AF Flow Models: the one process in the bundle allowed to open a socket.
/// App Sandbox + network.client, nothing else. It streams bytes into a
/// descriptor its host opened and reports progress; the host verifies.
final class Fetcher: NSObject, ModelDownloadServiceProtocol, URLSessionDataDelegate {
    private let handle: FileHandle
    private let urlString: String
    private let progress: ModelDownloadProgressProtocol?
    private var written: Int64 = 0
    private var lastReport = Date.distantPast
    private let done: (Int64, String?) -> Void
    private var finished = false

    init(handle: FileHandle, urlString: String, progress: ModelDownloadProgressProtocol?,
         done: @escaping (Int64, String?) -> Void) {
        self.handle = handle; self.urlString = urlString; self.progress = progress; self.done = done
    }

    func fetch(_ urlString: String, into handle: FileHandle, resumingFrom offset: Int64,
               reply: @escaping (Int64, String?) -> Void) {
        fatalError("Fetcher is one-shot; see Listener")
    }

    func start(offset: Int64) {
        guard let url = URL(string: urlString), ["https", "http"].contains(url.scheme ?? "") else {
            finish(error: "refused a URL that is not http(s): \(urlString)"); return
        }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            finish(error: "HTTP \(code)"); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date(); progress?.wrote(bytes: written, of: urlString)
            }
        } catch {
            finish(error: "write failed: \(error.localizedDescription)"); dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? { finish(error: "\(error.domain) \(error.code): \(error.localizedDescription)") }
        else { finish(error: nil) }
        session.finishTasksAndInvalidate()
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        try? handle.synchronize()
        progress?.wrote(bytes: written, of: urlString)
        done(written, error)
    }
}

final class Service: NSObject, ModelDownloadServiceProtocol {
    weak var connection: NSXPCConnection?
    private var active: Fetcher?
    func fetch(_ urlString: String, into handle: FileHandle, resumingFrom offset: Int64,
               reply: @escaping (Int64, String?) -> Void) {
        let progress = connection?.remoteObjectProxy as? ModelDownloadProgressProtocol
        let fetcher = Fetcher(handle: handle, urlString: urlString, progress: progress) { [weak self] n, e in
            self?.active = nil; reply(n, e)
        }
        active = fetcher
        fetcher.start(offset: offset)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        let service = Service()
        service.connection = c
        c.exportedInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        c.exportedObject = service
        c.remoteObjectInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        c.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
```
`Fetcher.fetch` exists only to satisfy the protocol on a type that is one-shot; `Service` is the exported object. If that reads wrong at implementation, drop the conformance from `Fetcher` and keep it on `Service` only.

`AFFlowModels/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.frolikov.afflow.models</string>
  <key>CFBundleName</key><string>AF Flow Models</string>
  <key>CFBundleDisplayName</key><string>AF Flow Models</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
```
`AFFlowModels/AFFlowModels.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
```

- [ ] **Step 3: The target, in both files.** `project.yml`:
```yaml
  AFFlowModels:
    type: xpc-service
    platform: macOS
    sources:
      - AFFlowModels
      - path: AFFlow/ModelDownload/ModelDownloadProtocol.swift
    settings:
      base:
        PRODUCT_NAME: AF Flow Models
        PRODUCT_BUNDLE_IDENTIFIER: com.frolikov.afflow.models
        INFOPLIST_FILE: AFFlowModels/Info.plist
        CODE_SIGN_ENTITLEMENTS: AFFlowModels/AFFlowModels.entitlements
        ENABLE_APP_SANDBOX: YES
        ENABLE_HARDENED_RUNTIME: YES
        SKIP_INSTALL: YES
      configs:
        Release:
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
```
and under `AFFlow.dependencies`: `- target: AFFlowModels` with `embed: true` (xcodegen's spelling for the "Embed XPC Services" copy phase, destination `Contents/XPCServices`). The pbxproj must be edited to match BY HAND (no xcodegen): a `PBXNativeTarget` of `productType = "com.apple.product-type.xpc-service"`, its `PBXSourcesBuildPhase`, a `PBXCopyFilesBuildPhase` in the `AFFlow` target with `dstSubfolderSpec = 16` and `dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices"`, and the target dependency. Use Xcode's GUI to add a "macOS > XPC Service" target and let it write the pbxproj, then diff and trim to exactly the settings above; that is faster and less error-prone than typing object graphs. Then run `python3 scripts/build-config-check.py` until it agrees with `project.yml`.

- [ ] **Step 4: The smoke test, which is the spike kept.** `scripts/xpc-smoke.sh` builds the app with `AF_FLOW_BUILD_ONLY=1`, starts `python3 -m http.server 8765 --bind 127.0.0.1` on a temp dir holding a 1 MB random file, runs a tiny Swift client (in `scripts/xpc-smoke-client.swift`, `swiftc`-compiled) that execs INSIDE the built `AF Flow.app` bundle path so `launchd` can find the service, asks the service to fetch the file into a descriptor, then asserts: the host's own `URLSession` attempt reports `NSPOSIXErrorDomain 1`; the service reply is `(1048576, nil)`; `shasum -a 256` of the destination equals that of the served file. Exit non-zero on any mismatch. Copy the 2026-09-06 spike's host and service code from PROGRESS.md session 21 as the starting point.

Run: `bash scripts/xpc-smoke.sh`
Expected last lines: `ok    host denied (EPERM)`, `ok    service fetched 1048576 bytes`, `ok    destination hash matches`, `RESULT: clean`.

- [ ] **Step 5: The boundary checker knows the service.** In `scripts/bundle-boundary-check.py`, add a second expectation: `Contents/XPCServices/AF Flow Models.xpc` must exist in a release bundle and its signature must carry EXACTLY `app-sandbox` and `network.client`; the app's own signature must still carry no `network.client`. Add a staged state for "service carries an extra entitlement" and one for "service missing" to `bundle-boundary-check-selftest.py`; both must FAIL. Run `python3 scripts/bundle-boundary-check-selftest.py`; expected `ALL STATES DISTINGUISHED` with 27 states.

- [ ] **Step 6: Commit**

```bash
git add AFFlow/ModelDownload/ModelDownloadProtocol.swift AFFlowModels project.yml AFFlow.xcodeproj/project.pbxproj scripts/xpc-smoke.sh scripts/xpc-smoke-client.swift scripts/bundle-boundary-check.py scripts/bundle-boundary-check-selftest.py
git commit -m "AF Flow Models: the one process in the bundle that may open a socket"
```

---

### Task 4: `ModelDownloader`, the app side, verified at the destination

**Files:**
- Create: `AFFlow/ModelDownload/ModelDownloader.swift`
- Test: `AFFlowTests/ModelDownloaderTests.swift`

**Interfaces:**
- Consumes: `PinnedFile` (Task 1), `ModelDownloadServiceProtocol` (Task 3).
- Produces:
  ```swift
  protocol Fetching {   // the seam: the real one wraps NSXPCConnection, tests use a fake
      func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                 progress: @escaping (Int64) -> Void) async throws -> Int64
  }
  enum ModelDownloadError: Error, Equatable { case hashMismatch(String), sizeMismatch(expected: Int64, got: Int64), transport(String), containment(String) }
  final class ModelDownloader {
      init(fetcher: Fetching, root: URL = AppSupportDirectory.url)
      func download(_ pin: PinnedFile, progress: @escaping (Int64, Int64) -> Void) async throws   // (bytesSoFar, total)
  }
  ```

Semantics, each pinned by a test below: bytes go to `<destination>.partial`; a run that finds a `.partial` resumes from its length; on completion size and SHA-256 are checked ON THE PARTIAL; a mismatch deletes the partial and throws; success renames partial to destination; a destination that already exists AND matches its pin by size is left alone and returns without fetching; containment uses `StarterModelInstaller.deepestExistingAncestor` and refuses a path that escapes `root`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CryptoKit
@testable import AFFlow

final class ModelDownloaderTests: XCTestCase {
    /// Serves `body` in `chunks`, honouring the resume offset; records calls.
    final class FakeFetcher: Fetching {
        var body: Data
        var chunk = 4
        var calls: [(URL, Int64)] = []
        var failAfterBytes: Int64? = nil
        init(_ body: Data) { self.body = body }
        func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                   progress: @escaping (Int64) -> Void) async throws -> Int64 {
            calls.append((url, offset))
            var written: Int64 = 0
            var index = Int(offset)
            while index < body.count {
                if let cap = failAfterBytes, written >= cap { throw ModelDownloadError.transport("simulated drop") }
                let end = min(index + chunk, body.count)
                try handle.write(contentsOf: body[index..<end])
                written += Int64(end - index); index = end
                progress(written)
            }
            return written
        }
    }

    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func pin(_ body: Data, path: String = "models/a.gguf", sha: String? = nil, size: Int64? = nil) -> PinnedFile {
        PinnedFile(relativePath: path, url: URL(string: "https://example.invalid/a")!,
                   sha256: sha ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                   byteCount: size ?? Int64(body.count))
    }

    func testGoodBytesLandAtTheDestinationAndNowhereElse() async throws {
        let body = Data("twenty bytes of model".utf8)
        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/a.gguf.partial").path))
    }

    func testATamperedHashRefusesAndLeavesNothingBehind() async throws {
        let body = Data("tampered".utf8)
        let fetcher = FakeFetcher(body)
        let bad = pin(body, sha: String(repeating: "0", count: 64))
        do { try await ModelDownloader(fetcher: fetcher, root: root).download(bad) { _, _ in }; XCTFail("accepted a wrong hash") }
        catch let error as ModelDownloadError { if case .hashMismatch = error {} else { XCTFail("\(error)") } }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("models").path)) ?? []
        XCTAssertEqual(left, [], "left behind: \(left)")
    }

    func testAShortBodyIsASizeMismatchNotASuccess() async throws {
        let body = Data("short".utf8)
        let fetcher = FakeFetcher(body)
        let bad = pin(body, size: 999)
        do { try await ModelDownloader(fetcher: fetcher, root: root).download(bad) { _, _ in }; XCTFail("accepted a short file") }
        catch let error as ModelDownloadError { if case .sizeMismatch = error {} else { XCTFail("\(error)") } }
    }

    func testADroppedConnectionResumesFromThePartial() async throws {
        let body = Data((0..<40).map { UInt8($0) })
        let fetcher = FakeFetcher(body); fetcher.failAfterBytes = 12
        let downloader = ModelDownloader(fetcher: fetcher, root: root)
        do { try await downloader.download(pin(body)) { _, _ in }; XCTFail("first attempt should drop") } catch {}
        let partial = root.appendingPathComponent("models/a.gguf.partial")
        XCTAssertEqual(try Data(contentsOf: partial).count, 12, "the partial was not kept")
        fetcher.failAfterBytes = nil
        try await downloader.download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.last?.1, 12, "the second attempt did not resume from the partial's length")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("models/a.gguf")), body)
    }

    func testAnExistingMatchingFileIsNotFetchedAgain() async throws {
        let body = Data("already here".utf8)
        let dest = root.appendingPathComponent("models/a.gguf")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: dest)
        let fetcher = FakeFetcher(body)
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }
        XCTAssertEqual(fetcher.calls.count, 0, "re-downloaded a file that was already there and correct")
    }

    func testAPathThatEscapesTheRootIsRefusedBeforeAnyFetch() async throws {
        let body = Data("x".utf8)
        let fetcher = FakeFetcher(body)
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: elsewhere)
        do { try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { _, _ in }; XCTFail("wrote through a symlink") }
        catch let error as ModelDownloadError { if case .containment = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(fetcher.calls.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testProgressReportsBytesAgainstTheTotal() async throws {
        let body = Data(repeating: 7, count: 10)
        let fetcher = FakeFetcher(body); fetcher.chunk = 5
        var seen: [(Int64, Int64)] = []
        try await ModelDownloader(fetcher: fetcher, root: root).download(pin(body)) { seen.append(($0, $1)) }
        XCTAssertEqual(seen.map(\.1), Array(repeating: 10, count: seen.count))
        XCTAssertEqual(seen.last?.0, 10)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/ModelDownloaderTests`
Expected: build failure, `cannot find type 'Fetching'`.

- [ ] **Step 3: Implementation**

```swift
import CryptoKit
import Foundation

protocol Fetching {
    func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
               progress: @escaping (Int64) -> Void) async throws -> Int64
}

enum ModelDownloadError: Error, Equatable {
    case hashMismatch(String)
    case sizeMismatch(expected: Int64, got: Int64)
    case transport(String)
    case containment(String)
}

/// The app side. Owns the destination, so it owns verification. The service
/// only ever sees a descriptor.
final class ModelDownloader {
    private let fetcher: Fetching
    private let root: URL
    init(fetcher: Fetching, root: URL = AppSupportDirectory.url) { self.fetcher = fetcher; self.root = root }

    func download(_ pin: PinnedFile, progress: @escaping (Int64, Int64) -> Void) async throws {
        let manager = FileManager.default
        let destination = URL(fileURLWithPath: root.path).appendingPathComponent(pin.relativePath).standardizedFileURL
        let partial = destination.appendingPathExtension("partial")

        // CONTAINMENT on the deepest existing ancestor, resolved; a dangling
        // link refused outright. The same rule as StarterModelInstaller.
        let rootReal = URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath()
        let ancestor = StarterModelInstaller.deepestExistingAncestor(of: destination.deletingLastPathComponent())
        let dangling = (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            && !manager.fileExists(atPath: ancestor.path)
        let ancestorReal = ancestor.resolvingSymlinksInPath()
        guard !dangling, ancestorReal.path == rootReal.path || ancestorReal.path.hasPrefix(rootReal.path + "/") else {
            throw ModelDownloadError.containment(pin.relativePath)
        }

        // Already there and the right size: nothing to do. (Size, not hash:
        // the caller hashes on load, and hashing gigabytes to decide not to
        // download them is the wrong trade on a friend's laptop.)
        if let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil,
           size == pin.byteCount {
            progress(pin.byteCount, pin.byteCount); return
        }

        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: partial.path) { manager.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        let offset = Int64(try handle.seekToEnd())
        defer { try? handle.close() }

        do {
            _ = try await fetcher.fetch(pin.url, into: handle, resumingFrom: offset) { written in
                progress(offset + written, pin.byteCount)
            }
        } catch {
            // Keep the partial for a resume; the transport error is the answer.
            throw (error as? ModelDownloadError) ?? .transport(String(describing: error))
        }
        try handle.synchronize()
        try handle.close()

        let got = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? -1
        guard got == pin.byteCount else {
            try? manager.removeItem(at: partial)
            throw ModelDownloadError.sizeMismatch(expected: pin.byteCount, got: got)
        }
        guard let digest = StarterModelInstaller.sha256(ofFileAt: partial), digest == pin.sha256.lowercased() else {
            try? manager.removeItem(at: partial)
            throw ModelDownloadError.hashMismatch(pin.relativePath)
        }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: partial, to: destination)
        progress(pin.byteCount, pin.byteCount)
    }
}

/// The real fetcher: one NSXPCConnection per download.
final class XPCFetcher: NSObject, Fetching, ModelDownloadProgressProtocol {
    private var onProgress: ((Int64) -> Void)?
    func wrote(bytes: Int64, of url: String) { onProgress?(bytes) }

    func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
               progress: @escaping (Int64) -> Void) async throws -> Int64 {
        onProgress = progress
        let connection = NSXPCConnection(serviceName: modelDownloadServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        connection.exportedObject = self
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: ModelDownloadError.transport("service unavailable: \(error.localizedDescription)"))
            } as! ModelDownloadServiceProtocol
            proxy.fetch(url.absoluteString, into: handle, resumingFrom: offset) { written, error in
                if let error { continuation.resume(throwing: ModelDownloadError.transport(error)) }
                else { continuation.resume(returning: written) }
            }
        }
    }
}
```
Note on the size-only short-circuit: the tests above pin it (`testAnExistingMatchingFileIsNotFetchedAgain`), and `TextCleanupManager` hashes at load; `ModelManager` does not, which is ledger item 29's neighbour and is named in Task 6.

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/run-tests.sh -only-testing:AFFlowTests/ModelDownloaderTests`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Mutations, three, by hand with backup + `cmp` (dirty tree).** (a) Delete the hash `guard`: `testATamperedHashRefusesAndLeavesNothingBehind` must fail. (b) Change `seekToEnd()` offset to `0`: the resume test must fail. (c) Delete the containment `guard`: the escape test must fail. Restore with `cp` from the backup and prove it with `cmp`; never `git checkout` an untracked file.

- [ ] **Step 6: Commit**

```bash
git add AFFlow/ModelDownload/ModelDownloader.swift AFFlowTests/ModelDownloaderTests.swift AFFlow.xcodeproj/project.pbxproj
git commit -m "ModelDownloader: bytes verified where they land, partials resumed, escapes refused"
```

---

### Task 5: `TierInstaller`, and the one Settings button

**Files:**
- Create: `AFFlow/ModelDownload/TierInstaller.swift`
- Modify: `AFFlow/UI/SettingsWindow.swift` (grep for the existing quality-ladder view from Phase 3; add ONE button and ONE status line; do not read the 181 KB file whole)
- Test: `AFFlowTests/TierInstallerTests.swift`

**Interfaces:**
- Consumes: `QualityTier` (speech id + cleanup kind), `SpeechModelDescriptor.pinnedFiles`, `LocalCleanupModelDescriptor.pinnedFile`, `ModelDownloader`.
- Produces:
  ```swift
  struct TierInstallReport: Equatable { var installed: [String]; var alreadyPresent: [String]; var failure: String? }   // relative paths
  final class TierInstaller {
      init(downloader: ModelDownloader, root: URL = AppSupportDirectory.url)
      static func pins(for tier: QualityTier, ram bytes: UInt64) -> [PinnedFile]
      func install(_ tier: QualityTier, ram bytes: UInt64, progress: @escaping (String, Int64, Int64) -> Void) async -> TierInstallReport
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AFFlow

final class TierInstallerTests: XCTestCase {
    /// The Full tier's pin list is the ladder's own answer, not a second copy:
    /// speech from `QualityTier.fullSpeechModelID`, cleanup by RAM.
    func testFullTierPinsFollowTheLadder() throws {
        let pins = TierInstaller.pins(for: .full, ram: 32 << 30)
        let speech = try XCTUnwrap(SpeechModelCatalog.model(named: QualityTier.fullSpeechModelID)?.pinnedFiles)
        for pin in speech { XCTAssertTrue(pins.contains(pin), pin.relativePath) }
        let cleanup = QualityTier.full.cleanupModel(forRAM: 32 << 30)   // the Phase 3 accessor; read QualityTier.swift for its exact name
        XCTAssertTrue(pins.contains(TextCleanupManager.descriptor(for: cleanup).pinnedFile))
    }

    /// A failure mid-tier leaves the report saying so, names the file, and the
    /// caller stays on Starter. Nothing is invented and nothing is half-visible.
    func testAFailureIsReportedAndStopsTheTier() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class Refusing: Fetching {
            func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
                       progress: @escaping (Int64) -> Void) async throws -> Int64 { throw ModelDownloadError.transport("offline") }
        }
        let installer = TierInstaller(downloader: ModelDownloader(fetcher: Refusing(), root: root), root: root)
        let report = await installer.install(.full, ram: 32 << 30) { _, _, _ in }
        XCTAssertEqual(report.installed, [])
        XCTAssertNotNil(report.failure)
        XCTAssertTrue(report.failure!.contains("offline"), report.failure!)
        let anything = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.filter { !$0.hasSuffix(".partial") && !$0.contains("/") == false } ?? []
        XCTAssertEqual(anything.filter { $0.hasSuffix(".gguf") || $0.hasSuffix(".bin") }, [], "a model file appeared despite the failure")
    }
}
```
Where the plan names a `QualityTier`/`TextCleanupManager` accessor it has not read (`cleanupModel(forRAM:)`, `descriptor(for:)`), the implementer greps `QualityTier.swift` and `TextCleanupManager.swift` for the Phase 3 names and uses those; this plan does not invent them.

- [ ] **Step 2: Run to verify they fail.** Expected: `cannot find 'TierInstaller'`.

- [ ] **Step 3: Implementation**

```swift
import Foundation

struct TierInstallReport: Equatable {
    var installed: [String] = []
    var alreadyPresent: [String] = []
    var failure: String? = nil
}

final class TierInstaller {
    private let downloader: ModelDownloader
    private let root: URL
    init(downloader: ModelDownloader, root: URL = AppSupportDirectory.url) { self.downloader = downloader; self.root = root }

    static func pins(for tier: QualityTier, ram bytes: UInt64) -> [PinnedFile] {
        var pins: [PinnedFile] = []
        if let speech = SpeechModelCatalog.model(named: tier.speechModelID)?.pinnedFiles { pins += speech }
        pins.append(TextCleanupManager.descriptor(for: tier.cleanupModel(forRAM: bytes)).pinnedFile)
        return pins
    }

    func install(_ tier: QualityTier, ram bytes: UInt64,
                 progress: @escaping (String, Int64, Int64) -> Void) async -> TierInstallReport {
        var report = TierInstallReport()
        for pin in Self.pins(for: tier, ram: bytes) {
            let destination = root.appendingPathComponent(pin.relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            if size == pin.byteCount { report.alreadyPresent.append(pin.relativePath); continue }
            do {
                try await downloader.download(pin) { done, total in progress(pin.relativePath, done, total) }
                report.installed.append(pin.relativePath)
            } catch {
                report.failure = "\(pin.relativePath): \(error)"
                return report      // stop; the app stays on Starter and says why
            }
        }
        return report
    }
}
```
Settings: one button "Get the Full tier" next to the Phase 3 ladder, disabled while running, a single line below it showing `progress` (file name, MB of MB) and afterwards either "Full tier installed" or the report's `failure` verbatim with "Try again". Wire it with `TierInstaller(downloader: ModelDownloader(fetcher: XPCFetcher()))`. All strings through the existing brand tokens; no Fraunces on file names (Cyrillic rule does not apply, but the "content" rule does).

- [ ] **Step 4: Run to verify they pass.** Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Full suite, then commit**

Run: `./scripts/run-tests.sh`. Expected: baseline + new tests, the same 3 known failures.
```bash
git add AFFlow/ModelDownload/TierInstaller.swift AFFlow/UI/SettingsWindow.swift AFFlowTests/TierInstallerTests.swift AFFlow.xcodeproj/project.pbxproj
git commit -m "TierInstaller: the Full tier arrives through the service, or Settings says why it did not"
```

---

### Task 6: release wiring and the honest end-to-end

**Files:**
- Modify: `scripts/release-build.sh` (sign `Contents/XPCServices/AF Flow Models.xpc` with its OWN entitlements file BEFORE signing the app, no `--deep`; the existing comment block already explains why nested bundles are signed inner-first)
- Modify: `docs/release-engineering.md`, `docs/launch-v1-plan.md` changelog, `STATE.md`, `PROGRESS.md`

- [ ] **Step 1:** In `release-build.sh` step 3, after the starter models are copied and before the app is signed, add:
```bash
SERVICE="$APP/Contents/XPCServices/AF Flow Models.xpc"
[ -d "$SERVICE" ] || fail "the model downloader service is missing from the bundle; the AFFlowModels target did not embed." 1
codesign --force --options runtime --timestamp \
    --entitlements AFFlowModels/AFFlowModels.entitlements --sign "$IDENTITY" "$SERVICE" \
    || fail "could not sign the model downloader service." 1
```
- [ ] **Step 2:** `python3 scripts/bundle-boundary-check.py --release <path>` on a preflight build must print the service's two entitlements and refuse a third (Task 3 step 5 staged it).
- [ ] **Step 3:** `bash scripts/xpc-smoke.sh` against the built bundle: clean.
- [ ] **Step 4:** With AF Flow running from the built bundle and an EMPTY `whisper-models` in a scratch container (use the test host's own container, never his: `af_paths.py test_host_support`), press "Get the Full tier" in Settings and watch the log: every file lands, sizes and hashes verified, and `ModelManager` loads turbo without a download attempt. This is the first observation that **WhisperKit loads from a populated `downloadBase` with the kernel denying egress for a model it did not fetch itself** (ledger 29); record the outcome either way.
- [ ] **Step 5:** LuLu will prompt ONCE for "AF Flow Models" the first time it reaches huggingface.co. That prompt, and whatever Andrew clicks, is exactly the rule `lulu-rule-check.py` now expects for `com.frolikov.afflow.models` while the bundle ships; run the checker and confirm it prints the rule as expected and stays clean. Record the rule's shape in PROGRESS.md.
- [ ] **Step 6:** Docs and commit.
```bash
git add scripts/release-build.sh docs/release-engineering.md docs/launch-v1-plan.md STATE.md PROGRESS.md
git commit -m "Phase 4 wired into the release build; the first offline load of a service-fetched model recorded"
```

---

## Self-review

- **Spec coverage.** Launch plan Phase 4: (1) new target, own bundle id, network entitlement: Task 3. (2) same pinned catalogue, speech pinning before shipping (open item 2): Tasks 1 and 2. (3) write path decided and documented: 4D, spike done 2026-09-06, Task 3 and 4 implement it. (4) tier argument, progress, verify hash and size in place, failure leaves the app on Starter with a retry in Settings, tampered hash refused and nothing left behind: Tasks 4 and 5. Open item 3's LuLu exception: done 2026-09-06, exercised in Task 6 step 5.
- **Placeholders.** Two accessor names in Task 5 (`cleanupModel(forRAM:)`, `descriptor(for:)`) are flagged as "read the Phase 3 name from the file", not invented; the pbxproj edit in Task 3 is described as a procedure because no generator exists on this machine. Everything else carries its code.
- **Type consistency.** `PinnedFile(relativePath:url:sha256:byteCount:)` is used identically in Tasks 1, 2, 4, 5; `Fetching.fetch(_:into:resumingFrom:progress:)` matches between the fake, `XPCFetcher` and `ModelDownloader`; `ModelDownloadServiceProtocol.fetch(_:into:resumingFrom:reply:)` matches service and client.

## Decisions this plan needs from Andrew before execution

1. **Network from the developer machine to establish pins** (Task 2): about 60 MB of plain files downloaded once from huggingface.co plus metadata calls, free, from his Mac. No model weights are downloaded.
2. **Xcode GUI for the target** (Task 3): the pbxproj is edited by adding the target in Xcode once, then trimming. Alternative is typing the object graph by hand; slower and riskier.
3. **The first LuLu prompt for "AF Flow Models"** (Task 6): he will see it and whatever he clicks becomes the rule; "Allow, this host only" is the shape the checker prints without complaint.
