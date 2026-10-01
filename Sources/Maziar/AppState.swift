import Foundation

enum Route: Equatable {
    case projectList
    case editor(Project)
}

/// The top-level destination shown by the outer sidebar (visible whenever `route == .projectList`,
/// hidden once a project is open — the editor takes the whole window like Overleaf's does).
enum AppSection: String, CaseIterable, Identifiable {
    case papers
    case projects
    case conferences
    case journals
    case library
    case diagrams

    var id: String { rawValue }

    var title: String {
        switch self {
        case .papers: return "Projects"
        case .projects: return "Editor"
        case .conferences: return "Conferences"
        case .journals: return "Journals"
        case .library: return "Library"
        case .diagrams: return "Diagrams"
        }
    }

    var icon: String {
        switch self {
        case .papers: return "doc.badge.clock"
        case .projects: return "doc.richtext"
        case .conferences: return "calendar.badge.clock"
        case .journals: return "book.closed"
        case .library: return "books.vertical"
        case .diagrams: return "flowchart"
        }
    }
}

/// Which Settings tab is selected — set right before calling `openSettings()` from a page's own
/// "Setting" button so the window opens directly on that page's settings instead of always
/// landing on Appearance, and left as-is (SwiftUI's `TabView(selection:)` keeps whatever the user
/// last clicked) the rest of the time.
enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case latex
    case ai
    case conferences
    case journals
    case library
    case customPages
    case accounts
    case backup
    case about

    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    @Published var route: Route = .projectList
    @Published var section: AppSection = .papers
    /// Non-nil when a user-added custom page (Settings → Custom Pages) is the active sidebar
    /// selection instead of one of the fixed `AppSection` cases — kept separate from `section`
    /// since `AppSection` is a fixed, `CaseIterable` enum that can't grow a case per custom page.
    /// Selecting any built-in section clears this back to nil.
    @Published var selectedCustomPageID: UUID?
    @Published var settingsTab: SettingsTab = .appearance

    func open(_ project: Project) {
        route = .editor(project)
    }

    func closeProject() {
        route = .projectList
    }
}
