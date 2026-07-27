import Foundation

/// Helpers for persisting meeting transcript settings.
enum MeetingTranscriptSettings {
    private static let saveDirectoryKey = "meetingTranscriptSaveDirectory"
    private static let saveDirectoryPathKey = saveDirectoryKey + "Path"
    private static let securityScopeLock = NSLock()
    private static var accessedSecurityScopedPaths = Set<String>()

    /// Returns the default save directory: Documents/Ghost Pepper Meetings.
    static func defaultSaveDirectory() -> URL {
        documentsArchiveURL()
    }

    /// The vault folder meetings should live in, if it exists.
    ///
    /// Only a SUGGESTION, used to open the folder picker in the right place.
    /// AF Flow is sandboxed, so it genuinely cannot write here until Andrew
    /// selects it himself, and returning a path he has not granted would produce
    /// silent write failures rather than access.
    static func suggestedVaultDirectory() -> URL? {
        // `FileManager.homeDirectoryForCurrentUser` returns the app's CONTAINER
        // in a sandboxed process, not ~. The first version of this used it, so
        // it looked inside the container, found nothing, and silently opened the
        // picker wherever macOS felt like. Andrew hit that immediately.
        //
        // `getpwuid` reports the real home regardless of the sandbox. Reading
        // the folder still requires his grant; this only decides where the
        // picker starts.
        guard let raw = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: raw), isDirectory: true)

        let url = home
            .appendingPathComponent("Claude")
            .appendingPathComponent("AndrewFrolikov OS")
            .appendingPathComponent("Meetings")

        // Deliberately NOT gated on `fileExists`: a sandboxed process cannot
        // necessarily stat a path it has no grant for, so checking would fail
        // for the same reason the original bug did. An `NSOpenPanel` given a
        // directory that is not there simply opens elsewhere, which is the
        // behaviour we already have to tolerate.
        return url
    }

    /// Load the user-chosen save directory, or nil to use the default.
    static func loadSaveDirectory() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: saveDirectoryKey) else {
            guard let path = UserDefaults.standard.string(forKey: saveDirectoryPathKey), !path.isEmpty else {
                return nil
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isOwnSandboxArchiveURL(url) {
                return defaultSaveDirectory()
            }
            if isLegacyAppContainerArchiveURL(url) {
                UserDefaults.standard.removeObject(forKey: saveDirectoryPathKey)
                return nil
            }
            return url
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isOwnSandboxArchiveURL(url) {
            if isStale {
                UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
            }
            return defaultSaveDirectory()
        }
        if isLegacyAppContainerArchiveURL(url) {
            UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
            return nil
        }
        startAccessingIfNeeded(url)
        if isStale {
            // Re-save fresh bookmark
            saveSaveDirectory(url)
        }
        return url
    }

    /// Persist the user-chosen save directory as a security-scoped bookmark.
    static func saveSaveDirectory(_ url: URL) {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            // Fallback: just save the path if bookmark fails (non-sandboxed app)
            UserDefaults.standard.set(url.path, forKey: saveDirectoryPathKey)
            return
        }
        UserDefaults.standard.set(bookmarkData, forKey: saveDirectoryKey)
        UserDefaults.standard.removeObject(forKey: saveDirectoryPathKey)
        startAccessingIfNeeded(url)
    }

    /// Returns the effective save directory (user-chosen or default).
    static func effectiveSaveDirectory() -> URL {
        return loadSaveDirectory() ?? defaultSaveDirectory()
    }

    private static func startAccessingIfNeeded(_ url: URL) {
        let path = url.standardizedFileURL.path
        securityScopeLock.lock()
        defer { securityScopeLock.unlock() }
        guard !accessedSecurityScopedPaths.contains(path) else { return }
        if url.startAccessingSecurityScopedResource() {
            accessedSecurityScopedPaths.insert(path)
        }
    }

    static func appContainerArchiveIfPresent() -> URL? {
        guard !isRunningInAppSandbox else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.github.matthartman.ghostpepper"
        let archive = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Documents/Ghost Pepper Meetings", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return archive
    }

    private static var isRunningInAppSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ||
            NSHomeDirectory().contains("/Library/Containers/")
    }

    private static func documentsArchiveURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Ghost Pepper Meetings", isDirectory: true)
    }

    private static func isOwnSandboxArchiveURL(_ url: URL) -> Bool {
        guard isRunningInAppSandbox else { return false }
        return url.standardizedFileURL.path == documentsArchiveURL().standardizedFileURL.path
    }

    private static func isLegacyAppContainerArchiveURL(_ url: URL) -> Bool {
        guard !isRunningInAppSandbox else { return false }
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") &&
            path.hasSuffix("/Data/Documents/Ghost Pepper Meetings")
    }
}
