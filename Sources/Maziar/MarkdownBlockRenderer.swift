import Foundation

/// A small, pragmatic Markdown-to-HTML renderer for notebook/notes cells — not a full CommonMark
/// implementation, just the block/inline syntax people actually type in a quick note: `#`/`##`
/// headers, `**bold**`/`*italic*`/`` `code` ``, `- `/`1. ` lists, `> ` blockquotes, and ` ``` ` code
/// fences. Runs line-by-line so raw HTML the user pastes (the built-in Title/Main Text/Subtitle box
/// templates, or anything else starting with `<`) still passes through completely untouched instead
/// of being escaped or re-wrapped — the same "Markdown with HTML passthrough" behavior a real
/// Jupyter markdown cell has. A line inside an open HTML tag (tracked via a simple open/close-tag
/// depth counter, not a real parser) is treated as still being raw HTML even if it doesn't itself
/// start with `<`, so a multi-line `<div>...</div>` block with blank lines in the middle — like the
/// box templates — isn't torn apart into separate, broken pieces.
enum MarkdownBlockRenderer {
    static func render(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false
        var htmlDepth = 0
        var inCodeFence = false
        var codeFenceLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            output.append("<p>" + inlineFormat(paragraphLines.joined(separator: " ")) + "</p>")
            paragraphLines.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            let tag = listIsOrdered ? "ol" : "ul"
            output.append("<\(tag)>" + listItems.map { "<li>" + inlineFormat($0) + "</li>" }.joined() + "</\(tag)>")
            listItems.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if trimmed == "```" {
                    output.append("<pre><code>" + escapeHTML(codeFenceLines.joined(separator: "\n")) + "</code></pre>")
                    codeFenceLines.removeAll()
                    inCodeFence = false
                } else {
                    codeFenceLines.append(line)
                }
                continue
            }
            if trimmed == "```" {
                flushParagraph(); flushList()
                inCodeFence = true
                continue
            }

            if htmlDepth > 0 {
                output.append(line)
                htmlDepth = max(0, htmlDepth + tagDepthDelta(line))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); flushList()
                continue
            }

            if trimmed.hasPrefix("<") {
                flushParagraph(); flushList()
                output.append(line)
                htmlDepth = max(0, tagDepthDelta(line))
                continue
            }

            // GitHub-style table: a row of `|`-separated cells directly followed by a `---|---`
            // separator row; every following non-blank line containing a `|` is a body row.
            if trimmed.contains("|"), index < lines.count, let alignments = tableAlignments(lines[index]),
               splitTableRow(trimmed).count == alignments.count {
                flushParagraph(); flushList()
                let headers = splitTableRow(trimmed)
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !next.isEmpty, next.contains("|") else { break }
                    rows.append(splitTableRow(next))
                    index += 1
                }
                output.append(tableHTML(headers: headers, alignments: alignments, rows: rows))
                continue
            }

            if let header = headerMatch(trimmed) {
                flushParagraph(); flushList()
                output.append("<h\(header.level)>" + inlineFormat(header.text) + "</h\(header.level)>")
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph(); flushList()
                let quoted = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                output.append("<blockquote>" + inlineFormat(quoted) + "</blockquote>")
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                if listIsOrdered { flushList() }
                listIsOrdered = false
                listItems.append(String(trimmed.dropFirst(2)))
                continue
            }

            if let item = orderedListItemMatch(trimmed) {
                flushParagraph()
                if !listIsOrdered { flushList() }
                listIsOrdered = true
                listItems.append(item)
                continue
            }

            flushList()
            paragraphLines.append(trimmed)
        }

        flushParagraph()
        flushList()
        if inCodeFence, !codeFenceLines.isEmpty {
            output.append("<pre><code>" + escapeHTML(codeFenceLines.joined(separator: "\n")) + "</code></pre>")
        }
        return output.joined(separator: "\n")
    }

    /// Counts unclosed HTML tags opened/closed on one line — deliberately crude (no attribute or
    /// self-closing-tag edge cases beyond the common void elements below), enough to track a
    /// `<div>...</div>` block's depth across blank lines without a real HTML parser.
    private static func tagDepthDelta(_ line: String) -> Int {
        var delta = 0
        if let openRegex = try? NSRegularExpression(pattern: "<([a-zA-Z][a-zA-Z0-9]*)(\\s[^>]*)?/?>") {
            let range = NSRange(line.startIndex..., in: line)
            openRegex.enumerateMatches(in: line, range: range) { match, _, _ in
                guard let match, let tagRange = Range(match.range(at: 1), in: line) else { return }
                let whole = (line as NSString).substring(with: match.range)
                let tag = line[tagRange].lowercased()
                let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link"]
                guard !voidElements.contains(tag), !whole.hasSuffix("/>") else { return }
                delta += 1
            }
        }
        if let closeRegex = try? NSRegularExpression(pattern: "</[a-zA-Z][a-zA-Z0-9]*>") {
            let range = NSRange(line.startIndex..., in: line)
            delta -= closeRegex.numberOfMatches(in: line, range: range)
        }
        return delta
    }

    /// Splits one table row on `|`, ignoring the optional leading/trailing pipe and `\|` escapes.
    private static func splitTableRow(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == "|" && previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                if character == "|" { current.removeLast() }
                current.append(character)
            }
            previous = character
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The per-column alignment if `line` is a table separator row (`|---|:--:|--:|`), else nil.
    private static func tableAlignments(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") || trimmed.contains("-") else { return nil }
        let cells = splitTableRow(trimmed)
        var alignments: [String] = []
        for cell in cells {
            guard !cell.isEmpty else { return nil }
            var core = Substring(cell)
            let left = core.hasPrefix(":")
            if left { core = core.dropFirst() }
            let right = core.hasSuffix(":")
            if right { core = core.dropLast() }
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? "center" : right ? "right" : left ? "left" : "")
        }
        return alignments.isEmpty ? nil : alignments
    }

    private static func tableHTML(headers: [String], alignments: [String], rows: [[String]]) -> String {
        func cell(_ tag: String, _ text: String, _ column: Int) -> String {
            let align = column < alignments.count ? alignments[column] : ""
            let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
            return "<\(tag)\(style)>" + inlineFormat(text) + "</\(tag)>"
        }
        var html = "<table><thead><tr>" + headers.enumerated().map { cell("th", $1, $0) }.joined() + "</tr></thead><tbody>"
        for row in rows {
            // Ragged rows are padded/truncated to the header's width, like GitHub does.
            let padded = (0..<headers.count).map { $0 < row.count ? row[$0] : "" }
            html += "<tr>" + padded.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    private static func headerMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#", level < 6 {
            level += 1
            rest = rest.dropFirst()
        }
        guard level > 0, rest.first == " " else { return nil }
        return (level, rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func orderedListItemMatch(_ line: String) -> String? {
        guard let dotRange = line.range(of: ". ") else { return nil }
        let prefix = line[line.startIndex..<dotRange.lowerBound]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return String(line[dotRange.upperBound...])
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Inline formatting applied within one paragraph/header/list-item/blockquote line — escapes
    /// HTML first (this text is plain Markdown, not raw HTML — unlike a whole line starting with
    /// `<`, which `render` never routes here), then layers on bold/italic/code/link syntax. Inline
    /// code runs first so `**`/`*`/`_` inside a code span aren't mistaken for formatting.
    private static func inlineFormat(_ text: String) -> String {
        var result = escapeHTML(text)
        result = replace(result, pattern: "`([^`]+)`", template: "<code>$1</code>")
        result = replace(result, pattern: "\\*\\*([^*]+)\\*\\*", template: "<strong>$1</strong>")
        result = replace(result, pattern: "__([^_]+)__", template: "<strong>$1</strong>")
        result = replace(result, pattern: "\\*([^*]+)\\*", template: "<em>$1</em>")
        result = replace(result, pattern: "(?<![a-zA-Z0-9])_([^_]+)_(?![a-zA-Z0-9])", template: "<em>$1</em>")
        result = replace(result, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", template: "<a href=\"$2\">$1</a>")
        // The note-formatting toolbar (color / font / size / underline) writes these two tags — the
        // only inline HTML let through, with a style limited to harmless characters.
        result = replace(result, pattern: "&lt;span style=\"([A-Za-z0-9#:;.,%' -]*)\"&gt;", template: "<span style=\"$1\">")
        result = result.replacingOccurrences(of: "&lt;/span&gt;", with: "</span>")
        result = result.replacingOccurrences(of: "&lt;u&gt;", with: "<u>").replacingOccurrences(of: "&lt;/u&gt;", with: "</u>")
        return result
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
