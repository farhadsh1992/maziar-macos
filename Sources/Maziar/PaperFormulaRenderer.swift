import AppKit
import Foundation
import PDFKit

/// Compiles a LaTeX formula to an image via the same `SystemLaTeXCompiler` used for full projects
/// — a tiny standalone document is compiled to PDF and its first page rasterized — so a formula
/// typed into a note renders as its true typeset shape rather than raw source text. Results are
/// cached in memory by (formula, display-mode); missing packages (e.g. `standalone.cls` on a
/// minimal TinyTeX install) are auto-installed by the compiler the same way full projects are.
@MainActor
final class PaperFormulaRenderer: ObservableObject {
    static let shared = PaperFormulaRenderer()

    enum RenderError: LocalizedError {
        case noCompilerFound
        case noPageProduced

        var errorDescription: String? {
            switch self {
            case .noCompilerFound:
                return "No LaTeX installation found. Install one in Settings \u{2192} LaTeX Compiler."
            case .noPageProduced:
                return "This formula didn't compile to an image."
            }
        }
    }

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage, Error>] = [:]

    private init() {}

    func image(for formula: String, displayMode: Bool, texManager: TeXInstallationManager) async throws -> NSImage {
        let key = cacheKey(formula: formula, displayMode: displayMode)
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return try await running.value }

        guard let pdflatexURL = texManager.pdflatexURL() else {
            throw RenderError.noCompilerFound
        }

        let task = Task<NSImage, Error> {
            try await Self.render(formula: formula, displayMode: displayMode, pdflatexURL: pdflatexURL)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let image = try await task.value
        cache[key] = image
        return image
    }

    func clearCache() {
        cache.removeAll()
    }

    private func cacheKey(formula: String, displayMode: Bool) -> String {
        (displayMode ? "D::" : "I::") + formula
    }

    nonisolated private static func render(formula: String, displayMode: Bool, pdflatexURL: URL) async throws -> NSImage {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maziar-formula-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mathBody = displayMode ? "\\[\n\(formula)\n\\]" : "$\(formula)$"
        let source = """
        \\documentclass[preview,border=2pt]{standalone}
        \\usepackage{amsmath}
        \\usepackage{amssymb}
        \\begin{document}
        \(mathBody)
        \\end{document}
        """
        let mainFile = "formula.tex"
        try source.write(to: tempDir.appendingPathComponent(mainFile), atomically: true, encoding: .utf8)

        let output = try await SystemLaTeXCompiler.compile(
            pdflatexURL: pdflatexURL,
            projectDirectory: tempDir,
            mainFile: mainFile
        )
        guard let document = PDFDocument(data: output.pdf), let page = document.page(at: 0) else {
            throw RenderError.noPageProduced
        }

        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 3
        let size = NSSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
