import Foundation

/// Generates a BibTeX entry for a library paper from its own tracked fields — no network call, no
/// AI, just formatting what's already known. Pure/no SwiftUI dependency, so it's headlessly
/// testable on its own.
enum BibTeXGenerator {
    /// "inproceedings" when the venue reads like a conference/workshop, "article" otherwise — not
    /// a perfect classifier, but the actual field values matter far more than getting the entry
    /// type exactly right for a citation you'll likely paste into a reference manager anyway.
    static func entryType(for entry: LibraryEntry) -> String {
        let lowerVenue = (entry.venue ?? "").lowercased()
        let conferenceKeywords = ["conference", "proceedings", "workshop", "symposium"]
        return conferenceKeywords.contains(where: lowerVenue.contains) ? "inproceedings" : "article"
    }

    /// "SmithLastName2023"-style — a real name parser this isn't, just enough to produce a
    /// reasonable, mostly-unique-in-practice citation key.
    static func citeKey(for entry: LibraryEntry) -> String {
        let firstAuthor = LibraryEntry.firstAuthorName(from: entry.authors)
        let surname = firstAuthor?.split(separator: " ").last.map(String.init) ?? "Unknown"
        let cleanedSurname = surname.filter { $0.isLetter || $0.isNumber }
        let year = LibraryEntry.nonEmpty(entry.year) ?? "n_d_"
        return (cleanedSurname.isEmpty ? "Unknown" : cleanedSurname) + year
    }

    /// Splits a free-text authors string into individual names — handles "A, B, C", "A and B",
    /// and the common "A, B, and C" mixed form (normalizing " and "/" & " to a comma first, so the
    /// oxford-comma-before-"and" case doesn't produce a stray empty entry after filtering).
    static func allAuthorNames(from authors: String?) -> [String] {
        guard let authors = LibraryEntry.nonEmpty(authors) else { return [] }
        let normalized = authors
            .replacingOccurrences(of: " and ", with: ",")
            .replacingOccurrences(of: " & ", with: ",")
        return normalized
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The full BibTeX entry text, ready to paste into a .bib file or reference manager.
    static func entry(for paper: LibraryEntry) -> String {
        let type = entryType(for: paper)
        let key = citeKey(for: paper)

        var fields: [(String, String)] = [("title", paper.title)]

        let authorNames = allAuthorNames(from: paper.authors)
        if !authorNames.isEmpty {
            fields.append(("author", authorNames.joined(separator: " and ")))
        }
        if let venue = LibraryEntry.nonEmpty(paper.venue) {
            fields.append((type == "inproceedings" ? "booktitle" : "journal", venue))
        }
        if let year = LibraryEntry.nonEmpty(paper.year) {
            fields.append(("year", year))
        }
        if let doi = LibraryEntry.nonEmpty(paper.doi) {
            fields.append(("doi", doi))
        }

        let body = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(type){\(key),\n\(body)\n}"
    }
}
