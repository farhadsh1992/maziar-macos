import SwiftUI

/// Rename a project and pick its card icon and color — used for sub-projects, whose cards (on the
/// Projects list and inside their parent) look like the Library's group cards.
struct ProjectIconSheet: View {
    let paper: Paper
    var onSave: (_ title: String, _ iconSystemName: String?, _ iconColorHex: String?) -> Void
    var onCancel: () -> Void

    @State private var title: String
    @State private var icon: String
    @State private var color: Color
    @State private var useCustomColor: Bool

    private static let iconChoices = [
        "hammer", "doc.text", "lightbulb.fill", "flask.fill", "cpu", "brain.head.profile",
        "chart.bar.fill", "atom", "function", "book.fill", "graduationcap.fill", "globe",
        "paintbrush.fill", "wrench.and.screwdriver.fill", "bolt.fill", "flame.fill", "leaf.fill", "star.fill",
        "folder.fill", "bookmark.fill", "tag.fill", "waveform", "camera.fill", "network",
    ]

    init(paper: Paper, onSave: @escaping (String, String?, String?) -> Void, onCancel: @escaping () -> Void) {
        self.paper = paper
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: paper.title)
        _icon = State(initialValue: paper.iconSystemName ?? paper.kind.icon)
        _color = State(initialValue: paper.iconColorHex.flatMap(Color.init(hex:)) ?? .accentColor)
        _useCustomColor = State(initialValue: paper.iconColorHex != nil)
    }

    private var tint: Color { useCustomColor ? color : Color.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Sub-Project").font(.headline)
            TextField("Name", text: $title).textFieldStyle(.roundedBorder)

            HStack {
                Text("Icon").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Color", isOn: $useCustomColor).toggleStyle(.checkbox).font(.caption)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(!useCustomColor)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.iconChoices, id: \.self) { choice in
                    Button { icon = choice } label: {
                        Image(systemName: choice)
                            .font(.system(size: 16))
                            .foregroundStyle(icon == choice ? tint : Color.primary)
                            .frame(width: 36, height: 36)
                            .background(icon == choice ? tint.opacity(0.2) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("Reset Icon & Color") {
                    icon = paper.kind.icon
                    useCustomColor = false
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        icon == paper.kind.icon ? nil : icon,
                        useCustomColor ? color.toHex() : nil
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// A project's color: a swatch button that opens a palette (plus a custom picker and "No Color").
/// The color marks the project's card on the Projects list and its dates in the calendar.
struct ProjectColorButton: View {
    let colorHex: String?
    var title = "Project Color"
    var help = "Project color \u{2014} shown on its card and in the calendar"
    var palette: [TextFormatPalette.Swatch] = TextFormatPalette.colors
    var noColorLabel = "No Color"
    var onChange: (String?) -> Void

    @State private var showPicker = false
    @State private var custom: Color = .accentColor

    private var current: Color? { colorHex.flatMap(Color.init(hex:)) }

    var body: some View {
        Button { showPicker.toggle() } label: {
            ZStack {
                Circle().fill(current ?? Color.clear).frame(width: 20, height: 20)
                Circle().stroke(current ?? Color.secondary.opacity(0.6), lineWidth: 1.5).frame(width: 20, height: 20)
                if current == nil {
                    Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.caption.bold())
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), spacing: 8) {
                    ForEach(palette) { swatch in
                        Button { onChange(swatch.hex) } label: {
                            Circle().fill(swatch.color).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary, lineWidth: colorHex?.uppercased().hasPrefix(swatch.hex) == true ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                    }
                }
                HStack {
                    ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                        .onChange(of: custom) { _, newValue in onChange(newValue.toHex()) }
                    Spacer()
                    Button(noColorLabel) { onChange(nil); showPicker = false }
                        .disabled(colorHex == nil)
                }
                .font(.caption)
            }
            .padding(14)
            .frame(width: 190)
        }
        .onAppear { custom = current ?? .accentColor }
    }
}

struct ProjectShortcutEditorTarget: Identifiable {
    let shortcut: ProjectShortcut
    let isNew: Bool
    var id: UUID { shortcut.id }
}

/// Add or edit a project's folder/website button.
struct ProjectShortcutSheet: View {
    let isNew: Bool
    var onSave: (ProjectShortcut) -> Void
    var onCancel: () -> Void

    @State private var draft: ProjectShortcut

    init(shortcut: ProjectShortcut, isNew: Bool, onSave: @escaping (ProjectShortcut) -> Void, onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: shortcut)
    }

    private var canSave: Bool {
        let target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return draft.kind == .folder || draft.webURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Website Button" : (draft.kind == .folder ? "Edit Folder Button" : "Edit Website Button")).font(.headline)
            TextField("Button name", text: $draft.title).textFieldStyle(.roundedBorder)
            if draft.kind == .folder {
                HStack {
                    TextField("Folder path", text: $draft.target).textFieldStyle(.roundedBorder)
                    Button("Choose\u{2026}") { chooseFolder() }
                }
            } else {
                TextField("Website address, e.g. github.com/me/repo", text: $draft.target)
                    .textFieldStyle(.roundedBorder)
                Text("It opens inside Maziar, in its own window.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Background").font(.caption).foregroundStyle(.secondary)
                ProjectColorButton(
                    colorHex: draft.colorHex, title: "Button Background", help: "Background color of the button",
                    onChange: { draft.colorHex = $0 }
                )
                Text("Text").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                ProjectColorButton(
                    colorHex: draft.textColorHex, title: "Button Text Color", help: "Text color of the button",
                    palette: TextFormatPalette.colors + [
                        TextFormatPalette.Swatch(name: "White", hex: "FFFFFF"), TextFormatPalette.Swatch(name: "Black", hex: "000000"),
                    ],
                    noColorLabel: "Automatic",
                    onChange: { draft.textColorHex = $0 }
                )
                Spacer()
            }
            // Live preview of the result.
            Button {} label: {
                Label(draft.title.isEmpty ? "Preview" : draft.title, systemImage: draft.icon)
            }
            .buttonStyle(ShortcutButtonStyle(
                tint: draft.colorHex.flatMap(Color.init(hex:)),
                textColor: draft.textColorHex.flatMap(Color.init(hex:))
            ))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    var saved = draft
                    saved.target = saved.target.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.title = name.isEmpty
                        ? (saved.kind == .folder ? URL(fileURLWithPath: saved.target).lastPathComponent : (saved.webURL?.host ?? saved.target))
                        : name
                    onSave(saved)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.target = url.path
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = url.lastPathComponent }
    }
}

/// The look of a project's folder/website buttons: taller than a normal bordered button, and filled
/// with a soft wash of the button's own color when it has one.
struct ShortcutButtonStyle: ButtonStyle {
    /// The button's background color; nil = the neutral default look.
    var tint: Color?
    /// The label color; nil = white or black, whichever reads better on `tint`.
    var textColor: Color?

    private static func isLight(_ color: Color) -> Bool {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return true }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > 0.6
    }

    func makeBody(configuration: Configuration) -> some View {
        let label: Color = textColor ?? (tint.map { Self.isLight($0) ? Color.black : Color.white } ?? Color.primary)
        let fill = tint ?? Color.secondary.opacity(0.18)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(label)
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(tint == nil ? 0.3 : 0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// What the "task-detail" window shows: one task of one project.
struct TaskWindowTarget: Codable, Hashable {
    var paperID: UUID
    var taskID: UUID
}

/// The window opened from a task's (i) button — looks the task up live, so edits land in the project.
struct TaskDetailWindow: View {
    let target: TaskWindowTarget
    @EnvironmentObject var paperStore: PaperStore

    var body: some View {
        if let paper = paperStore.papers.first(where: { $0.id == target.paperID }),
           paper.tasks.contains(where: { $0.id == target.taskID }) {
            TaskDetailView(
                task: Binding(
                    get: { paperStore.papers.first(where: { $0.id == target.paperID })?.tasks.first(where: { $0.id == target.taskID }) ?? PaperTask(text: "") },
                    set: { updated in
                        guard var current = paperStore.papers.first(where: { $0.id == target.paperID }),
                              let index = current.tasks.firstIndex(where: { $0.id == target.taskID }) else { return }
                        current.tasks[index] = updated
                        paperStore.update(current)
                    }
                ),
                projectTitle: paper.title
            )
            .navigationTitle(paper.tasks.first(where: { $0.id == target.taskID })?.text ?? "Task")
        } else {
            Text("This task no longer exists.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A task's details: tags, sub-tasks and a free-text note — the content of the task window.
struct TaskDetailView: View {
    @Binding var task: PaperTask
    var projectTitle: String
    @EnvironmentObject var taskTagStore: TaskTagStore

    @State private var newSubtask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(projectTitle).font(.caption).foregroundStyle(.secondary)
                TextField("Task", text: $task.text)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("TAGS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                if taskTagStore.tags.isEmpty {
                    Text("No tags yet \u{2014} create them in Settings \u{2192} Projects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(taskTagStore.tags) { tag in
                            let isOn = task.tagIDs.contains(tag.id)
                            Button {
                                if isOn { task.tagIDs.removeAll { $0 == tag.id } } else { task.tagIDs.append(tag.id) }
                            } label: {
                                HStack(spacing: 4) {
                                    if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                    Text(tag.name).lineLimit(1)
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .foregroundStyle(isOn ? Color.white : tag.color)
                                .background(isOn ? tag.color : tag.color.opacity(0.14))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(tag.color.opacity(0.7), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SUB-TASKS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    if !task.subtasks.isEmpty {
                        Text("\(task.subtasks.filter(\.isDone).count)/\(task.subtasks.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach($task.subtasks) { $subtask in
                    HStack(spacing: 6) {
                        Button { subtask.isDone.toggle() } label: {
                            Image(systemName: subtask.isDone ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.plain)
                        TextField("Sub-task", text: $subtask.text)
                            .textFieldStyle(.plain)
                            .strikethrough(subtask.isDone)
                            .foregroundStyle(subtask.isDone ? Color.secondary : Color.primary)
                        Button {
                            task.subtasks.removeAll { $0.id == subtask.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Add a sub-task", text: $newSubtask)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSubtask)
                    Button("Add", action: addSubtask)
                        .disabled(newSubtask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("LINKS & REFERENCES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                LinkListView(links: $task.links)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NOTE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $task.notes)
                    .font(.system(size: 14))
                    .frame(minHeight: 180, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 560)
    }

    private func addSubtask() {
        let trimmed = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task.subtasks.append(PaperSubtask(text: trimmed))
        newSubtask = ""
    }
}
