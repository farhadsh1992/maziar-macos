import SwiftUI
import AppKit

struct LibraryView: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var searchText = ""
    @AppStorage("maziar.library.sortMode") private var sortModeRaw = LibrarySortMode.dateAdded.rawValue
    @State private var showConnectSheet = false
    @State private var showURLSheet = false
    @State private var errorMessage: String?

    @State private var selectedGroupID: UUID?
    @State private var showNewGroupSheet = false
    @State private var editingGroup: LibraryGroup?
    @State private var groupPendingDeletion: LibraryGroup?
    @State private var keywordFilter: (field: LibraryKeywordField, value: String)?
    @State private var showScholarSearch = false
    @AppStorage("maziar.library.scholarPaneWidth") private var scholarPaneWidth: Double = 360

    private let refreshTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var sortMode: LibrarySortMode { LibrarySortMode(rawValue: sortModeRaw) ?? .dateAdded }
    private var selectedGroup: LibraryGroup? { libraryStore.group(selectedGroupID) }

    private var scopedEntries: [LibraryEntry] {
        libraryStore.entries(in: selectedGroup)
    }

    private var keywordFilteredEntries: [LibraryEntry] {
        guard let keywordFilter else { return scopedEntries }
        return libraryEntries(matching: keywordFilter.field, value: keywordFilter.value, in: scopedEntries)
    }

    private var sortedEntries: [LibraryEntry] {
        switch sortMode {
        case .dateAdded: return keywordFilteredEntries.sorted { $0.dateAdded > $1.dateAdded }
        case .title: return keywordFilteredEntries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year: return keywordFilteredEntries.sorted { ($0.year ?? "") > ($1.year ?? "") }
        }
    }

    private var visibleEntries: [LibraryEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sortedEntries }
        return sortedEntries.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.authors?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    /// Names the group explicitly (rather than a generic "no papers yet") so landing on a group
    /// that's genuinely empty doesn't read as "clicking it didn't do anything" — the search-bar
    /// label next to it does the same, but this is the more likely place someone's eye lands.
    private var emptyListMessage: String {
        if !searchText.isEmpty {
            return "No papers match \u{201c}\(searchText)\u{201d}\(selectedGroup.map { " in \u{201c}\($0.name)\u{201d}" } ?? "")."
        }
        if let keywordFilter {
            return "No papers with \(keywordFilter.field.label.lowercased()) \u{201c}\(keywordFilter.value)\u{201d}\(selectedGroup.map { " in \u{201c}\($0.name)\u{201d}" } ?? "")."
        }
        if let selectedGroup {
            return "\u{201c}\(selectedGroup.name)\u{201d} has no papers yet — add one above (it'll go straight into this group), or open a paper from \u{201c}All Papers\u{201d} and add it to this group from its \u{2193} chips."
        }
        return "No papers here yet — add one above."
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                if libraryStore.folderPath == nil {
                    notConnectedState
                } else {
                    groupsRow
                    Divider().opacity(0.3)
                    LibraryKeywordStrip(entries: scopedEntries, selectedValue: keywordFilter?.value) { field, value in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if let keywordFilter, keywordFilter.field == field, keywordFilter.value.caseInsensitiveCompare(value) == .orderedSame {
                                self.keywordFilter = nil
                            } else {
                                keywordFilter = (field, value)
                            }
                        }
                    }
                    Divider().opacity(0.3)
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showScholarSearch {
                ResizableDivider(width: $scholarPaneWidth, minWidth: 280, maxWidth: 700, invertDrag: true)
                    .frame(width: 6)
                ScholarSearchPane()
                    .frame(width: scholarPaneWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
        .onAppear { libraryStore.scan() }
        .onReceive(refreshTimer) { _ in libraryStore.scan() }
        .sheet(isPresented: $showConnectSheet) {
            ConnectFolderSheet(onPick: { url in
                libraryStore.connect(url)
                showConnectSheet = false
            }, onCancel: { showConnectSheet = false })
        }
        .sheet(isPresented: $showURLSheet) {
            AddByURLSheet(
                group: selectedGroup,
                onFinished: { showURLSheet = false },
                onCancel: { showURLSheet = false }
            )
        }
        .sheet(isPresented: $showNewGroupSheet) {
            GroupEditorSheet(existingGroup: nil, onSave: { name, icon, colorHex, imageData, info, keywords, links in
                if let created = try? libraryStore.createGroup(
                    name: name, iconSystemName: icon, iconColorHex: colorHex, customIconData: imageData,
                    info: info, keywords: keywords, links: links
                ) {
                    selectedGroupID = created.id
                }
                showNewGroupSheet = false
            }, onCancel: { showNewGroupSheet = false })
        }
        .sheet(item: $editingGroup) { group in
            GroupEditorSheet(existingGroup: group, onSave: { name, icon, colorHex, imageData, info, keywords, links in
                if name != group.name {
                    try? libraryStore.renameGroup(group, to: name)
                }
                libraryStore.updateGroupAppearance(
                    group, iconSystemName: icon, iconColorHex: colorHex, customIconData: imageData,
                    info: info, keywords: keywords, links: links
                )
                editingGroup = nil
            }, onCancel: { editingGroup = nil })
        }
        .confirmationDialog(
            groupPendingDeletion.map { "Delete the group \u{201c}\($0.name)\u{201d}?" } ?? "",
            isPresented: Binding(get: { groupPendingDeletion != nil }, set: { if !$0 { groupPendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let group = groupPendingDeletion {
                Button("Delete Group, Keep Papers (moved to All Papers)") {
                    libraryStore.deleteGroup(group, deleteFiles: false)
                    if selectedGroupID == group.id { selectedGroupID = nil }
                    groupPendingDeletion = nil
                }
                Button("Delete Group & Move Papers to Trash", role: .destructive) {
                    libraryStore.deleteGroup(group, deleteFiles: true)
                    if selectedGroupID == group.id { selectedGroupID = nil }
                    groupPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { groupPendingDeletion = nil }
            }
        }
    }

    /// Two rows rather than one — the identity row (brand/title/path + Settings) and a second row
    /// for every action button, which had gotten too crowded to fit comfortably side by side with
    /// the title once Search Scholar joined Sort/Refresh/Add Paper/Folder.
    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    BrandMark(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library").font(.title2.bold())
                        if let path = libraryStore.folderPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Not connected to a folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button {
                    openLibrarySettings()
                } label: {
                    Label("Setting", systemImage: "gearshape")
                }
            }

            HStack {
                if libraryStore.folderPath != nil {
                    Picker("Sort", selection: $sortModeRaw) {
                        ForEach(LibrarySortMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button {
                        libraryStore.scan()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Menu {
                        Button("Add Files…") { addPapers() }
                        Button("Add Folder… (all PDFs inside)") { addFolder() }
                        Button("Add via URL…") { showURLSheet = true }
                    } label: {
                        Label("Add Paper…", systemImage: "plus")
                    }
                    .tint(settings.libraryButtonColor())
                    Menu {
                        Button("Change Folder…") { showConnectSheet = true }
                        Button("Reveal in Finder") {
                            if let url = libraryStore.folderURL { NSWorkspace.shared.open(url) }
                        }
                        Button("Disconnect", role: .destructive) { libraryStore.disconnect() }
                    } label: {
                        Label("Folder", systemImage: "folder")
                    }
                } else {
                    Button {
                        showConnectSheet = true
                    } label: {
                        Label("Connect Folder…", systemImage: "link")
                    }
                    .tint(settings.libraryButtonColor())
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showScholarSearch.toggle() }
                } label: {
                    Label("Search Scholar", systemImage: "graduationcap")
                }
                .help("Toggle a Google Scholar search panel alongside the library")
            }
        }
        .padding(20)
        .background(settings.color(for: .libraryHeaderBackground))
    }

    private func openLibrarySettings() {
        appState.settingsTab = .library
        openSettings()
    }

    /// Group cards — one row by default (scrolling sideways once there are more than fit), or two
    /// rows if turned on in Settings → Library. `LazyHGrid` with a fixed row count grows sideways
    /// instead of down once it runs out of vertical room, so either way this scrolls horizontally
    /// rather than growing the page ever taller.
    private var groupRowSpecs: [GridItem] {
        libraryStore.groupsTwoRowLayout
            ? [GridItem(.fixed(84), spacing: 10), GridItem(.fixed(84), spacing: 10)]
            : [GridItem(.fixed(84), spacing: 10)]
    }

    private var groupsRow: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHGrid(rows: groupRowSpecs, spacing: 12) {
                GroupCardButton(title: "All Papers", systemIcon: "tray.full.fill", colorHex: nil, image: nil, tooltip: nil, isSelected: selectedGroupID == nil) {
                    selectedGroupID = nil
                }

                ForEach(libraryStore.groups) { group in
                    GroupCardButton(
                        title: group.name,
                        systemIcon: group.iconSystemName,
                        colorHex: group.iconColorHex,
                        image: group.customIconData.flatMap { NSImage(data: $0) },
                        tooltip: Self.tooltipText(for: group),
                        isSelected: selectedGroupID == group.id
                    ) {
                        selectedGroupID = group.id
                    }
                    .contextMenu {
                        Button("Rename / Change Icon…") { editingGroup = group }
                        Divider()
                        Button("Delete Group…", role: .destructive) { groupPendingDeletion = group }
                    }
                }

                Button {
                    showNewGroupSheet = true
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
                        Text("New Group").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 84, height: 84)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(height: libraryStore.groupsTwoRowLayout ? 200 : 108)
        .background(settings.color(for: .libraryGroupsBackground))
    }

    private var notConnectedState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Connect a library folder").font(.headline)
            Text("Point this at a folder inside your Google Drive for Desktop sync (e.g. under \u{201c}My Drive\u{201d}) — or create a new one right from the picker. Papers you add here get backed up automatically the same way any other file in that folder does; papers added from another device show up here the next time the page refreshes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Connect Folder…") { showConnectSheet = true }
                .buttonStyle(.borderedProminent)
                .tint(settings.libraryButtonColor())
            if let errorMessage {
                CopyableErrorView(message: errorMessage).frame(maxWidth: 440)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// A key for the circles on each paper's row — one dot + name per configured label color, and
    /// the reading-order numbers — so what a color/number means is visible without hovering a dot.
    /// Hidden entirely when nothing is configured.
    @ViewBuilder
    private var labelLegend: some View {
        if !libraryStore.paperLabels.isEmpty || !libraryStore.paperLabelNumbers.isEmpty {
            FlowLayout(spacing: 12) {
                ForEach(libraryStore.paperLabels) { option in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(option.color)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        Text(option.name).font(.caption)
                    }
                }
                if !libraryStore.paperLabelNumbers.isEmpty {
                    HStack(spacing: 4) {
                        Text("Order:").font(.caption).foregroundStyle(.secondary)
                        ForEach(libraryStore.paperLabelNumbers, id: \.self) { number in
                            Text("\(number)")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 14, height: 14)
                                .background(Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                        }
                    }
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func exportShownPapers() {
        let entries = visibleEntries
        Task {
            do {
                if let url = try await LibraryExportService.exportWithSavePanel(entries, libraryStore: libraryStore) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search title, author, tag...", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 280)
                if let selectedGroup {
                    Label(selectedGroup.name, systemImage: selectedGroup.iconSystemName)
                        .font(.caption)
                        .foregroundStyle(settings.libraryButtonColor())
                }
                if let keywordFilter {
                    HStack(spacing: 4) {
                        Label("\(keywordFilter.field.label): \(keywordFilter.value)", systemImage: keywordFilter.field.icon)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { self.keywordFilter = nil }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(settings.libraryButtonColor())
                    .background(settings.libraryButtonColor().opacity(0.12))
                    .clipShape(Capsule())
                }
                Spacer()
                Button {
                    exportShownPapers()
                } label: {
                    Label("Export \(visibleEntries.count) as ZIP", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(visibleEntries.isEmpty)
                .help("Download every paper currently shown — PDFs, notes and info — as one zip file")
                if let lastScanDate = libraryStore.lastScanDate {
                    Text("Updated \(lastScanDate, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            labelLegend
            Divider().opacity(0.3)

            if let scanError = libraryStore.scanError {
                CopyableErrorView(message: scanError)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            if let errorMessage {
                CopyableErrorView(message: errorMessage)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    if visibleEntries.isEmpty {
                        Text(emptyListMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(visibleEntries) { entry in
                        LibraryCard(
                            entry: entry,
                            isMissing: libraryStore.isFileMissing(entry),
                            onRemove: { deleteFile in libraryStore.remove(entry, deleteFile: deleteFile) }
                        )
                    }
                }
                .padding(20)
            }
        }
        .background(settings.color(for: .libraryListBackground))
    }

    private func addPapers() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        do {
            try libraryStore.addFiles(panel.urls, toGroup: selectedGroup)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add All PDFs"
        panel.message = "Every PDF found inside (including subfolders) will be added"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try libraryStore.addFolder(url, toGroup: selectedGroup)
            errorMessage = count == 0 ? "No PDFs were found in that folder." : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Assembled once per group for its hover tooltip — info, keywords, and links all in one
    /// place, so mousing over a card is enough to see them without opening the editor.
    private static func tooltipText(for group: LibraryGroup) -> String? {
        var lines: [String] = [group.name]
        if !group.info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(group.info)
        }
        if !group.keywords.isEmpty {
            lines.append("Keywords: " + group.keywords.joined(separator: ", "))
        }
        if !group.links.isEmpty {
            lines.append("Links:")
            lines.append(contentsOf: group.links)
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }
}

private struct GroupCardButton: View {
    let title: String
    let systemIcon: String
    let colorHex: String?
    let image: NSImage?
    let tooltip: String?
    let isSelected: Bool
    var action: () -> Void
    @EnvironmentObject var settings: AppSettings

    private var iconColor: Color {
        colorHex.flatMap(Color.init(hex:)) ?? settings.libraryButtonColor()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 52, height: 52)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: systemIcon)
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? settings.libraryButtonColor() : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                )
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 76)
            }
            .frame(width: 84, height: 84)
        }
        .buttonStyle(.plain)
        .help(tooltip ?? title)
    }
}

private struct GroupEditorSheet: View {
    let existingGroup: LibraryGroup?
    var onSave: (
        _ name: String, _ iconSystemName: String, _ iconColorHex: String?, _ imageData: Data?,
        _ info: String, _ keywords: [String], _ links: [String]
    ) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var selectedIcon: String
    @State private var iconColor: Color
    @State private var customImageData: Data?
    @State private var info: String
    @State private var keywordsText: String
    @State private var linksText: String

    private static let iconChoices = [
        "folder.fill", "star.fill", "bookmark.fill", "flame.fill", "leaf.fill",
        "graduationcap.fill", "brain.head.profile", "atom", "function", "chart.bar.fill",
        "lightbulb.fill", "tag.fill",
    ]

    init(existingGroup: LibraryGroup?, onSave: @escaping (String, String, String?, Data?, String, [String], [String]) -> Void, onCancel: @escaping () -> Void) {
        self.existingGroup = existingGroup
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existingGroup?.name ?? "")
        _selectedIcon = State(initialValue: existingGroup?.iconSystemName ?? "folder.fill")
        _iconColor = State(initialValue: existingGroup?.iconColorHex.flatMap(Color.init(hex:)) ?? .accentColor)
        _customImageData = State(initialValue: existingGroup?.customIconData)
        _info = State(initialValue: existingGroup?.info ?? "")
        _keywordsText = State(initialValue: existingGroup?.keywords.joined(separator: ", ") ?? "")
        _linksText = State(initialValue: existingGroup?.links.joined(separator: "\n") ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(existingGroup == nil ? "New Group" : "Edit Group").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)

                HStack {
                    Text("Icon").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker("Color", selection: $iconColor, supportsOpacity: false)
                        .labelsHidden()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.iconChoices, id: \.self) { icon in
                        Button {
                            selectedIcon = icon
                            customImageData = nil
                        } label: {
                            Image(systemName: icon)
                                .font(.system(size: 16))
                                .foregroundStyle(selectedIcon == icon && customImageData == nil ? iconColor : Color.primary)
                                .frame(width: 36, height: 36)
                                .background(selectedIcon == icon && customImageData == nil ? iconColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    if let customImageData, let nsImage = NSImage(data: customImageData) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button("Choose Image…") { pickImage() }
                    if customImageData != nil {
                        Button("Remove Image") { customImageData = nil }
                    }
                }

                Divider()

                Text("Info (shown on hover)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $info)
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                Text("Keywords (comma-separated)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. transformers, attention, nlp", text: $keywordsText)
                    .textFieldStyle(.roundedBorder)

                Text("Links (one per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $linksText)
                    .frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button(existingGroup == nil ? "Create" : "Save") {
                        let keywords = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let links = linksText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onSave(
                            name.trimmingCharacters(in: .whitespacesAndNewlines), selectedIcon, iconColor.toHex(), customImageData,
                            info.trimmingCharacters(in: .whitespacesAndNewlines), keywords, links
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 380, height: 560)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        customImageData = Self.thumbnailPNGData(from: image)
    }

    private static func thumbnailPNGData(from image: NSImage, maxDimension: CGFloat = 160) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct AddByURLSheet: View {
    let group: LibraryGroup?
    var onFinished: () -> Void
    var onCancel: () -> Void

    @EnvironmentObject var libraryStore: LibraryStore
    @State private var urlString = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Paper from URL").font(.headline)
            Text("Paste a direct link to a PDF — arXiv, a publisher, or any paper-hosting site. It's downloaded and added the same way a locally-picked file would be.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://example.com/paper.pdf", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .disabled(isDownloading)
                .onSubmit(download)

            if let errorMessage {
                CopyableErrorView(message: errorMessage)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).disabled(isDownloading)
                Button {
                    download()
                } label: {
                    if isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Download & Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func download() {
        guard !isDownloading else { return }
        errorMessage = nil
        isDownloading = true
        Task {
            do {
                try await libraryStore.downloadAndAddPaper(from: urlString, toGroup: group)
                isDownloading = false
                onFinished()
            } catch {
                errorMessage = error.localizedDescription
                isDownloading = false
            }
        }
    }
}

private struct ConnectFolderSheet: View {
    var onPick: (URL) -> Void
    var onCancel: () -> Void
    @State private var driveRoots: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a Library Folder").font(.headline)
            Text("Pick a folder inside your Google Drive for Desktop sync — Maziar just watches whatever folder you choose, so anything Google's app syncs down (or up) shows up here automatically. You can also create a new folder right from the picker.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !driveRoots.isEmpty {
                Text("Detected Google Drive account(s):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(driveRoots, id: \.self) { root in
                    Button {
                        openPicker(startingAt: root)
                    } label: {
                        Label(root.lastPathComponent.replacingOccurrences(of: "GoogleDrive-", with: ""), systemImage: "externaldrive.badge.icloud")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("No Google Drive for Desktop account detected — install it first, or pick any folder you sync another way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Choose Folder…") { openPicker(startingAt: nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { driveRoots = LibraryStore.suggestedDriveRoots() }
    }

    private func openPicker(startingAt url: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        panel.message = "Choose or create a folder for your paper library"
        if let url { panel.directoryURL = url }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        onPick(picked)
    }
}

private struct LibraryCard: View {
    let entry: LibraryEntry
    let isMissing: Bool
    var onRemove: (_ deleteFile: Bool) -> Void

    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showGroupEditor = false
    @State private var showRemoveConfirm = false

    private var memberGroups: [LibraryGroup] {
        libraryStore.groups.filter { entry.groupFileNames[$0.id] != nil }
    }

    private var currentLabelColor: PaperLabelOption? { libraryStore.labelColor(for: entry) }

    /// The small colored "light" next to the paper's title — filled with the paper's current label
    /// color (just a faint outline when uncolored), with its reading-order number (if any) printed
    /// right inside the dot so a numbered paper ("1" for read-first, "2" for read-next) is
    /// recognizable at a glance without hovering. Right-click it to assign — color and number are
    /// independent choices in two separate submenus, not one bundled label, so a paper can have
    /// either, both, or neither.
    private var labelPicker: some View {
        Circle()
            .fill(currentLabelColor?.color ?? Color.clear)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(currentLabelColor != nil ? Color.primary.opacity(0.25) : Color.secondary.opacity(0.4), lineWidth: 1))
            .overlay { labelNumberText }
            .contentShape(Circle())
            .contextMenu {
                Menu("Color") {
                    Button {
                        libraryStore.setLabelColor(nil, for: entry)
                    } label: {
                        if entry.labelColorID == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    if !libraryStore.paperLabels.isEmpty {
                        Divider()
                        ForEach(libraryStore.paperLabels) { option in
                            Button {
                                libraryStore.setLabelColor(option.id, for: entry)
                            } label: {
                                if entry.labelColorID == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                            }
                        }
                    }
                }
                Menu("Number") {
                    Button {
                        libraryStore.setLabelNumber(nil, for: entry)
                    } label: {
                        if entry.labelNumber == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
                    }
                    if !libraryStore.paperLabelNumbers.isEmpty {
                        Divider()
                        ForEach(libraryStore.paperLabelNumbers, id: \.self) { number in
                            Button {
                                libraryStore.setLabelNumber(number, for: entry)
                            } label: {
                                if entry.labelNumber == number { Label("\(number)", systemImage: "checkmark") } else { Text("\(number)") }
                            }
                        }
                    }
                }
            }
            .help(labelPickerHelpText)
    }

    @ViewBuilder
    private var labelNumberText: some View {
        if let number = entry.labelNumber {
            Text("\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(currentLabelColor != nil ? .white : Color.primary)
        }
    }

    private var labelPickerHelpText: String {
        let colorPart = currentLabelColor?.name
        let numberPart = entry.labelNumber.map { "#\($0)" }
        let parts = [colorPart, numberPart].compactMap { $0 }
        return parts.isEmpty ? "No label \u{2014} right-click to assign a color or number" : parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("File not found in the connected folder")
                        }
                        Text(entry.title).font(.headline)
                        labelPicker
                    }
                    let subtitle = [entry.authors, entry.venue, entry.year].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{2022} ")
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if !entry.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    if !memberGroups.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(memberGroups) { group in
                                Label(group.name, systemImage: group.iconSystemName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(group.iconColorHex.flatMap(Color.init(hex:)) ?? .secondary)
                                    .background((group.iconColorHex.flatMap(Color.init(hex:)) ?? .secondary).opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        openWindow(id: "paper-reader", value: entry.id)
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .disabled(isMissing)
                    .help("Open in Reader \u{2014} PDF with highlighting, translator/chat/notes")
                    Button {
                        openWindow(id: "paper-info", value: entry.id)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .help("Info: metadata, abstract, notes")
                    Button {
                        copyBibTeX()
                    } label: {
                        Image(systemName: "text.quote")
                    }
                    .help("Copy BibTeX citation")
                    Button {
                        exportZip()
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Download this paper as a ZIP \u{2014} PDF, notes and info")
                    Button {
                        showGroupEditor.toggle()
                    } label: {
                        Image(systemName: showGroupEditor ? "chevron.up" : "chevron.down")
                    }
                    .help("Change which groups this paper is in")
                }
                .buttonStyle(.borderless)
            }

            if showGroupEditor {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Groups").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        groupToggleChip(
                            label: "Library root", systemIcon: "tray.full.fill", color: .secondary,
                            isOn: entry.rootFileName != nil
                        ) { setGroupMembership(root: $0) }
                        ForEach(libraryStore.groups) { group in
                            groupToggleChip(
                                label: group.name, systemIcon: group.iconSystemName,
                                color: group.iconColorHex.flatMap(Color.init(hex:)) ?? .accentColor,
                                isOn: entry.groupFileNames[group.id] != nil
                            ) { setGroupMembership(group: group, isOn: $0) }
                        }
                    }
                    if libraryStore.groups.isEmpty {
                        Text("No groups yet — create one above.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Remove from Library…", role: .destructive) { showRemoveConfirm = true }
                    }
                }
                .padding(.top, 4)
            }
        }
        .confirmationDialog(
            "Remove \u{201c}\(entry.title)\u{201d} from the library?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove & Move File to Trash", role: .destructive) { onRemove(true) }
            Button("Remove (keep file)") { onRemove(false) }
            Button("Cancel", role: .cancel) {}
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(settings.color(for: .libraryCardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private func groupToggleChip(label: String, systemIcon: String, color: Color, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        Button {
            onToggle(!isOn)
        } label: {
            Label(label, systemImage: isOn ? "checkmark.circle.fill" : systemIcon)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isOn ? .white : color)
                .background(isOn ? color : color.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func exportZip() {
        Task {
            do {
                if let url = try await LibraryExportService.exportWithSavePanel([entry], libraryStore: libraryStore) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func copyBibTeX() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BibTeXGenerator.entry(for: entry), forType: .string)
    }

    private func setGroupMembership(root: Bool) {
        libraryStore.setGroups(for: entry, groupIDs: Set(entry.groupFileNames.keys), alsoRoot: root)
    }

    private func setGroupMembership(group: LibraryGroup, isOn: Bool) {
        var groupIDs = Set(entry.groupFileNames.keys)
        if isOn { groupIDs.insert(group.id) } else { groupIDs.remove(group.id) }
        libraryStore.setGroups(for: entry, groupIDs: groupIDs, alsoRoot: entry.rootFileName != nil)
    }
}

/// A simple wrapping row (unlike an `HStack`, items that don't fit continue on the next line) —
/// used for the per-paper group-membership chips, which have no fixed count. Built on the
/// `Layout` protocol (macOS 13+) rather than a third-party dependency.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        y += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + bounds.width, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
