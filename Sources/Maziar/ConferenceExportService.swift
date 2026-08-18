import Foundation
import WebKit

/// Exports the full tracked-conference list for use in another app — a plain JSON dump (every
/// field, machine-readable) or a formatted table PDF (human-readable, printable).
@MainActor
enum ConferenceExportService {
    static func exportJSON(_ conferences: [ConferenceEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(conferences)
    }

    /// Decodes a file produced by `exportJSON` (or hand-edited in the same shape) — the counterpart
    /// used by "Import JSON..." on the Conferences page, e.g. to restore a tracked list after
    /// reinstalling the app rather than re-adding and re-looking-up every conference by hand.
    static func importJSON(_ data: Data) throws -> [ConferenceEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ConferenceEntry].self, from: data)
    }

    static func exportPDF(_ conferences: [ConferenceEntry]) async throws -> Data {
        let html = tableHTML(conferences)
        let renderer = PDFRenderer()
        return try await renderer.render(html: html)
    }

    // MARK: - HTML table

    private static func tableHTML(_ conferences: [ConferenceEntry]) -> String {
        let rows = conferences.map(rowHTML).joined(separator: "\n")
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
          <h1>Maziar \u{2014} Tracked Conferences</h1>
          <table>
            <thead>
              <tr>
                <th style="width:12%">Name</th>
                <th style="width:9%">Rank</th>
                <th style="width:10%">Page Limit</th>
                <th style="width:9%">Format</th>
                <th style="width:16%">Deadlines</th>
                <th style="width:14%">Website</th>
                <th style="width:12%">Author Guide</th>
                <th style="width:12%">Template</th>
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

    private static func rowHTML(_ entry: ConferenceEntry) -> String {
        let deadlinesText = entry.deadlines
            .map { deadline -> String in
                let dateText = deadline.date?.formatted(date: .abbreviated, time: .omitted) ?? (deadline.rawText ?? "TBA")
                return "\(escape(deadline.label)): \(escape(dateText))"
            }
            .joined(separator: "<br>")
        let updatedText = entry.lastUpdated?.formatted(date: .abbreviated, time: .omitted) ?? "never"
        return """
        <tr>
          <td>\(escape(entry.name))</td>
          <td>\(escape(entry.rank ?? ""))</td>
          <td>\(escape(entry.pageLimit ?? ""))</td>
          <td>\(escape(entry.columnFormat ?? ""))</td>
          <td>\(deadlinesText)</td>
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
