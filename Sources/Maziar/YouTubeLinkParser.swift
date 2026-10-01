import Foundation

/// Pure parsing/URL-building helpers for YouTube video links — no networking, no AI, so it's
/// trivially headlessly testable. Handles every URL shape YouTube itself produces (`watch?v=`,
/// `youtu.be/`, `/embed/`, `/shorts/`, `/live/`), plus a bare 11-character video ID pasted
/// directly, since not everyone copies the full URL.
enum YouTubeLinkParser {
    static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return nil }

        if host.contains("youtu.be") {
            let id = url.pathComponents.filter { $0 != "/" }.first
            return (id?.isEmpty == false) ? id : nil
        }

        let path = url.path
        for prefix in ["/embed/", "/shorts/", "/live/"] {
            if path.hasPrefix(prefix) {
                let id = String(path.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
                return (id?.isEmpty == false) ? id : nil
            }
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        return nil
    }

    /// Accepts either a full YouTube URL (any shape above) or a bare video ID typed/pasted
    /// directly — YouTube video IDs are always exactly 11 URL-safe characters.
    static func videoID(fromPastedText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let id = videoID(from: url) { return id }
        if trimmed.count == 11, trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return trimmed
        }
        return nil
    }

    static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }

    static func watchURL(videoID: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    static func embedURL(videoID: String) -> URL {
        URL(string: "https://www.youtube.com/embed/\(videoID)")!
    }
}
