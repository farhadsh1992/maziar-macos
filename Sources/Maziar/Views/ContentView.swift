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
    @State private var hasActivatedOpenPrism = false
    @State private var activatedCustomPageIDs: Set<UUID> = []

    var body: some View {
        Group {
            switch appState.route {
            case .projectList:
                HStack(spacing: 0) {
                    OuterSectionSidebar()
                    Divider().opacity(0.4)
                    ZStack {
                        if appState.selectedCustomPageID == nil && appState.section != .diagrams && appState.section != .openPrism {
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
                            case .diagrams, .openPrism:
                                EmptyView() // unreachable; handled below, kept permanently mounted
                            }
                        }

                        if hasActivatedDiagrams {
                            let isActive = appState.selectedCustomPageID == nil && appState.section == .diagrams
                            DiagramsView()
                                .opacity(isActive ? 1 : 0)
                                .allowsHitTesting(isActive)
                        }

                        if hasActivatedOpenPrism {
                            let isActive = appState.selectedCustomPageID == nil && appState.section == .openPrism
                            OpenPrismView()
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
                        if newValue == .openPrism { hasActivatedOpenPrism = true }
                    }
                    .onChange(of: appState.selectedCustomPageID) { _, newValue in
                        if let newValue { activatedCustomPageIDs.insert(newValue) }
                    }
                    .onAppear {
                        if appState.section == .diagrams { hasActivatedDiagrams = true }
                        if appState.section == .openPrism { hasActivatedOpenPrism = true }
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
    @ObservedObject private var drive = GoogleDriveAccount.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showAccountMenu = false

    var body: some View {
        VStack(spacing: 4) {
            accountButton
            Divider().padding(.vertical, 4)
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

    /// Top of the rail: the account's picture and name. Clicking it opens a small menu — account
    /// settings, update from Google Drive, and save this Mac's setup/settings to Google Drive.
    private var accountButton: some View {
        Button {
            showAccountMenu.toggle()
        } label: {
            VStack(spacing: 4) {
                AccountAvatar(size: 28)
                    .overlay {
                        if drive.isBusy { ProgressView().controlSize(.small).background(Circle().fill(.ultraThinMaterial)) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Red: the last sync failed. Orange: not signed in, so nothing is syncing.
                        if drive.errorMessage != nil || !drive.isSignedIn {
                            Circle().fill(drive.errorMessage != nil ? Color.red : Color.orange).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }
                    }
                Text(accountLabel)
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 60, height: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(accountHelp)
        .popover(isPresented: $showAccountMenu, arrowEdge: .trailing) { accountMenu }
    }

    private var accountLabel: String {
        let name = drive.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Account" : name
    }

    private var accountMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AccountAvatar(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountLabel).font(.headline)
                    Text(drive.isSignedIn ? (drive.email ?? "Signed in") : "Not signed in to Google")
                        .font(.caption).foregroundStyle(.secondary)
                    if drive.isSignedIn {
                        Text(drive.lastSync.map { "Last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced yet")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            menuRow("Account settings", systemImage: "gearshape") {
                showAccountMenu = false
                appState.settingsTab = .accounts
                openSettings()
            }
            menuRow("Update from Google Drive", systemImage: "arrow.triangle.2.circlepath", enabled: drive.isSignedIn && !drive.isBusy) {
                showAccountMenu = false
                Task { await drive.syncNow() }
            }
            menuRow("Save setup & settings to Google Drive", systemImage: "icloud.and.arrow.up", enabled: drive.isSignedIn && !drive.isBusy) {
                showAccountMenu = false
                Task { await drive.upload() }
            }
            if !drive.isSignedIn {
                Text("Sign in with Google in Account settings to turn on syncing.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = drive.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 270)
    }

    private func menuRow(_ title: String, systemImage: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var accountHelp: String {
        guard drive.isSignedIn else { return "Account \u{2014} sign in with Google to sync Maziar across your Macs" }
        let who = drive.email.map { "Signed in as \($0). " } ?? ""
        let when = drive.lastSync.map { "Last synced \($0.formatted(date: .omitted, time: .shortened))." } ?? "Not synced yet."
        return who + when + " Click for the account menu."
    }
}
