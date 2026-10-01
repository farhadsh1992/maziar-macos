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

    @State private var newTaskText = ""
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
    @State private var newLinkText = ""
    @State private var showNewSubProjectSheet = false
    @State private var selectedChild: Paper?

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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch paper.kind {
                    case .paperSubmission:
                        projectSection
                        venueSection
                        tasksSection
                        reviewerSection
                        decisionSection
                        if paper.decision == .accepted {
                            generateSection
                            codePageSection
                        }
                    case .developing:
                        ideaSection
                        linksSection
                        tasksSection
                    }
                    libraryGroupSection
                    subProjectsSection
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
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
                HStack {
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
                    Spacer()
                    Button {
                        removeTask(task)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("New task", text: $newTaskText, prompt: Text("e.g. Run ablation study"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                Button("Add", action: addTask)
                    .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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

    // MARK: - Idea & links (developing projects)

    private var ideaSection: some View {
        SectionCard(title: "Idea", icon: "lightbulb") {
            TextEditor(text: Binding(get: { paper.ideaDescription }, set: { paper.ideaDescription = $0 }))
                .frame(minHeight: 100)
                .font(.system(size: 12))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private var linksSection: some View {
        SectionCard(title: "Links & References", icon: "link") {
            Text("GitHub Repo").font(.caption).foregroundStyle(.secondary)
            TextField(
                "https://github.com/...",
                text: Binding(get: { paper.githubRepoURLString ?? "" }, set: { paper.githubRepoURLString = $0.isEmpty ? nil : $0 })
            )
            .textFieldStyle(.roundedBorder)

            Divider()

            ForEach(Array(paper.links.enumerated()), id: \.offset) { index, link in
                HStack {
                    Text(link).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button {
                        removeLink(at: index)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Add a link or reference", text: $newLinkText, prompt: Text("e.g. https://... or a citation"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addLink)
                Button("Add", action: addLink)
                    .disabled(newLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addLink() {
        let trimmed = newLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paper.links.append(trimmed)
        newLinkText = ""
    }

    private func removeLink(at index: Int) {
        guard paper.links.indices.contains(index) else { return }
        paper.links.remove(at: index)
    }

    // MARK: - Library group

    private var linkedLibraryGroup: LibraryGroup? {
        guard let id = paper.libraryGroupID else { return nil }
        return libraryStore.group(id)
    }

    private var libraryGroupSection: some View {
        SectionCard(title: "Library Group", icon: "books.vertical") {
            if let group = linkedLibraryGroup {
                HStack {
                    Label(group.name, systemImage: group.iconSystemName)
                        .foregroundStyle(group.iconColorHex.flatMap(Color.init(hex:)) ?? .secondary)
                    Spacer()
                    Button("Reveal in Finder") {
                        if let dir = libraryStore.directoryURL(for: group) {
                            NSWorkspace.shared.open(dir)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Text("Reference papers you collect into \u{201c}\(group.name)\u{201d} on the Library page show up here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("No library group yet — connect a library folder first.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create Library Group") { createLibraryGroup() }
                        .buttonStyle(.bordered)
                        .disabled(libraryStore.folderPath == nil)
                }
            }
        }
    }

    private func createLibraryGroup() {
        guard let created = try? libraryStore.createGroup(name: paper.title) else { return }
        paper.libraryGroupID = created.id
    }

    // MARK: - Sub-projects

    private var subProjectsSection: some View {
        SectionCard(title: "Sub-Projects", icon: "square.stack") {
            let children = paperStore.children(of: paper)
            if children.isEmpty {
                Text("No sub-projects yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(children) { child in
                    HStack {
                        Image(systemName: child.kind.icon).font(.caption).foregroundStyle(.secondary)
                        Text(child.title).font(.subheadline)
                        Spacer()
                        if !child.tasks.isEmpty {
                            Text("\(child.doneTaskCount)/\(child.tasks.count) tasks")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button("Open") { selectedChild = child }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }
            Button {
                showNewSubProjectSheet = true
            } label: {
                Label("Add Sub-Project", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
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

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
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
