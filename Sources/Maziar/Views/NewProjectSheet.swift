import SwiftUI

/// Creates a new project — used both for a top-level project (`parentID: nil`, from the Projects
/// page) and a sub-project nested inside another one (`parentID: <parent's id>`, from
/// `PaperDetailView`'s Sub-Projects section) — the same sheet either way, just parameterized by
/// what the new project's parent should be. Also creates a matching Library group for the new
/// project (skipped, not forced, when no library folder is connected yet), so every project —
/// top-level or nested — gets somewhere to collect its own reference papers.
struct NewProjectSheet: View {
    let parentID: UUID?
    var onCreated: (Paper) -> Void
    var onCancel: () -> Void

    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var libraryStore: LibraryStore

    @State private var title = ""
    @State private var kind: ProjectKind = .paperSubmission
    @State private var pendingProjectPath: String?
    @State private var projectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(parentID == nil ? "New Project" : "New Sub-Project").font(.headline)

            Picker("Kind", selection: $kind) {
                ForEach(ProjectKind.allCases) { candidate in
                    Label(candidate.displayName, systemImage: candidate.icon).tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            if kind == .paperSubmission {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LaTeX project").font(.caption.bold())
                    if let pendingProjectPath {
                        HStack {
                            Label(URL(fileURLWithPath: pendingProjectPath).lastPathComponent, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Spacer()
                            Button("Remove") { self.pendingProjectPath = nil }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            ProjectCreationMenu(
                                label: "Add LaTeX Project",
                                onCreated: { pendingProjectPath = $0.path },
                                onError: { projectError = $0 }
                            )
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        Text("Optional \u{2014} it's automatically added to the Editor's project list either way, and you can also attach or create one later from this project's page.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let projectError {
                        CopyableErrorView(message: projectError)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func create() {
        var paper = paperStore.add(title: title, kind: kind, parentID: parentID)
        if let pendingProjectPath {
            paper.projectPath = pendingProjectPath
        }
        if let created = try? libraryStore.createGroup(name: paper.title) {
            paper.libraryGroupID = created.id
        }
        paperStore.update(paper)
        onCreated(paper)
    }
}
