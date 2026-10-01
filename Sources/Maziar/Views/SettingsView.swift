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
            LibrarySettingsTab()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(SettingsTab.library)
            CustomPagesSettingsTab()
                .tabItem { Label("Custom Pages", systemImage: "globe") }
                .tag(SettingsTab.customPages)
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(SettingsTab.accounts)
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
                ForEach(ThemeRegion.allCases.filter { $0.scope == .general }) { region in
                    colorRow(for: region)
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
                ForEach(ThemeRegion.allCases.filter { $0.scope == .library }) { region in
                    colorRow(for: region, currentValue: region == .libraryButtonColor ? settings.libraryButtonColor() : nil)
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Overrides colors just for the Library page — each section's background, and its own button/accent color (the app-wide one above until you set this).")
                    .font(.caption)
            }

            Section {
                Picker("Style", selection: $settings.readerVisualStyle) {
                    ForEach(ReaderVisualStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Appearance", selection: $settings.readerAppearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                ForEach(ThemeRegion.allCases.filter { $0.scope == .reader }) { region in
                    colorRow(for: region, currentValue: region == .readerButtonColor ? settings.readerButtonColor() : nil)
                }
            } header: {
                Text("Reader")
            } footer: {
                Text("\u{201c}Glass\u{201d} gives the companion pane and toolbar a translucent, blurred background instead of a solid one; \u{201c}Panel Background\u{201d} below only applies in Normal style. \u{201c}Appearance\u{201d} lets the Reader window use its own light/dark mode independent of the app-wide one above (\u{201c}System\u{201d} just follows it). Also overrides colors just for the Reader window, including the PDF's own background — the area behind/around the page itself, not the page content. The Reader's AI Chat source is set in Settings \u{2192} Library.")
                    .font(.caption)
            }

            Section {
                ForEach(ReaderCompanionMode.allCases) { m in
                    Toggle(m.label, isOn: Binding(
                        get: { settings.readerQuickAccessModes.contains(m) },
                        set: { isOn in
                            if isOn {
                                if !settings.readerQuickAccessModes.contains(m) {
                                    settings.readerQuickAccessModes.append(m)
                                }
                            } else {
                                settings.readerQuickAccessModes.removeAll { $0 == m }
                            }
                        }
                    ))
                }
            } header: {
                Text("Reader Quick-Access Icons")
            } footer: {
                Text("Choose which modes get a small icon button in the Reader window's left icon rail, for one-click access without opening the mode dropdown above the PDF's own controls. Every mode stays available in that dropdown regardless of what's checked here.")
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

    /// One color-picker row, shared by the general/Library/Reader sections above — `currentValue`
    /// overrides what's shown when unset (used for the Library/Reader button-color rows, which
    /// inherit the app-wide button color rather than a hardcoded default until customized).
    private func colorRow(for region: ThemeRegion, currentValue: Color? = nil) -> some View {
        HStack {
            ColorPicker(
                region.displayName,
                selection: Binding(
                    get: { currentValue ?? settings.color(for: region) },
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

private struct LibrarySettingsTab: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @State private var driveRoots: [URL] = []
    @State private var modelText = ""
    @State private var newLanguage = ""
    @State private var showAddLabelSheet = false
    @State private var editingLabel: PaperLabelOption?
    @State private var newLabelNumber = 1

    /// Same `@AppStorage` keys `NotebookEditorView` reads when inserting a Title/Main Text/
    /// Subtitle box, so editing here takes effect immediately without any separate sync step.
    @AppStorage("maziar.notebook.titleTemplate") private var titleTemplate = NotebookEditorView.defaultTitleTemplate
    @AppStorage("maziar.notebook.mainTextTemplate") private var mainTextTemplate = NotebookEditorView.defaultMainTextTemplate
    @AppStorage("maziar.notebook.subtitleTemplate") private var subtitleTemplate = NotebookEditorView.defaultSubtitleTemplate

    private var providerSelection: Binding<String> {
        Binding(
            get: { aiSettings.libraryProvider?.rawValue ?? "same" },
            set: { newValue in
                aiSettings.libraryProvider = newValue == "same" ? nil : AIProviderKind(rawValue: newValue)
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
                TextField("Model", text: $modelText, prompt: Text(aiSettings.model(for: aiSettings.effectiveLibraryProvider)))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: modelText) { _, newValue in
                        aiSettings.libraryModel = newValue
                    }
            } header: {
                Text("AI Model")
            } footer: {
                Text("Used for Extract Info with AI, the Translator, and per-paper chat. Uses the API key already set for that provider in Settings \u{2192} AI.")
                    .font(.caption)
            }
            .onAppear {
                modelText = aiSettings.libraryModel
            }

            Section {
                Picker("AI Chat", selection: $settings.readerAIChatSource) {
                    ForEach(ReaderAIChatSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Reader AI Chat")
            } footer: {
                Text("Chooses what the Reader window's AI Chat mode actually opens — Maziar's own built-in chat, or the ChatGPT/Claude website directly (renaming that mode's tab to match).")
                    .font(.caption)
            }

            Section {
                HStack {
                    TextField("Language", text: $newLanguage, prompt: Text("e.g. German"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addLanguage)
                    Button("Add", action: addLanguage)
                        .disabled(newLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(libraryStore.translatorLanguages, id: \.self) { language in
                    HStack {
                        Text(language)
                        Spacer()
                        Button(role: .destructive) {
                            libraryStore.removeTranslatorLanguage(language)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Translator Languages")
            } footer: {
                Text("These are the options offered in the reader window's Translator target-language picker.")
                    .font(.caption)
            }

            Section {
                Stepper(
                    "Maximum note/cell height: \(libraryStore.notesCellMaxLines) lines",
                    value: $libraryStore.notesCellMaxLines,
                    in: 3...200
                )
            } header: {
                Text("Notes")
            } footer: {
                Text("A note or notebook cell shrinks to fit short text on its own; this caps how tall it can grow for longer text before it scrolls internally instead of pushing the rest of the page down.")
                    .font(.caption)
            }

            Section {
                notebookTemplateEditor("Title Box", text: $titleTemplate, defaultValue: NotebookEditorView.defaultTitleTemplate)
                notebookTemplateEditor("Main Text Box", text: $mainTextTemplate, defaultValue: NotebookEditorView.defaultMainTextTemplate)
                notebookTemplateEditor("Subtitle Box", text: $subtitleTemplate, defaultValue: NotebookEditorView.defaultSubtitleTemplate)
            } header: {
                Text("Notebook Templates")
            } footer: {
                Text("The raw HTML each \u{201c}Add Cell\u{201d} box option in the reader's Notebook starts a new cell with. Edit directly, or Reset to Default to go back to the built-in version.")
                    .font(.caption)
            }

            Section {
                ForEach(libraryStore.paperLabels) { option in
                    HStack {
                        Circle()
                            .fill(option.color)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        Text(option.name)
                        Spacer()
                        Button("Edit") { editingLabel = option }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            libraryStore.removePaperLabel(option)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if libraryStore.paperLabels.isEmpty {
                    Text("No colors yet.").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    showAddLabelSheet = true
                } label: {
                    Label("Add Color", systemImage: "plus")
                }
            } header: {
                Text("Paper Label Colors")
            } footer: {
                Text("Colors you can assign to a paper in the Library list, shown as a small circle next to its title — right-click that circle to assign one.")
                    .font(.caption)
            }

            Section {
                FlowLayout(spacing: 6) {
                    ForEach(libraryStore.paperLabelNumbers, id: \.self) { number in
                        HStack(spacing: 4) {
                            Text("\(number)").font(.caption.monospacedDigit())
                            Button {
                                libraryStore.removePaperLabelNumber(number)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
                if libraryStore.paperLabelNumbers.isEmpty {
                    Text("No numbers yet.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Stepper("Add number: \(newLabelNumber)", value: $newLabelNumber, in: 1...999)
                    Button("Add") {
                        libraryStore.addPaperLabelNumber(newLabelNumber)
                    }
                    .disabled(libraryStore.paperLabelNumbers.contains(newLabelNumber))
                }
            } header: {
                Text("Paper Label Numbers")
            } footer: {
                Text("Numbers offered in that same circle's right-click menu, independent of color \u{2014} e.g. 1 for a paper to read first, 2 for the one after it.")
                    .font(.caption)
            }

            Section {
                if let path = libraryStore.folderPath {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Label("Not connected", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }

                if !driveRoots.isEmpty {
                    ForEach(driveRoots, id: \.self) { root in
                        Button {
                            openPicker(startingAt: root)
                        } label: {
                            Label(root.lastPathComponent.replacingOccurrences(of: "GoogleDrive-", with: ""), systemImage: "folder.badge.gearshape")
                        }
                    }
                }

                Button {
                    openPicker(startingAt: nil)
                } label: {
                    Label(libraryStore.folderPath == nil ? "Connect Folder…" : "Change Folder…", systemImage: "folder.badge.plus")
                }

                if libraryStore.folderPath != nil {
                    Button("Reveal in Finder") {
                        if let url = libraryStore.folderURL { NSWorkspace.shared.open(url) }
                    }
                    Button("Disconnect", role: .destructive) { libraryStore.disconnect() }
                }
            } header: {
                Text("Storage Folder")
            } footer: {
                Text("Where your papers (and their notes files) actually live — point this at a folder inside your Google Drive for Desktop sync (detected accounts are listed above as shortcuts) so everything you add here is backed up automatically. No Google sign-in inside Maziar: it just watches whatever folder you pick, the same way it would watch any other local folder.")
                    .font(.caption)
            }

            Section {
                Toggle("Two-row group bar", isOn: $libraryStore.groupsTwoRowLayout)
                if !libraryStore.groups.isEmpty {
                    ForEach(libraryStore.groups) { group in
                        Label(group.name, systemImage: group.iconSystemName)
                            .foregroundStyle(group.iconColorHex.flatMap(Color.init(hex:)) ?? .primary)
                    }
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("The group bar on the Library page defaults to one row, scrolling sideways once there are more groups than fit — turn this on to see two rows at once instead. Each group is a real subfolder of the storage folder above — add, rename, or delete groups from the Library page itself.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { driveRoots = LibraryStore.suggestedDriveRoots() }
        .sheet(isPresented: $showAddLabelSheet) {
            PaperLabelEditorSheet(
                existing: nil,
                onSave: { name, colorHex in
                    libraryStore.addPaperLabel(name: name, colorHex: colorHex)
                    showAddLabelSheet = false
                },
                onCancel: { showAddLabelSheet = false }
            )
        }
        .sheet(item: $editingLabel) { option in
            PaperLabelEditorSheet(
                existing: option,
                onSave: { name, colorHex in
                    libraryStore.updatePaperLabel(option, name: name, colorHex: colorHex)
                    editingLabel = nil
                },
                onCancel: { editingLabel = nil }
            )
        }
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
        libraryStore.connect(picked)
    }

    private func addLanguage() {
        if libraryStore.addTranslatorLanguage(newLanguage) {
            newLanguage = ""
        }
    }

    @ViewBuilder
    private func notebookTemplateEditor(_ title: String, text: Binding<String>, defaultValue: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.bold())
                Spacer()
                Button("Reset to Default") { text.wrappedValue = defaultValue }
                    .disabled(text.wrappedValue == defaultValue)
            }
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .padding(.vertical, 4)
    }
}

/// Add or edit one `PaperLabelOption` — shared by both flows (`existing` is nil for a brand new
/// color, set for editing one already in the list), same "one sheet, optional `existing`" shape as
/// the reader's own highlight-color add/rename sheets.
private struct PaperLabelEditorSheet: View {
    let existing: PaperLabelOption?
    var onSave: (_ name: String, _ colorHex: String) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var color: Color

    init(existing: PaperLabelOption?, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existing?.name ?? "")
        _color = State(initialValue: existing?.color ?? .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Paper Label Color" : "Edit Paper Label Color").font(.headline)
            TextField("Name (e.g. \u{201c}Important\u{201d})", text: $name).textFieldStyle(.roundedBorder)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(existing == nil ? "Add" : "Save") {
                    let hex = color.toHex() ?? existing?.colorHex ?? "F44336FF"
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), hex)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// Lets the user add their own pages to the app — each just a name and a URL, opened inside Maziar
/// the same way the built-in Diagrams page already is (`CustomWebPageView`, an embedded browser).
/// Each page can be shown/hidden in the left sidebar independently of being removed entirely, and
/// removed outright when no longer wanted.
private struct CustomPagesSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newName = ""
    @State private var newURLText = ""
    @State private var newIcon = "globe"
    @State private var newIconColor = Color(nsColor: .controlAccentColor)
    @State private var newIconImageData: Data?
    @State private var newAllowMultipleTabs = false
    @State private var newShowCVAutofillTool = false
    @State private var addError: String?

    var body: some View {
        Form {
            Section {
                ForEach(AppSection.allCases) { section in
                    HStack {
                        IconPickerButton(selection: Binding(
                            get: { settings.icon(for: section) },
                            set: { settings.setSectionIcon(section, iconSystemName: $0) }
                        ))
                        ColorPicker("", selection: Binding(
                            get: { settings.sectionIconColor(section) ?? Color(nsColor: .controlAccentColor) },
                            set: { settings.setSectionIconColor(section, color: $0) }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Toggle(section.title, isOn: Binding(
                            get: { !settings.hiddenSections.contains(section) },
                            set: { isOn in
                                if isOn {
                                    settings.hiddenSections.remove(section)
                                } else {
                                    settings.hiddenSections.insert(section)
                                }
                            }
                        ))
                        Spacer()
                        if settings.icon(for: section) != section.icon || settings.sectionIconColor(section) != nil {
                            Button {
                                settings.resetSectionIconAndColor(section)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Reset to default icon and color")
                        }
                    }
                }
            } header: {
                Text("Built-in Pages")
            } footer: {
                Text("Turn off any of the app's built-in pages to hide them from the sidebar \u{2014} turn them back on here anytime; nothing about the page itself is deleted. Icon and color are customizable too.")
                    .font(.caption)
            }

            Section {
                TextField("Name (e.g. \u{201c}Excalidraw\u{201d})", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("URL (e.g. excalidraw.com)", text: $newURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPage)
                HStack {
                    Text("Icon")
                    Spacer()
                    PageIconEditor(iconSystemName: $newIcon, iconColor: $newIconColor, iconImageData: $newIconImageData)
                }
                Toggle("Allow multiple tabs (like a browser)", isOn: $newAllowMultipleTabs)
                Toggle("Show CV AutoFill launcher", isOn: $newShowCVAutofillTool)
                if let addError {
                    Text(addError).font(.caption).foregroundStyle(.red)
                }
                Button("Add Page", action: addPage)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add a Page")
            } footer: {
                Text("Adds a new item to the left sidebar that opens the given URL directly inside Maziar, the same way the built-in Diagrams page does. \u{201c}Image\u{2026}\u{201d} lets you use your own picture as the sidebar icon instead of a symbol. \u{201c}Allow multiple tabs\u{201d} gives the page its own tab bar so you can have several sessions of it open at once, like a real browser. \u{201c}Show CV AutoFill launcher\u{201d} adds a small left-side button that opens the real Farhad's CV AutoFill app — handy on a page like LinkedIn's job feed.")
                    .font(.caption)
            }

            Section {
                if settings.customPages.isEmpty {
                    Text("No custom pages yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.customPages) { page in
                        CustomPageRow(page: page)
                    }
                }
            } header: {
                Text("Your Pages")
            } footer: {
                Text("Turn off \u{201c}Show in Sidebar\u{201d} to keep a page defined without it cluttering the sidebar \u{2014} it stays listed here and can be turned back on or removed anytime. Name and URL are editable here too.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func addPage() {
        addError = nil
        guard let normalized = CustomWebPage.normalizedURLString(newURLText) else {
            addError = "That doesn't look like a valid URL."
            return
        }
        settings.addCustomPage(name: newName, urlString: normalized, iconSystemName: newIcon, iconColorHex: newIconColor.toHex(), iconImageData: newIconImageData, allowMultipleTabs: newAllowMultipleTabs, showCVAutofillTool: newShowCVAutofillTool)
        newName = ""
        newURLText = ""
        newIcon = "globe"
        newIconColor = Color(nsColor: .controlAccentColor)
        newIconImageData = nil
        newAllowMultipleTabs = false
        newShowCVAutofillTool = false
    }
}

/// One row in "Your Pages" — name, URL, icon/color/image, sidebar visibility, and delete, all
/// editable after the page's already been created. Name and URL use local `@State` seeded from the
/// page (rather than binding a `TextField` straight to `AppSettings`) so an in-progress edit — e.g.
/// clearing the name to retype it, or a URL that isn't valid yet mid-keystroke — displays exactly
/// what's typed instead of a validating setter fighting the field on every keystroke; the change
/// only commits to `AppSettings` on `onChange`/`onSubmit`, once there's an actual value to commit.
private struct CustomPageRow: View {
    @EnvironmentObject var settings: AppSettings
    let page: CustomWebPage

    @State private var name: String
    @State private var urlText: String

    init(page: CustomWebPage) {
        self.page = page
        _name = State(initialValue: page.name)
        _urlText = State(initialValue: page.urlString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, newValue in
                        settings.setCustomPage(page, name: newValue)
                    }
                TextField("URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        settings.setCustomPage(page, urlString: urlText)
                    }
            }
            HStack {
                PageIconEditor(
                    iconSystemName: Binding(
                        get: { page.iconSystemName },
                        set: { settings.setCustomPage(page, iconSystemName: $0) }
                    ),
                    iconColor: Binding(
                        get: { page.iconColorHex.flatMap(Color.init(hex:)) ?? Color(nsColor: .controlAccentColor) },
                        set: { settings.setCustomPage(page, iconColorHex: $0.toHex()) }
                    ),
                    iconImageData: Binding(
                        get: { page.iconImageData },
                        set: { settings.setCustomPage(page, iconImageData: $0) }
                    )
                )
                Spacer()
                Toggle("Multiple Tabs", isOn: Binding(
                    get: { page.allowMultipleTabs },
                    set: { settings.setCustomPage(page, allowMultipleTabs: $0) }
                ))
                .toggleStyle(.switch)
                .help(page.allowMultipleTabs ? "Multiple tabs allowed, like a browser" : "One session only")
                Toggle("CV AutoFill", isOn: Binding(
                    get: { page.showCVAutofillTool },
                    set: { settings.setCustomPage(page, showCVAutofillTool: $0) }
                ))
                .toggleStyle(.switch)
                .help(page.showCVAutofillTool ? "Showing CV AutoFill launcher" : "CV AutoFill launcher hidden")
                Toggle("Show in Sidebar", isOn: Binding(
                    get: { page.showInSidebar },
                    set: { settings.setCustomPage(page, showInSidebar: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(page.showInSidebar ? "Showing in sidebar" : "Hidden from sidebar")
                Button(role: .destructive) {
                    settings.removeCustomPage(page)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One page's icon, editable as either a colored SF Symbol (`IconPickerButton` + `ColorPicker`) or
/// a user-picked image — the two are mutually exclusive in the sidebar, so this shows only whichever
/// is currently active, plus the controls to switch between them. Shared by both "Add a Page" (local
/// `@State` bindings) and "Your Pages" (bindings straight through to `AppSettings.setCustomPage`)
/// so the two don't duplicate this logic with slightly different behavior.
private struct PageIconEditor: View {
    @Binding var iconSystemName: String
    @Binding var iconColor: Color
    @Binding var iconImageData: Data?

    var body: some View {
        HStack(spacing: 8) {
            if let iconImageData, let nsImage = NSImage(data: iconImageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Button {
                    self.iconImageData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove image, use a symbol instead")
            } else {
                IconPickerButton(selection: $iconSystemName)
                ColorPicker("", selection: $iconColor, supportsOpacity: false)
                    .labelsHidden()
            }
            Button("Image…", action: chooseImage)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        iconImageData = Self.resizedPNGData(from: url)
    }

    /// Shrinks to a small square before storing — this gets persisted inline as part of the page's
    /// own JSON in `UserDefaults` (`AppSettings.customPages`), so keeping it small matters; a
    /// full-resolution photo would bloat that store for what only ever renders as a ~24pt icon.
    private static func resizedPNGData(from url: URL, maxDimension: CGFloat = 128) -> Data? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1)
        let targetSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A small button showing the currently-selected SF Symbol; clicking it opens a popover grid of
/// `CustomWebPage.suggestedIcons` to pick from.
private struct IconPickerButton: View {
    @Binding var selection: String
    @State private var showPicker = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Image(systemName: selection)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showPicker) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CustomWebPage.suggestedIcons, id: \.self) { icon in
                    Button {
                        selection = icon
                        showPicker = false
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                            .frame(width: 28, height: 28)
                            .background(
                                icon == selection ? Color.accentColor.opacity(0.2) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: 236)
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
    @EnvironmentObject var libraryStore: LibraryStore
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
                Text("Saves everything configurable in Maziar — Appearance, LaTeX Compiler options, AI provider/model choices and prompt tasks, tracked Conferences, Journals, Papers, and Library entries — as one file, to move to another Mac or keep as a backup. API keys are never included; they live in the Keychain, not here. The Library's connected folder path is included, but not the PDFs themselves — those live wherever that folder actually is (e.g. Google Drive).")
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
                Text("Replaces your current settings, tracked conferences, journals, papers, and library entries with what's in the chosen backup file. Takes effect immediately, no restart needed.")
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
            "Import this backup? It will overwrite your current settings, tracked conferences, journals, papers, and library entries.",
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
                paperStore: paperStore,
                libraryStore: libraryStore
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
