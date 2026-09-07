import CryptoKit
import Foundation

/// Moves the models the DMG carries into the folders the app actually reads.
///
/// **The gap this closes.** `release-build.sh` puts the Starter tier in
/// `Contents/Resources/StarterModels`; `TextCleanupManager` reads
/// `<App Support>/models` and `ModelManager` reads
/// `<App Support>/whisper-models`. Nothing joined the two, so on a friend's Mac
/// with an empty cache the app would have attempted a download the kernel
/// blocks, and the DMG's central promise, dictation working offline the moment
/// it opens, was not a claim the build kept. Codex found it on 2026-08-30.
///
/// **The bundled tree MIRRORS the destination tree**, so this file needs to
/// know nothing about model internals: `StarterModels/models/foo.gguf` lands at
/// `<App Support>/models/foo.gguf`. One layout, defined by the app, copied
/// verbatim. A second description of where a model lives is the defect that
/// put his models in a third folder for 24 days.
enum StarterModelInstaller {
    /// What a bundled file must be, checked where it LANDS. The
    /// `download-model.sh` lesson: verifying the source proves the source.
    struct Expectation: Equatable {
        let sha256: String
        let byteCount: Int64
    }

    struct Outcome: Equatable, CustomStringConvertible {
        var installed = 0
        var skipped = 0
        var failures: [String] = []
        var hadNothingBundled = false

        var description: String {
            "installed \(installed), skipped \(skipped), "
            + "failures \(failures), nothingBundled \(hadNothingBundled)"
        }
    }

    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies every bundled file that is not already present.
    ///
    /// `expected` is keyed by the same relative path the tree uses, so a model
    /// the catalogue pins by hash is checked and one it does not is copied on
    /// trust. Speech models are the second case today: WhisperKit fetches them
    /// by name and publishes no checksum this project could pin, which is
    /// stated in `model_catalogue.py` rather than papered over.
    static func install(
        from bundledRoot: URL,
        into destinationRoot: URL,
        expected: [String: Expectation] = [:]
    ) -> Outcome {
        var outcome = Outcome()
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: bundledRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            outcome.hadNothingBundled = true
            return outcome
        }
        // The root itself is never enumerated, so it was the one directory
        // symlink the walk below could not see. Codex, 2026-09-06.
        if (try? bundledRoot.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            outcome.failures.append("refused a bundled models folder that is itself a symbolic link")
            return outcome
        }

        // `.skipsHiddenFiles` is deliberately NOT set: a payload is not a place
        // for hidden files, and silently skipping them would hide a problem
        // rather than report it. Symbolic links are refused below.
        guard let walker = manager.enumerator(
            at: bundledRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []) else {
            outcome.failures.append("could not read the bundled models folder")
            return outcome
        }

        // Containment is decided on REAL paths. `standardizedFileURL` folds
        // `..` but does NOT resolve symlinks, and a first version relied on it
        // while its comment claimed otherwise: a `models` entry at the
        // destination that was itself a symlink passed the prefix test and the
        // bytes landed wherever it pointed. Codex, 2026-09-06.
        let destinationBase = URL(fileURLWithPath: destinationRoot.path).standardizedFileURL
        let destinationReal = destinationBase.resolvingSymlinksInPath()

        for case let source as URL in walker {
            // A SYMLINK IS THE ESCAPE THAT ACTUALLY EXISTS. A literal `..` in a
            // path cannot be staged: the filesystem resolves it at write time,
            // so the file simply lands elsewhere and never enters the payload.
            // A symlink does enter it, and this project already carries the
            // failure as ledger 21/22, "symlink evades containment". Refused
            // rather than resolved, because resolving invites the question of
            // where it is allowed to point and refusing does not.
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let name = source.lastPathComponent
                outcome.failures.append("refused a symbolic link in the bundled payload: \(name)")
                walker.skipDescendants()
                continue
            }
            // A HIDDEN entry is a staging mistake (Finder's .DS_Store, a
            // WhisperKit .cache) and is refused and reported, never installed
            // and never skipped in silence. `release-build.sh` refuses the
            // same thing at build time, so a shipped DMG never trips this.
            if source.lastPathComponent.hasPrefix(".") {
                outcome.failures.append("refused a hidden entry in the bundled payload: \(source.lastPathComponent)")
                walker.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }

            // The path RELATIVE to the payload root: a prefix strip, not a
            // replace-all, which would also fold a recurrence of the root
            // string deeper in the path.
            let rootPrefix = bundledRoot.standardizedFileURL.path + "/"
            let sourcePath = source.standardizedFileURL.path
            guard sourcePath.hasPrefix(rootPrefix) else {
                outcome.failures.append("refused a bundled entry outside the payload root: \(source.lastPathComponent)")
                continue
            }
            let relative = String(sourcePath.dropFirst(rootPrefix.count))
            let target = destinationBase.appendingPathComponent(relative).standardizedFileURL

            // CONTAINMENT, on the deepest ancestor that EXISTS. The parent may
            // not exist yet, and `resolvingSymlinksInPath` hands a path that
            // does not exist back UNCHANGED rather than resolving the part of
            // it that does, so a first version of this check passed a nested
            // payload path straight through a symlinked `models` folder. Codex
            // reproduced that against Foundation on 2026-09-06. Walking up to
            // the existing ancestor and resolving THAT is what decides where
            // `createDirectory` would put the missing levels.
            //
            // A DANGLING link is the one case resolving cannot answer: Foundation
            // returns a dangling link unchanged too, so it would read as
            // contained. The kernel happens to refuse to mkdir through one, but
            // an escape that fails by accident is not a refusal. Refused
            // outright. Independent third-pass review, 2026-09-06.
            let existingAncestor = Self.deepestExistingAncestor(of: target.deletingLastPathComponent())
            let ancestorIsDanglingLink =
                (try? existingAncestor.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                && !manager.fileExists(atPath: existingAncestor.path)
            let existingAncestorReal = existingAncestor.resolvingSymlinksInPath()
            guard !ancestorIsDanglingLink,
                  existingAncestorReal.path == destinationReal.path
                    || existingAncestorReal.path.hasPrefix(destinationReal.path + "/") else {
                outcome.failures.append("refused a bundled path that escapes the models folder: \(relative)")
                continue
            }

            // A symlink AT the destination path is named as one and left
            // alone; measuring it as a wrong-sized file would report the
            // link's own length.
            if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                outcome.failures.append("\(relative) is a symbolic link at the destination; left untouched")
                continue
            }

            // NEVER OVERWRITE. There are 6.8 GB of his own models on this Mac.
            // A file at a PINNED path is still checked by size, because a
            // truncated one is a model the app will later reject and try to
            // download, and that download dies in the kernel. Reported, left
            // alone. Size only: hashing his models on every launch is not free.
            if manager.fileExists(atPath: target.path) {
                if let want = expected[relative] {
                    let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? nil
                    if size != want.byteCount {
                        outcome.failures.append(
                            "\(relative) is already present but is \(size.map(String.init) ?? "unreadable") "
                            + "bytes where \(want.byteCount) are pinned; left untouched")
                        continue
                    }
                }
                outcome.skipped += 1
                continue
            }

            // Copy to a temporary name and rename into place, so a crash
            // mid-copy never leaves a half file at the path the app checks
            // and treats as a working model. Every failure path below removes
            // the staging file: nothing later would.
            let staging = target.deletingLastPathComponent()
                .appendingPathComponent(".installing-" + UUID().uuidString)
            do {
                try manager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: staging)

                if let want = expected[relative] {
                    let size = (try? manager.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? nil
                    let digest = sha256(ofFileAt: staging)
                    if size != want.byteCount || digest?.lowercased() != want.sha256.lowercased() {
                        try? manager.removeItem(at: staging)
                        outcome.failures.append(
                            "\(relative) does not match its pinned hash or byte count, so it was removed")
                        continue
                    }
                }

                // Two installers racing: the other one won, and the model is
                // there. Not a failure, and not a leftover either.
                if manager.fileExists(atPath: target.path) {
                    try? manager.removeItem(at: staging)
                    outcome.skipped += 1
                    continue
                }
                try manager.moveItem(at: staging, to: target)
                outcome.installed += 1
            } catch {
                try? manager.removeItem(at: staging)
                // If the model is there now, the other installer won the race
                // between the check above and the rename; that is a skip.
                if manager.fileExists(atPath: target.path) {
                    outcome.skipped += 1
                } else {
                    outcome.failures.append("\(relative): \(error.localizedDescription)")
                }
            }
        }
        return outcome
    }

    /// The nearest ancestor of `url` (or `url` itself) that exists on disk.
    /// Never climbs above the filesystem root; "/" always exists.
    static func deepestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL
        // A symlink "exists" for this purpose, dangling or not: the caller
        // resolves a live one and refuses a dangling one.
        while !FileManager.default.fileExists(atPath: candidate.path)
                && (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                && candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    /// The real call: the app's own bundle into the one folder that names
    /// itself, `AppSupportDirectory`.
    @discardableResult
    static func installBundledModels(bundle: Bundle = .main) -> Outcome {
        guard let root = bundle.resourceURL?
            .appendingPathComponent("StarterModels", isDirectory: true) else {
            var outcome = Outcome(); outcome.hadNothingBundled = true; return outcome
        }
        return install(from: root, into: AppSupportDirectory.url, expected: pinnedExpectations())
    }

    /// Only the cleanup models are hash-pinned; the speech models are fetched
    /// by name upstream with no published checksum, which is recorded in
    /// `model_catalogue.py` and is why this map is partial rather than total.
    static func pinnedExpectations() -> [String: Expectation] {
        var map: [String: Expectation] = [:]
        for descriptor in TextCleanupManager.cleanupModels {
            map["models/" + descriptor.fileName] = Expectation(
                sha256: descriptor.expectedSHA256,
                byteCount: descriptor.expectedByteCount)
        }
        return map
    }
}
