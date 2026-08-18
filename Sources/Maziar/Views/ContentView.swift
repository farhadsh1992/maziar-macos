import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Group {
            switch appState.route {
            case .projectList:
                HStack(spacing: 0) {
                    OuterSectionSidebar()
                    Divider().opacity(0.4)
                    Group {
                        switch appState.section {
                        case .papers:
                            PapersView()
                        case .projects:
                            ProjectListView()
                        case .conferences:
                            ConferencesView()
                        case .journals:
                            JournalsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
private struct OuterSectionSidebar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppSection.allCases) { section in
                Button {
                    appState.section = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.icon)
                            .font(.system(size: 17))
                        Text(section.title)
                            .font(.system(size: 9.5))
                            .lineLimit(1)
                    }
                    .frame(width: 60, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(appState.section == section ? settings.color(for: .buttonColor) : .secondary)
                .background(
                    appState.section == section
                        ? settings.color(for: .buttonColor).opacity(0.15)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help(section.title)
            }
            Spacer()
        }
        .padding(.top, 14)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(settings.color(for: .sidebarBackground))
    }
}
