import Foundation
import PDFKit
import AppKit

/// Extracts plain text locally from a CV file (PDF or Word `.docx`) — no API call needed just to
/// read the file, the same local-first approach "Farhad's CV AutoFill" (the browser extension/Mac
/// app this panel is a lighter Maziar-native counterpart to) already uses: PDFKit for PDFs,
/// `NSAttributedString` for `.docx`.
enum CVDocumentTextExtractor {
    static func extractText(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string
        case "docx", "doc":
            guard let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil
            ) else { return nil }
            return attributed.string
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
