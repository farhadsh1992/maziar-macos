import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PaperDetailView: View {
    @Binding var paper: Paper
    var onBack: () -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var libraryStore: LibraryStore
    @Environment(\.openWindow) private var openWindow

    @State private var newTaskText = ""
    @State private var draggingTaskID: UUID?
    @State private var dropTargetTaskID: UUID?
    @EnvironmentObject var taskTagStore: TaskTagStore
    @State private var renamingSectionID: UUID?
    @State private var sectionNameDraft = ""
    @State private var sectionPendingDeletion: ProjectSectionEntry?
    @State private var shortcutEditor: ProjectShortcutEditorTarget?
    @State private var shortcutError: String?
    @State private var isDraftingRebuttal = false
    @State private var rebuttalError: String?
    @State private var isGeneratingSlides = false
    @State private var isGeneratingPoster = false
    @State private var generationError: String?
    @State private var isGeneratingPage = false
    @State private var pageGenerationError: String?
    @State private var projectLinkError: String?
    @State private var isGettingSuggestions = false
    @State private var improvementError: String?
    @State private var showNewSubProjectSheet = false
    @State private var selectedChild: Paper?
    @State private var subProjectPendingDeletion: Paper?
    @State private var editingSubProject: Paper?

    var body: some View {
        if let selectedChild, paperStore.papers.contains(where: { $0.id == selectedChild.id }) {
            PaperDetailView(paper: childBinding(for: selectedChild), onBack: { self.selectedChild = nil })
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            shortcutsBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(visibleLayout) { entry in
                        sectionView(entry)
                            .overlay(alignment: .topTrailing) { sectionControls(entry) }
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, raw.hasPrefix("section:"),
                                      let dragged = UUID(uuidString: String(raw.dropFirst(8))) else { return false }
                                withAnimation(.easeInOut(duration: 0.15)) { moveSection(dragged, before: entry.id) }
                                return true
                            }
                    }
                    addSectionMenu
                }
                .padding(20)
                .environment(\.sectionScope, paper.id)
            }
        }
        .sheet(item: $shortcutEditor) { target in
            ProjectShortcutSheet(
                shortcut: target.shortcut,
                isNew: target.isNew,
                onSave: { saved in
                    if let index = paper.shortcuts.firstIndex(where: { $0.id == saved.id }) {
                        paper.shortcuts[index] = saved
                    } else {
                        paper.shortcuts.append(saved)
                    }
                    shortcutEditor = nil
                },
                onCancel: { shortcutEditor = nil }
            )
        }
        .alert("Can\u{2019}t Open", isPresented: Binding(get: { shortcutError != nil }, set: { if !$0 { shortcutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shortcutError ?? "")
        }
        .alert("Rename Section", isPresented: Binding(get: { renamingSectionID != nil }, set: { if !$0 { renamingSectionID = nil } })) {
            TextField("Name", text: $sectionNameDraft)
            Button("Save") { commitSectionRename() }
            Button("Cancel", role: .cancel) { renamingSectionID = nil }
        }
        .confirmationDialog(
            "Delete the section \u{201c}\(sectionPendingDeletion?.displayTitle ?? "")\u{201d} and everything in it?",
            isPresented: Binding(get: { sectionPendingDeletion != nil }, set: { if !$0 { sectionPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let doomed = sectionPendingDeletion { deleteSection(doomed) }
                sectionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { sectionPendingDeletion = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
        .sheet(item: $editingSubProject) { child in
            ProjectIconSheet(paper: child, onSave: { title, icon, colorHex in
                var updated = paperStore.papers.first(where: { $0.id == child.id }) ?? child
                updated.title = title
                updated.iconSystemName = icon
                updated.iconColorHex = colorHex
                paperStore.update(updated)
                editingSubProject = nil
            }, onCancel: { editingSubProject = nil })
        }
        .sheet(isPresented: $showNewSubProjectSheet) {
            NewProjectSheet(
                parentID: paper.id,
                onCreated: { child in
                    showNewSubProjectSheet = false
                    selectedChild = child
                },
                onCancel: { showNewSubProjectSheet = false }
            )
        }
    }

    // MARK: - Section layout (order, extra boxes)

    /// The boxes in display order — leaving out the Poster & Slides / Code Page boxes until accepted.
    private var visibleLayout: [ProjectSectionEntry] {
        paper.layout.filter { entry in
            switch entry.kind {
            case .generate, .codePage: return paper.decision == .accepted
            default: return true
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ entry: ProjectSectionEntry) -> some View {
        switch entry.kind {
        case .latexProject: projectSection
        case .venue: venueSection
        case .tasks: tasksSection
        case .subProjects: subProjectsSection
        case .reviewer: reviewerSection
        case .decision: decisionSection
        case .generate: generateSection
        case .codePage: codePageSection
        case .links: linksSection
        case .libraryGroups: libraryGroupSection
        case .information:
            SectionCard(title: entry.displayTitle, icon: "info.circle", collapseKey: entry.isExtra ? entry.id.uuidString : nil) {
                ProjectInfoBox(paper: $paper, instanceID: entry.isExtra ? entry.id : nil)
            }
        case .notes:
            SectionCard(title: entry.displayTitle, icon: "note.text", collapseKey: entry.isExtra ? entry.id.uuidString : nil) {
                ProjectNotesBox(scope: entry.isExtra ? entry.id : paper.id)
            }
        case .images:
            SectionCard(title: entry.displayTitle, icon: "photo.on.rectangle", collapseKey: entry.isExtra ? entry.id.uuidString : nil) {
                if entry.isExtra {
                    ProjectImagesView(
                        allImages: Binding(
                            get: { paper.extraImages[entry.id.uuidString] ?? [] },
                            set: { paper.extraImages[entry.id.uuidString] = $0 }
                        ),
                        paperID: paper.id
                    )
                } else {
                    ProjectImagesView(allImages: $paper.images, paperID: paper.id)
                }
            }
        }
    }

    /// The drag handle and ⋯ menu in a box's top-right corner.
    private func sectionControls(_ entry: ProjectSectionEntry) -> some View {
        let ids = visibleLayout.map(\.id)
        let index = ids.firstIndex(of: entry.id) ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .draggable("section:\(entry.id.uuidString)")
                .help("Drag to move this section")
            Menu {
                Button("Move Up") { moveSection(entry.id, by: -1) }.disabled(index == 0)
                Button("Move Down") { moveSection(entry.id, by: 1) }.disabled(index >= ids.count - 1)
                Button("Move to Top") { moveSection(entry.id, by: -index) }.disabled(index == 0)
                Button("Move to Bottom") { moveSection(entry.id, by: ids.count - 1 - index) }.disabled(index >= ids.count - 1)
                if entry.kind.isRepeatable {
                    Divider()
                    Button("Rename\u{2026}") { renamingSectionID = entry.id; sectionNameDraft = entry.displayTitle }
                }
                if entry.isExtra {
                    Button("Delete Section\u{2026}", role: .destructive) { sectionPendingDeletion = entry }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move or manage this section")
        }
        .padding(.top, 14)
        .padding(.trailing, 14)
    }

    private var addSectionMenu: some View {
        HStack {
            Menu {
                ForEach(ProjectSectionKind.allCases.filter(\.isRepeatable), id: \.self) { kind in
                    Button { addSection(kind) } label: { Label("\(kind.defaultTitle) box", systemImage: "plus") }
                }
            } label: {
                Label("Add Section", systemImage: "plus.rectangle.on.rectangle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add another Information, Notes or Images box")
            Spacer()
        }
    }

    /// Saves the order with every box in it (built-in ones included), so later changes keep it.
    private func setLayout(_ entries: [ProjectSectionEntry]) {
        paper.sectionLayout = entries
    }

    private func moveSection(_ id: UUID, by offset: Int) {
        guard offset != 0 else { return }
        var all = paper.layout
        let visible = visibleLayout.map(\.id)
        guard let visibleIndex = visible.firstIndex(of: id) else { return }
        let targetIndex = visibleIndex + offset
        guard visible.indices.contains(targetIndex), let from = all.firstIndex(where: { $0.id == id }) else { return }
        let neighborID = visible[targetIndex]
        let moved = all.remove(at: from)
        guard let neighbor = all.firstIndex(where: { $0.id == neighborID }) else { return }
        all.insert(moved, at: offset > 0 ? neighbor + 1 : neighbor)
        setLayout(all)
    }

    private func moveSection(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID else { return }
        var all = paper.layout
        guard let from = all.firstIndex(where: { $0.id == draggedID }) else { return }
        let moved = all.remove(at: from)
        guard let to = all.firstIndex(where: { $0.id == targetID }) else { return }
        all.insert(moved, at: to)
        setLayout(all)
    }

    private func addSection(_ kind: ProjectSectionKind) {
        var all = paper.layout
        let count = all.filter { $0.kind == kind }.count
        let entry = ProjectSectionEntry(id: UUID(), kind: kind, title: "\(kind.defaultTitle) \(count + 1)", isExtra: true)
        // Right behind the last box of the same kind.
        if let last = all.lastIndex(where: { $0.kind == kind }) { all.insert(entry, at: last + 1) } else { all.append(entry) }
        setLayout(all)
    }

    private func commitSectionRename() {
        defer { renamingSectionID = nil }
        let name = sectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renamingSectionID, !name.isEmpty else { return }
        var all = paper.layout
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].title = name
        setLayout(all)
    }

    private func deleteSection(_ entry: ProjectSectionEntry) {
        guard entry.isExtra else { return }
        switch entry.kind {
        case .information: paper.extraInfo[entry.id.uuidString] = nil
        case .images:
            (paper.extraImages[entry.id.uuidString] ?? []).forEach { ProjectImageStorage.delete($0, paperID: paper.id) }
            paper.extraImages[entry.id.uuidString] = nil
        case .notes: ProjectNotebookStorage.remove(entry.id)
        default: break
        }
        setLayout(paper.layout.filter { $0.id != entry.id })
    }

    // MARK: - Shortcuts (folder / website buttons)

    private var shortcutsBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(paper.shortcuts) { shortcut in
                        shortcutButton(shortcut)
                    }
                }
                .padding(.vertical, 2)
            }
            if paper.shortcuts.isEmpty {
                Text("Add buttons for a folder on this Mac or a website \u{2192}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Menu {
                Button { addFolderShortcut() } label: { Label("Add Folder\u{2026}", systemImage: "folder.badge.plus") }
                Button {
                    shortcutEditor = ProjectShortcutEditorTarget(shortcut: ProjectShortcut(kind: .website, title: "", target: ""), isNew: true)
                } label: { Label("Add Website\u{2026}", systemImage: "globe") }
            } label: {
                Label("Add Button", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add a button that opens a folder or a website")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func shortcutButton(_ shortcut: ProjectShortcut) -> some View {
        let missing = shortcut.kind == .folder && !FileManager.default.fileExists(atPath: shortcut.target)
        return Button { openShortcut(shortcut) } label: {
            Label(shortcut.title, systemImage: missing ? "exclamationmark.triangle" : shortcut.icon)
                .lineLimit(1)
        }
        .buttonStyle(ShortcutButtonStyle(
            tint: shortcut.colorHex.flatMap(Color.init(hex:)),
            textColor: shortcut.textColorHex.flatMap(Color.init(hex:))
        ))
        .help(missing ? "Folder not found: \(shortcut.target)" : shortcut.target)
        .contextMenu {
            Button("Open") { openShortcut(shortcut) }
            if shortcut.kind == .folder {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: shortcut.target)])
                }
                .disabled(missing)
            } else if let url = shortcut.webURL {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
            Button("Edit\u{2026}") { shortcutEditor = ProjectShortcutEditorTarget(shortcut: shortcut, isNew: false) }
            Divider()
            Button("Move Left") { moveShortcut(shortcut, by: -1) }
                .disabled(paper.shortcuts.first == shortcut)
            Button("Move Right") { moveShortcut(shortcut, by: 1) }
                .disabled(paper.shortcuts.last == shortcut)
            Divider()
            Button("Remove Button", role: .destructive) { paper.shortcuts.removeAll { $0.id == shortcut.id } }
        }
    }

    private func openShortcut(_ shortcut: ProjectShortcut) {
        switch shortcut.kind {
        case .folder:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: shortcut.target, isDirectory: &isDirectory) else {
                shortcutError = "The folder \u{201c}\(shortcut.target)\u{201d} no longer exists. Right-click the button and choose Edit\u{2026} to pick it again."
                return
            }
            NSWorkspace.shared.open(URL(fileURLWithPath: shortcut.target, isDirectory: isDirectory.boolValue))
        case .website:
            guard let url = shortcut.webURL else {
                shortcutError = "\u{201c}\(shortcut.target)\u{201d} isn\u{2019}t a valid web address. Right-click the button and choose Edit\u{2026}."
                return
            }
            openWindow(id: "project-web", value: ProjectWebTarget(id: shortcut.id, title: shortcut.title, urlString: url.absoluteString))
        }
    }

    private func addFolderShortcut() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to add as a button on this project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        paper.shortcuts.append(ProjectShortcut(kind: .folder, title: url.lastPathComponent, target: url.path))
    }

    private func moveShortcut(_ shortcut: ProjectShortcut, by offset: Int) {
        guard let index = paper.shortcuts.firstIndex(of: shortcut) else { return }
        let target = index + offset
        guard paper.shortcuts.indices.contains(target) else { return }
        paper.shortcuts.swapAt(index, target)
    }

    private func childBinding(for child: Paper) -> Binding<Paper> {
        Binding(
            get: { paperStore.papers.first(where: { $0.id == child.id }) ?? child },
            set: { paperStore.update($0) }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Projects", systemImage: "chevron.left")
            }
            BrandMark(size: 48)
            TextField("Paper title", text: Binding(get: { paper.title }, set: { paper.title = $0 }))
                .textFieldStyle(.plain)
                .font(.title2.bold())
            ProjectColorButton(
                colorHex: paper.iconColorHex,
                onChange: { paper.iconColorHex = $0 }
            )
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Project link

    private var linkedProject: Project? {
        guard let path = paper.projectPath else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        return Project(path: path, name: url.lastPathComponent, mainFile: "main.tex", lastOpened: Date())
    }

    private var projectSection: some View {
        SectionCard(title: "LaTeX Project", icon: "doc.richtext") {
            if let path = paper.projectPath, FileManager.default.fileExists(atPath: path) {
                HStack {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.subheadline.bold())
                    Spacer()
                    Button("Open in Editor") { openInEditor() }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.color(for: .buttonColor))
                }
                HStack {
                    Button("Download Zip...") { downloadProjectZip() }
                        .buttonStyle(.bordered)
                    Button("Download PDF...") { downloadProjectPDF() }
                        .buttonStyle(.bordered)
                    Spacer()
                    ProjectCreationMenu(
                        label: "Replace Project",
                        showRecents: true,
                        onCreated: { project in
                            paper.projectPath = project.path
                            appState.open(project)
                        },
                        onError: { message in projectLinkError = message }
                    )
                    .buttonStyle(.bordered)
                    Button("Remove") { paper.projectPath = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Unlinks this project from the paper only \u{2014} doesn't delete its files.")
                }
            } else {
                HStack {
                    Text("No project linked yet.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ProjectCreationMenu(
                        label: "Add LaTeX Project",
                        onCreated: { project in
                            paper.projectPath = project.path
                            appState.open(project)
                        },
                        onError: { message in projectLinkError = message }
                    )
                    .buttonStyle(.borderedProminent)
                    .tint(settings.color(for: .buttonColor))
                }
            }
            if let projectLinkError {
                CopyableErrorView(message: projectLinkError)
            }
        }
    }

    private func downloadProjectZip() {
        guard let project = linkedProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(project.name).zip"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportZip(project, to: url)
        } catch {
            projectLinkError = error.localizedDescription
        }
    }

    private func downloadProjectPDF() {
        guard let project = linkedProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(paper.title).pdf"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportPDF(project, to: url)
        } catch {
            projectLinkError = error.localizedDescription
        }
    }

    private func openInEditor() {
        guard let path = paper.projectPath else { return }
        let project = store.openProject(at: URL(fileURLWithPath: path))
        appState.open(project)
    }

    /// Best-effort read of the linked project's main LaTeX file, for AI context — same detection
    /// heuristic as `ProjectStore.detectMainFile` (prefer main.tex, else first .tex found).
    private func readProjectMainText() -> String? {
        guard let path = paper.projectPath else { return nil }
        let projectURL = URL(fileURLWithPath: path)
        let mainCandidate = projectURL.appendingPathComponent("main.tex")
        if let text = try? String(contentsOf: mainCandidate, encoding: .utf8) { return text }
        if let items = try? FileManager.default.contentsOfDirectory(at: projectURL, includingPropertiesForKeys: nil),
           let firstTex = items.first(where: { $0.pathExtension.lowercased() == "tex" }),
           let text = try? String(contentsOf: firstTex, encoding: .utf8) {
            return text
        }
        return nil
    }

    private func extractAbstract() -> String? {
        guard let text = readProjectMainText() else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "(?s)\\\\begin\\{abstract\\}(.*?)\\\\end\\{abstract\\}") else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Venue / deadline

    private var linkedConference: ConferenceEntry? {
        guard let name = paper.conferenceName, !name.isEmpty else { return nil }
        return conferenceStore.conferences.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var venueSection: some View {
        SectionCard(title: "Conference / Journal", icon: "calendar.badge.clock") {
            HStack {
                TextField(
                    "Conference or journal name",
                    text: Binding(get: { paper.conferenceName ?? "" }, set: { paper.conferenceName = $0.isEmpty ? nil : $0 }),
                    prompt: Text("e.g. NeurIPS")
                )
                .textFieldStyle(.roundedBorder)

                if !conferenceStore.conferences.isEmpty {
                    Menu {
                        ForEach(conferenceStore.conferences) { conference in
                            Button(conference.name) { paper.conferenceName = conference.name }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick from tracked conferences")
                }
            }

            if let linked = linkedConference {
                if let next = linked.nextDeadline {
                    HStack(spacing: 8) {
                        BlinkingDot()
                        Text("Next deadline: \(next.label) \u{2014} \(next.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? (next.rawText ?? "TBA"))")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.red)
                } else {
                    Text("Tracked, but no deadline fetched yet — go to Conferences and click Update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if paper.conferenceName != nil {
                TextField(
                    "Deadline (optional, not tracked as a conference)",
                    text: Binding(get: { paper.independentDeadlineString ?? "" }, set: { paper.independentDeadlineString = $0.isEmpty ? nil : $0 }),
                    prompt: Text("e.g. March 15, 2027")
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
        }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        SectionCard(title: "Tasks", icon: "checklist") {
            ForEach(paper.tasks) { task in
                taskRow(task)
            }
            HStack {
                TextField("New task", text: $newTaskText, prompt: Text("e.g. Run ablation study"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                Button("Add", action: addTask)
                    .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if paper.tasks.count > 1 {
                HStack(spacing: 10) {
                    Button("Sort by date") { sortTasksByDate() }
                        .buttonStyle(.plain)
                        .foregroundStyle(settings.color(for: .buttonColor))
                        .disabled(!paper.tasks.contains { $0.dueDate != nil })
                    Text("Drag \u{2630} (or right-click a task) to change the order.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
    }

    private func taskRow(_ task: PaperTask) -> some View {
        let isDropTarget = dropTargetTaskID == task.id && draggingTaskID != task.id
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .contentShape(Rectangle())
                .draggable(task.id.uuidString)
                .help("Drag to reorder")
            Button {
                toggleTask(task)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? settings.color(for: .buttonColor) : .secondary)
            }
            .buttonStyle(.plain)
            Text(task.text)
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? .secondary : .primary)
            ForEach(taskTagStore.tags(for: task)) { tag in
                Text(tag.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(tag.color)
                    .background(tag.color.opacity(0.16))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(tag.color.opacity(0.6), lineWidth: 1))
            }
            Spacer()
            taskInfoButton(task)
            taskDateControl(task)
            Button {
                removeTask(task)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .overlay(alignment: .top) {
            Rectangle().fill(settings.color(for: .buttonColor)).frame(height: 2).opacity(isDropTarget ? 1 : 0)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != task.id else { return false }
            withAnimation(.easeInOut(duration: 0.15)) { paperStore.moveTask(in: paper.id, taskID: id, before: task.id) }
            return true
        } isTargeted: { targeted in
            if targeted { dropTargetTaskID = task.id } else if dropTargetTaskID == task.id { dropTargetTaskID = nil }
        }
        .contextMenu {
            Button("Move to Top") { moveTask(task, toIndex: 0) }
            Button("Move Up") { moveTask(task, by: -1) }
            Button("Move Down") { moveTask(task, by: 1) }
            Button("Move to Bottom") { moveTask(task, toIndex: paper.tasks.count - 1) }
            Divider()
            if task.dueDate != nil { Button("Clear Date") { setTaskDate(nil, for: task) } }
            Button("Sub-Tasks & Notes\u{2026}") { openTaskWindow(task) }
            if !taskTagStore.tags.isEmpty {
                Menu("Tags") {
                    ForEach(taskTagStore.tags) { tag in
                        Button {
                            toggleTag(tag.id, on: task)
                        } label: {
                            Label(tag.name, systemImage: task.tagIDs.contains(tag.id) ? "checkmark" : "tag")
                        }
                    }
                }
            }
        }
    }

    /// The (i) button: opens the task's sub-tasks, notes and tags. Filled and annotated when the task
    /// already has some, so you can see at a glance which tasks have more behind them.
    private func taskInfoButton(_ task: PaperTask) -> some View {
        Button { openTaskWindow(task) } label: {
            HStack(spacing: 3) {
                if !task.subtasks.isEmpty {
                    Text("\(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)").font(.caption2.monospacedDigit())
                }
                if !task.links.isEmpty {
                    Image(systemName: "link").font(.caption2)
                }
                if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "note.text").font(.caption2)
                }
                Image(systemName: task.hasDetails ? "info.circle.fill" : "info.circle")
            }
            .foregroundStyle(task.hasDetails ? settings.color(for: .buttonColor) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Open sub-tasks, notes and tags in their own window")
    }

    private func openTaskWindow(_ task: PaperTask) {
        openWindow(id: "task-detail", value: TaskWindowTarget(paperID: paper.id, taskID: task.id))
    }

    private func toggleTag(_ tagID: UUID, on task: PaperTask) {
        guard let index = paper.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        if let existing = paper.tasks[index].tagIDs.firstIndex(of: tagID) {
            paper.tasks[index].tagIDs.remove(at: existing)
        } else {
            paper.tasks[index].tagIDs.append(tagID)
        }
    }

    /// "Add date" until one is set, then a compact date field (red once overdue) with a clear button.
    @ViewBuilder
    private func taskDateControl(_ task: PaperTask) -> some View {
        if let due = task.dueDate {
            let overdue = !task.isDone && due < Calendar.current.startOfDay(for: Date())
            DatePicker(
                "", selection: Binding(get: { due }, set: { setTaskDate($0, for: task) }),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
            .foregroundStyle(overdue ? Color.red : Color.primary)
            Button { setTaskDate(nil, for: task) } label: { Image(systemName: "calendar.badge.minus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the date")
        } else {
            Button { setTaskDate(Calendar.current.startOfDay(for: Date()), for: task) } label: {
                Label("Add date", systemImage: "calendar.badge.plus").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func setTaskDate(_ date: Date?, for task: PaperTask) {
        guard let index = paper.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        paper.tasks[index].dueDate = date.map { Calendar.current.startOfDay(for: $0) }
    }

    private func moveTask(_ task: PaperTask, by offset: Int) {
        guard let index = paper.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        moveTask(task, toIndex: index + offset)
    }

    private func moveTask(_ task: PaperTask, toIndex target: Int) {
        guard let index = paper.tasks.firstIndex(where: { $0.id == task.id }),
              paper.tasks.indices.contains(target), target != index else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            let moved = paper.tasks.remove(at: index)
            paper.tasks.insert(moved, at: target)
        }
    }

    /// Earliest date first; undated tasks keep their relative order at the bottom.
    private func sortTasksByDate() {
        let dated = paper.tasks.filter { $0.dueDate != nil }.sorted { $0.dueDate! < $1.dueDate! }
        let undated = paper.tasks.filter { $0.dueDate == nil }
        withAnimation(.easeInOut(duration: 0.15)) { paper.tasks = dated + undated }
    }

    private func addTask() {
        let trimmed = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paper.tasks.append(PaperTask(text: trimmed))
        newTaskText = ""
    }

    private func toggleTask(_ task: PaperTask) {
        guard let index = paper.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        paper.tasks[index].isDone.toggle()
    }

    private func removeTask(_ task: PaperTask) {
        paper.tasks.removeAll { $0.id == task.id }
    }

    // MARK: - Links (developing projects)

    private var linksSection: some View {
        SectionCard(title: "Links & References", icon: "link") {
            Text("GitHub Repo").font(.caption).foregroundStyle(.secondary)
            TextField(
                "https://github.com/...",
                text: Binding(get: { paper.githubRepoURLString ?? "" }, set: { paper.githubRepoURLString = $0.isEmpty ? nil : $0 })
            )
            .textFieldStyle(.roundedBorder)

            Divider()

            LinkListView(links: $paper.links)
        }
    }

    // MARK: - Library group

    private var linkedLibraryGroups: [LibraryGroup] {
        paper.libraryGroupIDs.compactMap { libraryStore.group($0) }
    }

    private func toggleLibraryGroup(_ id: UUID) {
        if paper.libraryGroupIDs.contains(id) {
            paper.libraryGroupIDs.removeAll { $0 == id }
        } else {
            paper.libraryGroupIDs.append(id)
        }
    }

    private var libraryGroupSection: some View {
        SectionCard(title: "Library Groups", icon: "books.vertical") {
            HStack(alignment: .top) {
                let groups = linkedLibraryGroups
                if groups.isEmpty {
                    Text("No groups tagged.").font(.caption).foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(groups) { group in
                            let tint = group.iconColorHex.flatMap(Color.init(hex:)) ?? .accentColor
                            HStack(spacing: 4) {
                                Label(group.name, systemImage: group.iconSystemName)
                                Button { toggleLibraryGroup(group.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .help("Remove this tag")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(tint)
                            .background(tint.opacity(0.14))
                            .clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                Menu {
                    ForEach(libraryStore.groups) { group in
                        Button {
                            toggleLibraryGroup(group.id)
                        } label: {
                            Label(group.isArchived ? "\(group.name) (archived)" : group.name,
                                  systemImage: paper.libraryGroupIDs.contains(group.id) ? "checkmark" : group.iconSystemName)
                        }
                    }
                } label: {
                    Label("Tag Groups", systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(libraryStore.groups.isEmpty)
            }
            if libraryStore.groups.isEmpty {
                Text("Create a group on the Library page first, then tag it here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(linkedLibraryGroups) { group in
                let papers = libraryStore.entries(in: group).sorted { $0.dateAdded > $1.dateAdded }
                Divider()
                Label("\(group.name) \u{00b7} \(papers.count) paper\(papers.count == 1 ? "" : "s")", systemImage: group.iconSystemName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.iconColorHex.flatMap(Color.init(hex:)) ?? .secondary)
                if papers.isEmpty {
                    Text("No papers in \u{201c}\(group.name)\u{201d} yet \u{2014} add some on the Library page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(papers) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.subheadline).lineLimit(2)
                            let detail = [entry.authors, entry.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00b7} ")
                            if !detail.isEmpty {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button { openWindow(id: "paper-reader", value: entry.id) } label: { Image(systemName: "doc.text") }
                            .disabled(libraryStore.isFileMissing(entry))
                            .help("Open in Reader")
                        Button { openWindow(id: "paper-notes", value: entry.id) } label: { Image(systemName: "note.text") }
                            .help("Open this paper's notes")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Sub-projects

    private var subProjectsSection: some View {
        SectionCard(title: "Sub-Projects", icon: "square.stack") {
            let children = paperStore.children(of: paper)
            FlowLayout(spacing: 12) {
                ForEach(children) { child in
                    GroupCardButton(
                        title: child.title,
                        systemIcon: child.cardIcon,
                        colorHex: child.iconColorHex,
                        image: nil,
                        tooltip: subProjectTooltip(child),
                        isSelected: false
                    ) {
                        selectedChild = child
                    }
                    .contextMenu {
                        Button("Open") { selectedChild = child }
                        Button("Rename / Change Icon\u{2026}") { editingSubProject = child }
                        Divider()
                        Button("Delete Sub-Project\u{2026}", role: .destructive) { subProjectPendingDeletion = child }
                    }
                }
                Button {
                    showNewSubProjectSheet = true
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: 52, height: 52)
                            Image(systemName: "plus")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        Text("New Sub-Project").font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 76)
                    }
                    .frame(width: 84, height: 84)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .confirmationDialog(
                "Delete \u{201c}\(subProjectPendingDeletion?.title ?? "")\u{201d} and everything inside it?",
                isPresented: Binding(get: { subProjectPendingDeletion != nil }, set: { if !$0 { subProjectPendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let doomed = subProjectPendingDeletion { paperStore.remove(doomed) }
                    subProjectPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { subProjectPendingDeletion = nil }
            }
        }
    }

    private func subProjectTooltip(_ child: Paper) -> String {
        var lines = [child.title, child.kind.displayName]
        if !child.tasks.isEmpty { lines.append("\(child.doneTaskCount)/\(child.tasks.count) tasks done") }
        let nested = paperStore.children(of: child).count
        if nested > 0 { lines.append("\(nested) sub-project\(nested == 1 ? "" : "s")") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reviewer comments / rebuttal

    private var reviewerSection: some View {
        SectionCard(title: "Reviewer Comments & Rebuttal", icon: "bubble.left.and.bubble.right") {
            Text("Add each reviewer's comments separately, then ask AI to organize them all and draft rebuttal points grounded in the linked paper.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(paper.reviewerComments) { comment in
                ReviewerCommentCard(
                    comment: reviewerCommentBinding(for: comment),
                    onRemove: { removeReviewerComment(comment) }
                )
            }
            Button {
                addReviewerComment()
            } label: {
                Label("Add Reviewer", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            HStack {
                Button {
                    draftRebuttal()
                } label: {
                    if isDraftingRebuttal {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Organize & Draft Rebuttal", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.color(for: .buttonColor))
                .disabled(isDraftingRebuttal || !aiSettings.isConfigured(aiSettings.activeProvider))
                Spacer()
            }
            if !aiSettings.isConfigured(aiSettings.activeProvider) {
                Label("No API key set for \(aiSettings.activeProvider.displayName) — add one in Settings \u{2192} AI.", systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let rebuttalError {
                CopyableErrorView(message: rebuttalError)
            }
            if !paper.rebuttalNotes.isEmpty {
                Divider()
                HStack {
                    Text("Drafted response").font(.caption.bold())
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paper.rebuttalNotes, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy")
                }
                Text(paper.rebuttalNotes)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func draftRebuttal() {
        rebuttalError = nil
        isDraftingRebuttal = true
        let comments = paper.reviewerComments
        let paperText = readProjectMainText()
        Task {
            do {
                let result = try await PaperRebuttalService.organizeAndDraft(reviewerComments: comments, paperText: paperText, settings: aiSettings)
                paper.rebuttalNotes = result
            } catch {
                rebuttalError = error.localizedDescription
            }
            isDraftingRebuttal = false
        }
    }

    private func addReviewerComment() {
        paper.reviewerComments.append(ReviewerComment(label: "Reviewer \(paper.reviewerComments.count + 1)"))
    }

    private func removeReviewerComment(_ comment: ReviewerComment) {
        paper.reviewerComments.removeAll { $0.id == comment.id }
    }

    private func reviewerCommentBinding(for comment: ReviewerComment) -> Binding<ReviewerComment> {
        Binding(
            get: { paper.reviewerComments.first(where: { $0.id == comment.id }) ?? comment },
            set: { newValue in
                guard let index = paper.reviewerComments.firstIndex(where: { $0.id == comment.id }) else { return }
                paper.reviewerComments[index] = newValue
            }
        )
    }

    // MARK: - Decision

    private var decisionSection: some View {
        SectionCard(title: "Decision", icon: "checkmark.seal") {
            switch paper.decision {
            case .pending:
                HStack {
                    Text("Once you hear back, record the outcome:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reject") { paper.decision = .rejected }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Button("Accept") { paper.decision = .accepted }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
            case .accepted:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Congratulations! Your paper was accepted.", systemImage: "party.popper.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Button("Undo") { paper.decision = .pending }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .rejected:
                VStack(alignment: .leading, spacing: 10) {
                    Label("Rejected", systemImage: "xmark.seal.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                    Button {
                        getImprovementSuggestions()
                    } label: {
                        if isGettingSuggestions {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Get AI Suggestions for Improving the Paper", systemImage: "lightbulb")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.color(for: .buttonColor))
                    .disabled(isGettingSuggestions || !aiSettings.isConfigured(aiSettings.activeProvider))
                    if !aiSettings.isConfigured(aiSettings.activeProvider) {
                        Label("No API key set for \(aiSettings.activeProvider.displayName) — add one in Settings \u{2192} AI.", systemImage: "key.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let improvementError {
                        CopyableErrorView(message: improvementError)
                    }
                    if !paper.improvementSuggestions.isEmpty {
                        Divider()
                        HStack {
                            Text("Suggestions").font(.caption.bold())
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(paper.improvementSuggestions, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Copy")
                        }
                        Text(paper.improvementSuggestions)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Button("Undo") { paper.decision = .pending }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func getImprovementSuggestions() {
        improvementError = nil
        isGettingSuggestions = true
        let comments = paper.reviewerComments
        let paperText = readProjectMainText()
        Task {
            do {
                let result = try await PaperImprovementService.suggestImprovements(reviewerComments: comments, paperText: paperText, settings: aiSettings)
                paper.improvementSuggestions = result
            } catch {
                improvementError = error.localizedDescription
            }
            isGettingSuggestions = false
        }
    }

    // MARK: - Poster / slides generation

    private var deckProviderSelection: Binding<String> {
        Binding(
            get: { aiSettings.deckProvider?.rawValue ?? "same" },
            set: { newValue in
                aiSettings.deckProvider = newValue == "same" ? nil : AIProviderKind(rawValue: newValue)
            }
        )
    }

    private var generateSection: some View {
        SectionCard(title: "Poster & Slides", icon: "rectangle.on.rectangle") {
            Text("Generates a real .pptx from the linked paper's content via AI — a poster is one big slide sized for printing; slides are a normal talk deck.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Picker("Generate using", selection: deckProviderSelection) {
                    Text("Same as AI Assistant (\(aiSettings.activeProvider.displayName))").tag("same")
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .fixedSize()
                ModelPickerField(
                    provider: aiSettings.effectiveDeckProvider,
                    modelText: Binding(get: { aiSettings.deckModel }, set: { aiSettings.deckModel = $0 })
                )
            }
            .font(.caption)

            HStack {
                Button {
                    generateDeck(style: .poster)
                } label: {
                    if isGeneratingPoster {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate Poster (.pptx)", systemImage: "doc.richtext")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingPoster || isGeneratingSlides || paper.projectPath == nil)

                Button {
                    generateDeck(style: .talk)
                } label: {
                    if isGeneratingSlides {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate Slides (.pptx)", systemImage: "rectangle.stack")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGeneratingPoster || isGeneratingSlides || paper.projectPath == nil)
            }
            if paper.projectPath == nil {
                Text("Link a LaTeX project above first.").font(.caption).foregroundStyle(.secondary)
            }
            if let generationError {
                CopyableErrorView(message: generationError)
            }
        }
    }

    private func generateDeck(style: PaperDeckService.Style) {
        generationError = nil
        let paperText = readProjectMainText()
        let title = paper.title
        switch style {
        case .poster: isGeneratingPoster = true
        case .talk: isGeneratingSlides = true
        }
        Task {
            do {
                let data = try await PaperDeckService.generateDeck(title: title, paperText: paperText, style: style, settings: aiSettings)
                switch style {
                case .poster: isGeneratingPoster = false
                case .talk: isGeneratingSlides = false
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
                panel.nameFieldStringValue = "\(title) \(style == .poster ? "Poster" : "Slides").pptx"
                panel.prompt = "Save"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
            } catch {
                switch style {
                case .poster: isGeneratingPoster = false
                case .talk: isGeneratingSlides = false
                }
                generationError = error.localizedDescription
            }
        }
    }

    // MARK: - Code page

    private var codePageProviderSelection: Binding<String> {
        Binding(
            get: { aiSettings.codePageProvider?.rawValue ?? "same" },
            set: { newValue in
                aiSettings.codePageProvider = newValue == "same" ? nil : AIProviderKind(rawValue: newValue)
            }
        )
    }

    private var codePageSection: some View {
        SectionCard(title: "Code Page", icon: "globe") {
            TextField(
                "GitHub repository URL",
                text: Binding(get: { paper.githubRepoURLString ?? "" }, set: { paper.githubRepoURLString = $0.isEmpty ? nil : $0 }),
                prompt: Text("https://github.com/you/paper-code")
            )
            .textFieldStyle(.roundedBorder)

            Text("AI writes the page's description paragraph from the linked paper; falls back to \\begin{abstract} if unconfigured or the request fails.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Picker("Generate using", selection: codePageProviderSelection) {
                    Text("Same as AI Assistant (\(aiSettings.activeProvider.displayName))").tag("same")
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .fixedSize()
                ModelPickerField(
                    provider: aiSettings.effectiveCodePageProvider,
                    modelText: Binding(get: { aiSettings.codePageModel }, set: { aiSettings.codePageModel = $0 })
                )
            }
            .font(.caption)

            Button {
                generateProjectPage()
            } label: {
                if isGeneratingPage {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Generate Project Page (.html)", systemImage: "doc.text.image")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isGeneratingPage)

            if let pageGenerationError {
                CopyableErrorView(message: pageGenerationError)
            }
        }
    }

    private func generateProjectPage() {
        pageGenerationError = nil
        isGeneratingPage = true
        let title = paper.title
        let paperText = readProjectMainText()
        Task {
            var description = extractAbstract()
            if let paperText, !paperText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               aiSettings.isConfigured(aiSettings.effectiveCodePageProvider) {
                do {
                    description = try await ProjectPageContentService.generateDescription(title: title, paperText: paperText, settings: aiSettings)
                } catch {
                    pageGenerationError = "AI description failed, used the paper's \\begin{abstract} instead: \(error.localizedDescription)"
                }
            }
            let data = ProjectPageGenerator.generate(paper: paper, abstract: description)
            isGeneratingPage = false
            saveProjectPage(data)
        }
    }

    private func saveProjectPage(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "index.html"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            pageGenerationError = error.localizedDescription
        }
    }
}

/// Which project's page the cards below belong to — lets each card remember its own open/closed state.
private struct SectionScopeKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    fileprivate var sectionScope: UUID? {
        get { self[SectionScopeKey.self] }
        set { self[SectionScopeKey.self] = newValue }
    }
}

/// Remembers which sections of which projects are closed, across launches. One shared instance
/// (rather than one per page) so a parent and its sub-project pages never overwrite each other's
/// state. Stored as one JSON dictionary under a `maziar.` key, so it also rides along with
/// Settings backup / Drive sync.
@MainActor
final class ProjectSectionState: ObservableObject {
    static let shared = ProjectSectionState()
    private static let key = "maziar.projects.collapsedSections"

    /// project id → titles of its closed sections.
    @Published private var collapsed: [String: [String]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            collapsed = decoded
        } else {
            collapsed = [:]
        }
    }

    func isCollapsed(_ project: UUID, _ section: String) -> Bool {
        collapsed[project.uuidString]?.contains(section) ?? false
    }

    func toggle(_ project: UUID, _ section: String) {
        var list = collapsed[project.uuidString] ?? []
        if let index = list.firstIndex(of: section) { list.remove(at: index) } else { list.append(section) }
        collapsed[project.uuidString] = list.isEmpty ? nil : list
        if let data = try? JSONEncoder().encode(collapsed) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    /// What the open/closed state is remembered under; defaults to the title.
    var collapseKey: String? = nil
    @ViewBuilder var content: Content

    @Environment(\.sectionScope) private var scope
    @ObservedObject private var state = ProjectSectionState.shared

    private var isCollapsed: Bool {
        guard let scope else { return false }
        return state.isCollapsed(scope, collapseKey ?? title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard let scope else { return }
                withAnimation(.easeInOut(duration: 0.15)) { state.toggle(scope, collapseKey ?? title) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                    Label(title, systemImage: icon).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Open this section" : "Close this section")
            if !isCollapsed {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct ReviewerCommentCard: View {
    @Binding var comment: ReviewerComment
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Reviewer label", text: $comment.label)
                    .textFieldStyle(.plain)
                    .font(.subheadline.bold())
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            TextEditor(text: $comment.text)
                .frame(minHeight: 70)
                .font(.system(size: 12))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A small pulsing dot — draws attention to the next deadline the way a "live"/recording
/// indicator does, without needing a Timer (an ever-repeating animation is enough).
