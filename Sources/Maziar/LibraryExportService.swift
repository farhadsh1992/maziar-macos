import Foundation
import AppKit
import UniformTypeIdentifiers

/// Bundles one or more Library papers into a single `.zip`: each paper's PDF, its notes (the legacy
/// `.txt` file and/or every notebook tab's `.ipynb`), a readable `info.txt` (title, authors, venue,
/// abstract, tags, label, groups), the same data as `info.json`, and a BibTeX `citation.bib`. One
/// paper zips as a single folder; several get one subfolder each, so names can't collide.
@MainActor
enum LibraryExportService {
    private struct Plan {
        var copies: [(source: URL, relativePath: String)] = []
        var texts: [(relativePath: String, content: Data)] = []
    }

    enum ExportError: LocalizedError {
        case zipFailed(String)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let reason): return "Couldn't create the zip file: \(reason)"
            }
        }
    }

    /// Asks where to save, builds the zip, and returns where it went — or `nil` if cancelled.
    static func exportWithSavePanel(_ entries: [LibraryEntry], libraryStore: LibraryStore) async throws -> URL? {
        guard !entries.isEmpty else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (entries.count == 1 ? sanitized(entries[0].title) : "Maziar Library Export") + ".zip"
        panel.message = "Save the PDF\(entries.count == 1 ? "" : "s"), notes and info as a zip file"
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        try await export(entries, libraryStore: libraryStore, to: destination)
        return destination
    }

    static func export(_ entries: [LibraryEntry], libraryStore: LibraryStore, to destination: URL) async throws {
        var plan = Plan()
        var usedFolders = Set<String>()
        for entry in entries {
            var folder = sanitized(entry.title)
            var suffix = 2
            while usedFolders.contains(folder) { folder = "\(sanitized(entry.title)) \(suffix)"; suffix += 1 }
            usedFolders.insert(folder)
            add(entry, under: entries.count == 1 ? "" : folder + "/", to: &plan, libraryStore: libraryStore)
        }
        let rootName = entries.count == 1 ? sanitized(entries[0].title) : "Maziar Library Export"
        let finished = plan
        try await Task.detached(priority: .userInitiated) {
            try build(plan: finished, rootName: rootName, destination: destination)
        }.value
    }

    private static func add(_ entry: LibraryEntry, under prefix: String, to plan: inout Plan, libraryStore: LibraryStore) {
        let fm = FileManager.default
        var missingNote = ""
        if let pdf = libraryStore.primaryURL(for: entry) {
            plan.copies.append((pdf, prefix + pdf.lastPathComponent))
        } else {
            missingNote = "\n\n(The PDF file could not be found in the connected folder, so it is not included.)"
        }

        if let txt = libraryStore.notesFileURL(for: entry), fm.fileExists(atPath: txt.path) {
            plan.copies.append((txt, prefix + "Notes/" + txt.lastPathComponent))
        }
        // Checked directly rather than via `notebookTabs(for:)`, which creates the folder and moves
        // files — exporting shouldn't change anything in the library.
        if let pdf = libraryStore.primaryURL(for: entry) {
            let flat = pdf.deletingPathExtension().appendingPathExtension("ipynb")
            if fm.fileExists(atPath: flat.path) {
                plan.copies.append((flat, prefix + "Notes/" + flat.lastPathComponent))
            }
        }
        if let folder = libraryStore.notebookFolderURL(for: entry),
           let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension.lowercased() == "ipynb" {
                plan.copies.append((file, prefix + "Notes/" + file.lastPathComponent))
            }
        }

        plan.texts.append((prefix + "info.txt", Data((infoText(for: entry, libraryStore: libraryStore) + missingNote).utf8)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let json = try? encoder.encode(entry) { plan.texts.append((prefix + "info.json", json)) }
        plan.texts.append((prefix + "citation.bib", Data(BibTeXGenerator.entry(for: entry).utf8)))
    }

    private static func infoText(for entry: LibraryEntry, libraryStore: LibraryStore) -> String {
        var lines = ["Title: \(entry.title)"]
        func add(_ label: String, _ value: String?) {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("\(label): \(value)") }
        }
        add("Authors", entry.authors)
        add("Year", entry.year)
        add("Venue", entry.venue)
        add("DOI", entry.doi)
        add("Affiliation", entry.affiliation)
        if !entry.tags.isEmpty { add("Tags", entry.tags.joined(separator: ", ")) }
        add("Label", libraryStore.labelColor(for: entry)?.name)
        add("Reading order", entry.labelNumber.map(String.init))
        let groups = libraryStore.groups.filter { entry.groupFileNames[$0.id] != nil }.map(\.name)
        if !groups.isEmpty { add("Groups", groups.joined(separator: ", ")) }
        add("Videos", entry.videoLinks.isEmpty ? nil : entry.videoLinks.joined(separator: "\n  "))
        add("Code", entry.codeLinks.isEmpty ? nil : entry.codeLinks.joined(separator: "\n  "))
        add("Added", entry.dateAdded.formatted(date: .abbreviated, time: .omitted))
        if let abstract = entry.abstract, !abstract.isEmpty { lines.append("\nAbstract:\n\(abstract)") }
        return lines.joined(separator: "\n")
    }

    /// Runs off the main actor — copying several large PDFs and zipping them shouldn't freeze the UI.
    nonisolated private static func build(plan: Plan, rootName: String, destination: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("maziar-export-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(rootName, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for (source, relative) in plan.copies {
            let target = root.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source, to: target) }
        }
        for (relative, content) in plan.texts {
            let target = root.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
        }

        try? fm.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", root.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed")
        }
    }

    private static func sanitized(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String((cleaned.isEmpty ? "Paper" : cleaned).prefix(120))
    }
}
