import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct JournalsView: View {
    @EnvironmentObject var journalStore: JournalStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var updatingIDs: Set<UUID> = []

    private func openJournalSettings() {
        appState.settingsTab = .journals
        openSettings()
    }
    @AppStorage("maziar.journals.sortMode") private var sortModeRaw = JournalSortMode.manual.rawValue
    @State private var isExportingPDF = false
    @State private var exportError: String?
    @State private var importSuccessMessage: String?
    @State private var showAIChat = false
    @State private var searchText = ""

    private var sortMode: JournalSortMode { JournalSortMode(rawValue: sortModeRaw) ?? .manual }

    private var sortedJournals: [JournalEntry] {
        switch sortMode {
        case .manual:
            return journalStore.journals
        case .rank:
            return journalStore.journals.sorted { $0.rankSortPriority < $1.rankSortPriority }
        case .reviewSpeed:
            return journalStore.journals.sorted { $0.reviewSpeedSortWeeks < $1.reviewSpeedSortWeeks }
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
    private var visibleJournals: [JournalEntry] {
        let sorted = sortedJournals
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
                JournalChatPanelView(
                    journals: journalStore.journals,
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
            if journalStore.journals.isEmpty {
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
                    Text("Journals").font(.title2.bold())
                    Text("Submission info fetched with \(aiSettings.effectiveJournalProvider.displayName)\(JournalInfoService.supportsLiveWebSearch(aiSettings.effectiveJournalProvider) ? " (live web search)" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !journalStore.journals.isEmpty {
                Picker("Sort", selection: $sortModeRaw) {
                    ForEach(JournalSortMode.allCases) { mode in
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
                .disabled(!updatingIDs.isEmpty || !aiSettings.isConfigured(aiSettings.effectiveJournalProvider))
            }
            Menu {
                Button("Export as JSON...") { exportJSON() }
                    .disabled(journalStore.journals.isEmpty)
                Button {
                    exportPDF()
                } label: {
                    if isExportingPDF {
                        Text("Rendering PDF...")
                    } else {
                        Text("Export as PDF...")
                    }
                }
                .disabled(isExportingPDF || journalStore.journals.isEmpty)
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
                openJournalSettings()
            } label: {
                Label("Setting", systemImage: "gearshape")
            }
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No journals tracked yet").font(.headline)
            Text("Add journal names in Settings \u{2192} Journals, then come back here to fetch their submission info. Reinstalled the app? Import a previously exported JSON file instead of starting over.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Open Settings") { openJournalSettings() }
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
                if !journalStore.journals.isEmpty {
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
                        if !aiSettings.isConfigured(aiSettings.effectiveJournalProvider) {
                            Label(
                                "No API key set for \(aiSettings.effectiveJournalProvider.displayName) — add one in Settings \u{2192} AI before updating.",
                                systemImage: "key.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                        }
                        if visibleJournals.isEmpty {
                            Text("No journals match \u{201c}\(searchText)\u{201d}.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 20)
                        }
                        ForEach(Array(visibleJournals.enumerated()), id: \.element.id) { index, entry in
                            JournalCard(
                                entry: entry,
                                isUpdating: updatingIDs.contains(entry.id),
                                onUpdate: { updateOne(entry) },
                                canMoveUp: canReorder && index > 0,
                                canMoveDown: canReorder && index < visibleJournals.count - 1,
                                onMoveUp: { journalStore.moveUp(entry) },
                                onMoveDown: { journalStore.moveDown(entry) },
                                showReorderButtons: canReorder
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
                ForEach(sortedJournals) { entry in
                    Button(entry.name) {
                        withAnimation { proxy.scrollTo(entry.id, anchor: .top) }
                    }
                }
            } label: {
                Label("Jump to Journal", systemImage: "arrow.up.arrow.down.circle")
            }
            .fixedSize()
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search journals...", text: $searchText)
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
            let data = try JournalExportService.exportJSON(journalStore.journals)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "journals.json"
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
        let journals = journalStore.journals
        Task {
            do {
                let data = try await JournalExportService.exportPDF(journals)
                isExportingPDF = false
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.pdf]
                panel.nameFieldStringValue = "journals.pdf"
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
    /// re-looking-up every journal by hand. Matches existing entries by name so re-importing the
    /// same file is safe to run more than once.
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
            let imported = try JournalExportService.importJSON(data)
            let count = journalStore.importEntries(imported)
            importSuccessMessage = "Imported \(count) journal\(count == 1 ? "" : "s")."
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func updateOne(_ entry: JournalEntry) {
        updatingIDs.insert(entry.id)
        Task {
            let updated = await JournalInfoService.update(entry, settings: aiSettings, helperWebsites: journalStore.helperWebsites)
            journalStore.update(updated)
            updatingIDs.remove(entry.id)
        }
    }

    private func updateAll() {
        for entry in journalStore.journals {
            updateOne(entry)
        }
    }
}

private struct JournalCard: View {
    let entry: JournalEntry
    let isUpdating: Bool
    let onUpdate: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let showReorderButtons: Bool
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var appState: AppState
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
                    Text(entry.name).font(.headline)
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
                        JournalRankBadgeCard(rank: rank)
                    }
                }
            }

            if let error = entry.lastUpdateError {
                CopyableErrorView(message: error)
            }

            turnaroundSection

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
            "Download this journal's LaTeX template and create a new project from it?",
            isPresented: $showTemplateConfirm,
            titleVisibility: .visible
        ) {
            Button("Download & Create Project") { importTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(entry.templateURLString ?? "")
        }
    }

    /// Journals are rolling-submission, not fixed-deadline like conferences — this is what
    /// actually varies journal-to-journal and matters for picking a venue, so it takes the
    /// visual slot the "next deadline" row occupies on the Conferences page.
    private var turnaroundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.reviewTime == nil && entry.publicationTime == nil {
                Text("No review/publication time info yet — click Update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let reviewTime = entry.reviewTime {
                    turnaroundRow(icon: "hourglass", label: "Review", value: reviewTime)
                }
                if let publicationTime = entry.publicationTime {
                    turnaroundRow(icon: "printer", label: "Publication", value: publicationTime)
                }
            }
        }
    }

    private func turnaroundRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(settings.color(for: .buttonColor))
            Text("\(label):")
                .font(.subheadline.bold())
            Text(value)
                .font(.subheadline)
                .foregroundStyle(settings.color(for: .buttonColor))
        }
    }

    private func importTemplate() {
        guard let templateURLString = entry.templateURLString else { return }
        templateImportError = nil
        Task {
            do {
                let project = try await Self.createProjectFromTemplate(
                    urlString: templateURLString, journalName: entry.name, store: store
                )
                appState.open(project)
            } catch {
                templateImportError = error.localizedDescription
            }
        }
    }

    private static func createProjectFromTemplate(
        urlString: String, journalName: String, store: ProjectStore
    ) async throws -> Project {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Maziar", code: 62, userInfo: [NSLocalizedDescriptionKey: "Invalid template URL."])
        }
        if url.pathExtension.lowercased() == "zip" {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(journalName)-template.zip")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            return try store.importZip(from: destination, into: store.defaultProjectsDirectory())
        }
        return try store.cloneGitRepo(urlString: urlString, into: store.defaultProjectsDirectory())
    }
}

/// Small, distinct card under a journal's Update button, so its rank/impact metric reads as a
/// badge rather than blending in with the rest of the card's text.
private struct JournalRankBadgeCard: View {
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
