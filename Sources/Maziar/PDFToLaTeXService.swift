import Foundation

/// Reconstructs a single rendered PDF page back into LaTeX source, for the Reader window's
/// "Convert to LaTeX" tool. Like `EquationLatexService`, the PDF has no LaTeX left in it to
/// recover (it was compiled away into glyphs/paths) — this asks a vision-capable AI model to
/// transcribe the page's structure, text, math, tables, and figures back into markup, one page at
/// a time (`PaperReaderWindow.convertPDFToLatex` drives the per-page loop and assembles the
/// results). Full pixel-for-pixel fidelity (exact figure placement, precise multi-column line
/// breaks) isn't achievable from a rasterized page image alone — this aims for a faithful
/// *reconstruction* of the layout (same section structure, same column count, same tables/
/// equations/figures) that recompiles into a PDF reading the same as the original, not a literal
/// re-derivation of the author's own unavailable source.
@MainActor
enum PDFToLaTeXService {
    /// One page's transcribed LaTeX body — no preamble/`\begin{document}`, just the content that
    /// goes inside it for this page.
    struct PageResult {
        let body: String
    }

    private static let systemPrompt = """
    You transcribe one page of an academic paper's PDF (given as an image) into LaTeX source, \
    aiming to recreate the page's structure and layout as faithfully as LaTeX allows — not just \
    its plain text.

    Rules:
    - Output ONLY the LaTeX that would go in the document body for this page's content — no \
    \\documentclass, no \\usepackage, no \\begin{document}/\\end{document}, no markdown code fences, \
    no commentary before or after.
    - Preserve heading levels using \\section*{...}, \\subsection*{...}, etc. (starred, since \
    page-by-page transcription can't reliably track numbering across the whole paper).
    - If the page is laid out in two (or more) columns, wrap this page's body in \
    \\begin{multicols}{2} ... \\end{multicols} (from the multicol package) and break paragraphs \
    roughly where the columns actually break. If it's single-column, don't use multicols.
    - Transcribe math as inline $...$ or display \\[...\\] / align environments, matching what's \
    shown.
    - Reproduce tables with a tabular environment (booktabs-style \\toprule/\\midrule/\\bottomrule \
    rules are fine) matching the visible rows/columns.
    - For each figure, chart, diagram, or photo on the page, emit a real figure environment: \
    \\begin{figure}[htbp]\\centering\\includegraphics[width=0.8\\linewidth]{PLACEHOLDER}\
    \\caption{...}\\end{figure} — use the literal text PLACEHOLDER (unchanged) as the \
    includegraphics argument; it gets substituted afterward with the real extracted image file. \
    Write the actual caption text visible near the figure, or a short factual description of the \
    image if no caption is visible.
    - Escape LaTeX special characters (%, &, #, _, {, }, etc.) that appear in ordinary text so the \
    result compiles.
    - For an asterisk used as a math superscript/subscript (e.g. optimal-value notation like Q*, \
    f*), write it as $Q^{*}$ or $Q^{\\ast}$ — never as $Q^\\*$. \\* is LaTeX's own reserved \
    discretionary-hyphenation command, not a literal asterisk; using it as a superscript/subscript \
    argument silently corrupts the document and only errors out much later, somewhere unrelated.
    - If this is a title page (paper title, authors, abstract), use \\section*{...} for the title \
    and reproduce the abstract as normal text under an "Abstract" heading — don't use \\title/\
    \\author/\\maketitle, since those only make sense once for the whole document, not per page.
    """

    static func convertPage(imageBase64: String, settings: AISettings) async throws -> PageResult {
        let provider = settings.effectiveLibraryProvider
        let model = settings.effectiveLibraryModel()
        let reply = try await AIClient.send(
            provider: provider,
            settings: settings,
            systemPrompt: systemPrompt,
            history: [AIChatMessage(role: .user, content: "Transcribe this page to LaTeX.", imagesBase64: [imageBase64])],
            modelOverride: model
        )
        var trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            trimmed = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = sanitizeDiscretionaryAsterisk(trimmed)
        return PageResult(body: trimmed)
    }

    /// Belt-and-suspenders for the systemPrompt rule above: even with that rule, a model can still
    /// slip and emit `\*` as a superscript/subscript argument (e.g. `Q^\*`). `\*` is LaTeX's own
    /// discretionary-hyphenation macro, not a literal asterisk — using it there corrupts TeX's
    /// internal state without erroring until much later in the document, at some unrelated brace,
    /// making it look like a bug in whatever feature happened to trigger the next compile (this is
    /// exactly what made the color picker look guilty of causing a "Missing { inserted" error it had
    /// nothing to do with). Rewriting `^\*`/`_\*` to `^{\ast}`/`_{\ast}` here — a real LaTeX math
    /// "asterisk" symbol — catches that before it ever reaches the compiler.
    private static func sanitizeDiscretionaryAsterisk(_ tex: String) -> String {
        // The replacement template needs "\\" (two backslashes) so ICU's regex
        // engine emits one literal backslash in the output — a single "\\"
        // here gets silently swallowed by ICU's own \-escaping, producing the
        // broken "{ast}" instead of "{\ast}" (verified empirically, not just
        // assumed, since this class of double-unescaping bug is easy to get
        // subtly wrong and ship silently).
        tex.replacingOccurrences(of: #"([\^_])\\\*"#, with: "$1{\\\\ast}", options: .regularExpression)
    }

    /// Assembles per-page bodies into one compilable `.tex` document. `pageBackgroundHex`/
    /// `pageTextColorHex` (6-digit `RRGGBB`, no `#`) become a `\pagecolor{...}` preamble line and a
    /// `\color{...}` line right after `\begin{document}` (both `xcolor`'s `[HTML]` model) —
    /// changing either of the reader's color pickers rewrites just that one line directly in the
    /// already-converted source, so picking a new color doesn't require re-running the AI
    /// conversion, only a recompile.
    static func assembleDocument(pageBodies: [String], pageBackgroundHex: String, pageTextColorHex: String) -> String {
        let usesMulticols = pageBodies.contains { $0.contains("multicols") }
        var preamble = """
        \\documentclass[10pt]{article}
        \\usepackage[margin=1in]{geometry}
        \\usepackage{amsmath,amssymb}
        \\usepackage{graphicx}
        \\usepackage{booktabs}
        \\usepackage{xcolor}
        """
        if usesMulticols {
            preamble += "\n\\usepackage{multicol}"
        }
        preamble += "\n\\pagecolor[HTML]{\(pageBackgroundHex)}\n\n\\begin{document}\n\\color[HTML]{\(pageTextColorHex)}\n\n"
        let body = pageBodies.enumerated().map { index, text in
            "% -- page \(index + 1) --\n\(text)\n\\clearpage"
        }.joined(separator: "\n\n")
        return preamble + body + "\n\n\\end{document}\n"
    }
}
