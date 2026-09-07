import CryptoKit
import Foundation

/// The seam between the app and the service.
///
/// The real implementation is `XPCFetcher`; the tests use a fake. The service
/// itself is exercised for real by `scripts/xpc-smoke.sh`, against the built
/// bundle, with a control that must fail.
protocol Fetching {
    /// Writes the body of `url` into `handle`, starting at `offset` bytes, and
    /// returns how many bytes THIS call wrote.
    func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
               progress: @escaping (Int64) -> Void) async throws -> Int64
}

enum ModelDownloadError: Error, Equatable {
    case hashMismatch(String)
    case sizeMismatch(expected: Int64, got: Int64)
    case transport(String)
    case containment(String)
}

/// Fetches a pinned file and verifies it WHERE IT LANDS.
///
/// **The division of labour is the security design.** The service has the
/// network and nothing else: no path, no hash, no idea what a model is. This
/// side owns the destination, so this side decides where bytes may go and
/// whether the bytes that arrived are the bytes that were pinned. Verifying at
/// the source would prove something about the source.
///
/// **A partial is never visible as a model.** Bytes go to `<name>.partial` and
/// are renamed only after size and hash agree, so a crash or a dropped
/// connection leaves something the next run can resume from, and never
/// something the app will load.
final class ModelDownloader {
    private let fetcher: Fetching
    private let root: URL

    init(fetcher: Fetching, root: URL = AppSupportDirectory.url) {
        self.fetcher = fetcher
        self.root = root
    }

    func download(_ pin: PinnedFile, progress: @escaping (Int64, Int64) -> Void) async throws {
        let manager = FileManager.default
        let destination = URL(fileURLWithPath: root.path)
            .appendingPathComponent(pin.relativePath).standardizedFileURL
        let partial = destination.appendingPathExtension("partial")

        // CONTAINMENT, before a single byte is fetched, on the deepest ancestor
        // that EXISTS with symlinks resolved. `resolvingSymlinksInPath` hands a
        // path that does not exist back unchanged, so resolving the parent
        // alone lets a nested path through a symlinked ancestor; a DANGLING
        // link is refused outright, because resolving cannot answer for it and
        // the kernel refusing to mkdir through one is an accident, not a rule.
        // The same reasoning, and the same failures, as `StarterModelInstaller`.
        let rootReal = URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath()
        let ancestor = StarterModelInstaller.deepestExistingAncestor(
            of: destination.deletingLastPathComponent())
        let ancestorIsDanglingLink =
            (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            && !manager.fileExists(atPath: ancestor.path)
        let ancestorReal = ancestor.resolvingSymlinksInPath()
        guard !ancestorIsDanglingLink,
              ancestorReal.path == rootReal.path || ancestorReal.path.hasPrefix(rootReal.path + "/") else {
            throw ModelDownloadError.containment(pin.relativePath)
        }

        // Already there at the pinned size: nothing to do, and nothing to
        // fetch over a metered connection. Size rather than hash on purpose:
        // hashing gigabytes on every launch to decide NOT to download them is
        // the wrong trade, and the loader hashes before it trusts a file.
        if let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil,
           size == pin.byteCount {
            progress(pin.byteCount, pin.byteCount)
            return
        }

        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if !manager.fileExists(atPath: partial.path) {
            manager.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        // Resume from whatever survived the last attempt. On a 4 GB model over
        // a hotel connection this is the difference between a retry and a
        // reason to give up.
        let offset = Int64(try handle.seekToEnd())

        do {
            _ = try await fetcher.fetch(pin.url, into: handle, resumingFrom: offset) { written in
                progress(offset + written, pin.byteCount)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            // The partial STAYS: it is what the next attempt resumes from.
            try? handle.close()
            throw (error as? ModelDownloadError) ?? .transport(String(describing: error))
        }

        let got = (try? manager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? -1
        guard got == pin.byteCount else {
            // Wrong length is not resumable: something served a different file,
            // or an error page. Start clean rather than append to nonsense.
            try? manager.removeItem(at: partial)
            throw ModelDownloadError.sizeMismatch(expected: pin.byteCount, got: got)
        }
        guard let digest = StarterModelInstaller.sha256(ofFileAt: partial),
              digest == pin.sha256.lowercased() else {
            try? manager.removeItem(at: partial)
            throw ModelDownloadError.hashMismatch(pin.relativePath)
        }

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: partial, to: destination)
        progress(pin.byteCount, pin.byteCount)
    }
}

/// The real fetcher: one connection to the embedded service per file.
///
/// The app opens the destination in its own container and passes the
/// descriptor; sandbox permission is decided at `open()`, so the capability
/// crosses the boundary with it and the service writes into a file it could
/// never have opened itself.
final class XPCFetcher: NSObject, Fetching, ModelDownloadProgressProtocol {
    private let lock = NSLock()
    private var onProgress: ((Int64) -> Void)?

    func wrote(bytes: Int64, of url: String) {
        lock.lock()
        let report = onProgress
        lock.unlock()
        report?(bytes)
    }

    func fetch(_ url: URL, into handle: FileHandle, resumingFrom offset: Int64,
               progress: @escaping (Int64) -> Void) async throws -> Int64 {
        lock.lock()
        onProgress = progress
        lock.unlock()
        defer {
            lock.lock()
            onProgress = nil
            lock.unlock()
        }

        let connection = NSXPCConnection(serviceName: modelDownloadServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        connection.exportedObject = self
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            // Resumed exactly once: an error handler and a reply can both
            // arrive when a service dies mid-call.
            let answered = NSLock()
            var done = false
            func answer(_ result: Result<Int64, Error>) {
                answered.lock()
                let first = !done
                done = true
                answered.unlock()
                guard first else { return }
                continuation.resume(with: result)
            }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                answer(.failure(ModelDownloadError.transport(
                    "the model downloader is unavailable: \(error.localizedDescription)")))
            }) as? ModelDownloadServiceProtocol else {
                answer(.failure(ModelDownloadError.transport(
                    "the model downloader did not offer the expected interface")))
                return
            }
            proxy.fetch(url.absoluteString, into: handle, resumingFrom: offset) { written, error in
                if let error {
                    answer(.failure(ModelDownloadError.transport(error)))
                } else {
                    answer(.success(written))
                }
            }
        }
    }
}
