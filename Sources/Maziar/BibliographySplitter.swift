import Foundation

/// Splits a paper's own extracted text into individual bibliography entries — entirely locally,
/// no AI call involved, so it can't fail from a truncated or malformed AI response the way asking
/// a model to reproduce a long reference list can (a real paper can have 50-100+ entries, and an
/// AI asked to echo all of them back as structured JSON can simply run out of output length before
/// finishing the array, corrupting the whole result). Handles the dominant numbered-citation style
/// (`[1] ...`, `[2] ...`) used by most CS/ML venues (IEEE, ACL, ACM, arXiv) — the vast majority of
/// what this app's own users are likely reading. Papers using an unnumbered author-year style
/// (APA/Chicago) aren't handled here; `PaperReferencesService` is the AI-based fallback for those.
enum BibliographySplitter {
    static func referenceEntries(from fullText: String) -> [String] {
        guard let sectionText = referencesSectionText(fullText) else { return [] }
        return splitNumberedEntries(sectionText)
    }

    /// Finds the References/Bibliography heading and returns everything after it. Uses the *last*
    /// match rather than the first, since a paper's own table of contents can list "References" as
    /// a line well before the real section — the actual section is always the last one.
    static func referencesSectionText(_ fullText: String) -> String? {
        let pattern = #"(?im)^[ \t]*(?:[ivxlcdm\d]+[.\s]+)?(references|bibliography)[ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = fullText as NSString
        let matches = regex.matches(in: fullText, range: NSRange(location: 0, length: nsText.length))
        guard let last = matches.last else { return nil }
        let start = last.range.location + last.range.length
        guard start < nsText.length else { return nil }
        return nsText.substring(from: start)
    }

    private static func splitNumberedEntries(_ text: String) -> [String] {
        let pattern = #"\[\d{1,3}\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard matches.count >= 2 else { return [] }

        var entries: [String] = []
        for (index, match) in matches.enumerated() {
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length
            let raw = nsText.substring(with: NSRange(location: start, length: end - start))
            let cleaned = clean(raw)
            if !cleaned.isEmpty { entries.append(cleaned) }
        }
        return entries
    }

    /// Collapses the whitespace/line-wrap artifacts inherent to PDF-extracted text into single
    /// spaces, so an entry reads as one clean line instead of the ragged multi-line shape it had
    /// on the actual PDF page.
    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
