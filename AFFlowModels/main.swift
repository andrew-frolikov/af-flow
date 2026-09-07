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
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 is the resumed case. Anything else, including a redirect landing
        // on an error page, stops before a byte is written: an HTML error body
        // appended to a partial model is exactly the corruption the hash check
        // would later blame on the network.
        guard code == 200 || code == 206 else {
            complete(error: "HTTP \(code)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                progress?.wrote(bytes: written, of: urlString)
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
        progress?.wrote(bytes: written, of: urlString)
        finish(written, error)
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
