import Foundation
import PDFKit

/// Picks a paper's title from the PDF itself rather than its filename — most academic PDFs are
/// named after an arXiv ID, a DOI, or whatever the browser happened to save it as, none of which
/// is the paper's actual title. Tries the PDF's own embedded metadata title first (free, instant,
/// no AI call), then a plain first-page-text heuristic; falls back to the filename only if neither
/// yields something plausible.
enum PDFTitleExtractor {
    static func title(forPDFAt url: URL, fallback: String) -> String {
        guard let document = PDFDocument(url: url) else { return fallback }
        return title(for: document, fallback: fallback)
    }

    static func title(for document: PDFDocument, fallback: String) -> String {
        if let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleTitle(trimmed) {
                return trimmed
            }
        }
        if let pageText = document.page(at: 0)?.string, let heuristic = firstLineHeuristic(from: pageText) {
            return heuristic
        }
        return fallback
    }

    /// Rejects titles that are too short/long to be real, or that are obviously just the source
    /// filename or a generic authoring-tool placeholder (common when a PDF's metadata was never
    /// set explicitly — e.g. "Microsoft Word - paper_final_v3.docx", "untitled").
    static func isPlausibleTitle(_ text: String) -> Bool {
        let length = text.count
        guard length >= 8, length <= 300 else { return false }
        let lowered = text.lowercased()
        if lowered.hasSuffix(".pdf") || lowered.hasSuffix(".docx") || lowered.hasSuffix(".doc") { return false }
        if lowered.hasPrefix("microsoft word") { return false }
        if lowered == "untitled" || lowered == "untitled document" { return false }
        return true
    }

    /// Best-effort: the first sufficiently long, sufficiently short line near the top of the first
    /// page, skipping obvious non-title lines (an arXiv identifier watermark, a bare page number).
    /// Not a layout/font-size analysis — just enough to beat a raw filename most of the time.
    static func firstLineHeuristic(from pageText: String) -> String? {
        let lines = pageText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines.prefix(8) {
            let lowered = line.lowercased()
            if lowered.hasPrefix("arxiv:") { continue }
            if line.allSatisfy({ $0.isNumber }) { continue }
            if isPlausibleTitle(line) {
                return line
            }
        }
        return nil
    }
}
