import XCTest
@testable import AFFlow

/// The DMG carries the Starter tier so a friend can dictate offline the moment
/// the app opens. Nothing was moving those files into place.
///
/// `release-build.sh` copies them to `Contents/Resources/StarterModels`, and
/// the app looks in Application Support: `models/` for the cleanup GGUF and
/// `whisper-models/models/...` for the speech model. Codex found the gap on
/// 2026-08-30. Until this installer existed, a fresh install with an empty
/// cache and no network entitlement would have tried a download the kernel
/// blocks, so **"dictation works the moment the app opens, offline" was not a
/// claim the build kept.**
///
/// THE RULES THIS INSTALLER OBEYS, each of them bought by an earlier failure:
///
///   - **It never overwrites.** There are 6.8 GB of his models on this Mac and
///     an installer that clobbers is one bad path away from destroying them.
///   - **It verifies at the DESTINATION.** `download-model.sh`'s lesson: bytes
///     are checked where they land, not where they came from.
///   - **It never writes outside the models root**, checked by resolving the
///     path rather than by inspecting the string.
///   - **A partial copy is never visible as a model.** Copy to a temporary
///     name, then rename into place.
///   - **No bundled models is not an error.** Every development build is in
///     that state.
final class StarterModelInstallerTests: XCTestCase {
    private var root: URL!
    private var bundled: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("starter-\(UUID().uuidString)", isDirectory: true)
        bundled = root.appendingPathComponent("StarterModels", isDirectory: true)
        destination = root.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func stageBundled(_ relativePath: String, contents: String) throws -> URL {
        let url = bundled.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func existingAtDestination(_ relativePath: String) -> String? {
        try? String(contentsOf: destination.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func install() -> StarterModelInstaller.Outcome {
        StarterModelInstaller.install(from: bundled, into: destination)
    }

    // MARK: - The happy path, which is a friend's first launch

    func testItPutsBundledModelsWhereTheAppLooks() throws {
        // WhisperKit keeps a speech model in TWO places under the same root:
        // the Core ML files under argmaxinc/whisperkit-coreml/<variant>, and
        // the tokenizer under openai/<short name>, which is ALSO the folder
        // `ModelManager.modelIsCached` tests. A payload carrying only the
        // first would install cleanly and still trigger a blocked download.
        try stageBundled("models/Qwen3.5-0.8B-Q4_K_M.gguf", contents: "cleanup weights")
        try stageBundled("whisper-models/models/argmaxinc/whisperkit-coreml/openai_whisper-small/AudioEncoder.mlmodelc/x",
                         contents: "speech weights")
        try stageBundled("whisper-models/models/openai/whisper-small/tokenizer.json",
                         contents: "tokenizer")

        let outcome = install()
        XCTAssertEqual(outcome.installed, 3, "outcome was \(outcome)")
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(existingAtDestination("models/Qwen3.5-0.8B-Q4_K_M.gguf"), "cleanup weights")
        XCTAssertEqual(existingAtDestination(
            "whisper-models/models/argmaxinc/whisperkit-coreml/openai_whisper-small/AudioEncoder.mlmodelc/x"),
                       "speech weights")
        XCTAssertEqual(existingAtDestination("whisper-models/models/openai/whisper-small/tokenizer.json"),
                       "tokenizer")
    }

    /// A development build has no bundled payload, and that is normal.
    func testNoBundledFolderIsNotAFailure() {
        let outcome = StarterModelInstaller.install(
            from: root.appendingPathComponent("does-not-exist", isDirectory: true),
            into: destination)
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(outcome.failures, [])
        XCTAssertTrue(outcome.hadNothingBundled)
    }

    // MARK: - His 6.8 GB

    func testItNeverOverwritesAModelThatIsAlreadyThere() throws {
        try stageBundled("models/Qwen3.5-0.8B-Q4_K_M.gguf", contents: "bundled")
        let already = destination.appendingPathComponent("models/Qwen3.5-0.8B-Q4_K_M.gguf")
        try FileManager.default.createDirectory(at: already.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "HIS OWN 4.2 GB".write(to: already, atomically: true, encoding: .utf8)

        let outcome = install()
        XCTAssertEqual(existingAtDestination("models/Qwen3.5-0.8B-Q4_K_M.gguf"), "HIS OWN 4.2 GB",
                       "the installer overwrote a model that was already there")
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(outcome.skipped, 1)
    }

    func testASecondRunInstallsNothing() throws {
        try stageBundled("models/a.gguf", contents: "weights")
        XCTAssertEqual(install().installed, 1)
        let second = install()
        XCTAssertEqual(second.installed, 0)
        XCTAssertEqual(second.skipped, 1)
    }

    // MARK: - Refusals

    /// **A SYMLINK is the escape that actually exists.** The first version of
    /// this test staged a literal `models/../../escaped.gguf`, which cannot be
    /// created: the filesystem resolves `..` at write time, so the file lands
    /// outside the payload and the installer never sees it. The test failed and
    /// was right to.
    ///
    /// A symlink inside the payload is the real vector, and this project
    /// already carries it as an open item: ledger 21/22, "symlink evades
    /// containment". The installer does not follow one.
    func testItRefusesASymlinkPointingOutOfThePayload() throws {
        let outside = root.appendingPathComponent("outside-secret.gguf")
        try "his own data".write(to: outside, atomically: true, encoding: .utf8)

        let linkDirectory = bundled.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkDirectory.appendingPathComponent("linked.gguf"),
            withDestinationURL: outside)

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0, "a symlink was followed and copied")
        XCTAssertFalse(outcome.failures.isEmpty,
                       "a symlink in the payload was silently ignored rather than refused")
        XCTAssertNil(existingAtDestination("models/linked.gguf"),
                     "a symlinked file landed in the models folder")
    }

    /// And a symlinked DIRECTORY must not be walked into either, or the file
    /// check above is bypassed one level up.
    func testItDoesNotWalkIntoASymlinkedDirectory() throws {
        let outsideDirectory = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "his own data".write(to: outsideDirectory.appendingPathComponent("secret.gguf"),
                                 atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: bundled.appendingPathComponent("models"),
            withDestinationURL: outsideDirectory)

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0, "the installer walked into a symlinked directory")
        XCTAssertNil(existingAtDestination("models/secret.gguf"))
        // REPORTED, not merely skipped. `FileManager.enumerator` happens not to
        // descend into a symlinked directory on its own, so the two assertions
        // above stayed green with the refusal branch deleted (mutation test,
        // 2026-09-06). A payload entry that vanishes silently hides a broken
        // build; the refusal has to be visible in the outcome.
        XCTAssertFalse(outcome.failures.isEmpty,
                       "a symlinked directory in the payload was silently ignored rather than refused")
    }

    /// Verified where the bytes LAND, not where they came from.
    func testItRefusesBundledBytesThatDoNotMatchTheirPinnedHash() throws {
        try stageBundled("models/pinned.gguf", contents: "tampered")
        let outcome = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf":
                        StarterModelInstaller.Expectation(sha256: String(repeating: "0", count: 64),
                                                          byteCount: 8)])
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertFalse(outcome.failures.isEmpty)
        XCTAssertNil(existingAtDestination("models/pinned.gguf"),
                     "a file that failed its hash was left at the destination")
    }

    func testItAcceptsBundledBytesThatDoMatch() throws {
        let body = "known bytes"
        try stageBundled("models/pinned.gguf", contents: body)
        let outcome = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf":
                        StarterModelInstaller.Expectation(
                            sha256: StarterModelInstaller.sha256(ofFileAt:
                                bundled.appendingPathComponent("models/pinned.gguf")) ?? "",
                            byteCount: Int64(body.utf8.count))])
        XCTAssertEqual(outcome.installed, 1, "outcome was \(outcome)")
        XCTAssertEqual(existingAtDestination("models/pinned.gguf"), body)
    }

    /// A wrong byte count is a different failure from a wrong hash and must be
    /// caught on its own, because a truncated file can still be staged.
    func testItRefusesAWrongByteCountEvenWhenTheHashArgumentIsRight() throws {
        let body = "known bytes"
        try stageBundled("models/pinned.gguf", contents: body)
        let realHash = StarterModelInstaller.sha256(
            ofFileAt: bundled.appendingPathComponent("models/pinned.gguf")) ?? ""
        let outcome = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf":
                        StarterModelInstaller.Expectation(sha256: realHash, byteCount: 999_999)])
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertNil(existingAtDestination("models/pinned.gguf"))
    }

    /// **Containment is decided on REAL paths.** If the destination's own
    /// `models` entry is a symlink pointing elsewhere, a string-prefix check
    /// passes and the bytes land outside the models root. Codex, 2026-09-06.
    func testItRefusesToWriteThroughASymlinkedDestinationDirectory() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("models"),
            withDestinationURL: elsewhere)
        try stageBundled("models/a.gguf", contents: "weights")

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0, "bytes were written through a symlinked destination")
        XCTAssertFalse(outcome.failures.isEmpty, "the symlinked destination was not reported")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: elsewhere.appendingPathComponent("a.gguf").path),
                       "the file landed outside the models root")
    }

    /// **And through a symlink SEVERAL levels up.** `resolvingSymlinksInPath`
    /// returns a path that does not exist yet UNCHANGED, so a nested payload
    /// path whose parent folders are still to be created slipped past the
    /// first fix while the direct-child test above went green. Codex
    /// reproduced it against Foundation on 2026-09-06.
    func testItRefusesToWriteThroughASymlinkSeveralLevelsAboveANewFile() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("models"),
            withDestinationURL: elsewhere)
        try stageBundled("models/new/deeper/a.gguf", contents: "weights")

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0, "bytes were written through a symlinked ancestor")
        XCTAssertFalse(outcome.failures.isEmpty, "the symlinked ancestor was not reported")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: elsewhere.appendingPathComponent("new/deeper/a.gguf").path),
                       "the file landed outside the models root")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: elsewhere.appendingPathComponent("new").path),
                       "a directory was created outside the models root")
    }

    /// A DANGLING symlink at the destination points at a place that does not
    /// exist yet. `deepestExistingAncestor` stops on the link itself; whatever
    /// resolving it yields, nothing may be created at the link's target.
    /// Honest note: this one passed first time, so it pins the behaviour
    /// rather than proving a fix; the refusal comes either from containment
    /// or from the kernel refusing to create through a dangling link.
    func testItDoesNotCreateAnythingThroughADanglingDestinationSymlink() throws {
        let gone = root.appendingPathComponent("gone", isDirectory: true)
            .appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gone"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("models"), withDestinationURL: gone)
        try stageBundled("models/new/a.gguf", contents: "weights")

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0, "bytes were written through a dangling symlink")
        // The REFUSAL branch, not a kernel error dressed as one. The first
        // version of this test went green on "couldn't be saved": mkdir does
        // not traverse a dangling link, so the escape failed by accident and
        // the containment check had passed it. The independent third-pass
        // review caught that on 2026-09-06; a dangling ancestor is now
        // refused outright.
        XCTAssertTrue(outcome.failures.contains { $0.contains("escapes the models folder") },
                      "the dangling ancestor was not refused by containment: \(outcome.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path),
                       "the dangling link's target was created outside the models root")
    }

    /// **A hidden file in the payload is refused and reported**, not installed.
    /// The comment in the installer said skipping one silently would hide a
    /// problem; the code then installed it, which hides it better. A Finder
    /// `.DS_Store` or a WhisperKit `.cache` in the staging folder is a staging
    /// mistake, and `release-build.sh` refuses it at build time too.
    func testAHiddenFileInThePayloadIsRefusedNotInstalled() throws {
        try stageBundled("models/.DS_Store", contents: "finder litter")
        try stageBundled("models/a.gguf", contents: "weights")

        let outcome = install()
        XCTAssertEqual(outcome.installed, 1, "outcome was \(outcome)")
        XCTAssertNil(existingAtDestination("models/.DS_Store"), "a hidden file was installed")
        XCTAssertTrue(outcome.failures.contains { $0.contains(".DS_Store") },
                      "the hidden file was not reported: \(outcome.failures)")
    }

    /// A symlink sitting at a pinned destination path is named as one, not
    /// measured as a wrong-sized file.
    func testASymlinkAtAPinnedDestinationIsReportedAsASymlink() throws {
        try stageBundled("models/pinned.gguf", contents: "the real bytes")
        let elsewhere = root.appendingPathComponent("elsewhere.gguf")
        try "x".write(to: elsewhere, atomically: true, encoding: .utf8)
        let models = destination.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: models.appendingPathComponent("pinned.gguf"), withDestinationURL: elsewhere)

        let outcome = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf": StarterModelInstaller.Expectation(
                sha256: String(repeating: "0", count: 64), byteCount: 14)])
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertTrue(outcome.failures.contains { $0.contains("symbolic link") },
                      "a symlink at the destination was not named as one: \(outcome.failures)")
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "x", "the link's target was touched")
    }

    /// The payload ROOT itself is never enumerated, so a symlinked root was the
    /// one directory symlink the walk could not see.
    func testASymlinkedPayloadRootIsRefused() throws {
        let realPayload = root.appendingPathComponent("real-payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realPayload.appendingPathComponent("models"), withIntermediateDirectories: true)
        try "weights".write(to: realPayload.appendingPathComponent("models/a.gguf"),
                            atomically: true, encoding: .utf8)
        let linkedRoot = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realPayload)

        let outcome = StarterModelInstaller.install(from: linkedRoot, into: destination)
        XCTAssertEqual(outcome.installed, 0, "a symlinked payload root was followed")
        XCTAssertFalse(outcome.failures.isEmpty, "a symlinked payload root was not reported")
    }

    /// **An existing file at a PINNED path is checked, not trusted.** It is
    /// still never overwritten, but a truncated or stale file that the app will
    /// later reject must be REPORTED rather than counted as a quiet skip,
    /// because the download it would trigger is one the kernel blocks.
    /// Byte count only: hashing his models on every launch is not free.
    func testAnExistingPinnedFileOfTheWrongSizeIsReportedAndLeftAlone() throws {
        try stageBundled("models/pinned.gguf", contents: "the real bytes")
        let already = destination.appendingPathComponent("models/pinned.gguf")
        try FileManager.default.createDirectory(at: already.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "trunc".write(to: already, atomically: true, encoding: .utf8)

        let outcome = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf":
                        StarterModelInstaller.Expectation(
                            sha256: StarterModelInstaller.sha256(ofFileAt:
                                bundled.appendingPathComponent("models/pinned.gguf")) ?? "",
                            byteCount: Int64("the real bytes".utf8.count))])
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(existingAtDestination("models/pinned.gguf"), "trunc",
                       "an existing file was overwritten")
        XCTAssertFalse(outcome.failures.isEmpty,
                       "a wrong-sized file at a pinned path was counted as a quiet skip")
    }

    // MARK: - Nothing half-copied is ever visible as a model

    /// A copy that FAILS must clean up after itself too, because nothing later
    /// removes a stray staging file. Honest note: this test was NOT seen red.
    /// `FileManager.copyItem` on an unreadable source leaves nothing behind, so
    /// it pins the guarantee without exercising the catch-block cleanup; the
    /// path it would need (a target appearing between the existence check and
    /// the rename, or a copy dying mid-write) cannot be staged from a test.
    func testAFailedCopyLeavesNoStagingFileBehind() throws {
        let source = try stageBundled("models/unreadable.gguf", contents: "weights")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }

        let outcome = install()
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertFalse(outcome.failures.isEmpty, "a failed copy was not reported")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: destination.appendingPathComponent("models").path)) ?? []
        XCTAssertEqual(leftovers, [], "a failed copy left something at the destination: \(leftovers)")
    }

    /// The destination is written under a temporary name and renamed, so a
    /// crash mid-copy leaves no file at the path the app checks. Verified by
    /// there being no leftover temporary file after a refusal.
    func testARefusedCopyLeavesNoTemporaryBehind() throws {
        try stageBundled("models/pinned.gguf", contents: "tampered")
        _ = StarterModelInstaller.install(
            from: bundled, into: destination,
            expected: ["models/pinned.gguf":
                        StarterModelInstaller.Expectation(sha256: String(repeating: "0", count: 64),
                                                          byteCount: 8)])
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: destination.appendingPathComponent("models").path)) ?? []
        XCTAssertEqual(leftovers, [], "a partial copy was left at the destination: \(leftovers)")
    }
}
