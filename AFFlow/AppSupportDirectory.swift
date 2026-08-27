import Foundation

/// The one place that decides where AF Flow keeps its Application Support data.
///
/// WHY THIS EXISTS. The folder used to be named after the upstream project. Five
/// call sites each built that path themselves, so renaming the app by find and
/// replace would have pointed all five at an empty new folder and silently
/// orphaned every meeting recording, debug log and recognised voice already on
/// disk. Nothing would have crashed. The data would simply have stopped being
/// there, which is the worst shape a bug can take.
///
/// So the rename carries a migration, and the migration lives in exactly one
/// place. `resolve(in:)` takes its base directory as a parameter so a test can
/// drive it against a temporary directory rather than the real container.
enum AppSupportDirectory {
    static let folderName = "AF Flow"

    /// The pre-rename folder name. Kept as a constant, not a literal buried in a
    /// condition, because the day it is deleted should be a deliberate edit.
    static let legacyFolderName = "GhostPepper"

    /// The folder name nobody chose.
    ///
    /// The 2026-08-25 rename find-and-replaced `GhostPepper` into `AFFlow`
    /// inside two hardcoded path literals, so the models went to `AFFlow` while
    /// this file moved everything else to `AF Flow`. Between that day and this
    /// fix, a model downloaded for the first time landed there and NOWHERE
    /// ELSE. Measured on his test host: 65 files, 153.7 MB, no copy under the
    /// real folder. So this name cannot simply be dropped; what is under it has
    /// to be carried across.
    static let interimFolderName = "AFFlow"

    static var url: URL {
        let resolved = resolve(in: baseDirectory)
        // Once per process, not per access: this walks a directory tree, and
        // `url` is read on hot paths.
        _ = interimAbsorption
        return resolved
    }

    private static let interimAbsorption: Void = {
        absorbInterimFolder(in: baseDirectory)
    }()

    /// Move anything that exists ONLY in the interim folder into the real one.
    ///
    /// Three rules, and each one is there because of how this kind of code
    /// fails:
    ///
    ///   - a file already present in the real folder is LEFT ALONE, in both
    ///     places. Never overwrite: the copy the app has been reading is the
    ///     one that works.
    ///   - nothing is ever deleted. Empty directories are pruned, and a
    ///     directory that still holds something stays.
    ///   - a failure to move one file does not stop the others, because a
    ///     partial migration that reports success is worse than a loud one.
    ///
    /// The pre-rename folder is deliberately NOT absorbed. That one means an
    /// old install beside a live one, and `resolve` already decides between
    /// them; this one means a defect, and its contents may be unique.
    @discardableResult
    static func absorbInterimFolder(in base: URL) -> Int {
        let current = resolve(in: base)
        let interim = base.appendingPathComponent(interimFolderName, isDirectory: true)
        guard interim.standardizedFileURL != current.standardizedFileURL else { return 0 }
        guard isDirectory(interim) else { return 0 }

        let manager = FileManager.default
        guard let walker = manager.enumerator(at: interim, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }

        var moved = 0
        var directories: [URL] = []
        for case let item as URL in walker {
            if isDirectory(item) {
                directories.append(item)
                continue
            }
            let relative = item.path.dropFirst(interim.path.count).drop(while: { $0 == "/" })
            let destination = current.appendingPathComponent(String(relative))
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.moveItem(at: item, to: destination)
                moved += 1
            } catch {
                NSLog("AppSupportDirectory: could not carry %@ across: %@",
                      String(relative), error.localizedDescription)
            }
        }

        // Deepest first, so a directory emptied by the loop above can itself be
        // pruned. `removeEmptyDirectory` checks the contents before removing,
        // so a directory still holding something survives.
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try? removeEmptyDirectory(directory)
        }
        try? removeEmptyDirectory(interim)
        return moved
    }

    private static func removeEmptyDirectory(_ url: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
        guard contents.isEmpty else { return }
        try FileManager.default.removeItem(at: url)
    }

    static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
    }

    /// Returns the current folder, moving the legacy folder into place once if
    /// that is what is on disk.
    ///
    /// Three outcomes, and the third is the one that matters:
    ///
    ///   - the new folder exists: use it, and never look at the old one
    ///   - neither exists: use the new name, and let the caller create it
    ///   - only the old one exists: move it, and **if the move fails, keep using
    ///     the old folder**
    ///
    /// A failed move must not degrade into "start fresh somewhere else". Reaching
    /// the data under its old name is always better than not reaching it at all.
    static func resolve(in base: URL) -> URL {
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)

        // `fileExists(atPath:)` alone is not the question being asked. It answers
        // true for a plain FILE sitting at that path, and the first version of
        // this asked exactly that, so a file named "AF Flow" would have been
        // accepted as the data folder and every write under it would then have
        // failed. The test that installs such a file is what caught it.
        if isDirectory(current) { return current }
        guard isDirectory(legacy) else { return current }

        do {
            try FileManager.default.moveItem(at: legacy, to: current)
            return current
        } catch {
            return legacy
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
