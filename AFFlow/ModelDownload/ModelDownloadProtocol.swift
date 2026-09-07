import Foundation

/// The service's bundle identifier, and the name `NSXPCConnection` resolves.
///
/// Inside the family on purpose (launch plan open item 3, ratified 2026-08-30):
/// moving it out to keep `lulu-rule-check.py`'s sentence absolute would hide it
/// from `system-list-check.py`, which audits by the same prefix and is the
/// checker with the track record. `lulu_rules.HELPER_ID` is the other half of
/// this constant; the two must agree.
let modelDownloadServiceName = "com.frolikov.afflow.models"

/// What the service does, and ALL it does: bytes from one URL into one
/// descriptor its host already opened.
///
/// It never chooses a URL, never opens a file, never verifies a hash, and has
/// no idea what a model is. Verification belongs to the side that owns the
/// destination (`ModelDownloader`), which is the `download-model.sh` lesson:
/// bytes are checked where they LAND, not where they came from. Handing the
/// service a descriptor rather than a path is what lets the app keep its
/// container to itself: sandbox permission is decided at `open()`, so the
/// descriptor carries the capability across the boundary and the service can
/// write into a file it could never have opened.
@objc protocol ModelDownloadServiceProtocol {
    /// `offset` > 0 is sent as a `Range` header, so a dropped download resumes
    /// instead of starting again. `reply` carries the bytes THIS call wrote and
    /// an error string, or nil.
    func fetch(_ urlString: String,
               into handle: FileHandle,
               resumingFrom offset: Int64,
               reply: @escaping (Int64, String?) -> Void)

    /// Stops an in-flight transfer and replies to the outstanding `fetch`.
    ///
    /// Without this, cancelling was a lie: the host's `Task.cancel()` cannot
    /// reach across XPC, so the bytes kept flowing to completion while the UI
    /// said the download had stopped, and the manager refused to start another
    /// one because its state was still `.downloading`.
    func cancelActiveDownload()
}

/// Exported by the APP so the service can report progress while it streams.
@objc protocol ModelDownloadProgressProtocol {
    func wrote(bytes: Int64, of url: String)
}
