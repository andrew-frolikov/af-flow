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

    static var url: URL {
        resolve(in: baseDirectory)
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
