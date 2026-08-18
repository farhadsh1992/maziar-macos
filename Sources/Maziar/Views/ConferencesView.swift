import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConferencesView: View {
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    private func openConferenceSettings() {
        appState.settingsTab = .conferences
        openSettings()
    }
    @State private var updatingIDs: Set<UUID> = []
    @AppStorage("maziar.conferences.sortMode") private var sortModeRaw = ConferenceSortMode.manual.rawValue
    @State private var isExportingPDF = false
    @State private var exportError: String?
    @State private var importSuccessMessage: String?
    @State private var showAIChat = false
    @State private var searchText = ""

    private var sortMode: ConferenceSortMode { ConferenceSortMode(rawValue: sortModeRaw) ?? .manual }

    /// A conference has an "active submission" light when some tracked paper targets it, has a
    /// LaTeX project actually attached, and hasn't been decided yet — accepting or rejecting
    /// turns the light off, since there's nothing left in flight at that point.
    private func hasActiveSubmission(_ entry: ConferenceEntry) -> Bool {
        paperStore.papers.contains {
            $0.projectPath != nil
                && $0.decision == .pending
                && $0.conferenceName?.caseInsensitiveCompare(entry.name) == .orderedSame
        }
    }

    private var sortedConferences: [ConferenceEntry] {
        switch sortMode {
        case .manual:
            return conferenceStore.conferences
        case .deadline:
            return conferenceStore.conferences.sorted {
                ($0.nextDeadline?.date ?? .distantFuture) < ($1.nextDeadline?.date ?? .distantFuture)
            }
        case .rank:
            return conferenceStore.conferences.sorted { $0.rankSortPriority < $1.rankSortPriority }
        }
    }

    /// Reorder buttons only make sense when what's on screen is actually the persisted manual
    /// order — with a sort mode active, or a search filter hiding some cards, the visually
    /// "next" card isn't necessarily adjacent in the underlying array `moveUp`/`moveDown` swap.
    private var canReorder: Bool {
        sortMode == .manual && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sorted, then filtered by the search box — search never changes the underlying order, only
    /// which of it is shown.
    private var visibleConferences: [ConferenceEntry] {
        let sorted = sortedConferences
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || ($0.fullName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            content
            if showAIChat {
                Divider()
                ConferenceChatPanelView(
                    conferences: conferenceStore.conferences,
                    onTriggerUpdate: { entry in updateOne(entry) }
                )
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .background(settings.color(for: .windowBackground))
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if conferenceStore.conferences.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                BrandMark(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conferences").font(.title2.bold())
                    Text("Deadlines fetched with \(aiSettings.effectiveConferenceProvider.displayName)\(ConferenceInfoService.supportsLiveWebSearch(aiSettings.effectiveConferenceProvider) ? " (live web search)" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !conferenceStore.conferences.isEmpty {
                Picker("Sort", selection: $sortModeRaw) {
                    ForEach(ConferenceSortMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button {
                    updateAll()
                } label: {
                    Label("Update All", systemImage: "arrow.clockwise")
                }
                .disabled(!updatingIDs.isEmpty || !aiSettings.isConfigured(aiSettings.effectiveConferenceProvider))
            }
            Menu {
                Button("Export as JSON...") { exportJSON() }
                    .disabled(conferenceStore.conferences.isEmpty)
                Button {
                    exportPDF()
                } label: {
                    if isExportingPDF {
                        Text("Rendering PDF...")
                    } else {
                        Text("Export as PDF...")
                    }
                }
                .disabled(isExportingPDF || conferenceStore.conferences.isEmpty)
                Divider()
                Button("Import JSON...") { importJSON() }
            } label: {
                Label("Export / Import", systemImage: "arrow.up.arrow.down.square")
            }
            Button {
                showAIChat.toggle()
            } label: {
                Label("AI Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .tint(showAIChat ? settings.color(for: .buttonColor) : nil)
            Button {
                openConferenceSettings()
            } label: {
                Label("Setting", systemImage: "gearshape")
            }
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No conferences tracked yet").font(.headline)
            Text("Add conference names in Settings \u{2192} Conferences, then come back here to fetch their deadlines. Reinstalled the app? Import a previously exported JSON file instead of starting over.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Open Settings") { openConferenceSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.color(for: .buttonColor))
                Button("Import JSON...") { importJSON() }
                    .buttonStyle(.bordered)
            }
            if let exportError {
                CopyableErrorView(message: exportError)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !conferenceStore.conferences.isEmpty {
                    jumpMenu(proxy: proxy)
                    Divider().opacity(0.3)
                }
                if let exportError {
                    CopyableErrorView(message: exportError)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                if let importSuccessMessage {
                    Label(importSuccessMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !aiSettings.isConfigured(aiSettings.effectiveConferenceProvider) {
                            Label(
                                "No API key set for \(aiSettings.effectiveConferenceProvider.displayName) — add one in Settings \u{2192} AI before updating.",
                                systemImage: "key.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                        }
                        if visibleConferences.isEmpty {
                            Text("No conferences match \u{201c}\(searchText)\u{201d}.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(Array(visibleConferences.enumerated()), id: \.element.id) { index, entry in
                            ConferenceCard(
                                entry: entry,
                                isUpdating: updatingIDs.contains(entry.id),
                                onUpdate: { updateOne(entry) },
                                canMoveUp: canReorder && index > 0,
                                canMoveDown: canReorder && index < visibleConferences.count - 1,
                                onMoveUp: { conferenceStore.moveUp(entry) },
                                onMoveDown: { conferenceStore.moveDown(entry) },
                                showReorderButtons: canReorder,
                                hasActiveSubmission: hasActiveSubmission(entry)
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func jumpMenu(proxy: ScrollViewProxy) -> some View {
        HStack {
            Menu {
                ForEach(sortedConferences) { entry in
                    Button(entry.name) {
                        withAnimation { proxy.scrollTo(entry.id, anchor: .top) }
                    }
                }
            } label: {
                Label("Jump to Conference", systemImage: "arrow.up.arrow.down.circle")
            }
            .fixedSize()
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search conferences...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 220)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func exportJSON() {
        exportError = nil
        do {
            let data = try ConferenceExportService.exportJSON(conferenceStore.conferences)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "conferences.json"
            panel.prompt = "Save"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportPDF() {
        exportError = nil
        isExportingPDF = true
        let conferences = conferenceStore.conferences
        Task {
            do {
                let data = try await ConferenceExportService.exportPDF(conferences)
                isExportingPDF = false
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = "conferences.pdf"
                panel.prompt = "Save"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
            } catch {
                isExportingPDF = false
                exportError = error.localizedDescription
            }
        }
    }

    /// Restores a tracked list from a JSON file exported via "Export as JSON..." (here or on
    /// another Mac) — the main use case is a fresh install: import instead of re-adding and
    /// re-looking-up every conference by hand. Matches existing entries by name so re-importing
    /// the same file is safe to run more than once.
    private func importJSON() {
        exportError = nil
        importSuccessMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try ConferenceExportService.importJSON(data)
            let count = conferenceStore.importEntries(imported)
            importSuccessMessage = "Imported \(count) conference\(count == 1 ? "" : "s")."
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func updateOne(_ entry: ConferenceEntry) {
        updatingIDs.insert(entry.id)
        Task {
            let updated = await ConferenceInfoService.update(entry, settings: aiSettings, helperWebsites: conferenceStore.helperWebsites)
            conferenceStore.update(updated)
            updatingIDs.remove(entry.id)
        }
    }

    private func updateAll() {
        for entry in conferenceStore.conferences {
            updateOne(entry)
        }
    }
}

private struct ConferenceCard: View {
    let entry: ConferenceEntry
    let isUpdating: Bool
    let onUpdate: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let showReorderButtons: Bool
    /// True when a tracked paper targets this conference, has a LaTeX project attached (actually
    /// being worked on, not just planned), and hasn't been accepted/rejected yet.
    let hasActiveSubmission: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appState: AppState
    @State private var showPastDeadlines = false
    @State private var showTemplateConfirm = false
    @State private var templateImportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                if showReorderButtons {
                    VStack(spacing: 2) {
                        Button(action: onMoveUp) {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMoveUp)
                        Button(action: onMoveDown) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMoveDown)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if hasActiveSubmission {
                            BlinkingDot(color: .green, size: 8)
                        }
                        Text(entry.name).font(.headline)
                    }
                    if let fullName = entry.fullName, !fullName.isEmpty {
                        Text(fullName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let lastUpdated = entry.lastUpdated {
                        Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never updated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(spacing: 6) {
                    Button(action: onUpdate) {
                        if isUpdating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Update", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isUpdating)
                    if let rank = entry.rank, !rank.isEmpty {
                        RankBadgeCard(rank: rank)
                    }
                }
            }

            if let error = entry.lastUpdateError {
                CopyableErrorView(message: error)
            }

            deadlinesSection

            if entry.pageLimit != nil || entry.columnFormat != nil {
                HStack(spacing: 12) {
                    if let pageLimit = entry.pageLimit {
                        Label(pageLimit, systemImage: "doc.plaintext")
                    }
                    if let columnFormat = entry.columnFormat {
                        Label(columnFormat, systemImage: "rectangle.split.2x1")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if entry.authorGuideURL != nil || entry.templateURL != nil || entry.nextConferenceWebsiteURL != nil {
                HStack(spacing: 10) {
                    if let url = entry.nextConferenceWebsiteURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open Website", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let url = entry.authorGuideURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Author Guide", systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if entry.templateURL != nil {
                        Button {
                            showTemplateConfirm = true
                        } label: {
                            Label("Use LaTeX Template", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let notes = entry.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let templateImportError {
                CopyableErrorView(message: templateImportError)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .confirmationDialog(
            "Download this conference's LaTeX template and create a new project from it?",
            isPresented: $showTemplateConfirm,
            titleVisibility: .visible
        ) {
            Button("Download & Create Project") { importTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.templateURLString ?? "")
        }
    }

    private var deadlinesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let next = entry.nextDeadline {
                deadlineRow(next, style: .next)
            } else if entry.deadlines.isEmpty {
                Text("No deadline info yet — click Update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No upcoming dated deadline found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(entry.upcomingDeadlines.dropFirst()) { deadline in
                deadlineRow(deadline, style: .upcoming)
            }

            ForEach(entry.undatedDeadlines) { deadline in
                deadlineRow(deadline, style: .undated)
            }

            if !entry.pastDeadlines.isEmpty {
                DisclosureGroup("Past deadlines (\(entry.pastDeadlines.count))", isExpanded: $showPastDeadlines) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entry.pastDeadlines) { deadline in
                            deadlineRow(deadline, style: .past)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    private enum DeadlineStyle { case next, upcoming, undated, past }

    private func deadlineRow(_ deadline: ConferenceDeadlineInfo, style: DeadlineStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: style == .next ? "flag.fill" : "circle.fill")
                .font(.system(size: style == .next ? 11 : 5))
                .foregroundStyle(color(for: style))
            Text(deadline.label)
                .font(style == .next ? .subheadline.bold() : .caption)
                .foregroundStyle(style == .past ? .secondary : .primary)
            Text(displayDate(deadline))
                .font(style == .next ? .subheadline : .caption)
                .foregroundStyle(color(for: style))
        }
    }

    private func color(for style: DeadlineStyle) -> Color {
        switch style {
        case .next: return settings.color(for: .buttonColor)
        case .upcoming: return .primary
        case .undated: return .secondary
        case .past: return .secondary
        }
    }

    private func displayDate(_ deadline: ConferenceDeadlineInfo) -> String {
        if let date = deadline.date {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return deadline.rawText ?? "date TBA"
    }

    private func importTemplate() {
        guard let templateURLString = entry.templateURLString else { return }
        templateImportError = nil
        Task {
            do {
                let project = try await Self.createProjectFromTemplate(
                    urlString: templateURLString, conferenceName: entry.name, store: store
                )
                appState.open(project)
            } catch {
                templateImportError = error.localizedDescription
            }
        }
    }

    private static func createProjectFromTemplate(
        urlString: String, conferenceName: String, store: ProjectStore
    ) async throws -> Project {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Maziar", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid template URL."])
        }
        if url.pathExtension.lowercased() == "zip" {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(conferenceName)-template.zip")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            return try store.importZip(from: destination, into: store.defaultProjectsDirectory())
        }
        return try store.cloneGitRepo(urlString: urlString, into: store.defaultProjectsDirectory())
    }
}

/// An error message that's selectable (drag to select part of it) and has a one-click "copy all"
/// button — the raw API/parse error text is often the only clue for diagnosing a bad update.
/// Small, distinct card under a conference's Update button, so its rank reads as a badge rather
/// than blending in with the rest of the card's text.
private struct RankBadgeCard: View {
    let rank: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "rosette")
                .font(.system(size: 12))
            Text(rank)
                .font(.caption2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 60)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

struct CopyableErrorView: View {
    let message: String
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Label {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy full error")
        }
    }
}
