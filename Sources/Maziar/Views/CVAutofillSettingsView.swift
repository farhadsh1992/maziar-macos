import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// CV AutoFill's own logo mark — kept separate from `AppBranding` since it's this one feature's own
/// identity (the same crest used by the standalone browser extension/Mac app it's a lighter
/// Maziar-native counterpart to), not the app's own.
enum CVAutofillBranding {
    static let logoImage: NSImage? = Bundle.module.url(forResource: "CVAutoFillLogo", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    static var logo: Image? {
        guard let logoImage else { return nil }
        return Image(nsImage: logoImage)
    }
}

private enum CVAutofillSettingsTab: String, CaseIterable, Identifiable {
    case info
    case askAI
    case jobs
    case quickAccess
    case prompts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Info"
        case .askAI: return "Ask AI"
        case .jobs: return "Jobs"
        case .quickAccess: return "Quick Access"
        case .prompts: return "Prompts"
        }
    }

    var icon: String {
        switch self {
        case .info: return "doc.text"
        case .askAI: return "bubble.left.and.bubble.right"
        case .jobs: return "briefcase"
        case .quickAccess: return "bolt"
        case .prompts: return "text.quote"
        }
    }
}

/// The CV AutoFill panel's own separate "Setting" window — opened via its own button in
/// `CVAutofillPanel`, deliberately NOT a tab inside Maziar's regular Settings (⌘,), matching the
/// original browser extension's own separate Options page (reached via its popup's own "Setting"
/// button, not the browser's general settings). Tabbed the same way that extension's Options page
/// is, minus the pieces that duplicate other Maziar features (multi-provider API keys — this reuses
/// the app's own AI Assistant settings; conference/journal tracking — already its own Maziar
/// feature) or don't apply to a native app (the Claude Code/Codex terminal CLI bridge).
struct CVAutofillSettingsWindow: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @EnvironmentObject var aiSettings: AISettings
    @State private var selectedTab: CVAutofillSettingsTab = .info

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let logo = CVAutofillBranding.logo {
                    logo
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("CV AutoFill").font(.title3.bold())
                    Text("Setting").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            TabView(selection: $selectedTab) {
                ForEach(CVAutofillSettingsTab.allCases) { tab in
                    tabContent(tab)
                        .tabItem { Label(tab.title, systemImage: tab.icon) }
                        .tag(tab)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
    }

    @ViewBuilder
    private func tabContent(_ tab: CVAutofillSettingsTab) -> some View {
        switch tab {
        case .info: CVAutofillInfoTab()
        case .askAI: CVAutofillAskAITab()
        case .jobs: CVAutofillJobsTab()
        case .quickAccess: CVAutofillQuickAccessTab()
        case .prompts: CVAutofillPromptsTab()
        }
    }
}

// MARK: - Info tab (CV, cover letter, addresses, notes, backup)

private struct CVAutofillInfoTab: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @EnvironmentObject var aiSettings: AISettings

    @State private var isParsingCV = false
    @State private var cvParseError: String?
    @State private var coverLetterError: String?
    @State private var newNoteTitle = ""
    @State private var newNoteContent = ""
    @State private var newAddressTitle = ""
    @State private var newAddressContent = ""
    @State private var backupStatus: String?
    @State private var backupError: String?

    var body: some View {
        Form {
            cvSection
            coverLetterSection
            addressesSection
            notesSection
            backupSection
        }
        .formStyle(.grouped)
    }

    // MARK: CV

    private var cvSection: some View {
        Section {
            if cvAutofillStore.isLoaded {
                Label(cvAutofillStore.cvFileName ?? "CV loaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No CV set", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose File…", action: chooseCVFile)
                    .disabled(isParsingCV)
                if isParsingCV {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if cvAutofillStore.isLoaded {
                    Button("Clear", role: .destructive) { cvAutofillStore.clearCV() }
                }
            }
            if let cvParseError {
                CopyableErrorView(message: cvParseError)
            }
            if cvAutofillStore.isLoaded {
                TextEditor(text: Binding(
                    get: { cvAutofillStore.structuredCVJSON ?? "" },
                    set: { cvAutofillStore.structuredCVJSON = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 160)
            }
        } header: {
            Text("Your CV")
        } footer: {
            Text("Upload a PDF or Word (.docx) CV \u{2014} extracted locally, then structured once by AI (name, contact, work history, education, skills) and reused for autofill and every generated document. Editable directly above.")
                .font(.caption)
        }
    }

    private func chooseCVFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "docx") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = CVDocumentTextExtractor.extractText(from: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cvParseError = "Couldn't read any text from that file."
            return
        }

        cvParseError = nil
        isParsingCV = true
        Task {
            do {
                let structured = try await CVAutofillService.structureCV(
                    fromText: text, settings: aiSettings,
                    promptOverride: cvAutofillStore.promptOverride(for: .cvSchema)
                )
                cvAutofillStore.structuredCVJSON = structured
                cvAutofillStore.cvFileName = url.lastPathComponent
            } catch {
                cvParseError = error.localizedDescription
            }
            isParsingCV = false
        }
    }

    // MARK: Cover letter

    private var coverLetterSection: some View {
        Section {
            if cvAutofillStore.hasCoverLetter {
                Label(cvAutofillStore.coverLetterFileName ?? "Cover letter saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No reference cover letter set", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose File…", action: chooseCoverLetterFile)
                Spacer()
                if cvAutofillStore.hasCoverLetter {
                    Button("Clear", role: .destructive) { cvAutofillStore.clearCoverLetter() }
                }
            }
            if let coverLetterError {
                CopyableErrorView(message: coverLetterError)
            }
        } header: {
            Text("Reference Cover Letter")
        } footer: {
            Text("Optional \u{2014} a past cover letter of yours, used as a style/tone guide when generating new ones (never copied verbatim). Extracted locally, no AI call needed just to read it.")
                .font(.caption)
        }
    }

    private func chooseCoverLetterFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "docx") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = CVDocumentTextExtractor.extractText(from: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            coverLetterError = "Couldn't read any text from that file."
            return
        }
        coverLetterError = nil
        cvAutofillStore.coverLetterText = text
        cvAutofillStore.coverLetterFileName = url.lastPathComponent
    }

    // MARK: Addresses

    private var addressesSection: some View {
        Section {
            TextField("Title \u{2014} e.g. Home", text: $newAddressTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $newAddressContent)
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button("Add address") {
                cvAutofillStore.addAddress(title: newAddressTitle, content: newAddressContent)
                newAddressTitle = ""
                newAddressContent = ""
            }
            .disabled(newAddressTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newAddressContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if cvAutofillStore.addresses.isEmpty {
                Text("No addresses yet.").foregroundStyle(.secondary)
            } else {
                ForEach(cvAutofillStore.addresses) { address in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(address.title).font(.callout.bold())
                            Text(address.content).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            cvAutofillStore.removeAddress(address)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Addresses")
        } footer: {
            Text("Labeled physical addresses (home, work) \u{2014} used to fill address-shaped form fields during autofill.")
                .font(.caption)
        }
    }

    // MARK: Notes ("Add info")

    private var notesSection: some View {
        Section {
            HStack {
                TextField("Title", text: $newNoteTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("Content", text: $newNoteContent)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    cvAutofillStore.addNote(title: newNoteTitle, content: newNoteContent)
                    newNoteTitle = ""
                    newNoteContent = ""
                }
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newNoteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if cvAutofillStore.notes.isEmpty {
                Text("No notes yet.").foregroundStyle(.secondary)
            } else {
                ForEach(cvAutofillStore.notes) { note in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.callout.bold())
                            Text(note.content).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            cvAutofillStore.removeNote(note)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Add Info")
        } footer: {
            Text("Anything else worth the AI knowing \u{2014} folded into every autofill/cover-letter/tailored-CV prompt alongside your CV.")
                .font(.caption)
        }
    }

    // MARK: Backup

    private var backupSection: some View {
        Section {
            HStack {
                Button("Export backup…", action: exportBackup)
                Button("Import backup…", action: importBackupPrompt)
                Spacer()
            }
            if let backupStatus {
                Text(backupStatus).font(.caption).foregroundStyle(.secondary)
            }
            if let backupError {
                CopyableErrorView(message: backupError)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Exports your CV, cover letter, notes, addresses, saved jobs, Quick Access buttons, and prompt customizations to one JSON file \u{2014} for restoring after a reinstall. Doesn't include API keys, since this feature reuses Maziar's own AI Assistant settings rather than storing separate ones.")
                .font(.caption)
        }
    }

    private func exportBackup() {
        backupError = nil
        guard let data = cvAutofillStore.exportBackupData() else {
            backupError = "Couldn't build the backup file."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cv-autofill-backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            backupStatus = "Exported."
        } catch {
            backupError = error.localizedDescription
        }
    }

    private func importBackupPrompt() {
        backupError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try cvAutofillStore.importBackup(from: data)
            backupStatus = "Imported."
        } catch {
            backupError = error.localizedDescription
        }
    }
}

// MARK: - Ask AI tab

private struct CVAutofillAskAITab: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore

    var body: some View {
        Form {
            Section {
                Picker("Ask AI opens", selection: $cvAutofillStore.askAITarget) {
                    ForEach(CVAutofillAskAITarget.allCases) { target in
                        Text(target.buttonLabel).tag(target)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Ask AI")
            } footer: {
                Text("Which site the panel's \u{201c}Ask ChatGPT\u{201d}/\u{201c}Ask Claude\u{201d} button opens in a small window.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Jobs tab

private struct CVAutofillJobsTab: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @State private var exportError: String?
    @State private var exportStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Applied Jobs").font(.headline)
                Spacer()
                Button("Export Word + JSON…", action: exportJobs)
                    .disabled(cvAutofillStore.savedJobs.isEmpty)
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            if cvAutofillStore.savedJobs.isEmpty {
                Spacer()
                Text("No jobs saved yet \u{2014} use \u{201c}Save this job\u{201d} in the panel.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach($cvAutofillStore.savedJobs) { $job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.title.isEmpty ? "Untitled role" : job.title).font(.callout.bold())
                                    if !job.company.isEmpty {
                                        Text(job.company).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(job.savedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                                    Text(job.link).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    cvAutofillStore.removeSavedJob(job)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            TextField("Results \u{2014} e.g. Interviewed, Rejected, Offer\u{2026}", text: $job.results)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }

            if let exportStatus {
                Text(exportStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let exportError {
                CopyableErrorView(message: exportError).padding(.horizontal)
            }
        }
        .padding(.bottom, 12)
    }

    private func exportJobs() {
        exportError = nil
        exportStatus = nil
        let paragraphs: [DOCXBuilder.Paragraph] = [DOCXBuilder.Paragraph(text: "Applied Jobs", style: .heading)]
            + cvAutofillStore.savedJobs.map { job in
                var lines = [job.title.isEmpty ? "Untitled role" : job.title]
                if !job.company.isEmpty { lines.append(job.company) }
                lines.append(job.link)
                if !job.results.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Results: \(job.results)")
                }
                return DOCXBuilder.Paragraph(text: lines.joined(separator: "\n"))
            }
        do {
            let docxData = try DOCXBuilder.build(title: "Applied Jobs", paragraphs: paragraphs)
            let jsonData = (try? JSONEncoder().encode(cvAutofillStore.savedJobs)) ?? Data()

            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose Folder"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            try docxData.write(to: folder.appendingPathComponent("applied jobs.docx"))
            try jsonData.write(to: folder.appendingPathComponent("applied jobs.json"))
            exportStatus = "Exported to \(folder.lastPathComponent)."
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Quick Access tab

private struct CVAutofillQuickAccessTab: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    @State private var icon = "📄"
    @State private var type: CVAutofillQuickAccessType = .copyText
    @State private var valueText = ""
    @State private var label = ""

    private let iconSuggestions = ["📄", "📎", "🔗", "🌐", "📧", "📞", "🏠", "💼", "🎓", "📝", "⭐"]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Icon", text: $icon)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: $type) {
                        ForEach(CVAutofillQuickAccessType.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }
                }
                HStack(spacing: 4) {
                    ForEach(iconSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { icon = suggestion }
                            .buttonStyle(.bordered)
                    }
                }

                switch type {
                case .copyText:
                    TextField("Text to copy", text: $valueText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                case .copyLink:
                    TextField("https://...", text: $valueText)
                        .textFieldStyle(.roundedBorder)
                case .openFile:
                    HStack {
                        TextField("File path", text: $valueText)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseFile)
                    }
                }
                TextField("Label (optional) \u{2014} shown as a tooltip", text: $label)
                    .textFieldStyle(.roundedBorder)

                Button("Add button") {
                    cvAutofillStore.addQuickAccessItem(icon: icon, type: type, value: valueText, label: label)
                    valueText = ""
                    label = ""
                }
                .disabled(icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Add a Button")
            } footer: {
                Text("Small icon buttons shown in the panel \u{2014} each copies a saved snippet of text or a link, or opens a local file (e.g. a portfolio PDF you reference often).")
                    .font(.caption)
            }

            Section {
                if cvAutofillStore.quickAccessItems.isEmpty {
                    Text("No Quick Access buttons yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(cvAutofillStore.quickAccessItems.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text(item.icon).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label.isEmpty ? item.type.title : item.label).font(.callout)
                                Text(item.value).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                cvAutofillStore.moveQuickAccessItem(item, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            Button {
                                cvAutofillStore.moveQuickAccessItem(item, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == cvAutofillStore.quickAccessItems.count - 1)
                            Button(role: .destructive) {
                                cvAutofillStore.removeQuickAccessItem(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                Text("Your Buttons")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        valueText = url.path
    }
}

// MARK: - Prompts tab

private struct CVAutofillPromptsTab: View {
    var body: some View {
        Form {
            ForEach(CVAutofillService.PromptKey.allCases) { key in
                CVAutofillPromptSection(key: key)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CVAutofillPromptSection: View {
    @EnvironmentObject var cvAutofillStore: CVAutofillStore
    let key: CVAutofillService.PromptKey
    @State private var text = ""
    @State private var didLoad = false

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 100)
            HStack {
                Button("Save") {
                    cvAutofillStore.setPromptOverride(key, text: text)
                }
                Button("Reset to default") {
                    cvAutofillStore.resetPrompt(key)
                    text = key.defaultPrompt
                }
                Spacer()
            }
        } header: {
            Text(key.title)
        } footer: {
            Text(key.subtitle).font(.caption)
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            text = cvAutofillStore.promptOverride(for: key) ?? key.defaultPrompt
        }
    }
}
