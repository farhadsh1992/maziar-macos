import SwiftUI

/// Wraps `NotebookEditorView` with a row of named tabs — each tab is a separate `.ipynb` file
/// inside the paper's own notebook folder (`LibraryStore.notebookFolderURL`/`notebookTabs`), so a
/// paper can have more than one notebook (e.g. its main notes, plus separate "Questions"/
/// "Problems" tabs) instead of being limited to a single file. The first tab always keeps the
/// paper's own base filename — the same file a pre-multi-tab paper's notes already lived in,
/// migrated into the new folder as that first tab automatically (`LibraryStore.notebookTabs` does
/// the migration), so existing notes aren't lost or duplicated. Each tab auto-saves as it changes,
/// the same live-save behavior the Reader's Notebook page already had for a single notebook.
struct NotebookTabsView: View {
    let entry: LibraryEntry
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var settings: AppSettings

    @State private var tabs: [LibraryStore.NotebookTab] = []
    @State private var selectedTabID: String?
    @State private var cells: [NotebookCell] = []
    @State private var showAddTabSheet = false
    @State private var newTabName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            tabButton(tab)
                        }
                    }
                }
                Button {
                    newTabName = ""
                    showAddTabSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add a new notebook tab")
            }

            NotebookEditorView(cells: $cells)
                .onChange(of: cells) { _, newValue in
                    guard let tab = currentTab else { return }
                    libraryStore.writeNotebook(NotebookDocument(cells: newValue), for: entry, tab: tab)
                }
        }
        .onAppear { loadTabs() }
        .onChange(of: entry.id) { _, _ in loadTabs() }
        .sheet(isPresented: $showAddTabSheet) { addTabSheet }
    }

    private var currentTab: LibraryStore.NotebookTab? {
        tabs.first { $0.id == selectedTabID }
    }

    private func tabButton(_ tab: LibraryStore.NotebookTab) -> some View {
        let isSelected = selectedTabID == tab.id
        return HStack(spacing: 4) {
            Text(tab.name)
                .font(.caption)
                .lineLimit(1)
            if tabs.count > 1 {
                Button {
                    removeTab(tab)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? settings.color(for: .buttonColor).opacity(0.18) : Color.secondary.opacity(0.1))
        .foregroundStyle(isSelected ? settings.color(for: .buttonColor) : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { selectTab(tab) }
    }

    private var addTabSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Notebook Tab").font(.headline)
            TextField("Name (e.g. Questions)", text: $newTabName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTab)
            HStack {
                Spacer()
                Button("Cancel") { showAddTabSheet = false }
                Button("Add") {
                    addTab()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTabName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func loadTabs() {
        tabs = libraryStore.notebookTabs(for: entry)
        if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs.first?.id
        }
        loadCells()
    }

    private func loadCells() {
        guard let tab = currentTab else {
            cells = []
            return
        }
        cells = libraryStore.readNotebook(for: entry, tab: tab).cells
    }

    private func selectTab(_ tab: LibraryStore.NotebookTab) {
        guard selectedTabID != tab.id else { return }
        selectedTabID = tab.id
        loadCells()
    }

    private func addTab() {
        guard let tab = libraryStore.addNotebookTab(named: newTabName, for: entry) else { return }
        showAddTabSheet = false
        tabs = libraryStore.notebookTabs(for: entry)
        selectedTabID = tab.id
        loadCells()
    }

    private func removeTab(_ tab: LibraryStore.NotebookTab) {
        libraryStore.removeNotebookTab(tab, for: entry)
        tabs = libraryStore.notebookTabs(for: entry)
        if selectedTabID == tab.id {
            selectedTabID = tabs.first?.id
        }
        loadCells()
    }
}
