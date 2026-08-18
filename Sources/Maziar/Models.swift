import Foundation

struct Project: Identifiable, Codable, Hashable {
    var path: String
    var name: String
    var mainFile: String
    var lastOpened: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

final class FileNode: Identifiable, ObservableObject, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    @Published var children: [FileNode]?

    init(url: URL) {
        self.url = url
        self.id = url.path
        self.name = url.lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        self.children = isDir.boolValue ? FileNode.loadChildren(of: url) : nil
    }

    static func loadChildren(of url: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let nodes = items
            .filter { $0.lastPathComponent != ".git" }
            .map { FileNode(url: $0) }

        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func reload() {
        guard isDirectory else { return }
        children = FileNode.loadChildren(of: url)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
