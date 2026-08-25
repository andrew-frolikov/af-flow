import Foundation

enum ReaderCaptureError: LocalizedError {
    case invalidURL
    case fetchFailed(Int)
    case decodeFailed
    case noContent

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Not a valid URL."
        case .fetchFailed(let code): return "Couldn't fetch the page (HTTP \(code))."
        case .decodeFailed: return "Couldn't decode the page text."
        case .noContent: return "Couldn't find article content on the page."
        }
    }
}

/// Fetches a web page, extracts a title + readable body, and writes it to the
/// meeting archive as a markdown file the existing meeting parser can open.
///
/// v0 extractor: very basic regex/string-based HTML → markdown. Good enough for
/// blog posts and static pages; will struggle with SPAs. Upgrade path is to
/// swap in Mozilla Readability.js via headless WKWebView when quality matters.
enum ReaderCapture {
    struct Result {
        let fileURL: URL
        let title: String
    }

    @MainActor
    static func capture(urlString: String, archiveRoot: URL) async throws -> Result {
        guard let url = normalizeURL(urlString) else { throw ReaderCaptureError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ReaderCaptureError.fetchFailed(http.statusCode)
        }
        guard let html = decodeHTML(data) else { throw ReaderCaptureError.decodeFailed }

        let title = extractTitle(from: html) ?? url.host ?? "Untitled"
        let body = extractBody(from: html)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderCaptureError.noContent
        }

        let transcript = MeetingTranscript(meetingName: title)
        transcript.articleBody = body
        transcript.sourceURL = url.absoluteString

        let directory = archiveRoot
            .appendingPathComponent("Reads", isDirectory: true)
            .appendingPathComponent(dateFolderName(for: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let slug = MeetingMarkdownWriter.slugify(title)
        let fileURL = uniqueFileURL(directory: directory, baseName: slug)
        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: transcript)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return Result(fileURL: fileURL, title: title)
    }

    // MARK: - HTML decoding

    private static func decodeHTML(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }

    private static func normalizeURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    // MARK: - Title

    private static func extractTitle(from html: String) -> String? {
        if let og = match(html, pattern: "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)") {
            return decodeEntities(og)
        }
        if let title = match(html, pattern: "<title[^>]*>([^<]+)</title>") {
            return decodeEntities(title)
        }
        return nil
    }

    // MARK: - Body extraction

    private static func extractBody(from html: String) -> String {
        var stripped = html
        // Drop script/style blocks and HTML comments — they confuse the converter.
        stripped = removeBlocks(stripped, tag: "script")
        stripped = removeBlocks(stripped, tag: "style")
        stripped = removeBlocks(stripped, tag: "noscript")
        // Drop common chrome that's often above the article title.
        stripped = removeBlocks(stripped, tag: "nav")
        stripped = removeBlocks(stripped, tag: "header")
        stripped = removeBlocks(stripped, tag: "footer")
        stripped = removeBlocks(stripped, tag: "aside")
        stripped = stripped.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        // Prefer <article>, then <main>, then <body>.
        var candidate = firstMatchInner(stripped, tags: ["article", "main"]) ?? firstMatchInner(stripped, tags: ["body"]) ?? stripped

        // If there's an <h1>, treat it as the start of the real article — drops
        // any breadcrumb/category text the page rendered above the title.
        if let h1Range = candidate.range(of: "<h1\\b", options: [.regularExpression, .caseInsensitive]) {
            candidate = String(candidate[h1Range.lowerBound...])
        }

        return htmlToMarkdown(candidate)
    }

    private static func removeBlocks(_ html: String, tag: String) -> String {
        let pattern = "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>"
        return html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    private static func firstMatchInner(_ html: String, tags: [String]) -> String? {
        for tag in tags {
            let pattern = "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>"
            if let inner = match(html, pattern: pattern) { return inner }
        }
        return nil
    }

    // MARK: - HTML → Markdown (very basic)

    private static func htmlToMarkdown(_ html: String) -> String {
        var s = html

        // Headings
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            s = s.replacingOccurrences(
                of: "<h\(level)\\b[^>]*>([\\s\\S]*?)</h\(level)>",
                with: "\n\n\(hashes) $1\n\n",
                options: .regularExpression
            )
        }

        // Block elements → paragraph breaks
        s = s.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: .regularExpression)
        s = s.replacingOccurrences(of: "</li>", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<blockquote\\b[^>]*>", with: "\n\n> ", options: .regularExpression)
        s = s.replacingOccurrences(of: "</blockquote>", with: "\n\n", options: .caseInsensitive)

        // Inline emphasis
        s = s.replacingOccurrences(of: "<(strong|b)\\b[^>]*>", with: "**", options: .regularExpression)
        s = s.replacingOccurrences(of: "</(strong|b)>", with: "**", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(em|i)\\b[^>]*>", with: "*", options: .regularExpression)
        s = s.replacingOccurrences(of: "</(em|i)>", with: "*", options: .regularExpression)
        s = s.replacingOccurrences(of: "<code\\b[^>]*>", with: "`", options: .regularExpression)
        s = s.replacingOccurrences(of: "</code>", with: "`", options: .caseInsensitive)

        // Links → [text](href)
        s = s.replacingOccurrences(
            of: "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            with: "[$2]($1)",
            options: .regularExpression
        )

        // Drop everything else
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        s = decodeEntities(s)
        s = collapseWhitespace(s)
        return s
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n[ \\t]+", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""), ("&copy;", "©"),
            ("&reg;", "®"), ("&trade;", "™"),
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }

        out = replaceNumericEntities(out, hex: false)
        out = replaceNumericEntities(out, hex: true)
        return out
    }

    private static func replaceNumericEntities(_ s: String, hex: Bool) -> String {
        let pattern = hex ? "&#x([0-9A-Fa-f]+);" : "&#([0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out = s
        for m in matches.reversed() {
            let digits = ns.substring(with: m.range(at: 1))
            let code = UInt32(digits, radix: hex ? 16 : 10) ?? 0
            if let scalar = Unicode.Scalar(code) {
                let replacement = String(Character(scalar))
                let nsOut = out as NSString
                out = nsOut.replacingCharacters(in: m.range, with: replacement)
            }
        }
        return out
    }

    private static func match(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - File output

    private static func dateFolderName(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func uniqueFileURL(directory: URL, baseName: String) -> URL {
        let base = baseName.isEmpty ? "article" : baseName
        var candidate = directory.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        return candidate
    }
}
