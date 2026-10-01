import SwiftUI
import AppKit
import PDFKit

/// The "info" popup window for one paper — a real separate OS window (`openWindow(id:
/// "paper-info", value: entry.id)`) rather than the card's old inline-expand, so it can stay open
/// alongside the reader companion window while you work. Shows every editable field plus the
/// Abstract and the Notes companion file.
struct PaperInfoWindow: View {
    let paperID: UUID
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var draft: LibraryEntry?
    @State private var notes: [PaperNote] = []
    @State private var notesFormat: LibraryStore.NotesFormat = .notebook
    @State private var isExtracting = false
    @State private var isLookingUp = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirm = false

    private var liveEntry: LibraryEntry? { libraryStore.entries.first { $0.id == paperID } }

    var body: some View {
        Group {
            if let boundDraft = Binding($draft) {
                content(boundDraft)
            } else {
                Text("This paper is no longer in the library.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 460, height: 620)
        .onAppear(perform: load)
    }

    private func content(_ draft: Binding<LibraryEntry>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: draft.title)
                    .font(.title3.bold())
                    .textFieldStyle(.plain)

                if let errorMessage {
                    CopyableErrorView(message: errorMessage)
                }

                Group {
                    TextField("Authors", text: Binding(get: { draft.wrappedValue.authors ?? "" }, set: { draft.wrappedValue.authors = $0.isEmpty ? nil : $0 }))
                    HStack {
                        TextField("Year", text: Binding(get: { draft.wrappedValue.year ?? "" }, set: { draft.wrappedValue.year = $0.isEmpty ? nil : $0 }))
                        TextField("Venue", text: Binding(get: { draft.wrappedValue.venue ?? "" }, set: { draft.wrappedValue.venue = $0.isEmpty ? nil : $0 }))
                    }
                    TextField("DOI", text: Binding(get: { draft.wrappedValue.doi ?? "" }, set: { draft.wrappedValue.doi = $0.isEmpty ? nil : $0 }))
                    TextField("First Author's Institution", text: Binding(get: { draft.wrappedValue.affiliation ?? "" }, set: { draft.wrappedValue.affiliation = $0.isEmpty ? nil : $0 }))
                    TextField("Tags (comma-separated)", text: Binding(
                        get: { draft.wrappedValue.tags.joined(separator: ", ") },
                        set: { draft.wrappedValue.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    ))
                }
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        extractWithAI(draft: draft)
                    } label: {
                        if isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Extract Info with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(isExtracting || !aiSettings.isConfigured(aiSettings.effectiveLibraryProvider) || libraryStore.primaryURL(for: draft.wrappedValue) == nil)
                    .help("Reads title/authors/year/venue/DOI/abstract from the PDF's own first page.")

                    Button {
                        lookUpOnScholar(draft: draft)
                    } label: {
                        if isLookingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Look Up on Scholar", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isLookingUp || !aiSettings.isConfigured(aiSettings.effectiveLibraryProvider) || draft.wrappedValue.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Searches Google Scholar and the web by title to fill in/confirm authors, venue, year, DOI, and affiliation.")
                }

                Divider()

                Text("Abstract").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { draft.wrappedValue.abstract ?? "" }, set: { draft.wrappedValue.abstract = $0.isEmpty ? nil : $0 }))
                    .frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .font(.system(size: 12))

                HStack {
                    Text("BibTeX").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(BibTeXGenerator.entry(for: draft.wrappedValue), forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Text(BibTeXGenerator.entry(for: draft.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                Group {
                    switch notesFormat {
                    case .legacyText:
                        PaperNotesEditor(notes: $notes)
                    case .notebook:
                        NotebookTabsView(entry: draft.wrappedValue)
                    }
                }
                .frame(height: 280)

                HStack {
                    Button("Reveal in Finder") {
                        if let url = libraryStore.primaryURL(for: draft.wrappedValue) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(libraryStore.primaryURL(for: draft.wrappedValue) == nil)
                    Button("Remove", role: .destructive) { showRemoveConfirm = true }
                    Spacer()
                    Button("Save") { save(draft.wrappedValue) }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.color(for: .buttonColor))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .confirmationDialog(
            "Remove \u{201c}\(draft.wrappedValue.title)\u{201d} from the library?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove (keep file)") { remove(draft.wrappedValue, deleteFile: false) }
            Button("Remove & Move File to Trash", role: .destructive) { remove(draft.wrappedValue, deleteFile: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func load() {
        guard let entry = liveEntry else {
            // Reachable if the paper was removed, or — far more often — because macOS restored
            // this window from a past session's saved state, pointing at a stale paper ID. Close
            // immediately rather than leave an empty window sitting around.
            dismiss()
            return
        }
        draft = entry
        notesFormat = libraryStore.notesFormat(for: entry)
        if notesFormat == .legacyText {
            notes = PaperNotesDocument.decode(libraryStore.readNotes(for: entry))
        }
    }

    /// The `.notebook` case needs nothing here — `NotebookTabsView` saves each tab itself as it
    /// changes, the same live-save behavior the Reader window's Notebook page already had, rather
    /// than gating notebook edits behind this window's "Save" button the way plain fields are.
    private func save(_ entry: LibraryEntry) {
        libraryStore.update(entry)
        if notesFormat == .legacyText {
            libraryStore.writeNotes(PaperNotesDocument.encode(notes), for: entry)
        }
    }

    private func remove(_ entry: LibraryEntry, deleteFile: Bool) {
        libraryStore.remove(entry, deleteFile: deleteFile)
        dismiss()
    }

    private func extractWithAI(draft draftBinding: Binding<LibraryEntry>) {
        guard let fileURL = libraryStore.primaryURL(for: draftBinding.wrappedValue),
              let document = PDFDocument(url: fileURL), let firstPage = document.page(at: 0) else {
            errorMessage = "Couldn't open this PDF to read its first page."
            return
        }
        let text = firstPage.string ?? ""
        isExtracting = true
        Task {
            do {
                let result = try await LibraryMetadataService.extract(fromFirstPageText: text, settings: aiSettings)
                if let title = result.title, !title.isEmpty { draftBinding.wrappedValue.title = title }
                if let authors = result.authors, !authors.isEmpty { draftBinding.wrappedValue.authors = authors }
                if let year = result.year, !year.isEmpty { draftBinding.wrappedValue.year = year }
                if let venue = result.venue, !venue.isEmpty { draftBinding.wrappedValue.venue = venue }
                if let doi = result.doi, !doi.isEmpty { draftBinding.wrappedValue.doi = doi }
                if let affiliation = result.affiliation, !affiliation.isEmpty { draftBinding.wrappedValue.affiliation = affiliation }
                if let abstract = result.abstract, !abstract.isEmpty { draftBinding.wrappedValue.abstract = abstract }
                save(draftBinding.wrappedValue)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isExtracting = false
        }
    }

    private func lookUpOnScholar(draft draftBinding: Binding<LibraryEntry>) {
        isLookingUp = true
        let title = draftBinding.wrappedValue.title
        Task {
            do {
                let result = try await PaperScholarLookupService.lookup(title: title, settings: aiSettings)
                if let title = result.title, !title.isEmpty { draftBinding.wrappedValue.title = title }
                if let authors = result.authors, !authors.isEmpty { draftBinding.wrappedValue.authors = authors }
                if let year = result.year, !year.isEmpty { draftBinding.wrappedValue.year = year }
                if let venue = result.venue, !venue.isEmpty { draftBinding.wrappedValue.venue = venue }
                if let doi = result.doi, !doi.isEmpty { draftBinding.wrappedValue.doi = doi }
                if let affiliation = result.affiliation, !affiliation.isEmpty { draftBinding.wrappedValue.affiliation = affiliation }
                if let abstract = result.abstract, !abstract.isEmpty { draftBinding.wrappedValue.abstract = abstract }
                save(draftBinding.wrappedValue)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLookingUp = false
        }
    }
}
