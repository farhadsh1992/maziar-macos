import Foundation

/// Best-effort plain-text extraction from a webpage — used to give the AI a head start when a
/// conference's official site URL is already known, instead of relying entirely on its own
/// (slower, less reliable) search tool. Not a full HTML parser: strips scripts/styles/tags with
/// regex and collapses whitespace, which is good enough for a "read the deadlines off this page"
/// prompt.
enum WebPageFetcher {
    static func fetchPlainText(from url: URL, maxLength: Int = 6000, timeout: TimeInterval = 20) async -> String? {
        guard let html = await fetchRawHTML(from: url, timeout: timeout) else { return nil }
        let text = plainText(fromHTML: html)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxLength))
    }

    /// Extracts `(visible link text, resolved absolute URL)` pairs from a page's `<a>` tags — used
    /// to read a "list of conferences" page (e.g. thecvf.com) well enough to hand the links to an
    /// LLM for it to pick out which ones are actual conferences. A lightweight regex scrape, not a
    /// full HTML/DOM parser: good enough for typical static listing pages, not for JS-rendered ones.
    static func fetchLinks(from url: URL, maxLinks: Int = 400, timeout: TimeInterval = 20) async -> [(text: String, href: String)] {
        guard let html = await fetchRawHTML(from: url, timeout: timeout) else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\s+[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var results: [(text: String, href: String)] = []
        var seen = Set<String>()

        for match in matches {
            guard results.count < maxLinks else { break }
            guard match.range(at: 1).location != NSNotFound, match.range(at: 2).location != NSNotFound else { continue }
            let href = nsHTML.substring(with: match.range(at: 1))
            let text = plainText(fromHTML: nsHTML.substring(with: match.range(at: 2)))
            guard text.count > 1 else { continue }
            guard let resolved = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
            let resolvedString = resolved.absoluteString
            let dedupeKey = "\(text)|\(resolvedString)"
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            results.append((text: text, href: resolvedString))
        }
        return results
    }

    private static func fetchRawHTML(from url: URL, timeout: TimeInterval) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Maziar/1.0", forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script.*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style.*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
