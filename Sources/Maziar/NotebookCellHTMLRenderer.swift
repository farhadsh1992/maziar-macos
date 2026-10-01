import Foundation

/// Assembles a notebook cell's source into renderable HTML. Cell source is treated as
/// Markdown-with-HTML-passthrough, the same as a real Jupyter markdown cell — raw HTML the user
/// types or pastes (e.g. the built-in title/box templates) comes through untouched, since that's
/// exactly how Jupyter itself would render it. The one addition on top of plain passthrough is
/// `$...$`/`$$...$$` LaTeX formulas (`NoteContentParser`, shared with the plain-note renderer),
/// substituted with an `<img>` tag pointing at an already-rendered base64 PNG (rendering itself
/// happens elsewhere, via `PaperFormulaRenderer` — this stays pure/synchronous so it's testable
/// without a running app).
enum NotebookCellHTMLRenderer {
    static func cacheKey(_ formula: String, displayMode: Bool) -> String {
        (displayMode ? "D::" : "I::") + formula
    }

    /// Substitutes each math segment with a private-use-area placeholder token *before* running
    /// `MarkdownBlockRenderer` (real Markdown block/inline formatting — headers, bold, lists, etc.
    /// — added specifically so a blank cell isn't limited to raw HTML passthrough), then swaps the
    /// token back out for the real `<img>`/fallback markup afterward. Doing the math substitution
    /// first and handing the renderer real `<img>` tags directly would have them run through
    /// `MarkdownBlockRenderer`'s own HTML-escaping (it doesn't know an inline `<img>` mid-sentence
    /// is *already* safe HTML rather than literal Markdown text) and come out as escaped, broken
    /// `&lt;img ...&gt;` text instead of an image. The placeholder token is plain, non-`<` text, so
    /// it survives escaping untouched and lands back in exactly the right spot.
    static func bodyHTML(source: String, formulaImages: [String: String]) -> String {
        let segments = NoteContentParser.parse(source)
        var placeholderSource = ""
        var replacements: [String: String] = [:]

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let text):
                placeholderSource += text
            case .inlineMath(let formula):
                let token = mathPlaceholder(index)
                let key = cacheKey(formula, displayMode: false)
                if let base64 = formulaImages[key] {
                    replacements[token] = "<img class=\"maziar-formula-inline\" src=\"data:image/png;base64,\(base64)\">"
                } else {
                    replacements[token] = "<code>$\(escapeHTML(formula))$</code>"
                }
                placeholderSource += token
            case .displayMath(let formula):
                let token = mathPlaceholder(index)
                let key = cacheKey(formula, displayMode: true)
                if let base64 = formulaImages[key] {
                    replacements[token] = "<div class=\"maziar-formula-block\"><img src=\"data:image/png;base64,\(base64)\"></div>"
                } else {
                    replacements[token] = "<pre><code>$$\(escapeHTML(formula))$$</code></pre>"
                }
                placeholderSource += token
            }
        }

        var html = MarkdownBlockRenderer.render(placeholderSource)
        for (token, replacement) in replacements {
            html = html.replacingOccurrences(of: token, with: replacement)
        }
        return html
    }

    private static func mathPlaceholder(_ index: Int) -> String {
        "\u{E000}MAZIAR_MATH_\(index)\u{E000}"
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Wraps assembled body content in a full HTML document with a light reset and
    /// dark-mode-aware default colors, so a plain-text cell (no HTML of its own) still reads
    /// reasonably, while a cell that IS custom-styled HTML renders exactly as authored — its own
    /// inline `style` attributes take precedence over these defaults.
    static func fullDocument(bodyHTML: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0; padding: 10px;
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 14px;
            color: #1a1a1a;
            background: #ffffff;
            word-wrap: break-word;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #f0f0f0; background: #1e1e1e; }
          }
          img { max-width: 100%; }
          img.maziar-formula-inline { vertical-align: middle; max-height: 1.4em; }
          .maziar-formula-block { text-align: center; margin: 8px 0; }
          pre { white-space: pre-wrap; }
        </style>
        </head>
        <body>
        \(bodyHTML)
        <script>
          function maziarReportHeight() {
            window.webkit.messageHandlers.heightChanged.postMessage(document.body.scrollHeight);
          }
          new ResizeObserver(maziarReportHeight).observe(document.body);
          document.querySelectorAll('img').forEach(function (img) {
            img.addEventListener('load', maziarReportHeight);
          });
          window.addEventListener('load', maziarReportHeight);
          maziarReportHeight();
        </script>
        </body>
        </html>
        """
    }
}
