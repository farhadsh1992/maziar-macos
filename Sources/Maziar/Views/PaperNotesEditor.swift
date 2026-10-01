import SwiftUI

/// Several titled notes, not one big blob — each title renders bold and larger (a real visual
/// "heading"), used identically in both the Info window and the Reader companion window's Notes
/// page so editing from either place behaves the same way. Both sides serialize through
/// `PaperNotesDocument` into the one shared `.txt` companion file `LibraryStore` manages.
struct PaperNotesEditor: View {
    @Binding var notes: [PaperNote]
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var libraryStore: LibraryStore
    @State private var previewingNoteIDs: Set<UUID> = []
    @State private var noteHeights: [UUID: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    notes.append(PaperNote(title: "", body: ""))
                } label: {
                    Label("Add Note", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .tint(settings.color(for: .buttonColor))
            }

            if notes.isEmpty {
                Text("No notes yet — click Add Note.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            }

            ScrollView {
                // `VStack`, not `LazyVStack` — see the identical fix/reasoning in
                // `NotebookEditorView.swift`: a lazy stack doesn't reliably re-measure a child
                // whose own intrinsic size grows after the fact, which left a note's
                // `TextField(axis: .vertical)` box stuck after a couple of lines.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($notes) { $note in
                        noteBlock($note)
                    }
                }
            }

            Text("Saved as one real .txt file next to the paper.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func noteBlock(_ note: Binding<PaperNote>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                TextField("Note title", text: note.title)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .foregroundStyle(settings.color(for: .buttonColor))
                Spacer()
                Button {
                    toggle(note.wrappedValue.id)
                } label: {
                    Image(systemName: isPreviewing(note.wrappedValue.id) ? "pencil" : "text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(isPreviewing(note.wrappedValue.id) ? "Edit" : "Preview Markdown & LaTeX")
                Button {
                    notes.removeAll { $0.id == note.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove note")
            }
            if isPreviewing(note.wrappedValue.id) {
                ScrollView {
                    NoteRenderedView(text: note.wrappedValue.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 220)
            } else {
                GrowingTextEditor(
                    text: note.body,
                    height: noteHeightBinding(for: note.wrappedValue.id),
                    font: .systemFont(ofSize: 12.5),
                    maxLines: libraryStore.notesCellMaxLines
                )
                // See the matching `.id()` in `NotebookEditorView.cellBlock` — same
                // position-vs-identity `NSViewRepresentable` reuse bug, fixed the same way, for the
                // same `GrowingTextEditor`. Deleting a note in the middle of the list reindexes
                // every note after it, which is enough to trigger it even without an explicit
                // reorder control here.
                .id(note.wrappedValue.id)
                .frame(height: noteHeights[note.wrappedValue.id] ?? Self.defaultNoteHeight)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func isPreviewing(_ id: UUID) -> Bool { previewingNoteIDs.contains(id) }

    private func toggle(_ id: UUID) {
        if previewingNoteIDs.contains(id) {
            previewingNoteIDs.remove(id)
        } else {
            previewingNoteIDs.insert(id)
        }
    }

    private static let defaultNoteHeight: CGFloat = 28

    private func noteHeightBinding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { noteHeights[id] ?? Self.defaultNoteHeight },
            set: { noteHeights[id] = $0 }
        )
    }
}
