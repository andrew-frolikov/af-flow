import Foundation

/// **AF Flow Models: the one process in this bundle allowed to open a socket.**
///
/// The main app has no `com.apple.security.network.client` and never gets it
/// back; every outbound connection it attempts dies in the kernel. This service
/// carries that entitlement and nothing else, and `launchd` starts it with its
/// OWN sandbox rather than its host's, which is the mechanism the 2026-09-06
/// spike proved on this Mac: the host got `NSPOSIXErrorDomain 1` for its own
/// fetch while the service fetched the same URL and wrote the bytes into a
/// descriptor the host had passed it.
///
/// It is deliberately stupid. It gets a URL string and a file handle. It does
/// not know where models live, what a hash is, or which model is being
/// installed, so a compromised or confused service can only write bytes into a
/// file its host already chose and already opened.
private final class Download: NSObject, URLSessionDataDelegate {
    private let handle: FileHandle
    private let urlString: String
    private let progress: ModelDownloadProgressProtocol?
    private let finish: (Int64, String?) -> Void

    private var written: Int64 = 0
    private var lastReport = Date.distantPast
    private var finished = false
    private var session: URLSession?
    private var requestedOffset: Int64 = 0

    init(handle: FileHandle,
         urlString: String,
         progress: ModelDownloadProgressProtocol?,
         finish: @escaping (Int64, String?) -> Void) {
        self.handle = handle
        self.urlString = urlString
        self.progress = progress
        self.finish = finish
    }

    func start(resumingFrom offset: Int64) {
        // http(s) only. The service will not be talked into opening a file:// or
        // any other scheme by a caller, however the caller got its URL.
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            complete(error: "refused a URL that is not http(s)")
            return
        }
        requestedOffset = offset
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        // Only a success is written into the descriptor. What this does NOT
        // do, stated because the first version's comment claimed it did:
        // redirects are followed by URLSession before this is called, so an
        // error page served as 200 by whatever the redirect landed on IS
        // written. The destination-side hash and size are what catch that; the
        // cost is bandwidth, never a bad install.
        guard code == 200 || code == 206 else {
            complete(error: "HTTP \(code)")
            completionHandler(.cancel)
            return
        }

        if requestedOffset > 0 {
            if code == 200 {
                // THE SERVER IGNORED THE RANGE and is sending the whole file.
                // `python3 -m http.server` does exactly this, and so do some
                // proxies and mirrors. Appending it to what is already there
                // produces a file the size check rejects, wasting the entire
                // download. Truncating first turns it into a clean restart.
                do {
                    try handle.truncate(atOffset: 0)
                    // This transfer now starts from zero, and `written` means
                    // what it says: the bytes THIS call wrote. The host adds
                    // its stale resume offset when it renders progress, so a
                    // bar can read high by that much after a truncation. The
                    // file SIZE is what decides success and it is exact, so
                    // this is a cosmetic overshoot in a rare case, not a lie
                    // about what is on disk.
                    written = 0
                } catch {
                    complete(error: "the server ignored the resume request and the partial "
                             + "could not be cleared: \(error.localizedDescription)")
                    completionHandler(.cancel)
                    return
                }
            } else if let range = http?.value(forHTTPHeaderField: "Content-Range"),
                      !range.hasPrefix("bytes \(requestedOffset)-") {
                // A 206 for a range nobody asked for would land at the wrong
                // offset. Refused rather than written and blamed on the hash.
                complete(error: "the server answered a different range (\(range)) "
                         + "than the \(requestedOffset) bytes already fetched")
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress?.wrote(bytes: max(written, 0), of: urlString)
            }
        } catch {
            complete(error: "write failed: \(error.localizedDescription)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            complete(error: "\(error.domain) \(error.code): \(error.localizedDescription)")
        } else {
            complete(error: nil)
        }
        session.finishTasksAndInvalidate()
    }

    /// Called from several places and exactly once: a cancel after an error
    /// arrives here a second time through `didCompleteWithError`.
    private func complete(error: String?) {
        guard !finished else { return }
        finished = true
        try? handle.synchronize()
        // `written` can be negative for a moment after a truncation, which
        // means "this transfer has undone more than it has written"; the
        // caller only ever needs a count of what is in the file now.
        let total = max(written, 0)
        progress?.wrote(bytes: total, of: urlString)
        finish(total, error)
    }

    /// Stops an in-flight transfer. The host calls this when its own task is
    /// cancelled; without it, pressing Cancel left the bytes flowing to
    /// completion while the UI claimed the download had stopped.
    func cancel() {
        session?.invalidateAndCancel()
        complete(error: nil)
    }
}

private final class Service: NSObject, ModelDownloadServiceProtocol {
    weak var connection: NSXPCConnection?
    private var active: Download?

    func fetch(_ urlString: String,
               into handle: FileHandle,
               resumingFrom offset: Int64,
               reply: @escaping (Int64, String?) -> Void) {
        let progress = connection?.remoteObjectProxy as? ModelDownloadProgressProtocol
        let download = Download(handle: handle, urlString: urlString, progress: progress) { [weak self] written, error in
            self?.active = nil
            reply(written, error)
        }
        // Held so ARC does not release the delegate mid-stream.
        active = download
        download.start(resumingFrom: offset)
    }

    func cancelActiveDownload() {
        active?.cancel()
        active = nil
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = Service()
        service.connection = connection
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadProgressProtocol.self)
        connection.resume()
        return true
    }
}

private let delegate = Listener()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
