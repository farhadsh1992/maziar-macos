import Foundation

enum SelectedFileKind {
    case text
    case image
    case pdf
    case unsupported
}

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var project: Project
    @Published var rootNode: FileNode
    @Published var selectedNode: FileNode?
    @Published var openFileText: String = ""
    @Published var pdfData: Data?
    @Published var compileLog: String = ""
    @Published var isCompiling = false
    @Published var compileError: String?

    private var saveWorkItem: DispatchWorkItem?
    private var autoCompileWorkItem: DispatchWorkItem?

    init(project: Project) {
        self.project = project
        self.rootNode = FileNode(url: project.url)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic"]
    private static let unsupportedExtensions: Set<String> = ["fdb_latexmk", "fls", "synctex", "gz", "aux", "log", "out", "toc", "bbl", "blg", "brf", "nav", "snm"]

    var selectedFileKind: SelectedFileKind {
        guard let selectedNode else { return .unsupported }
        let ext = selectedNode.url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if Self.unsupportedExtensions.contains(ext) { return .unsupported }
        return .text
    }

    func selectFile(_ node: FileNode) {
        guard !node.isDirectory else { return }
        flushPendingSave()
        selectedNode = node
        if selectedFileKind == .text {
            openFileText = (try? String(contentsOf: node.url, encoding: .utf8)) ?? ""
        } else {
            openFileText = ""
        }
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let node = selectedNode
        let text = openFileText
        let item = DispatchWorkItem { [weak self] in
            self?.writeFile(node: node, text: text)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeFile(node: selectedNode, text: openFileText)
    }

    /// Debounced auto-compile after edits settle, when Settings → LaTeX Compiler → "Auto-compile on save" is on.
    func scheduleAutoCompile(using texManager: TeXInstallationManager) {
        guard texManager.autoCompileOnSave, !isCompiling else { return }
        autoCompileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isCompiling else { return }
            Task { await self.compile(using: texManager) }
        }
        autoCompileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func writeFile(node: FileNode?, text: String) {
        guard let node, !node.isDirectory else { return }
        try? text.write(to: node.url, atomically: true, encoding: .utf8)
        FileHistoryManager.shared.record(content: text, for: node.url)
    }

    func restoreSnapshot(_ snapshot: FileSnapshot, for node: FileNode) {
        guard let content = snapshot.loadContent() else { return }
        if selectedNode?.id == node.id {
            openFileText = content
        }
        try? content.write(to: node.url, atomically: true, encoding: .utf8)
        FileHistoryManager.shared.record(content: content, for: node.url)
    }

    func findMainNode() -> FileNode? {
        func search(_ node: FileNode) -> FileNode? {
            if !node.isDirectory && node.name == project.mainFile { return node }
            for child in node.children ?? [] {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(rootNode)
    }

    /// Finds the file node for an absolute path, expanding subdirectories along the way
    /// (needed since SyncTeX inverse search may target a file not yet browsed to in the tree).
    func findNode(forAbsolutePath path: String) -> FileNode? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        func search(_ node: FileNode) -> FileNode? {
            if node.url.standardizedFileURL.path == target { return node }
            guard node.isDirectory else { return nil }
            if node.children == nil { node.reload() }
            for child in node.children ?? [] {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(rootNode)
    }

    /// The currently-open file's path relative to the project root, as SyncTeX records it.
    var selectedFileRelativePath: String? {
        guard let selectedNode else { return nil }
        let base = project.url.standardizedFileURL.path
        var path = selectedNode.url.standardizedFileURL.path
        if path.hasPrefix(base) {
            path.removeFirst(base.count)
            if path.hasPrefix("/") { path.removeFirst() }
        }
        return path
    }

    // MARK: - File/folder management

    enum FileOpError: LocalizedError {
        case alreadyExists(String)
        case system(Error)
        var errorDescription: String? {
            switch self {
            case .alreadyExists(let name): return "\"\(name)\" already exists."
            case .system(let error): return error.localizedDescription
            }
        }
    }

    private func targetDirectory(for node: FileNode) -> URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    @discardableResult
    func createFile(named name: String, in parent: FileNode) -> Result<Void, FileOpError> {
        let url = targetDirectory(for: parent).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return .failure(.alreadyExists(name)) }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            return .failure(.system(NSError(domain: "Maziar", code: 20, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the file."])))
        }
        rootNode.reload()
        return .success(())
    }

    @discardableResult
    func createFolder(named name: String, in parent: FileNode) -> Result<Void, FileOpError> {
        let url = targetDirectory(for: parent).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return .failure(.alreadyExists(name)) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            rootNode.reload()
            return .success(())
        } catch {
            return .failure(.system(error))
        }
    }

    @discardableResult
    func renameNode(_ node: FileNode, to newName: String) -> Result<Void, FileOpError> {
        let newURL = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return .failure(.alreadyExists(newName)) }
        do {
            try FileManager.default.moveItem(at: node.url, to: newURL)
            let wasSelected = selectedNode?.id == node.id
            rootNode.reload()
            if wasSelected, let renamed = findNode(forAbsolutePath: newURL.path) {
                selectFile(renamed)
            }
            return .success(())
        } catch {
            return .failure(.system(error))
        }
    }

    /// Moves to Trash rather than deleting outright, so it's recoverable.
    func deleteNode(_ node: FileNode) {
        try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        if selectedNode?.id == node.id {
            selectedNode = nil
            openFileText = ""
        }
        rootNode.reload()
    }

    func compile(using texManager: TeXInstallationManager) async {
        flushPendingSave()
        compileError = nil
        isCompiling = true
        defer { isCompiling = false }

        guard let pdflatexURL = texManager.pdflatexURL() else {
            compileError = "\(texManager.selectedDistribution.displayName) is not installed. Open Settings (\u{2318},) to install it."
            return
        }

        do {
            let result = try await SystemLaTeXCompiler.compile(
                pdflatexURL: pdflatexURL,
                projectDirectory: project.url,
                mainFile: project.mainFile,
                engine: texManager.engine,
                extraFlags: texManager.extraCompilerFlags
            )
            pdfData = result.pdf
            compileLog = result.log
            compileError = result.succeeded ? nil : "Compilation finished with errors — check the log."
        } catch {
            compileError = error.localizedDescription
            compileLog = error.localizedDescription
        }
    }
}
