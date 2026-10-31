import SwiftUI

/// A paper's notes in their own window — the same notes the Info window and the Reader show (the
/// notebook with its tabs, or the older plain-notes format), but openable straight from the Library
/// without opening the paper or the Info window first, and kept open beside either.
struct PaperNotesWindow: View {
    let paperID: UUID
    @EnvironmentObject var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [PaperNote] = []
    @State private var notesFormat: LibraryStore.NotesFormat = .notebook

    private var entry: LibraryEntry? { libraryStore.entries.first { $0.id == paperID } }

    var body: some View {
        Group {
            if let entry {
                Group {
                    switch notesFormat {
                    case .legacyText:
                        PaperNotesEditor(notes: $notes, defaultPreview: true)
                    case .notebook:
                        NotebookTabsView(entry: entry, defaultPreview: true)
                    }
                }
                .padding(12)
                .onAppear {
                    notesFormat = libraryStore.notesFormat(for: entry)
                    if notesFormat == .legacyText {
                        notes = PaperNotesDocument.decode(libraryStore.readNotes(for: entry))
                    }
                }
                .onChange(of: notes) { _, newValue in
                    guard notesFormat == .legacyText else { return }
                    libraryStore.writeNotes(PaperNotesDocument.encode(newValue), for: entry)
                }
                .navigationTitle("Maziar-Notes \u{2014} \(entry.title)")
            } else {
                // The paper was removed, or macOS restored this window pointing at a stale id.
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}
