import SwiftUI
import AppKit

struct PapersView: View {
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @State private var selectedPaper: Paper?
    @State private var showNewPaperSheet = false
    @State private var newPaperTitle = ""
    @State private var pendingProjectPath: String?
    @State private var newPaperProjectError: String?

    var body: some View {
        if let selected = selectedPaper, paperStore.papers.contains(where: { $0.id == selected.id }) {
            PaperDetailView(paper: binding(for: selected), onBack: { selectedPaper = nil })
        } else {
            list
        }
    }

    private var list: some View {
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
                if paperStore.papers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(paperStore.papers.enumerated()), id: \.element.id) { index, paper in
                                if index > 0 {
                                    Divider().opacity(0.4)
                                }
                                PaperCard(
                                    paper: paper,
                                    onOpen: { selectedPaper = paper },
                                    onDelete: { paperStore.remove(paper) },
                                    canMoveUp: index > 0,
                                    canMoveDown: index < paperStore.papers.count - 1,
                                    onMoveUp: { paperStore.moveUp(paper) },
                                    onMoveDown: { paperStore.moveDown(paper) }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
        .sheet(isPresented: $showNewPaperSheet) { newPaperSheet }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects").font(.title2.bold())
                Text("Track a paper end to end: venue, deadline, tasks, and rebuttal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                startNewPaper()
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.color(for: .buttonColor))
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No projects yet").font(.headline)
            Text("Start a project to track its venue, deadline, tasks, and reviewer rebuttal in one place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("New Project") { startNewPaper() }
                .buttonStyle(.borderedProminent)
                .tint(settings.color(for: .buttonColor))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var newPaperSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project").font(.headline)
            TextField("Title", text: $newPaperTitle)
                .textFieldStyle(.roundedBorder)

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
                            onError: { newPaperProjectError = $0 }
                        )
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    Text("Optional \u{2014} it's automatically added to the Editor's project list either way, and you can also attach or create one later from this project's page.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let newPaperProjectError {
                    CopyableErrorView(message: newPaperProjectError)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { showNewPaperSheet = false }
                Button("Create") { createPaper() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func startNewPaper() {
        newPaperTitle = ""
        pendingProjectPath = nil
        newPaperProjectError = nil
        showNewPaperSheet = true
    }

    private func createPaper() {
        let paper = paperStore.add(title: newPaperTitle)
        if let pendingProjectPath {
            var updated = paper
            updated.projectPath = pendingProjectPath
            paperStore.update(updated)
        }
        showNewPaperSheet = false
        selectedPaper = paper
    }

    private func binding(for paper: Paper) -> Binding<Paper> {
        Binding(
            get: { paperStore.papers.first(where: { $0.id == paper.id }) ?? paper },
            set: { paperStore.update($0) }
        )
    }
}

private struct PaperCard: View {
    let paper: Paper
    let onOpen: () -> Void
    let onDelete: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conferenceStore: ConferenceStore
    @State private var showDeleteConfirm = false

    private var linkedConference: ConferenceEntry? {
        guard let name = paper.conferenceName else { return nil }
        return conferenceStore.conferences.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Green normally; red once the next deadline is within 24h (or already past); off once the
    /// paper's been marked rejected, since there's nothing left to race against at that point.
    private var statusLightColor: Color? {
        guard paper.decision != .rejected else { return nil }
        if let date = linkedConference?.nextDeadline?.date {
            let hoursRemaining = date.timeIntervalSinceNow / 3600
            if hoursRemaining <= 24 { return .red }
        }
        return .green
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(!canMoveUp)
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(!canMoveDown)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let statusLightColor {
                        BlinkingDot(color: statusLightColor, size: 8)
                    }
                    Text(paper.title).font(.headline)
                }
                HStack(spacing: 12) {
                    if let conferenceName = paper.conferenceName, !conferenceName.isEmpty {
                        Label(conferenceName, systemImage: "calendar.badge.clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let next = linkedConference?.nextDeadline {
                        Text("Next: \(next.label) \u{2014} \(next.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? (next.rawText ?? "TBA"))")
                            .font(.caption)
                            .foregroundStyle(settings.color(for: .buttonColor))
                    } else if let deadline = paper.independentDeadlineString, !deadline.isEmpty {
                        Text("Deadline: \(deadline)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !paper.tasks.isEmpty {
                        Text("\(paper.doneTaskCount)/\(paper.tasks.count) tasks done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .confirmationDialog("Delete \"\(paper.title)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }
}
