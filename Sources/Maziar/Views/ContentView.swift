import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    /// Tracks which "holds a live embedded WKWebView session" destinations have been visited at
    /// least once this session — Diagrams, and each individual custom page. Each such destination,
    /// once first activated, stays permanently mounted in the `ZStack` below (just hidden via
    /// opacity/hit-testing when not the current selection) rather than being destroyed and
    /// recreated by a plain `switch`/`if` branch the way the lighter native pages still are —
    /// destroying `DiagramsView`/`CustomWebPageView` on every navigation away was tearing down
    /// their embedded `WKWebView`s, forcing a full reload every time the user navigated back,
    /// reported from real usage as "every time move between them is refresh." The native pages
    /// (Papers/Projects/Conferences/Journals/Library) don't hold that kind of expensive, stateful
    /// session, so they're left as a plain conditional switch — cheap to recreate, no reason to
    /// keep them alive off-screen.
    @State private var hasActivatedDiagrams = false
    @State private var activatedCustomPageIDs: Set<UUID> = []

    var body: some View {
        Group {
            switch appState.route {
            case .projectList:
                HStack(spacing: 0) {
                    OuterSectionSidebar()
                    Divider().opacity(0.4)
                    ZStack {
                        if appState.selectedCustomPageID == nil && appState.section != .diagrams {
                            switch appState.section {
                            case .papers:
                                PapersView()
                            case .projects:
                                ProjectListView()
                            case .conferences:
                                ConferencesView()
                            case .journals:
                                JournalsView()
                            case .library:
                                LibraryView()
                            case .diagrams:
                                EmptyView() // unreachable; handled below, kept permanently mounted
                            }
                        }

                        if hasActivatedDiagrams {
                            let isActive = appState.selectedCustomPageID == nil && appState.section == .diagrams
                            DiagramsView()
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                        }

                        ForEach(Array(activatedCustomPageIDs), id: \.self) { pageID in
                            if let page = settings.customPages.first(where: { $0.id == pageID }) {
                                let isActive = appState.selectedCustomPageID == pageID
                                CustomWebPageView(page: page)
                                    .opacity(isActive ? 1 : 0)
                                    .allowsHitTesting(isActive)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: appState.section) { _, newValue in
                        if newValue == .diagrams { hasActivatedDiagrams = true }
                    }
                    .onChange(of: appState.selectedCustomPageID) { _, newValue in
                        if let newValue { activatedCustomPageIDs.insert(newValue) }
                    }
                    .onAppear {
                        if appState.section == .diagrams { hasActivatedDiagrams = true }
                        if let id = appState.selectedCustomPageID { activatedCustomPageIDs.insert(id) }
                    }
                }
            case .editor(let project):
                ProjectEditorView(project: project)
                    .id(project.path)
            }
        }
        // Cascades to every plain Text in the app (titles, labels, deadlines, etc.) so they're
        // all copyable without annotating each one individually — doesn't affect TextField/
        // TextEditor (already selectable) or button tap targets.
        .textSelection(.enabled)
    }
}

/// Persistent left icon rail for switching between the app's top-level sections. Only shown at
/// the dashboard level — once a project is open, the editor takes the whole window (Overleaf-like).
/// Below the fixed `AppSection` buttons, also lists any user-added custom pages (Settings → Custom
/// Pages) that have "Show in Sidebar" turned on.
private struct OuterSectionSidebar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppSection.allCases.filter { !settings.hiddenSections.contains($0) }) { section in
                let isSelected = appState.selectedCustomPageID == nil && appState.section == section
                // A custom icon color, when set, is the icon's own identity color and stays visible
                // whether or not the section is currently selected — same pattern as custom pages'
                // own `resolvedColor` below.
                let resolvedColor = settings.sectionIconColor(section)
                    ?? (isSelected ? settings.color(for: .buttonColor) : .secondary)
                Button {
                    appState.section = section
                    appState.selectedCustomPageID = nil
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: settings.icon(for: section))
                            .font(.system(size: 17))
                        Text(section.title)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                    }
                    .frame(width: 60, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(resolvedColor)
                .background(
                    isSelected
                        ? settings.color(for: .buttonColor).opacity(0.15)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help(section.title)
            }

            let sidebarPages = settings.customPages.filter { $0.showInSidebar }
            if !sidebarPages.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(sidebarPages) { page in
                    let isSelected = appState.selectedCustomPageID == page.id
                    // A custom icon color, when set, is the icon's own identity color and stays
                    // visible whether or not the page is currently selected — the background pill
                    // below is what actually signals "this is the active page," independent of tint.
                    let resolvedColor = page.iconColorHex.flatMap(Color.init(hex:))
                        ?? (isSelected ? settings.color(for: .buttonColor) : .secondary)
                    Button {
                        appState.selectedCustomPageID = page.id
                    } label: {
                        VStack(spacing: 4) {
                            if let imageData = page.iconImageData, let nsImage = NSImage(data: imageData) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Image(systemName: page.iconSystemName)
                                    .font(.system(size: 17))
                            }
                            Text(page.name)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                        }
                        .frame(width: 60, height: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(resolvedColor)
                    .background(
                        isSelected
                            ? settings.color(for: .buttonColor).opacity(0.15)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(page.name)
                }
            }

            Spacer()
        }
        .padding(.top, 14)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(settings.color(for: .sidebarBackground))
    }
}
