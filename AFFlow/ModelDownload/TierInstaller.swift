import Foundation

/// What one attempt at installing a tier did.
///
/// Three outcomes, not two, for the same reason every checker in this project
/// has three: "installed nothing" because everything was already there and
/// "installed nothing" because the first file failed are opposite facts, and
/// collapsing them is how a friend ends up staring at an app that quietly
/// never improved.
struct TierInstallReport: Equatable {
    var installed: [String] = []
    var alreadyPresent: [String] = []
    var failure: String?
    /// Which file the failure was about, so the message can name it.
    var failedPath: String?

    var isComplete: Bool { failure == nil }
}

/// Turns a tier into the files it needs and puts them on disk.
///
/// It asks `QualityTier` what a rung runs rather than holding its own list:
/// that type is the single place saying what Starter and Full are, and a second
/// list is how the ladder and the downloader come to disagree about what was
/// installed.
final class TierInstaller {
    private let downloader: ModelDownloader
    private let root: URL

    init(downloader: ModelDownloader, root: URL = AppSupportDirectory.url) {
        self.downloader = downloader
        self.root = root
    }

    /// Every pinned file a tier needs on this machine.
    ///
    /// The cleanup model depends on RAM, which is why the memory is a
    /// parameter rather than read here: a test has to be able to ask about a
    /// machine it is not running on.
    ///
    /// Main-actor because the cleanup catalogue is, and `install` reads it
    /// there and then does every byte of file work OFF it. Copying a gigabyte
    /// on the main thread is the defect the first-launch installer had.
    @MainActor
    static func pins(for tier: QualityTier, physicalMemory: UInt64) -> [PinnedFile] {
        (try? pinsOrThrow(for: tier, physicalMemory: physicalMemory)) ?? []
    }

    /// The same list, but saying WHY it is short.
    ///
    /// A tier whose speech model has no pins cannot be installed, and the
    /// first version returned the cleanup model alone: `install` would then
    /// report success having fetched half a tier, and the app would sit on a
    /// speech model that is not there. Independent review, 2026-09-07.
    @MainActor
    static func pinsOrThrow(for tier: QualityTier, physicalMemory: UInt64) throws -> [PinnedFile] {
        var pins: [PinnedFile] = []
        guard let model = SpeechModelCatalog.model(named: tier.speechModelID) else {
            throw ModelDownloadError.transport(
                "the catalogue has no speech model called \(tier.speechModelID)")
        }
        guard let speech = model.pinnedFiles, !speech.isEmpty else {
            throw ModelDownloadError.transport(
                "\(model.name) has no pinned files, so it cannot be downloaded")
        }
        pins += speech
        let kind = tier.cleanupModel(physicalMemory: physicalMemory)
        guard let cleanup = TextCleanupManager.descriptor(for: kind) else {
            throw ModelDownloadError.transport(
                "the catalogue has no cleanup model for \(kind.rawValue)")
        }
        pins.append(cleanup.pinnedFile)
        return pins
    }

    /// Installs what is missing and reports what happened.
    ///
    /// **Stops at the first failure on purpose.** A tier is not useful in
    /// pieces: three of five files installed is still a model that cannot
    /// load, and continuing would spend a friend's bandwidth to reach the same
    /// place with a longer error. The files already fetched stay, so a retry
    /// resumes rather than restarts.
    func install(_ tier: QualityTier,
                 physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                 progress: @escaping (String, Int64, Int64) -> Void) async -> TierInstallReport {
        var report = TierInstallReport()
        let pins: [PinnedFile]
        do {
            pins = try await MainActor.run { try Self.pinsOrThrow(for: tier, physicalMemory: physicalMemory) }
        } catch {
            report.failure = Self.explain(error, file: "the \(tier) tier")
            return report
        }
        for pin in pins {
            let destination = root.appendingPathComponent(pin.relativePath)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            if size == pin.byteCount {
                report.alreadyPresent.append(pin.relativePath)
                continue
            }
            progress(pin.relativePath, 0, pin.byteCount)
            do {
                try await downloader.download(pin) { done, total in
                    progress(pin.relativePath, done, total)
                }
                report.installed.append(pin.relativePath)
            } catch {
                report.failedPath = pin.relativePath
                report.failure = Self.explain(error, file: pin.relativePath)
                return report
            }
        }
        return report
    }

    /// Plain words, because this string reaches a friend who did not write it.
    static func explain(_ error: Error, file: String) -> String {
        guard let error = error as? ModelDownloadError else {
            return "\(file): \(error.localizedDescription)"
        }
        switch error {
        case .transport(let detail):
            return "\(file) could not be downloaded: \(detail)"
        case .hashMismatch:
            return "\(file) arrived with the wrong contents and was discarded. "
                + "Nothing was installed; try again."
        case .sizeMismatch(let expected, let got):
            return "\(file) arrived as \(got) bytes where \(expected) were expected, "
                + "so it was discarded. Try again."
        case .containment(let path):
            return "\(path) would have been written outside the models folder, so it was refused."
        }
    }
}
