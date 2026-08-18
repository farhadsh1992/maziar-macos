import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.settingsTab) {
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            LaTeXCompilerSettingsTab()
                .tabItem { Label("LaTeX Compiler", systemImage: "hammer") }
                .tag(SettingsTab.latex)
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            ConferencesSettingsTab()
                .tabItem { Label("Conferences", systemImage: "calendar.badge.clock") }
                .tag(SettingsTab.conferences)
            JournalsSettingsTab()
                .tabItem { Label("Journals", systemImage: "book.closed") }
                .tag(SettingsTab.journals)
            BackupSettingsTab()
                .tabItem { Label("Backup", systemImage: "square.and.arrow.up.on.square") }
                .tag(SettingsTab.backup)
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 900, minHeight: 480, idealHeight: 560, maxHeight: 900)
        .textSelection(.enabled)
    }
}

private struct AppearanceSettingsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                ForEach(ThemeRegion.allCases) { region in
                    HStack {
                        ColorPicker(
                            region.displayName,
                            selection: Binding(
                                get: { settings.color(for: region) },
                                set: { settings.setColor($0, for: region) }
                            ),
                            supportsOpacity: false
                        )
                        if settings.customColors[region] != nil {
                            Button {
                                settings.resetColor(for: region)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Reset to default")
                        }
                    }
                }
                Button("Reset All Colors to Default") { settings.resetAllColors() }
                    .disabled(settings.customColors.isEmpty)
            } header: {
                Text("Custom Colors")
            } footer: {
                Text("Overrides the background of each part of the app independently. Leave unset to follow the Appearance mode automatically.")
                    .font(.caption)
            }

            Section {
                ForEach(SyntaxColorRole.allCases) { role in
                    HStack {
                        ColorPicker(
                            role.displayName,
                            selection: Binding(
                                get: { settings.syntaxColor(for: role) },
                                set: { settings.setSyntaxColor($0, for: role) }
                            ),
                            supportsOpacity: false
                        )
                        if settings.syntaxColors[role] != nil {
                            Button {
                                settings.resetSyntaxColor(for: role)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Reset to default")
                        }
                    }
                }
                Button("Reset All Text Colors to Default") { settings.resetAllSyntaxColors() }
                    .disabled(settings.syntaxColors.isEmpty)
            } header: {
                Text("Editor Text Colors")
            } footer: {
                Text("Colors used for syntax highlighting in the code editor.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LaTeXCompilerSettingsTab: View {
    @EnvironmentObject var texManager: TeXInstallationManager
    @State private var refreshTick = 0

    var body: some View {
        Form {
            Section {
                Picker("TeX Distribution", selection: $texManager.selectedDistribution) {
                    ForEach(TeXDistribution.allCases) { distro in
                        Text(distro.displayName).tag(distro)
                    }
                }
                .pickerStyle(.segmented)

                Text(texManager.selectedDistribution.sizeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusRow
            } header: {
                Text("LaTeX Compiler")
            } footer: {
                Text("Maziar compiles with pdflatex/latexmk from a local TeX distribution. Pick one above; if it isn't installed yet, Maziar can install it for you. Missing packages are detected and installed automatically during compilation.")
                    .font(.caption)
            }

            // Each compiler preference is just a @Published property on TeXInstallationManager
            // plus a row here — add another the same way (e.g. a "Clean aux files" action, a
            // "PDF viewer sync" toggle) rather than growing this section ad hoc.
            Section {
                Picker("Engine", selection: $texManager.engine) {
                    ForEach(LaTeXEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }

                Toggle("Auto-compile on save", isOn: $texManager.autoCompileOnSave)

                TextField("Extra latexmk flags", text: $texManager.extraCompilerFlags, prompt: Text("e.g. -shell-escape"))
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Compile Options")
            } footer: {
                Text("Engine switches between pdfLaTeX, XeLaTeX, and LuaLaTeX. Auto-compile recompiles ~1.5s after you stop typing. Extra flags are appended to every latexmk invocation.")
                    .font(.caption)
            }

            if texManager.isInstalling {
                Section("Install Progress") {
                    ScrollView {
                        Text(texManager.installLog.isEmpty ? "Starting installer..." : texManager.installLog)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 180)
                }
            }

            if let error = texManager.installError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .id(refreshTick)
    }

    private var statusRow: some View {
        let installed = texManager.isInstalled(texManager.selectedDistribution)
        return HStack {
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let path = texManager.pdflatexURL() {
                    Text(path.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Label("Not installed", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { refreshTick += 1 }
                .controlSize(.small)
            if !installed {
                Button {
                    texManager.install(texManager.selectedDistribution)
                } label: {
                    if texManager.isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install \(texManager.selectedDistribution.displayName)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(texManager.isInstalling)
            }
        }
    }
}

private struct AISettingsTab: View {
    @EnvironmentObject var aiSettings: AISettings

    var body: some View {
        Form {
            Section {
                Picker("Active Provider", selection: $aiSettings.activeProvider) {
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Text("AI Assistant")
            } footer: {
                Text("Used by the AI Assistant panel in the project editor to explain errors, answer LaTeX questions, and propose edits you can apply.")
                    .font(.caption)
            }

            ForEach(AIProviderKind.allCases) { provider in
                ProviderSection(provider: provider)
            }

            PromptTasksSection()
        }
        .formStyle(.grouped)
    }
}

private struct PromptTasksSection: View {
    @EnvironmentObject var aiSettings: AISettings

    var body: some View {
        Section {
            ForEach(aiSettings.promptTasks) { task in
                PromptTaskRow(task: binding(for: task), onDelete: { aiSettings.removePromptTask(task) })
            }
            Button {
                aiSettings.addPromptTask(label: "newtask", prompt: "", includesPDFPages: false)
            } label: {
                Label("Add Prompt Task", systemImage: "plus")
            }
        } header: {
            Text("Prompt Tasks")
        } footer: {
            Text("In the AI Assistant, type \"#label\" to expand to the saved prompt below — anything typed after the label is appended as extra instructions. \"Include PDF pages\" attaches the compiled PDF as images, for tasks that need to visually inspect the output rather than just the LaTeX source.")
                .font(.caption)
        }
    }

    private func binding(for task: PromptTask) -> Binding<PromptTask> {
        Binding(
            get: { aiSettings.promptTasks.first(where: { $0.id == task.id }) ?? task },
            set: { aiSettings.updatePromptTask($0) }
        )
    }
}

private struct PromptTaskRow: View {
    @Binding var task: PromptTask
    var onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Label", text: $task.label)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $task.prompt)
                    .frame(minHeight: 70)
                    .font(.system(size: 12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Toggle("Include PDF pages (vision)", isOn: $task.includesPDFPages)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Task", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        } label: {
            Text("#\(task.label.isEmpty ? "untitled" : task.label)")
        }
    }
}

private struct ProviderSection: View {
    @EnvironmentObject var aiSettings: AISettings
    @ObservedObject private var tokenUsage = TokenUsageStore.shared
    let provider: AIProviderKind

    @State private var apiKeyText: String = ""
    @State private var modelText: String = ""
    @State private var baseURLText: String = ""
    @State private var inputPriceText: String = ""
    @State private var outputPriceText: String = ""
    @State private var showAdvanced = false
    @State private var showUsage = false

    private var totals: ProviderTokenTotals { tokenUsage.totals[provider] ?? ProviderTokenTotals() }
    private var estimatedCost: Double { tokenUsage.estimatedCost(for: provider, settings: aiSettings) }

    var body: some View {
        Section {
            SecureField("API Key", text: $apiKeyText, prompt: Text("sk-..."))
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKeyText) { _, newValue in
                    aiSettings.setAPIKey(newValue, for: provider)
                }

            TextField("Model", text: $modelText, prompt: Text(provider.suggestedModel))
                .textFieldStyle(.roundedBorder)
                .onChange(of: modelText) { _, newValue in
                    aiSettings.setModel(newValue, for: provider)
                }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("Base URL", text: $baseURLText, prompt: Text(provider.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: baseURLText) { _, newValue in
                        aiSettings.setBaseURL(newValue, for: provider)
                    }
            }

            DisclosureGroup("Usage & Cost", isExpanded: $showUsage) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tokens used").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(totals.promptTokens) in / \(totals.completionTokens) out")
                            .font(.caption)
                    }
                    HStack {
                        Text("Estimated cost").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(estimatedCost, format: .currency(code: "USD"))
                            .font(.caption.bold())
                    }
                    HStack {
                        Text("Input $ / 1M tokens").font(.caption)
                        Spacer()
                        TextField("", text: $inputPriceText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: inputPriceText) { _, newValue in
                                if let value = Double(newValue) { aiSettings.setInputPrice(value, for: provider) }
                            }
                    }
                    HStack {
                        Text("Output $ / 1M tokens").font(.caption)
                        Spacer()
                        TextField("", text: $outputPriceText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: outputPriceText) { _, newValue in
                                if let value = Double(newValue) { aiSettings.setOutputPrice(value, for: provider) }
                            }
                    }
                    Button("Reset Usage", role: .destructive) {
                        tokenUsage.reset(provider)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("Rough estimate, not fetched live — edit the rates above to match your actual plan; provider pricing changes over time.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        } header: {
            HStack {
                Text(provider.displayName)
                if aiSettings.isConfigured(provider) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
            }
        }
        .onAppear {
            apiKeyText = aiSettings.apiKey(for: provider) ?? ""
            modelText = aiSettings.models[provider] ?? ""
            baseURLText = aiSettings.baseURLs[provider] ?? ""
            inputPriceText = String(format: "%.2f", aiSettings.inputPrice(for: provider))
            outputPriceText = String(format: "%.2f", aiSettings.outputPrice(for: provider))
        }
    }
}

private struct ConferencesSettingsTab: View {
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var aiSettings: AISettings
    @State private var newName = ""
    @State private var newFullName = ""
    @State private var newThisYearWebsite = ""
    @State private var newNextYearWebsite = ""
    @State private var modelText = ""
    @AppStorage("maziar.conferences.lastListingURL") private var listingURLText = ""
    @State private var isImportingListing = false
    @State private var listingImportError: String?
    @State private var importCandidates: [ConferenceCandidate] = []
    @State private var showImportSheet = false
    @AppStorage("maziar.conferences.lastKeywords") private var keywordText = ""
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    @State private var suggestionCandidates: [ConferenceCandidate] = []
    @State private var showSuggestionSheet = false
    @State private var newHelperWebsite = ""

    private var providerSelection: Binding<String> {
        Binding(
            get: { aiSettings.conferenceProvider?.rawValue ?? "same" },
            set: { newValue in
                aiSettings.conferenceProvider = newValue == "same" ? nil : AIProviderKind(rawValue: newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: providerSelection) {
                    Text("Same as AI Assistant (\(aiSettings.activeProvider.displayName))").tag("same")
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                TextField("Model", text: $modelText, prompt: Text(aiSettings.model(for: aiSettings.effectiveConferenceProvider)))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: modelText) { _, newValue in
                        aiSettings.conferenceModel = newValue
                    }
            } header: {
                Text("Update Using")
            } footer: {
                Text("If the AI Assistant's usual provider doesn't handle conference lookups well (bad JSON, no web search), point this at a different provider/model here without changing what the chat panel uses. Uses the API key already set for that provider in Settings \u{2192} AI.")
                    .font(.caption)
            }
            .onAppear {
                modelText = aiSettings.conferenceModel
            }

            Section {
                TextField("Short name", text: $newName, prompt: Text("e.g. NeurIPS"))
                    .textFieldStyle(.roundedBorder)
                TextField("Full name (optional)", text: $newFullName, prompt: Text("e.g. Conference on Neural Information Processing Systems"))
                    .textFieldStyle(.roundedBorder)
                TextField("Website (this year)", text: $newThisYearWebsite, prompt: Text("https://neurips.cc/Conferences/2026 (optional)"))
                    .textFieldStyle(.roundedBorder)
                TextField("Website (next year)", text: $newNextYearWebsite, prompt: Text("https://neurips.cc/Conferences/2027 (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addConference)
                Button("Add Conference", action: addConference)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Tracked Conferences")
            } footer: {
                Text("Add a conference by its short name, then go to the Conferences page and click Update to fetch its current deadlines, author guide, and LaTeX template via AI. The full name is optional but helps the AI find the right conference faster when the acronym alone is ambiguous, and shows in small text under the name on the Conferences page. Supplying this/next year's website speeds updates up and makes them more reliable — the app fetches that page directly instead of relying on the AI's own (slower) web search.")
                    .font(.caption)
            }

            Section {
                HStack {
                    TextField("Website that lists conferences", text: $listingURLText, prompt: Text("https://www.thecvf.com"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(importFromListing)
                    Button(action: importFromListing) {
                        if isImportingListing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Find Conferences")
                        }
                    }
                    .disabled(listingURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingListing)
                }
                if let listingImportError {
                    CopyableErrorView(message: listingImportError)
                }
            } header: {
                Text("Import From a Listing Website")
            } footer: {
                Text("For a page that lists many conferences (e.g. thecvf.com), Maziar reads its links and asks AI to identify which ones are actual conferences, then lets you pick which to add — including each one's own site URL when found, so later Updates on the Conferences page can fetch it directly instead of searching.")
                    .font(.caption)
            }
            .sheet(isPresented: $showImportSheet) {
                ConferenceImportSheet(
                    candidates: importCandidates,
                    onAdd: { selectedIDs in addSelectedCandidates(selectedIDs) },
                    onCancel: { showImportSheet = false }
                )
            }

            Section {
                HStack {
                    TextField("Research keywords", text: $keywordText, prompt: Text("e.g. computer vision, medical imaging"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(suggestByKeyword)
                    Button(action: suggestByKeyword) {
                        if isSuggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Suggest Conferences")
                        }
                    }
                    .disabled(keywordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSuggesting)
                }
                if let suggestionError {
                    CopyableErrorView(message: suggestionError)
                }
            } header: {
                Text("Suggest by Keyword")
            } footer: {
                Text("Enter your research area and AI will suggest well-known relevant conferences to track, skipping ones already in your list. Uses the same provider/model configured above.")
                    .font(.caption)
            }
            .sheet(isPresented: $showSuggestionSheet) {
                ConferenceImportSheet(
                    candidates: suggestionCandidates,
                    onAdd: { selectedIDs in addSelectedSuggestions(selectedIDs) },
                    onCancel: { showSuggestionSheet = false }
                )
            }

            Section {
                HStack {
                    TextField("Website", text: $newHelperWebsite, prompt: Text("https://www.wikicfp.com/cfp/"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addHelperWebsite)
                    Button("Add", action: addHelperWebsite)
                        .disabled(newHelperWebsite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(conferenceStore.helperWebsites, id: \.self) { url in
                    HStack {
                        Text(url).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            conferenceStore.removeHelperWebsite(url)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Helper Websites")
            } footer: {
                Text("General reference sites (deadline aggregators, ranking portals, bibliography databases) suggested to the AI as search starting points on every conference lookup, alongside — not instead of — the conference's own site. Only useful with a web-search-capable provider (Claude, Gemini); other providers will still see the list but can't actually browse them.")
                    .font(.caption)
            }

            if !conferenceStore.conferences.isEmpty {
                Section {
                    ForEach(Array(conferenceStore.conferences.enumerated()), id: \.element.id) { index, entry in
                        ConferenceSettingsRow(
                            entry: binding(for: entry),
                            onDelete: { conferenceStore.remove(entry) },
                            canMoveUp: index > 0,
                            canMoveDown: index < conferenceStore.conferences.count - 1,
                            onMoveUp: { conferenceStore.moveUp(entry) },
                            onMoveDown: { conferenceStore.moveDown(entry) }
                        )
                    }
                } header: {
                    Text("Reorder")
                } footer: {
                    Text("Use the arrows to change the order conferences appear in on the Conferences page.")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for entry: ConferenceEntry) -> Binding<ConferenceEntry> {
        Binding(
            get: { conferenceStore.conferences.first(where: { $0.id == entry.id }) ?? entry },
            set: { conferenceStore.update($0) }
        )
    }

    private func addConference() {
        guard conferenceStore.add(name: newName, fullName: newFullName) else { return }
        if let added = conferenceStore.conferences.last {
            var updated = added
            let thisYear = newThisYearWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextYear = newNextYearWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.thisYearWebsiteURLString = thisYear.isEmpty ? nil : thisYear
            updated.nextYearWebsiteURLString = nextYear.isEmpty ? nil : nextYear
            conferenceStore.update(updated)
        }
        newName = ""
        newFullName = ""
        newThisYearWebsite = ""
        newNextYearWebsite = ""
    }

    private func importFromListing() {
        listingImportError = nil
        isImportingListing = true
        let urlString = listingURLText
        Task {
            do {
                let candidates = try await ConferenceListImportService.importCandidates(fromListingURL: urlString, settings: aiSettings)
                isImportingListing = false
                if candidates.isEmpty {
                    listingImportError = "No conferences were recognized on that page."
                } else {
                    importCandidates = candidates
                    showImportSheet = true
                }
            } catch {
                isImportingListing = false
                listingImportError = error.localizedDescription
            }
        }
    }

    private func addSelectedCandidates(_ selectedIDs: Set<UUID>) {
        for candidate in importCandidates where selectedIDs.contains(candidate.id) {
            guard conferenceStore.add(name: candidate.name) else { continue }
            if let websiteURLString = candidate.websiteURLString, var added = conferenceStore.conferences.last {
                added.thisYearWebsiteURLString = websiteURLString
                conferenceStore.update(added)
            }
        }
        showImportSheet = false
    }

    private func suggestByKeyword() {
        suggestionError = nil
        isSuggesting = true
        let keywords = keywordText
        let existingNames = conferenceStore.conferences.map(\.name)
        Task {
            do {
                let candidates = try await ConferenceKeywordSuggestionService.suggestCandidates(
                    forKeywords: keywords, excluding: existingNames, settings: aiSettings
                )
                isSuggesting = false
                if candidates.isEmpty {
                    suggestionError = "No new suggestions came back for those keywords."
                } else {
                    suggestionCandidates = candidates
                    showSuggestionSheet = true
                }
            } catch {
                isSuggesting = false
                suggestionError = error.localizedDescription
            }
        }
    }

    private func addSelectedSuggestions(_ selectedIDs: Set<UUID>) {
        for candidate in suggestionCandidates where selectedIDs.contains(candidate.id) {
            guard conferenceStore.add(name: candidate.name) else { continue }
            if let websiteURLString = candidate.websiteURLString, var added = conferenceStore.conferences.last {
                added.thisYearWebsiteURLString = websiteURLString
                conferenceStore.update(added)
            }
        }
        showSuggestionSheet = false
    }

    private func addHelperWebsite() {
        guard conferenceStore.addHelperWebsite(newHelperWebsite) else { return }
        newHelperWebsite = ""
    }
}

private struct ConferenceImportSheet: View {
    let candidates: [ConferenceCandidate]
    var onAdd: (Set<UUID>) -> Void
    var onCancel: () -> Void
    @State private var selected: Set<UUID>

    init(candidates: [ConferenceCandidate], onAdd: @escaping (Set<UUID>) -> Void, onCancel: @escaping () -> Void) {
        self.candidates = candidates
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selected = State(initialValue: Set(candidates.map { $0.id }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Found \(candidates.count) conference\(candidates.count == 1 ? "" : "s")")
                .font(.headline)
            List(candidates) { candidate in
                Toggle(isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: { isOn in if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                        if let url = candidate.websiteURLString {
                            Text(url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 340)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add \(selected.count) Conference\(selected.count == 1 ? "" : "s")") {
                    onAdd(selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct ConferenceSettingsRow: View {
    @Binding var entry: ConferenceEntry
    var onDelete: () -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Full name",
                    text: Binding(
                        get: { entry.fullName ?? "" },
                        set: { entry.fullName = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("optional")
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    "Website (this year)",
                    text: Binding(
                        get: { entry.thisYearWebsiteURLString ?? "" },
                        set: { entry.thisYearWebsiteURLString = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("https://... (optional)")
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    "Website (next year)",
                    text: Binding(
                        get: { entry.nextYearWebsiteURLString ?? "" },
                        set: { entry.nextYearWebsiteURLString = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("https://... (optional)")
                )
                .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Label("Remove Conference", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                Text(entry.name)
                Spacer()
                if let lastUpdated = entry.lastUpdated {
                    Text(lastUpdated, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never updated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct JournalsSettingsTab: View {
    @EnvironmentObject var journalStore: JournalStore
    @EnvironmentObject var aiSettings: AISettings
    @State private var newName = ""
    @State private var newFullName = ""
    @State private var newThisYearWebsite = ""
    @State private var newNextYearWebsite = ""
    @State private var modelText = ""
    @AppStorage("maziar.journals.lastListingURL") private var listingURLText = ""
    @State private var isImportingListing = false
    @State private var listingImportError: String?
    @State private var importCandidates: [JournalCandidate] = []
    @State private var showImportSheet = false
    @AppStorage("maziar.journals.lastKeywords") private var keywordText = ""
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    @State private var suggestionCandidates: [JournalCandidate] = []
    @State private var showSuggestionSheet = false
    @State private var newHelperWebsite = ""

    private var providerSelection: Binding<String> {
        Binding(
            get: { aiSettings.journalProvider?.rawValue ?? "same" },
            set: { newValue in
                aiSettings.journalProvider = newValue == "same" ? nil : AIProviderKind(rawValue: newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: providerSelection) {
                    Text("Same as AI Assistant (\(aiSettings.activeProvider.displayName))").tag("same")
                    ForEach(AIProviderKind.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                TextField("Model", text: $modelText, prompt: Text(aiSettings.model(for: aiSettings.effectiveJournalProvider)))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: modelText) { _, newValue in
                        aiSettings.journalModel = newValue
                    }
            } header: {
                Text("Update Using")
            } footer: {
                Text("If the AI Assistant's usual provider doesn't handle journal lookups well (bad JSON, no web search), point this at a different provider/model here without changing what the chat panel uses. Uses the API key already set for that provider in Settings \u{2192} AI.")
                    .font(.caption)
            }
            .onAppear {
                modelText = aiSettings.journalModel
            }

            Section {
                TextField("Short name", text: $newName, prompt: Text("e.g. TPAMI"))
                    .textFieldStyle(.roundedBorder)
                TextField("Full name (optional)", text: $newFullName, prompt: Text("e.g. IEEE Transactions on Pattern Analysis and Machine Intelligence"))
                    .textFieldStyle(.roundedBorder)
                TextField("Website (this year)", text: $newThisYearWebsite, prompt: Text("https://... (optional)"))
                    .textFieldStyle(.roundedBorder)
                TextField("Website (next year)", text: $newNextYearWebsite, prompt: Text("https://... (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addJournal)
                Button("Add Journal", action: addJournal)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Tracked Journals")
            } footer: {
                Text("Add a journal by its short name, then go to the Journals page and click Update to fetch its current submission info, author guidelines, and LaTeX template via AI. The full name is optional but helps the AI find the right journal faster when the acronym alone is ambiguous, and shows in small text under the name on the Journals page. Supplying this/next year's website speeds updates up and makes them more reliable — the app fetches that page directly instead of relying on the AI's own (slower) web search.")
                    .font(.caption)
            }

            Section {
                HStack {
                    TextField("Website that lists journals", text: $listingURLText, prompt: Text("e.g. a publisher's journal directory"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(importFromListing)
                    Button(action: importFromListing) {
                        if isImportingListing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Find Journals")
                        }
                    }
                    .disabled(listingURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImportingListing)
                }
                if let listingImportError {
                    CopyableErrorView(message: listingImportError)
                }
            } header: {
                Text("Import From a Listing Website")
            } footer: {
                Text("For a page that lists many journals (e.g. a publisher's journal directory), Maziar reads its links and asks AI to identify which ones are actual journals, then lets you pick which to add — including each one's own site URL when found, so later Updates on the Journals page can fetch it directly instead of searching.")
                    .font(.caption)
            }
            .sheet(isPresented: $showImportSheet) {
                JournalImportSheet(
                    candidates: importCandidates,
                    onAdd: { selectedIDs in addSelectedCandidates(selectedIDs) },
                    onCancel: { showImportSheet = false }
                )
            }

            Section {
                HStack {
                    TextField("Research keywords", text: $keywordText, prompt: Text("e.g. computer vision, medical imaging"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(suggestByKeyword)
                    Button(action: suggestByKeyword) {
                        if isSuggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Suggest Journals")
                        }
                    }
                    .disabled(keywordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSuggesting)
                }
                if let suggestionError {
                    CopyableErrorView(message: suggestionError)
                }
            } header: {
                Text("Suggest by Keyword")
            } footer: {
                Text("Enter your research area and AI will suggest well-known relevant journals to track, skipping ones already in your list. Uses the same provider/model configured above.")
                    .font(.caption)
            }
            .sheet(isPresented: $showSuggestionSheet) {
                JournalImportSheet(
                    candidates: suggestionCandidates,
                    onAdd: { selectedIDs in addSelectedSuggestions(selectedIDs) },
                    onCancel: { showSuggestionSheet = false }
                )
            }

            Section {
                HStack {
                    TextField("Website", text: $newHelperWebsite, prompt: Text("https://www.scimagojr.com/"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addHelperWebsite)
                    Button("Add", action: addHelperWebsite)
                        .disabled(newHelperWebsite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(journalStore.helperWebsites, id: \.self) { url in
                    HStack {
                        Text(url).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            journalStore.removeHelperWebsite(url)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Helper Websites")
            } footer: {
                Text("General reference sites (impact-factor/quartile portals, indexing databases) suggested to the AI as search starting points on every journal lookup, alongside — not instead of — the journal's own site. Only useful with a web-search-capable provider (Claude, Gemini); other providers will still see the list but can't actually browse them.")
                    .font(.caption)
            }

            if !journalStore.journals.isEmpty {
                Section {
                    ForEach(Array(journalStore.journals.enumerated()), id: \.element.id) { index, entry in
                        JournalSettingsRow(
                            entry: binding(for: entry),
                            onDelete: { journalStore.remove(entry) },
                            canMoveUp: index > 0,
                            canMoveDown: index < journalStore.journals.count - 1,
                            onMoveUp: { journalStore.moveUp(entry) },
                            onMoveDown: { journalStore.moveDown(entry) }
                        )
                    }
                } header: {
                    Text("Reorder")
                } footer: {
                    Text("Use the arrows to change the order journals appear in on the Journals page.")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for entry: JournalEntry) -> Binding<JournalEntry> {
        Binding(
            get: { journalStore.journals.first(where: { $0.id == entry.id }) ?? entry },
            set: { journalStore.update($0) }
        )
    }

    private func addJournal() {
        guard journalStore.add(name: newName, fullName: newFullName) else { return }
        if let added = journalStore.journals.last {
            var updated = added
            let thisYear = newThisYearWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextYear = newNextYearWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.thisYearWebsiteURLString = thisYear.isEmpty ? nil : thisYear
            updated.nextYearWebsiteURLString = nextYear.isEmpty ? nil : nextYear
            journalStore.update(updated)
        }
        newName = ""
        newFullName = ""
        newThisYearWebsite = ""
        newNextYearWebsite = ""
    }

    private func importFromListing() {
        listingImportError = nil
        isImportingListing = true
        let urlString = listingURLText
        Task {
            do {
                let candidates = try await JournalListImportService.importCandidates(fromListingURL: urlString, settings: aiSettings)
                isImportingListing = false
                if candidates.isEmpty {
                    listingImportError = "No journals were recognized on that page."
                } else {
                    importCandidates = candidates
                    showImportSheet = true
                }
            } catch {
                isImportingListing = false
                listingImportError = error.localizedDescription
            }
        }
    }

    private func addSelectedCandidates(_ selectedIDs: Set<UUID>) {
        for candidate in importCandidates where selectedIDs.contains(candidate.id) {
            guard journalStore.add(name: candidate.name) else { continue }
            if let websiteURLString = candidate.websiteURLString, var added = journalStore.journals.last {
                added.thisYearWebsiteURLString = websiteURLString
                journalStore.update(added)
            }
        }
        showImportSheet = false
    }

    private func suggestByKeyword() {
        suggestionError = nil
        isSuggesting = true
        let keywords = keywordText
        let existingNames = journalStore.journals.map(\.name)
        Task {
            do {
                let candidates = try await JournalKeywordSuggestionService.suggestCandidates(
                    forKeywords: keywords, excluding: existingNames, settings: aiSettings
                )
                isSuggesting = false
                if candidates.isEmpty {
                    suggestionError = "No new suggestions came back for those keywords."
                } else {
                    suggestionCandidates = candidates
                    showSuggestionSheet = true
                }
            } catch {
                isSuggesting = false
                suggestionError = error.localizedDescription
            }
        }
    }

    private func addSelectedSuggestions(_ selectedIDs: Set<UUID>) {
        for candidate in suggestionCandidates where selectedIDs.contains(candidate.id) {
            guard journalStore.add(name: candidate.name) else { continue }
            if let websiteURLString = candidate.websiteURLString, var added = journalStore.journals.last {
                added.thisYearWebsiteURLString = websiteURLString
                journalStore.update(added)
            }
        }
        showSuggestionSheet = false
    }

    private func addHelperWebsite() {
        guard journalStore.addHelperWebsite(newHelperWebsite) else { return }
        newHelperWebsite = ""
    }
}

private struct JournalImportSheet: View {
    let candidates: [JournalCandidate]
    var onAdd: (Set<UUID>) -> Void
    var onCancel: () -> Void
    @State private var selected: Set<UUID>

    init(candidates: [JournalCandidate], onAdd: @escaping (Set<UUID>) -> Void, onCancel: @escaping () -> Void) {
        self.candidates = candidates
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selected = State(initialValue: Set(candidates.map { $0.id }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Found \(candidates.count) journal\(candidates.count == 1 ? "" : "s")")
                .font(.headline)
            List(candidates) { candidate in
                Toggle(isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: { isOn in if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                        if let url = candidate.websiteURLString {
                            Text(url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 340)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add \(selected.count) Journal\(selected.count == 1 ? "" : "s")") {
                    onAdd(selected)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct JournalSettingsRow: View {
    @Binding var entry: JournalEntry
    var onDelete: () -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Full name",
                    text: Binding(
                        get: { entry.fullName ?? "" },
                        set: { entry.fullName = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("optional")
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    "Website (this year)",
                    text: Binding(
                        get: { entry.thisYearWebsiteURLString ?? "" },
                        set: { entry.thisYearWebsiteURLString = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("https://... (optional)")
                )
                .textFieldStyle(.roundedBorder)
                TextField(
                    "Website (next year)",
                    text: Binding(
                        get: { entry.nextYearWebsiteURLString ?? "" },
                        set: { entry.nextYearWebsiteURLString = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ),
                    prompt: Text("https://... (optional)")
                )
                .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Label("Remove Journal", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                    if let fullName = entry.fullName, !fullName.isEmpty {
                        Text(fullName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let lastUpdated = entry.lastUpdated {
                    Text(lastUpdated, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never updated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BackupSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var texManager: TeXInstallationManager
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var journalStore: JournalStore
    @EnvironmentObject var paperStore: PaperStore
    @State private var backupError: String?
    @State private var importSuccessMessage: String?
    @State private var pendingImportData: Data?
    @State private var showImportConfirm = false

    var body: some View {
        Form {
            Section {
                Button("Export Settings...") { exportBackup() }
            } header: {
                Text("Export")
            } footer: {
                Text("Saves everything configurable in Maziar — Appearance, LaTeX Compiler options, AI provider/model choices and prompt tasks, tracked Conferences, Journals, and Papers — as one file, to move to another Mac or keep as a backup. API keys are never included; they live in the Keychain, not here.")
                    .font(.caption)
            }

            Section {
                Button("Import Settings...") { chooseImportFile() }
                if let importSuccessMessage {
                    Label(importSuccessMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Import")
            } footer: {
                Text("Replaces your current settings, tracked conferences, journals, and papers with what's in the chosen backup file. Takes effect immediately, no restart needed.")
                    .font(.caption)
            }

            if let backupError {
                Section {
                    CopyableErrorView(message: backupError)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Import this backup? It will overwrite your current settings, tracked conferences, journals, and papers.",
            isPresented: $showImportConfirm,
            titleVisibility: .visible
        ) {
            Button("Import & Overwrite", role: .destructive) { performImport() }
            Button("Cancel", role: .cancel) { pendingImportData = nil }
        }
    }

    private func exportBackup() {
        backupError = nil
        do {
            let data = try AppSettingsBackupService.exportData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.propertyList]
            panel.nameFieldStringValue = "Maziar Settings.plist"
            panel.prompt = "Save"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func chooseImportFile() {
        backupError = nil
        importSuccessMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .xml, .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingImportData = try Data(contentsOf: url)
            showImportConfirm = true
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func performImport() {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            try AppSettingsBackupService.importData(
                data,
                appSettings: settings,
                aiSettings: aiSettings,
                texManager: texManager,
                conferenceStore: conferenceStore,
                journalStore: journalStore,
                paperStore: paperStore
            )
            importSuccessMessage = "Settings imported."
        } catch {
            backupError = error.localizedDescription
        }
    }
}

private struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if let logo = AppBranding.logo {
                logo
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 180)
            }
            Text("Maziar").font(.title.bold())
            Text(AppBranding.aboutText)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Spacer()
            Text("Version 0.1.0")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
