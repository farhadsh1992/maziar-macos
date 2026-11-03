import SwiftUI
import AppKit

/// The inside of an Information box: a row of tabs (sub-informations) over a rich-text editor. The
/// project's own box (`instanceID == nil`) keeps its text in `infoSections` and mirrors the first tab
/// into the old Idea fields; an extra box keeps its tabs in `extraInfo`.
struct ProjectInfoBox: View {
    @Binding var paper: Paper
    let instanceID: UUID?

    @StateObject private var controller = RichTextController()
    @State private var selectedID: UUID?
    @State private var renamingID: UUID?
    @State private var nameDraft = ""
    @State private var pendingDeletion: ProjectInfoSection?

    private var stored: [ProjectInfoSection] {
        instanceID.map { paper.extraInfo[$0.uuidString] ?? [] } ?? paper.infoSections
    }

    /// The tabs as shown: the stored ones, or — before any are saved — one built from the old Idea
    /// box (the project's own) or an empty one (an extra box).
    private var sections: [ProjectInfoSection] {
        let saved = stored
        if !saved.isEmpty { return saved }
        if let instanceID { return [ProjectInfoSection(id: instanceID, title: "Information")] }
        return [ProjectInfoSection(id: paper.id, title: "Information", rtf: paper.ideaRichText, plain: paper.ideaDescription)]
    }

    private var currentID: UUID {
        let all = sections
        if let selectedID, all.contains(where: { $0.id == selectedID }) { return selectedID }
        return all[0].id
    }

    private func setSections(_ updated: [ProjectInfoSection]) {
        if let instanceID {
            paper.extraInfo[instanceID.uuidString] = updated
        } else {
            paper.infoSections = updated
            paper.ideaRichText = updated.first?.rtf
            paper.ideaDescription = updated.first?.plain ?? ""
        }
    }

    private func update(_ id: UUID, rtf: Data?, plain: String) {
        var all = sections
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].rtf = rtf
        all[index].plain = plain
        setSections(all)
    }

    private func add() {
        var all = sections
        let section = ProjectInfoSection(title: "Information \(all.count + 1)")
        all.append(section)
        setSections(all)
        selectedID = section.id
    }

    private func move(_ id: UUID, by offset: Int) {
        var all = sections
        guard let index = all.firstIndex(where: { $0.id == id }), all.indices.contains(index + offset) else { return }
        all.swapAt(index, index + offset)
        setSections(all)
    }

    private func move(_ draggedID: UUID, before targetID: UUID) {
        var all = sections
        guard draggedID != targetID,
              let from = all.firstIndex(where: { $0.id == draggedID }),
              let to = all.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = all.remove(at: from)
        all.insert(moved, at: to)
        setSections(all)
    }

    private func commitRename() {
        defer { renamingID = nil }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renamingID, !name.isEmpty else { return }
        var all = sections
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].title = name
        setSections(all)
    }

    private func delete(_ id: UUID) {
        var all = sections
        guard all.count > 1, let index = all.firstIndex(where: { $0.id == id }) else { return }
        all.remove(at: index)
        setSections(all)
        selectedID = all[min(index, all.count - 1)].id
    }

    private func tab(_ section: ProjectInfoSection) -> some View {
        let all = sections
        let isSelected = section.id == currentID
        return Text(section.title)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { selectedID = section.id }
            .draggable("tab:\(section.id.uuidString)")
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, raw.hasPrefix("tab:"),
                      let dragged = UUID(uuidString: String(raw.dropFirst(4))) else { return false }
                move(dragged, before: section.id)
                return true
            }
            .contextMenu {
                Button("Rename\u{2026}") { renamingID = section.id; nameDraft = section.title }
                Button("Move Left") { move(section.id, by: -1) }
                    .disabled(all.first?.id == section.id)
                Button("Move Right") { move(section.id, by: 1) }
                    .disabled(all.last?.id == section.id)
                Divider()
                Button("Delete\u{2026}", role: .destructive) { pendingDeletion = section }
                    .disabled(all.count < 2)
            }
    }

    var body: some View {
        let all = sections
        let id = currentID
        let current = all.first { $0.id == id } ?? all[0]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(all) { tab($0) }
                    }
                    .padding(.vertical, 2)
                }
                Button { add() } label: { Image(systemName: "plus") }
                    .help("Add an information tab")
                Button { move(current.id, by: -1) } label: { Image(systemName: "arrow.left") }
                    .disabled(all.first?.id == current.id)
                    .help("Move this tab left")
                Button { move(current.id, by: 1) } label: { Image(systemName: "arrow.right") }
                    .disabled(all.last?.id == current.id)
                    .help("Move this tab right")
                Button { renamingID = current.id; nameDraft = current.title } label: { Image(systemName: "pencil") }
                    .help("Rename this tab")
                Button { pendingDeletion = current } label: { Image(systemName: "trash") }
                    .disabled(all.count < 2)
                    .help("Delete this tab")
            }
            .buttonStyle(.borderless)
            .alert("Rename Information", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
                TextField("Name", text: $nameDraft)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renamingID = nil }
            }
            .confirmationDialog(
                "Delete \u{201c}\(pendingDeletion?.title ?? "")\u{201d} and its text?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let doomed = pendingDeletion { delete(doomed.id) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
            TextFormatBar(
                onBold: { controller.toggleBold() },
                onItalic: { controller.toggleItalic() },
                onUnderline: { controller.toggleUnderline() },
                onFont: { controller.setFont(family: $0) },
                onSize: { controller.setSize($0) },
                onColor: { controller.setColor($0?.nsColor) }
            )
            RichTextEditor(
                initialRTF: current.rtf,
                initialPlainText: current.plain,
                controller: controller,
                onChange: { rtf, plain in update(id, rtf: rtf, plain: plain) }
            )
            .id(id)
            .frame(height: 170)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }
}

/// The inside of a Notes box: tabs over a Markdown notebook. `scope` names where its notebooks are
/// stored — the project's own id for the built-in box, the box's id for an extra one.
struct ProjectNotesBox: View {
    let scope: UUID

    @State private var notes: [NotebookCell] = []
    @State private var noteSections: [ProjectNoteSection] = []
    @State private var selectedID: UUID?
    @State private var renaming: ProjectNoteSection?
    @State private var nameDraft = ""
    @State private var pendingDeletion: ProjectNoteSection?

    private func load() {
        let sections = ProjectNotebookStorage.sections(for: scope)
        noteSections = sections
        selectedID = sections[0].id
        notes = ProjectNotebookStorage.read(scope, section: sections[0].id)
    }

    private func select(_ section: ProjectNoteSection) {
        guard section.id != selectedID else { return }
        // `notes` is written on every change, so the tab being left is already saved.
        notes = ProjectNotebookStorage.read(scope, section: section.id)
        selectedID = section.id
    }

    private func add() {
        let section = ProjectNoteSection(title: "Notes \(noteSections.count + 1)")
        noteSections.append(section)
        ProjectNotebookStorage.writeSections(noteSections, for: scope)
        select(section)
    }

    private func move(_ section: ProjectNoteSection, by offset: Int) {
        guard let index = noteSections.firstIndex(of: section) else { return }
        let target = index + offset
        guard noteSections.indices.contains(target) else { return }
        noteSections.swapAt(index, target)
        ProjectNotebookStorage.writeSections(noteSections, for: scope)
    }

    private func move(id draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID,
              let from = noteSections.firstIndex(where: { $0.id == draggedID }),
              let to = noteSections.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = noteSections.remove(at: from)
        noteSections.insert(moved, at: to)
        ProjectNotebookStorage.writeSections(noteSections, for: scope)
    }

    private func commitRename() {
        defer { renaming = nil }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renaming, !name.isEmpty,
              let index = noteSections.firstIndex(where: { $0.id == target.id }) else { return }
        noteSections[index].title = name
        ProjectNotebookStorage.writeSections(noteSections, for: scope)
    }

    private func delete(_ section: ProjectNoteSection) {
        guard noteSections.count > 1, let index = noteSections.firstIndex(of: section) else { return }
        noteSections.remove(at: index)
        ProjectNotebookStorage.writeSections(noteSections, for: scope)
        ProjectNotebookStorage.removeSection(section.id, for: scope)
        if selectedID == section.id {
            let next = noteSections[min(index, noteSections.count - 1)]
            notes = ProjectNotebookStorage.read(scope, section: next.id)
            selectedID = next.id
        }
    }

    private func tab(_ section: ProjectNoteSection) -> some View {
        let isSelected = section.id == selectedID
        return Text(section.title)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { select(section) }
            .draggable("tab:\(section.id.uuidString)")
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, raw.hasPrefix("tab:"),
                      let dragged = UUID(uuidString: String(raw.dropFirst(4))) else { return false }
                move(id: dragged, before: section.id)
                return true
            }
            .contextMenu {
                Button("Rename\u{2026}") { renaming = section; nameDraft = section.title }
                Button("Move Left") { move(section, by: -1) }
                    .disabled(noteSections.first == section)
                Button("Move Right") { move(section, by: 1) }
                    .disabled(noteSections.last == section)
                Divider()
                Button("Delete\u{2026}", role: .destructive) { pendingDeletion = section }
                    .disabled(noteSections.count < 2)
            }
    }

    var body: some View {
        let selected = noteSections.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(noteSections) { tab($0) }
                    }
                    .padding(.vertical, 2)
                }
                Button { add() } label: { Image(systemName: "plus") }
                    .help("Add a notes tab")
                if let selected {
                    Button { move(selected, by: -1) } label: { Image(systemName: "arrow.left") }
                        .disabled(noteSections.first == selected)
                        .help("Move this tab left")
                    Button { move(selected, by: 1) } label: { Image(systemName: "arrow.right") }
                        .disabled(noteSections.last == selected)
                        .help("Move this tab right")
                    Button { renaming = selected; nameDraft = selected.title } label: { Image(systemName: "pencil") }
                        .help("Rename this tab")
                    Button { pendingDeletion = selected } label: { Image(systemName: "trash") }
                        .disabled(noteSections.count < 2)
                        .help("Delete this tab")
                }
            }
            .buttonStyle(.borderless)
            .alert("Rename Notes", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $nameDraft)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Delete \u{201c}\(pendingDeletion?.title ?? "")\u{201d} and its notes?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let doomed = pendingDeletion { delete(doomed) }
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            }
            NotesFormatBar()
            Text("Select text in a cell, then use the tools above. Bold and italic are Markdown; color, font and size are saved as small HTML tags.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            NotebookEditorView(cells: $notes, defaultPreview: true)
                .id(selectedID)
                .frame(height: 440)
        }
        .onAppear { load() }
        .onChange(of: scope) { _, _ in load() }
        .onChange(of: notes) { _, newValue in
            if let selectedID { ProjectNotebookStorage.write(newValue, for: scope, section: selectedID) }
        }
    }
}
