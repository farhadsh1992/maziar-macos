import Foundation

/// Exports the full tracked-journal list for use in another app — a plain JSON dump (every field,
/// machine-readable) or a formatted table PDF (human-readable, printable). PDF rendering is shared
/// with `ConferenceExportService` via `PDFRenderer`.
@MainActor
enum JournalExportService {
    static func exportJSON(_ journals: [JournalEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(journals)
    }

    /// Decodes a file produced by `exportJSON` (or hand-edited in the same shape) — the counterpart
    /// used by "Import JSON..." on the Journals page, e.g. to restore a tracked list after
    /// reinstalling the app rather than re-adding and re-looking-up every journal by hand.
    static func importJSON(_ data: Data) throws -> [JournalEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([JournalEntry].self, from: data)
    }

    static func exportPDF(_ journals: [JournalEntry]) async throws -> Data {
        let html = tableHTML(journals)
        let renderer = PDFRenderer()
        return try await renderer.render(html: html)
    }

    // MARK: - HTML table

    private static func tableHTML(_ journals: [JournalEntry]) -> String {
        let rows = journals.map(rowHTML).joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          @page { size: A3 landscape; margin: 12mm; }
          body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 9px; color: #111; }
          h1 { font-size: 16px; margin: 0 0 10px 0; }
          table { width: 100%; border-collapse: collapse; table-layout: fixed; }
          th, td { border: 1px solid #999; padding: 4px 6px; text-align: left; vertical-align: top;
                   word-wrap: break-word; overflow-wrap: break-word; }
          th { background: #eee; }
        </style>
        </head>
        <body>
          <h1>Maziar \u{2014} Tracked Journals</h1>
          <table>
            <thead>
              <tr>
                <th style="width:11%">Name</th>
                <th style="width:8%">Rank</th>
                <th style="width:9%">Page Limit</th>
                <th style="width:8%">Format</th>
                <th style="width:11%">Review Time</th>
                <th style="width:11%">Publication Time</th>
                <th style="width:14%">Website</th>
                <th style="width:12%">Author Guide</th>
                <th style="width:10%">Template</th>
                <th style="width:6%">Updated</th>
              </tr>
            </thead>
            <tbody>
              \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """
    }

    private static func rowHTML(_ entry: JournalEntry) -> String {
        let updatedText = entry.lastUpdated?.formatted(date: .abbreviated, time: .omitted) ?? "never"
        return """
        <tr>
          <td>\(escape(entry.name))</td>
          <td>\(escape(entry.rank ?? ""))</td>
          <td>\(escape(entry.pageLimit ?? ""))</td>
          <td>\(escape(entry.columnFormat ?? ""))</td>
          <td>\(escape(entry.reviewTime ?? ""))</td>
          <td>\(escape(entry.publicationTime ?? ""))</td>
          <td>\(escape(entry.nextConferenceWebsiteURL?.absoluteString ?? ""))</td>
          <td>\(escape(entry.authorGuideURLString ?? ""))</td>
          <td>\(escape(entry.templateURLString ?? ""))</td>
          <td>\(escape(updatedText))</td>
        </tr>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
