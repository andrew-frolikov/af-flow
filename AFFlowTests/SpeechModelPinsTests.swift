import XCTest
@testable import AFFlow

/// **Launch plan open item 2: the helper must not ship unpinned downloads.**
///
/// WhisperKit fetches a model by NAME and publishes no checksum, so until this
/// existed the speech models were the one thing this project downloaded on
/// trust. `scripts/speech-model-pins.py` generates the pins from the Hugging
/// Face tree API at a FIXED COMMIT, taking each LFS file's SHA-256 as given and
/// hashing the handful of plain files once. These tests are what stops a
/// half-generated file from passing as a pinned one.
final class SpeechModelPinsTests: XCTestCase {
    /// Both rungs of the ladder, complete. A model needs BOTH folders
    /// WhisperKit uses: the Core ML files under `argmaxinc/whisperkit-coreml/`
    /// and the tokenizer under `openai/`. `ModelManager.modelIsCached` requires
    /// both, so pinning one and not the other produces an install that looks
    /// finished and cannot load.
    func testEveryLadderSpeechModelIsFullyPinned() throws {
        for id in [QualityTier.starterSpeechModelID, QualityTier.fullSpeechModelID] {
            let descriptor = try XCTUnwrap(SpeechModelCatalog.model(named: id))
            let pins = try XCTUnwrap(descriptor.pinnedFiles, "\(id) has no pins")
            XCTAssertFalse(pins.isEmpty, id)
            XCTAssertEqual(Set(pins.map(\.relativePath)).count, pins.count, "duplicate paths in \(id)")
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            for pin in pins {
                XCTAssertTrue(pin.relativePath.hasPrefix("whisper-models/models/"), pin.relativePath)
                XCTAssertEqual(pin.sha256.count, 64, pin.relativePath)
                XCTAssertNil(pin.sha256.rangeOfCharacter(from: hex.inverted), pin.relativePath)
                XCTAssertGreaterThan(pin.byteCount, 0, pin.relativePath)
                XCTAssertTrue(pin.url.absoluteString.contains("/resolve/"),
                              "not an immutable resolve URL: \(pin.url)")
            }
            let coreML = "whisper-models/models/argmaxinc/whisperkit-coreml/\(descriptor.name)/"
            XCTAssertTrue(pins.contains { $0.relativePath.hasPrefix(coreML) }, "no Core ML files for \(id)")
            // The tokenizer lands under `openai/<repo>`, which is NOT
            // `cachePathComponents`. Since 2026-09-10 that field names the Core
            // ML folder for EVERY WhisperKit model. Before, it named the tokenizer
            // folder for tiny, small and small.en, which sent the loader to the
            // wrong folder, and the release gate misread it on 2026-09-06.
            XCTAssertTrue(pins.contains {
                $0.relativePath.hasPrefix("whisper-models/models/openai/")
                    && $0.relativePath.hasSuffix("/tokenizer.json")
            }, "no tokenizer for \(id); WhisperKit needs one")
            // `cachePathComponents` must name exactly the Core ML folder, the one
            // the loader hands WhisperKit. Equality, not a prefix check: the pins
            // also fill the tokenizer folder, so a prefix check passes for the
            // mixed meaning that broke the Starter load on 2026-09-10.
            XCTAssertEqual(descriptor.cachePathComponents, ["argmaxinc", "whisperkit-coreml", descriptor.name],
                           "\(id): cachePathComponents must name the Core ML folder")
        }
    }

    /// A branch name in the URL would let the bytes move under a pinned hash
    /// and break every download at once. Only a commit is immutable.
    func testRevisionsAreCommitHashesNotBranches() {
        XCTAssertFalse(SpeechModelPins.hubRevisions.isEmpty)
        for (repo, revision) in SpeechModelPins.hubRevisions {
            XCTAssertEqual(revision.count, 40, "\(repo) is pinned to '\(revision)', which is not a commit")
        }
    }

    /// Every pinned URL names a revision the pins actually recorded, so a
    /// regenerated file cannot leave a URL behind at an older commit.
    func testEveryPinnedURLUsesARecordedRevision() {
        let revisions = Set(SpeechModelPins.hubRevisions.values)
        for (variant, pins) in SpeechModelPins.files {
            for pin in pins {
                let parts = pin.url.absoluteString.components(separatedBy: "/resolve/")
                XCTAssertEqual(parts.count, 2, pin.url.absoluteString)
                let revision = parts[1].components(separatedBy: "/")[0]
                XCTAssertTrue(revisions.contains(revision),
                              "\(variant): \(pin.relativePath) points at \(revision), which is not in hubRevisions")
            }
        }
    }

    /// FluidAudio and SpeechAnalyzer fetch their own models by their own means;
    /// claiming to pin them would be a claim this project cannot keep.
    func testNonWhisperKitBackendsHaveNoPins() {
        for descriptor in SpeechModelCatalog.availableModels where descriptor.backend != .whisperKit {
            XCTAssertNil(descriptor.pinnedFiles, descriptor.name)
        }
    }
}
