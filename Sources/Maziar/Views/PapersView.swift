import SwiftUI
import AppKit

struct PapersView: View {
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var settings: AppSettings
    @State private var selectedPaper: Paper?
    @State private var showNewPaperSheet = false

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
                let topLevel = paperStore.topLevelPapers()
                if topLevel.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(topLevel.enumerated()), id: \.element.id) { index, paper in
                                if index > 0 {
                                    Divider().opacity(0.4)
                                }
                                PaperCard(
                                    paper: paper,
                                    onOpen: { selectedPaper = paper },
                                    onDelete: { paperStore.remove(paper) },
                                    canMoveUp: index > 0,
                                    canMoveDown: index < topLevel.count - 1,
                                    onMoveUp: { paperStore.moveUp(paper) },
                                    onMoveDown: { paperStore.moveDown(paper) },
                                    onOpenChild: { selectedPaper = $0 }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Pinned to the bottom of the page, always in view under the project list.
            Divider().opacity(0.4)
            ProjectsCalendarView(onOpenProject: { selectedPaper = $0 })
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.color(for: .windowBackground))
        .sheet(isPresented: $showNewPaperSheet) {
            NewProjectSheet(
                parentID: nil,
                onCreated: { paper in
                    showNewPaperSheet = false
                    selectedPaper = paper
                },
                onCancel: { showNewPaperSheet = false }
            )
        }
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

    private func startNewPaper() {
        showNewPaperSheet = true
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
    /// Opens a sub-project straight from this card, without going through its parent first.
    let onOpenChild: (Paper) -> Void
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var conferenceStore: ConferenceStore
    @EnvironmentObject var paperStore: PaperStore
    @State private var showDeleteConfirm = false
    @State private var showSubProjects = true

    private var linkedConference: ConferenceEntry? {
        guard let name = paper.conferenceName else { return nil }
        return conferenceStore.conferences.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private var subProjectCount: Int { paperStore.children(of: paper).count }

    private var projectColor: Color? { paperStore.color(of: paper) }

    /// Green normally; red once the next deadline is within 24h (or already past); off once the
    /// paper's been marked rejected (nothing left to race against), and off entirely for a
    /// `.developing` project, which has no venue/deadline workflow to track in the first place.
    private var statusLightColor: Color? {
        guard paper.kind == .paperSubmission, paper.decision != .rejected else { return nil }
        if let date = linkedConference?.nextDeadline?.date {
            let hoursRemaining = date.timeIntervalSinceNow / 3600
            if hoursRemaining <= 24 { return .red }
        }
        return .green
    }

    private var mainRow: some View {
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
                    Image(systemName: paper.kind.icon)
                        .font(.caption)
                        .foregroundStyle(projectColor ?? Color.secondary)
                        .help(paper.kind.displayName)
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
                    if subProjectCount > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showSubProjects.toggle() }
                        } label: {
                            Label("\(subProjectCount)", systemImage: showSubProjects ? "chevron.down" : "square.stack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("\(subProjectCount) sub-project\(subProjectCount == 1 ? "" : "s") \u{2014} click to \(showSubProjects ? "hide" : "show")")
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow
            if showSubProjects && subProjectCount > 0 {
                Divider().opacity(0.4)
                SubProjectBar(parent: paper, onOpen: onOpenChild)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                // A soft wash of the project's color spreading in from the left edge, like light.
                if let projectColor {
                    LinearGradient(colors: [projectColor.opacity(0.22), projectColor.opacity(0)], startPoint: .leading, endPoint: .init(x: 0.45, y: 0.5))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // The glowing line down the left side — drawn outside the clip so its glow spills past the edge.
        .overlay(alignment: .leading) {
            if let projectColor {
                Capsule()
                    .fill(projectColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
                    .shadow(color: projectColor.opacity(0.9), radius: 4)
                    .shadow(color: projectColor.opacity(0.6), radius: 10)
            }
        }
        .confirmationDialog("Delete \"\(paper.title)\"?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A project's sub-projects as a row of cards under it — the same tiles as the Library's group bar —
/// each opening directly, with right-click to rename or change its icon and color.
private struct SubProjectBar: View {
    let parent: Paper
    let onOpen: (Paper) -> Void
    @EnvironmentObject var paperStore: PaperStore
    @EnvironmentObject var settings: AppSettings
    @State private var editing: Paper?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SUB-PROJECTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(paperStore.children(of: parent)) { child in
                        GroupCardButton(
                            title: child.title,
                            systemIcon: child.cardIcon,
                            colorHex: child.iconColorHex,
                            image: nil,
                            tooltip: tooltip(for: child),
                            isSelected: false
                        ) { onOpen(child) }
                        .contextMenu {
                            Button("Open") { onOpen(child) }
                            Button("Rename / Change Icon\u{2026}") { editing = child }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(settings.color(for: .libraryGroupsBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .sheet(item: $editing) { child in
            ProjectIconSheet(paper: child, onSave: { title, icon, colorHex in
                var updated = paperStore.papers.first(where: { $0.id == child.id }) ?? child
                updated.title = title
                updated.iconSystemName = icon
                updated.iconColorHex = colorHex
                paperStore.update(updated)
                editing = nil
            }, onCancel: { editing = nil })
        }
    }

    private func tooltip(for child: Paper) -> String {
        var lines = [child.title, child.kind.displayName]
        if !child.tasks.isEmpty { lines.append("\(child.doneTaskCount)/\(child.tasks.count) tasks done") }
        let nested = paperStore.children(of: child).count
        if nested > 0 { lines.append("\(nested) sub-project\(nested == 1 ? "" : "s")") }
        return lines.joined(separator: "\n")
    }
}
