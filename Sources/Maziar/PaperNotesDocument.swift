import Foundation

/// One titled note within a paper's notes file — the notes page holds any number of these, but
/// they're always serialized into (and read back from) the single plain-text `.txt` companion
/// file `LibraryStore` already manages, not one file per note. The format is plain Markdown-style
/// headers (`## Title`) specifically so the raw `.txt` file still reads sensibly if opened outside
/// Maziar (Finder Quick Look, a text editor, a Markdown viewer) rather than being some
/// Maziar-only encoding.
struct PaperNote: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var body: String
}

enum PaperNotesDocument {
    /// `## Title` on its own line starts a note; every line after it (until the next `## ` line or
    /// the end of the file) is that note's body. Content before the first `## ` line — i.e. a
    /// notes file written before this feature existed, or a fresh legacy migration from
    /// `LibraryEntry.notes` — becomes one untitled note rather than being discarded, so nothing a
    /// user already wrote is ever silently lost by upgrading to titled notes.
    static func decode(_ text: String) -> [PaperNote] {
        guard !text.isEmpty else { return [] }
        let lines = text.components(separatedBy: "\n")
        var notes: [PaperNote] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            guard currentTitle != nil || !currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            notes.append(PaperNote(title: currentTitle ?? "", body: body))
        }

        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3))
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }
        flush()
        return notes
    }

    static func encode(_ notes: [PaperNote]) -> String {
        notes.map { note in
            let titleLine = "## \(note.title)"
            return note.body.isEmpty ? titleLine : "\(titleLine)\n\(note.body)"
        }.joined(separator: "\n\n")
    }
}
