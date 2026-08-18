import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProjectListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @State private var searchText = ""
    @State private var showNewProjectSheet = false
    @State private var newProjectName = "Untitled Project"
    @State private var pendingTemplateKey = "article"
    @State private var showGitHubImportSheet = false
    @State private var gitHubURLText = ""
    @State private var showOverleafImportSheet = false
    @State private var overleafProjectIdText = ""
    @State private var overleafTokenText = ""
    @State private var isImportingOverleaf = false
    @State private var importError: String?
    @State private var institution: String? = UserDefaults.standard.string(forKey: "maziar.institution")
    @State private var showAffiliationPrompt = false
    @State private var affiliationText = ""

    private var filtered: [Project] {
        guard !searchText.isEmpty else { return store.recents }
        return store.recents.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                ZStack {
                    if let logo = AppBranding.logo {
                        logo
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 520)
                            .opacity(0.05)
                            .allowsHitTesting(false)
                    }
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(settings.color(for: .windowBackground))
        .sheet(isPresented: $showNewProjectSheet) { newProjectSheet }
        .sheet(isPresented: $showGitHubImportSheet) { gitHubImportSheet }
        .sheet(isPresented: $showOverleafImportSheet) { overleafImportSheet }
        .sheet(isPresented: $showAffiliationPrompt) { affiliationSheet }
        .alert("Import Failed", isPresented: .constant(importError != nil), actions: {
            Button("OK") { importError = nil }
        }, message: {
            Text(importError ?? "")
        })
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(icon: "folder.fill", title: "Projects", active: true)
                sidebarRow(icon: "doc.text", title: "Your projects", indent: true)
                sidebarRow(icon: "person.2", title: "Shared with you", indent: true)
                sidebarRow(icon: "archivebox", title: "Archived projects", indent: true)
            }
            .padding(.top, 14)

            Divider().opacity(0.3).padding(.vertical, 12).padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("ORGANIZE TAGS")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                sidebarRow(icon: "plus", title: "New tag")
            }

            Spacer()

            affiliationCard
                .padding(12)

            Divider().opacity(0.3)

            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(icon: "trash", title: "Trash")
                sidebarRow(icon: "questionmark.circle", title: "Help")
                sidebarRow(icon: "person.crop.circle", title: "Account")
            }
            .padding(.bottom, 10)
        }
        .background(settings.color(for: .sidebarBackground))
    }

    private func sidebarRow(icon: String, title: String, active: Bool = false, indent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
            Text(title).font(.system(size: 12.5))
            Spacer()
        }
        .padding(.leading, indent ? 28 : 16)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(active ? settings.color(for: .buttonColor).opacity(0.18) : Color.clear)
        .foregroundStyle(active ? settings.color(for: .buttonColor) : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
    }

    private var affiliationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let institution {
                Text("Affiliated with").font(.caption2).foregroundStyle(.secondary)
                Text(institution).font(.caption.bold())
            } else {
                Text("Are you affiliated with an institution?")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add affiliation") { showAffiliationPrompt = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var affiliationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add affiliation").font(.headline)
            Text("Stored locally on this Mac only.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Institution name", text: $affiliationText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showAffiliationPrompt = false }
                Button("Save") {
                    let trimmed = affiliationText.trimmingCharacters(in: .whitespacesAndNewlines)
                    institution = trimmed.isEmpty ? nil : trimmed
                    UserDefaults.standard.set(institution, forKey: "maziar.institution")
                    showAffiliationPrompt = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                BrandMark(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maziar")
                        .font(.title2.bold())
                    Text("Your LaTeX projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search projects...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 220)

                Button {
                    if let project = store.openProjectPicker() {
                        appState.open(project)
                    }
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }

                newProjectMenu

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .padding(20)
    }

    private var newProjectMenu: some View {
        Menu {
            Button {
                startNewProject(templateKey: "article")
            } label: {
                Label("Blank Project", systemImage: "doc")
            }

            Menu {
                Button("Existing Project (.zip)") { importZip() }
                Button("Word Document (.docx)") { importDocument(extensions: ["docx", "doc"]) }
                Button("Markdown Document (.md)") { importDocument(extensions: ["md", "markdown"]) }
                Button("GitHub Repo") { showGitHubImportSheet = true }
                Button("Overleaf Project") { showOverleafImportSheet = true }
            } label: {
                Label("Import", systemImage: "tray.and.arrow.down")
            }

            Menu {
                Button("Article") { startNewProject(templateKey: "article") }
                Button("Report") { startNewProject(templateKey: "report") }
                Button("Beamer Presentation") { startNewProject(templateKey: "beamer") }
                Button("CV / Resume") { startNewProject(templateKey: "cv") }
                Divider()
                Button("More Templates...") { }
                    .disabled(true)
            } label: {
                Label("Templates", systemImage: "square.grid.2x2")
            }

            Button {
                startNewProject(templateKey: "example", defaultName: "Example Project")
            } label: {
                Label("Example Project", systemImage: "sparkles")
            }
        } label: {
            Label("New Project", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonStyle(.borderedProminent)
        .tint(settings.color(for: .buttonColor))
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("TITLE").frame(width: 300, alignment: .leading)
                    Text("LOCATION").frame(maxWidth: .infinity, alignment: .leading)
                    Text("LAST OPENED").frame(width: 150, alignment: .leading)
                    Spacer().frame(width: 30)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 8)

                ForEach(filtered) { project in
                    ProjectRow(
                        project: project,
                        onOpen: { appState.open(project) },
                        onRemove: { store.remove(project) }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { appState.open(project) }
                    .contextMenu {
                        Button("Open") { appState.open(project) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([project.url])
                        }
                        Divider()
                        Button("Download as Zip...") { downloadZip(project) }
                        Button("Download PDF...") { downloadPDF(project) }
                        Divider()
                        Button("Remove from Recents", role: .destructive) {
                            store.remove(project)
                        }
                    }
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No projects yet").font(.headline)
            Text("Create a new project or open an existing LaTeX folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - New project sheet

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { createProject() }
            HStack {
                Spacer()
                Button("Cancel") { showNewProjectSheet = false }
                Button("Create") { createProject() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func startNewProject(templateKey: String, defaultName: String = "Untitled Project") {
        pendingTemplateKey = templateKey
        newProjectName = defaultName
        showNewProjectSheet = true
    }

    private func createProject() {
        do {
            let project = try store.createProject(
                named: newProjectName,
                in: store.defaultProjectsDirectory(),
                templateKey: pendingTemplateKey
            )
            showNewProjectSheet = false
            appState.open(project)
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Import actions

    private var gitHubImportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from GitHub").font(.headline)
            TextField("Repository URL", text: $gitHubURLText, prompt: Text("https://github.com/user/repo.git"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showGitHubImportSheet = false }
                Button("Clone") { cloneGitHub() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var overleafImportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Overleaf").font(.headline)
            Text("Requires an Overleaf paid plan with Git integration enabled. Find the project ID in the Overleaf project's URL, and generate a git token under Overleaf \u{2192} Account Settings \u{2192} Git.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Overleaf Project ID", text: $overleafProjectIdText, prompt: Text("e.g. 64f1b2c3a1b2c3d4e5f6a7b8"))
                .textFieldStyle(.roundedBorder)
            SecureField("Overleaf Git Token", text: $overleafTokenText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showOverleafImportSheet = false }
                if isImportingOverleaf {
                    ProgressView().controlSize(.small)
                }
                Button("Import") { importOverleaf() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImportingOverleaf)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func importOverleaf() {
        let id = overleafProjectIdText
        let token = overleafTokenText
        isImportingOverleaf = true
        Task {
            do {
                let project = try await store.cloneOverleafProject(
                    projectId: id, token: token, into: store.defaultProjectsDirectory()
                )
                isImportingOverleaf = false
                showOverleafImportSheet = false
                appState.open(project)
            } catch {
                isImportingOverleaf = false
                importError = error.localizedDescription
            }
        }
    }

    private func importZip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try store.importZip(from: url, into: store.defaultProjectsDirectory())
            appState.open(project)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importDocument(extensions: [String]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try store.importDocument(from: url, into: store.defaultProjectsDirectory())
            appState.open(project)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func cloneGitHub() {
        do {
            let project = try store.cloneGitRepo(urlString: gitHubURLText, into: store.defaultProjectsDirectory())
            showGitHubImportSheet = false
            appState.open(project)
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - Downloads

    private func downloadZip(_ project: Project) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(project.name).zip"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportZip(project, to: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func downloadPDF(_ project: Project) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(project.name).pdf"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportPDF(project, to: url)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let onOpen: () -> Void
    let onRemove: () -> Void
    @EnvironmentObject var settings: AppSettings
    @State private var showRemoveConfirm = false

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(settings.color(for: .buttonColor))
                Text(project.name).lineLimit(1)
            }
            .frame(width: 300, alignment: .leading)

            Text(project.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(project.lastOpened, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 10) {
                Button(action: onOpen) {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.plain)
                .help("Open")

                Button {
                    showRemoveConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove from list (keeps the folder on disk)")
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .confirmationDialog(
            "Remove \"\(project.name)\" from your projects list?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from List", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes it from Maziar's list — the project folder stays on disk.")
        }
    }
}
