import Foundation

/// One downloadable file, pinned by hash and size.
///
/// **Why one shape.** The downloader verifies bytes in exactly one place, so
/// both catalogues have to speak the same language: the cleanup GGUFs, which
/// have carried a URL, a SHA-256 and a byte count from the start, and the
/// speech models, which carried none until `SpeechModelPins` (launch plan open
/// item 2). Two shapes would mean two verifications, and the one written
/// second is the one that ships unpinned bytes.
///
/// **`relativePath` is the app's own layout**, the same root
/// `StarterModelInstaller` mirrors: `models/<file>.gguf` for cleanup,
/// `whisper-models/models/...` for speech. Nothing here decides where a model
/// lives; `AppSupportDirectory` does, and this resolves against it.
struct PinnedFile: Equatable, Hashable {
    /// Relative to `AppSupportDirectory.url`, never absolute.
    let relativePath: String
    let url: URL
    /// Lowercase hex, 64 characters.
    let sha256: String
    let byteCount: Int64

    var destination: URL { AppSupportDirectory.url.appendingPathComponent(relativePath) }
}

extension CleanupModelDescriptor {
    /// The catalogue already pins URL, hash and size; this is the same fact in
    /// the shape the downloader reads. `models/` is where `TextCleanupManager`
    /// looks, not a new decision made here.
    var pinnedFile: PinnedFile {
        PinnedFile(relativePath: "models/" + fileName,
                   url: URL(string: url)!,
                   sha256: expectedSHA256.lowercased(),
                   byteCount: expectedByteCount)
    }
}
