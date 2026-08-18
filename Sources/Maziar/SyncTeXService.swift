import Foundation
import CoreGraphics

struct SyncTeXViewResult {
    let page: Int
    /// Point in TeX's native top-left-origin, Y-down page space (points).
    let x: Double
    let y: Double
}

struct SyncTeXEditResult {
    let file: String
    let line: Int
}

/// Wraps the `synctex` CLI (ships alongside pdflatex/latexmk in TeX Live/TinyTeX/MacTeX,
/// though not always installed by default — callers should treat a nil binary as "unavailable")
/// for forward search (editor position -> PDF location) and inverse search (PDF click ->
/// source file/line), driving Cmd+Click navigation between the editor and PDF preview.
enum SyncTeXService {
    static func binaryURL(alongside pdflatexURL: URL) -> URL? {
        let candidate = pdflatexURL.deletingLastPathComponent().appendingPathComponent("synctex")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    static func forwardSearch(synctexURL: URL, sourceRelativePath: String, line: Int, pdfURL: URL) -> SyncTeXViewResult? {
        let output = run(
            synctexURL,
            ["view", "-i", "\(max(line, 1)):1:\(sourceRelativePath)", "-o", pdfURL.path],
            directory: pdfURL.deletingLastPathComponent()
        )
        return parseView(output)
    }

    static func inverseSearch(synctexURL: URL, page: Int, x: Double, y: Double, pdfURL: URL) -> SyncTeXEditResult? {
        let output = run(
            synctexURL,
            ["edit", "-o", "\(page):\(x):\(y):\(pdfURL.path)"],
            directory: pdfURL.deletingLastPathComponent()
        )
        return parseEdit(output)
    }

    private static func parseView(_ output: String) -> SyncTeXViewResult? {
        var page: Int?
        var h: Double?
        var v: Double?
        for rawLine in output.split(separator: "\n") {
            if rawLine.hasPrefix("Page:") { page = Int(rawLine.dropFirst(5)) }
            else if rawLine.hasPrefix("h:") { h = Double(rawLine.dropFirst(2)) }
            else if rawLine.hasPrefix("v:") { v = Double(rawLine.dropFirst(2)) }
            if let page, let h, let v { return SyncTeXViewResult(page: page, x: h, y: v) }
        }
        return nil
    }

    private static func parseEdit(_ output: String) -> SyncTeXEditResult? {
        var file: String?
        var lineNumber: Int?
        for rawLine in output.split(separator: "\n") {
            if rawLine.hasPrefix("Input:") { file = String(rawLine.dropFirst(6)) }
            else if rawLine.hasPrefix("Line:") { lineNumber = Int(rawLine.dropFirst(5)) }
            if let file, let lineNumber { return SyncTeXEditResult(file: file, line: lineNumber) }
        }
        return nil
    }

    private static func run(_ executable: URL, _ arguments: [String], directory: URL) -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Shared hand-off point between the editor and PDF panes for SyncTeX navigation requests —
/// each side publishes a pending target; the other side consumes and clears it.
@MainActor
final class SyncTeXBridge: ObservableObject {
    @Published var pendingEditorLine: Int?
    @Published var pendingPDFTarget: (page: Int, point: CGPoint)?
}
