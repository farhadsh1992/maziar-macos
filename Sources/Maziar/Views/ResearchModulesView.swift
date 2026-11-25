import SwiftUI

/// Hosts the two research routes on the same localhost server as Numenor.
struct ResearchModulesView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var server = NumenorServer.shared
    @State private var sourceError: String?

    private struct Source: Encodable {
        let folder: String?
        let entries: [LibraryEntry]
        let groups: [Group]

        struct Group: Encodable {
            let id: UUID
            let name: String
            let folderName: String
            let archived: Bool?
            let subgroups: [LibrarySubgroup]?
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let sourceError {
                Text(sourceError)
                    .font(.caption)
                    .padding(6)
            }
            switch server.state {
            case .running(let url):
                ScholarBrowserView(
                    initialURL: url.appendingPathComponent("library2"),
                    onViewCreated: { _ in },
                    canGoBack: .constant(false),
                    canGoForward: .constant(false),
                    isLoading: .constant(false),
                    currentURL: .constant(nil),
                    opensLocalJupyterInBrowser: true
                )
                .id(url)
            case .notInstalled:
                placeholder("Set up the local web server to open Library2 and Reader2.", action: "Set Up", server.install)
            case .stopped:
                placeholder("The local web server is stopped.", action: "Start", server.start)
            case .starting:
                ProgressView("Starting the local web server…")
            case .working(let step):
                ProgressView(step)
            case .failed(let message):
                placeholder(message, action: "Retry", server.startIfNeeded)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            publishSource()
            server.startIfNeeded()
        }
        .onChange(of: library.folderPath) { publishSource() }
        .onChange(of: library.entries) { publishSource() }
        .onChange(of: library.groups) { publishSource() }
    }

    private func placeholder(_ message: String, action: String, _ perform: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text("Library2").font(.title2.bold())
            Text(message).multilineTextAlignment(.center)
            Button(action, action: perform)
        }
        .padding(24)
    }

    /// Export a catalog snapshot for the Node process. The original store is only read here.
    private func publishSource() {
        let folder = DriveNumenorSync.baseDirectory.appendingPathComponent("Research2", isDirectory: true)
        let data = Source(folder: library.folderPath, entries: library.entries, groups: library.groups.map {
            Source.Group(id: $0.id, name: $0.name, folderName: $0.folderName, archived: $0.archived, subgroups: $0.subgroups)
        })
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(data).write(to: folder.appendingPathComponent("library-source.json"), options: .atomic)
            sourceError = nil
        } catch {
            sourceError = "Library2 could not read the connected catalog. \(error.localizedDescription)"
        }
    }
}
