import Foundation
import AppKit

@MainActor
final class ProjectStore: ObservableObject {
    @Published var recents: [Project] = []

    private let recentsURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar", isDirectory: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        recentsURL = appSupport.appendingPathComponent("recents.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: recentsURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        recents = decoded
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastOpened > $1.lastOpened }
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: recentsURL, options: .atomic)
    }

    func touch(_ project: Project) {
        var updated = project
        updated.lastOpened = Date()
        recents.removeAll { $0.path == updated.path }
        recents.insert(updated, at: 0)
        persist()
    }

    func remove(_ project: Project) {
        recents.removeAll { $0.path == project.path }
        persist()
    }

    /// Common cloud-sync folders detected on this Mac (iCloud Drive, Dropbox, Google Drive),
    /// for the "move project into a synced folder" sharing option.
    func cloudFolderCandidates() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var candidates: [(String, URL)] = [
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")),
            ("Dropbox", home.appendingPathComponent("Dropbox"))
        ]
        if let cloudStorage = try? fm.contentsOfDirectory(
            at: home.appendingPathComponent("Library/CloudStorage"), includingPropertiesForKeys: nil
        ) {
            for entry in cloudStorage where entry.lastPathComponent.hasPrefix("GoogleDrive-") {
                candidates.append(("Google Drive", entry.appendingPathComponent("My Drive")))
            }
        }
        return candidates.filter { fm.fileExists(atPath: $0.1.path) }
    }

    /// Moves a project's folder into a new parent directory (e.g. a cloud-synced folder) in place.
    @discardableResult
    func moveProject(_ project: Project, into targetParent: URL) throws -> Project {
        let fm = FileManager.default
        let destination = uniqueURL(base: targetParent, name: project.name)
        try fm.moveItem(at: project.url, to: destination)
        recents.removeAll { $0.path == project.path }
        persist()
        return openProject(at: destination)
    }

    /// Clones an Overleaf project via its Git Bridge remote (git.overleaf.com/<project_id>).
    @discardableResult
    func cloneOverleafProject(projectId: String, token: String, into directory: URL) async throws -> Project {
        let trimmedId = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !token.isEmpty else {
            throw NSError(domain: "Maziar", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Enter both the Overleaf project ID and a git token."
            ])
        }
        let projectURL = uniqueURL(base: directory, name: "Overleaf \(trimmedId)")
        let remote = "https://git:\(token)@git.overleaf.com/\(trimmedId)"
        try await GitService.clone(url: remote, into: projectURL)
        KeychainHelper.set(token, forKey: "overleaf-token:\(trimmedId)")
        // Re-point the remote without the embedded token (avoids leaving the secret in .git/config).
        _ = try? await GitService.setRemote(name: "overleaf", url: "https://git.overleaf.com/\(trimmedId)", at: projectURL)
        return openProject(at: projectURL)
    }

    /// The compiled PDF for a project, if it's been compiled at least once — latexmk/pdflatex
    /// write it next to the main .tex file with the same base name.
    func compiledPDFURL(for project: Project) -> URL? {
        let mainURL = project.url.appendingPathComponent(project.mainFile)
        let pdfURL = mainURL.deletingPathExtension().appendingPathExtension("pdf")
        return FileManager.default.fileExists(atPath: pdfURL.path) ? pdfURL : nil
    }

    /// Copies a project's compiled PDF to `destinationURL`. Throws with a clear message if the
    /// project hasn't been compiled yet.
    func exportPDF(_ project: Project, to destinationURL: URL) throws {
        guard let pdfURL = compiledPDFURL(for: project) else {
            throw NSError(domain: "Maziar", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "\"\(project.name)\" hasn't been compiled yet — no PDF found. Open it and compile first."
            ])
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: pdfURL, to: destinationURL)
    }

    /// Zips a project's whole folder to `destinationURL` (same tool/flags Finder's own "Compress"
    /// uses, for a .zip that behaves the way users expect when they later double-click it).
    func exportZip(_ project: Project, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", project.url.path, destinationURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "Failed to create the zip archive."
            throw NSError(domain: "Maziar", code: 31, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func defaultProjectsDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    func createProject(named name: String, in directory: URL, templateKey: String = "article") throws -> Project {
        let fm = FileManager.default
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmed.isEmpty ? "Untitled Project" : trimmed
        let projectURL = uniqueURL(base: directory, name: safeName)
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)

        guard let templateURL = Bundle.module.url(
            forResource: "main", withExtension: "tex", subdirectory: "Templates/\(templateKey)"
        ) else {
            throw NSError(domain: "Maziar", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing bundled project template \"\(templateKey)\"."
            ])
        }
        let mainDest = projectURL.appendingPathComponent("main.tex")
        try fm.copyItem(at: templateURL, to: mainDest)

        let project = Project(
            path: projectURL.path,
            name: projectURL.lastPathComponent,
            mainFile: "main.tex",
            lastOpened: Date()
        )
        touch(project)
        return project
    }

    /// Imports a .zip archive (e.g. an exported Overleaf project) as a new local project.
    @discardableResult
    func importZip(from zipURL: URL, into directory: URL) throws -> Project {
        let fm = FileManager.default

        guard fm.fileExists(atPath: zipURL.path) else {
            throw NSError(domain: "Maziar", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Can't read \"\(zipURL.lastPathComponent)\". Try picking it again."
            ])
        }

        let name = zipURL.deletingPathExtension().lastPathComponent
        let projectURL = uniqueURL(base: directory, name: name)
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)

        // `unzip` (Info-ZIP) is the most tolerant of real-world zip variants — in particular
        // archives with streamed "data descriptor" entries (common from zip libraries like
        // Python's zipfile/Node's archiver, which is how many project exports, e.g. Overleaf's,
        // are built), where `ditto` can lose sync mid-archive ("Couldn't read pkzip signature").
        // Fall back to `ditto` for the cases it handles better (non-ASCII filenames).
        do {
            try runExtractor(
                executable: "/usr/bin/unzip", arguments: ["-q", "-o", zipURL.path, "-d", projectURL.path]
            )
        } catch let unzipError {
            try? fm.removeItem(at: projectURL)
            try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
            do {
                try runExtractor(
                    executable: "/usr/bin/ditto", arguments: ["-xk", zipURL.path, projectURL.path]
                )
            } catch let dittoError {
                try? fm.removeItem(at: projectURL)
                throw NSError(domain: "Maziar", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to extract the zip archive.\nunzip: \(unzipError.localizedDescription)\nditto: \(dittoError.localizedDescription)"
                ])
            }
        }

        // Zip metadata Finder/ditto can leave behind; ignore when deciding whether to flatten.
        try? fm.removeItem(at: projectURL.appendingPathComponent("__MACOSX"))
        try? fm.removeItem(at: projectURL.appendingPathComponent(".DS_Store"))

        // If the archive contains a single top-level folder, flatten it.
        if let items = try? fm.contentsOfDirectory(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey]),
           items.count == 1,
           let onlyItem = items.first,
           (try? onlyItem.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let temp = projectURL.appendingPathExtension("tmp-flatten")
            try fm.moveItem(at: onlyItem, to: temp)
            try fm.removeItem(at: projectURL)
            try fm.moveItem(at: temp, to: projectURL)
        }

        let project = openProject(at: projectURL)
        return project
    }

    /// Clones a GitHub (or any git) repository as a new local project.
    @discardableResult
    func cloneGitRepo(urlString: String, into directory: URL) throws -> Project {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let remoteURL = URL(string: trimmed) else {
            throw NSError(domain: "Maziar", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Enter a valid repository URL."
            ])
        }
        var repoName = remoteURL.deletingPathExtension().lastPathComponent
        if repoName.isEmpty { repoName = "Imported Repo" }
        let projectURL = uniqueURL(base: directory, name: repoName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--depth", "1", trimmed, projectURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "git clone failed."
            try? FileManager.default.removeItem(at: projectURL)
            throw NSError(domain: "Maziar", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return openProject(at: projectURL)
    }

    /// Converts a Word (.docx) or Markdown (.md) document into a new LaTeX project using pandoc.
    @discardableResult
    func importDocument(from sourceURL: URL, into directory: URL) throws -> Project {
        guard let pandoc = Self.locatePandoc() else {
            throw NSError(domain: "Maziar", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Pandoc is required to import Word/Markdown documents. Install it with \"brew install pandoc\" and try again."
            ])
        }
        let fm = FileManager.default
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let projectURL = uniqueURL(base: directory, name: name)
        try fm.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let mainDest = projectURL.appendingPathComponent("main.tex")

        let process = Process()
        process.executableURL = pandoc
        process.arguments = [sourceURL.path, "-o", mainDest.path, "--standalone"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: mainDest.path) else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "Pandoc conversion failed."
            try? fm.removeItem(at: projectURL)
            throw NSError(domain: "Maziar", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let project = Project(
            path: projectURL.path,
            name: projectURL.lastPathComponent,
            mainFile: "main.tex",
            lastOpened: Date()
        )
        touch(project)
        return project
    }

    @discardableResult
    private func runExtractor(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Maziar", code: 2, userInfo: [
                NSLocalizedDescriptionKey: output.isEmpty ? "exit code \(process.terminationStatus)" : output
            ])
        }
        return output
    }

    private static func locatePandoc() -> URL? {
        let candidates = ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func uniqueURL(base: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = base.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    func openProjectPicker() -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder containing your LaTeX project"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return openProject(at: url)
    }

    @discardableResult
    func openProject(at url: URL) -> Project {
        let mainFile = detectMainFile(in: url)
        let project = Project(
            path: url.path,
            name: url.lastPathComponent,
            mainFile: mainFile,
            lastOpened: Date()
        )
        touch(project)
        return project
    }

    private func detectMainFile(in url: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("main.tex").path) {
            return "main.tex"
        }
        if let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
           let firstTex = items.first(where: { $0.pathExtension.lowercased() == "tex" }) {
            return firstTex.lastPathComponent
        }
        return "main.tex"
    }
}
