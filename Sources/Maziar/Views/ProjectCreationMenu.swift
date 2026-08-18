import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reusable "add a LaTeX project" menu — the same set of options as the Editor page's own "New
/// Project" button (blank/import/templates/example), plus optionally a way to pick a project
/// that's already in the Editor's recents list without browsing the filesystem again. Used
/// wherever a screen needs to create or attach a project (Projects list, a project's own page)
/// without re-implementing `ProjectListView`'s whole menu.
struct ProjectCreationMenu: View {
    @EnvironmentObject var store: ProjectStore
    var label: String = "New Project"
    var showRecents: Bool = true
    var onCreated: (Project) -> Void
    var onError: (String) -> Void

    @State private var showNewProjectSheet = false
    @State private var newProjectName = "Untitled Project"
    @State private var pendingTemplateKey = "article"
    @State private var showGitHubImportSheet = false
    @State private var gitHubURLText = ""
    @State private var showOverleafImportSheet = false
    @State private var overleafProjectIdText = ""
    @State private var overleafTokenText = ""
    @State private var isImportingOverleaf = false

    var body: some View {
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
            } label: {
                Label("Templates", systemImage: "square.grid.2x2")
            }

            Button {
                startNewProject(templateKey: "example", defaultName: "Example Project")
            } label: {
                Label("Example Project", systemImage: "sparkles")
            }

            Divider()

            Button {
                browseExisting()
            } label: {
                Label("Browse for Existing Folder...", systemImage: "folder")
            }

            if showRecents && !store.recents.isEmpty {
                Menu {
                    ForEach(store.recents) { project in
                        Button(project.name) { onCreated(project) }
                    }
                } label: {
                    Label("Choose from Editor's Recents", systemImage: "clock")
                }
            }
        } label: {
            Label(label, systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .sheet(isPresented: $showNewProjectSheet) { newProjectSheet }
        .sheet(isPresented: $showGitHubImportSheet) { gitHubImportSheet }
        .sheet(isPresented: $showOverleafImportSheet) { overleafImportSheet }
    }

    // MARK: - Blank / template

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createProject)
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
            let project = try store.createProject(named: newProjectName, in: store.defaultProjectsDirectory(), templateKey: pendingTemplateKey)
            showNewProjectSheet = false
            onCreated(project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Zip / document import

    private func importZip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            onCreated(try store.importZip(from: url, into: store.defaultProjectsDirectory()))
        } catch {
            onError(error.localizedDescription)
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
            onCreated(try store.importDocument(from: url, into: store.defaultProjectsDirectory()))
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - GitHub

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

    private func cloneGitHub() {
        do {
            let project = try store.cloneGitRepo(urlString: gitHubURLText, into: store.defaultProjectsDirectory())
            showGitHubImportSheet = false
            onCreated(project)
        } catch {
            onError(error.localizedDescription)
        }
    }

    // MARK: - Overleaf

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
                let project = try await store.cloneOverleafProject(projectId: id, token: token, into: store.defaultProjectsDirectory())
                isImportingOverleaf = false
                showOverleafImportSheet = false
                onCreated(project)
            } catch {
                isImportingOverleaf = false
                onError(error.localizedDescription)
            }
        }
    }

    // MARK: - Browse existing

    private func browseExisting() {
        guard let project = store.openProjectPicker() else { return }
        onCreated(project)
    }
}
