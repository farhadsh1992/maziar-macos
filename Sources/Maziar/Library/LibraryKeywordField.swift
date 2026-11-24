import Foundation

/// One of the categories the Library page's keyword strip cycles through — pure data/logic here
/// (no SwiftUI) so it's headlessly testable independent of the marquee view that renders it.
enum LibraryKeywordField: String, CaseIterable, Identifiable {
    case venue
    case firstAuthor
    case year
    case affiliation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .venue: return "Venue"
        case .firstAuthor: return "First Author"
        case .year: return "Year"
        case .affiliation: return "Institution"
        }
    }

    var icon: String {
        switch self {
        case .venue: return "building.columns"
        case .firstAuthor: return "person.fill"
        case .year: return "calendar"
        case .affiliation: return "graduationcap.fill"
        }
    }

    /// This field's value for one entry, or nil if that entry doesn't have one.
    func value(for entry: LibraryEntry) -> String? {
        switch self {
        case .venue: return LibraryEntry.nonEmpty(entry.venue)
        case .firstAuthor: return LibraryEntry.firstAuthorName(from: entry.authors)
        case .year: return LibraryEntry.nonEmpty(entry.year)
        case .affiliation: return LibraryEntry.nonEmpty(entry.affiliation)
        }
    }
}

extension LibraryEntry {
    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Best-effort first author out of a free-text authors string — splits on the separators an
    /// author list commonly uses ("," / ";" / " and " / " & ") and takes whatever comes before the
    /// first one. Not a real name parser (no attempt at "Last, First" reordering, initials, etc.)
    /// — good enough to group papers by their first author, not to display a formatted byline.
    static func firstAuthorName(from authors: String?) -> String? {
        guard let authors = nonEmpty(authors) else { return nil }
        let separators = [",", ";", " and ", " AND ", " & "]
        var candidate = authors
        for separator in separators {
            if let range = candidate.range(of: separator) {
                candidate = String(candidate[candidate.startIndex..<range.lowerBound])
                break
            }
        }
        return nonEmpty(candidate)
    }
}

/// Every distinct value a field takes across a set of entries, together with how many entries
/// have that value — case-insensitively deduplicated/counted (keeping the first-seen casing) and
/// sorted alphabetically. What the strip's chips actually show ("2020 (3)").
func libraryDistinctValueCounts(for field: LibraryKeywordField, in entries: [LibraryEntry]) -> [(value: String, count: Int)] {
    var indexByLowercased: [String: Int] = [:]
    var result: [(value: String, count: Int)] = []
    for entry in entries {
        guard let value = field.value(for: entry) else { continue }
        let key = value.lowercased()
        if let index = indexByLowercased[key] {
            result[index].count += 1
        } else {
            indexByLowercased[key] = result.count
            result.append((value: value, count: 1))
        }
    }
    return result.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
}

/// Every distinct value a field takes across a set of entries, case-insensitively deduplicated
/// (keeping the first-seen casing) and sorted alphabetically — the list of chips one marquee
/// category shows.
func libraryDistinctValues(for field: LibraryKeywordField, in entries: [LibraryEntry]) -> [String] {
    libraryDistinctValueCounts(for: field, in: entries).map(\.value)
}

/// Every entry whose value for `field` matches `value` (case-insensitively) — what clicking a chip
/// in the strip filters the paper list down to.
func libraryEntries(matching field: LibraryKeywordField, value: String, in entries: [LibraryEntry]) -> [LibraryEntry] {
    entries.filter { field.value(for: $0)?.caseInsensitiveCompare(value) == .orderedSame }
}
