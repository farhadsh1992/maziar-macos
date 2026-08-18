import SwiftUI
import AppKit

struct ShareSheetView: View {
    @EnvironmentObject var store: ProjectStore
    @StateObject private var vm: ShareViewModel
    @Environment(\.dismiss) private var dismiss
    var onProjectMoved: (Project) -> Void

    init(project: Project, onProjectMoved: @escaping (Project) -> Void) {
        _vm = StateObject(wrappedValue: ShareViewModel(project: project))
        self.onProjectMoved = onProjectMoved
    }

    var body: some View {
        Form {
            cloudFolderSection
            gitSection
            overleafSection

            if !vm.log.isEmpty {
                Section("Activity") {
                    ScrollView {
                        Text(vm.log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 110)
                }
            }
            if let error = vm.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)
        }
    }

    // MARK: - Cloud folder sync

    private var cloudFolderSection: some View {
        Section {
            Text("Put this project's folder in a cloud-synced location. Everyone with access to that folder (via Dropbox/Drive/iCloud sharing) gets near-real-time file sync — no live cursors, and simultaneous edits become a \"conflicted copy\" from the sync provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let candidates = store.cloudFolderCandidates()
            if candidates.isEmpty {
                Text("No iCloud Drive, Dropbox, or Google Drive folder was found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates, id: \.url) { candidate in
                    Button("Move Project to \(candidate.name)") {
                        moveProject(into: candidate.url)
                    }
                }
            }
            Button("Choose Folder...") { chooseFolderAndMove() }
        } header: {
            Text("Cloud Folder Sync")
        }
    }

    private func moveProject(into target: URL) {
        do {
            let moved = try store.moveProject(vm.project, into: target)
            onProjectMoved(moved)
            NSWorkspace.shared.activateFileViewerSelecting([moved.url])
            dismiss()
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func chooseFolderAndMove() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveProject(into: url)
    }

    // MARK: - Git

    private var gitSection: some View {
        Section {
            if vm.isGitRepo {
                Label("Git repository (\(vm.currentBranch ?? "no branch"))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Initialize Git Repository") { Task { await vm.initGitRepo() } }
            }

            HStack {
                TextField("Remote URL (origin)", text: $vm.originURL, prompt: Text("https://github.com/user/repo.git"))
                    .textFieldStyle(.roundedBorder)
                Button("Set") { Task { await vm.setOrigin() } }
                    .disabled(vm.originURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Button("Push") { Task { await vm.push() } }
                Button("Pull") { Task { await vm.pull() } }
                if vm.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(!vm.isGitRepo || vm.originURL.isEmpty || vm.isBusy)
        } header: {
            Text("Git Collaboration")
        } footer: {
            Text("Collaborators clone/pull the same remote and push their commits. Real history and mergeable diffs, but not simultaneous live editing.")
                .font(.caption)
        }
    }

    // MARK: - Overleaf Git Bridge

    private var overleafSection: some View {
        Section {
            if vm.overleafLinked {
                Label("Linked to Overleaf project \(vm.overleafProjectId)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            TextField("Overleaf Project ID", text: $vm.overleafProjectId,
                      prompt: Text("from the Overleaf project URL"))
                .textFieldStyle(.roundedBorder)
            SecureField("Overleaf Git Token", text: $vm.overleafToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button(vm.overleafLinked ? "Update Link" : "Link Project") { Task { await vm.linkOverleaf() } }
                Button("Pull from Overleaf") { Task { await vm.pullFromOverleaf() } }
                    .disabled(!vm.overleafLinked)
                Button("Push to Overleaf") { Task { await vm.pushToOverleaf() } }
                    .disabled(!vm.overleafLinked)
                if vm.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        } header: {
            Text("Overleaf Git Bridge")
        } footer: {
            Text("Requires an Overleaf paid plan with Git integration. Get the project ID from the Overleaf project's URL, and generate a git token in Overleaf \u{2192} Account Settings \u{2192} Git. This syncs on demand (pull/push) — it is not simultaneous live typing with Overleaf's own web editor, which has no public API for that. The token is stored in the macOS Keychain, not in this project's files.")
                .font(.caption)
        }
    }
}
