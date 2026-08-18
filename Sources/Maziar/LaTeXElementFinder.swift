import Foundation

/// A LaTeX visual element (image or float) found near a clicked source line, along with the
/// line range it occupies — used by Dynamic PDF editing (resize / nudge placement / free-drag).
struct LaTeXElement {
    enum Kind {
        case image(widthSpec: String?)
        case float(environment: String, placement: String?)
    }

    var kind: Kind
    /// 1-based, inclusive line range this element occupies in its source file.
    var lineRange: ClosedRange<Int>
    var sourceFile: String

    var isImage: Bool { if case .image = kind { return true }; return false }
}

/// Regex-based scanning/mutation of LaTeX source for Dynamic PDF editing. Deliberately limited
/// to the common single-line conventions (`\includegraphics{...}` and `\begin{figure}[..]` /
/// `\end{figure}` each on their own line) rather than attempting a full LaTeX parser — safe for
/// typical documents, but unusual formatting (e.g. multi-line \includegraphics calls) won't be
/// detected.
enum LaTeXElementFinder {
    private static let includegraphicsRegex = try! NSRegularExpression(
        pattern: #"\\includegraphics(?:\[([^\]]*)\])?\{[^}]*\}"#
    )
    private static let floatBeginRegex = try! NSRegularExpression(
        pattern: #"\\begin\{(figure\*?|table\*?)\}(?:\[([a-zA-Z!]*)\])?"#
    )

    /// Finds the image or float nearest `targetLine` within a search window, preferring an
    /// element whose own range contains the target line.
    static func findElement(in text: String, sourceFile: String, nearLine targetLine: Int, window: Int = 30) -> LaTeXElement? {
        let lines = text.components(separatedBy: "\n")
        let lo = max(0, targetLine - 1 - window)
        let hi = min(lines.count - 1, targetLine - 1 + window)
        guard lo <= hi else { return nil }

        var candidates: [LaTeXElement] = []

        // Images (single-line).
        for i in lo...hi {
            let line = lines[i]
            let nsLine = line as NSString
            if let match = includegraphicsRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                var widthSpec: String?
                if match.range(at: 1).location != NSNotFound {
                    widthSpec = nsLine.substring(with: match.range(at: 1))
                }
                candidates.append(LaTeXElement(kind: .image(widthSpec: widthSpec), lineRange: (i + 1)...(i + 1), sourceFile: sourceFile))
            }
        }

        // Floats: find \begin on its own line, then the matching \end of the same kind.
        for i in lo...hi {
            let line = lines[i]
            let nsLine = line as NSString
            guard let match = floatBeginRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { continue }
            let kind = nsLine.substring(with: match.range(at: 1))
            let placement = match.range(at: 2).location != NSNotFound ? nsLine.substring(with: match.range(at: 2)) : nil
            let endPattern = "\\end{\(kind)}"
            var endLine = i
            for j in i..<lines.count {
                if lines[j].contains(endPattern) { endLine = j; break }
                if j - i > 200 { break } // don't scan unbounded for a malformed/unclosed float
            }
            candidates.append(LaTeXElement(kind: .float(environment: kind, placement: placement), lineRange: (i + 1)...(endLine + 1), sourceFile: sourceFile))
        }

        guard !candidates.isEmpty else { return nil }
        return candidates.min { a, b in
            distance(from: targetLine, to: a.lineRange) < distance(from: targetLine, to: b.lineRange)
        }
    }

    private static func distance(from line: Int, to range: ClosedRange<Int>) -> Int {
        if range.contains(line) { return 0 }
        return min(abs(line - range.lowerBound), abs(line - range.upperBound))
    }

    // MARK: - Mutations (all take/return the full file text)

    /// Rescales an image's width by `factor` (e.g. 1.1 = 10% larger), inserting a `width=`
    /// option if none exists yet (starting from a 0.5\linewidth baseline).
    static func resizeImage(in text: String, lineRange: ClosedRange<Int>, factor: Double) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let lineIndex = lines.indices.first(where: { $0 + 1 == lineRange.lowerBound }) else { return text }
        let line = lines[lineIndex]
        let nsLine = line as NSString
        guard let match = includegraphicsRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { return text }

        let hasOptions = match.range(at: 1).location != NSNotFound
        let existingOptions = hasOptions ? nsLine.substring(with: match.range(at: 1)) : ""
        let newOptions = rescaledOptions(existingOptions, factor: factor)

        let newLine: String
        if hasOptions {
            let optionsRange = match.range(at: 1)
            newLine = nsLine.replacingCharacters(in: optionsRange, with: newOptions)
        } else {
            // Insert [options] right after \includegraphics.
            let insertPoint = match.range.location + "\\includegraphics".count
            newLine = nsLine.replacingCharacters(in: NSRange(location: insertPoint, length: 0), with: "[\(newOptions)]")
        }
        lines[lineIndex] = newLine
        return lines.joined(separator: "\n")
    }

    private static func rescaledOptions(_ options: String, factor: Double) -> String {
        let widthKeyRegex = try! NSRegularExpression(pattern: #"width=([0-9.]+)(\\linewidth|\\textwidth|cm|in|pt|mm)?"#)
        let nsOptions = options as NSString
        if let match = widthKeyRegex.firstMatch(in: options, range: NSRange(location: 0, length: nsOptions.length)) {
            let numberString = nsOptions.substring(with: match.range(at: 1))
            let unit = match.range(at: 2).location != NSNotFound ? nsOptions.substring(with: match.range(at: 2)) : ""
            let number = Double(numberString) ?? 0.5
            let newNumber = max(0.05, min(number * factor, unit.isEmpty || unit == "\\linewidth" || unit == "\\textwidth" ? 1.5 : 100))
            let newValue = "width=\(formatted(newNumber))\(unit)"
            let mutable = NSMutableString(string: options)
            mutable.replaceCharacters(in: match.range, with: newValue)
            return mutable as String
        }
        // No width key yet — add one, keeping any other existing options.
        let baseline = "width=\(formatted(0.5 * factor))\\linewidth"
        return options.isEmpty ? baseline : "\(options),\(baseline)"
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// Cycles a float's placement specifier through a small preset sequence.
    static func cyclePlacement(in text: String, lineRange: ClosedRange<Int>, environment: String) -> String {
        let presets = ["htbp", "h", "t", "b", "p", "!htbp"]
        var lines = text.components(separatedBy: "\n")
        guard let lineIndex = lines.indices.first(where: { $0 + 1 == lineRange.lowerBound }) else { return text }
        let line = lines[lineIndex]
        let nsLine = line as NSString
        guard let match = floatBeginRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { return text }

        let current = match.range(at: 2).location != NSNotFound ? nsLine.substring(with: match.range(at: 2)) : nil
        let nextIndex = ((presets.firstIndex(of: current ?? "") ?? -1) + 1) % presets.count
        let next = presets[nextIndex]

        let newLine: String
        if match.range(at: 2).location != NSNotFound {
            newLine = nsLine.replacingCharacters(in: match.range(at: 2), with: next)
        } else {
            let insertPoint = match.range(at: 1).location + match.range(at: 1).length + 1 // after \begin{kind}
            newLine = nsLine.replacingCharacters(in: NSRange(location: insertPoint, length: 0), with: "[\(next)]")
        }
        lines[lineIndex] = newLine
        return lines.joined(separator: "\n")
    }

    /// Swaps a float's whole line block with the adjacent non-blank block above/below it —
    /// an approximation of "nudge earlier/later in the document flow" (LaTeX floats have no
    /// literal position to move; this changes where in the source, and hence roughly where in
    /// the layout, the float competes for placement).
    static func moveBlock(in text: String, lineRange: ClosedRange<Int>, direction: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let startIdx = lineRange.lowerBound - 1
        let endIdx = lineRange.upperBound - 1
        guard startIdx >= 0, endIdx < lines.count, startIdx <= endIdx else { return text }

        if direction < 0 {
            var i = startIdx - 1
            while i >= 0, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i -= 1 }
            guard i >= 0 else { return text }
            var blockStart = i
            while blockStart - 1 >= 0, !lines[blockStart - 1].trimmingCharacters(in: .whitespaces).isEmpty { blockStart -= 1 }
            let neighbor = Array(lines[blockStart...i])
            let float = Array(lines[startIdx...endIdx])
            lines.replaceSubrange(blockStart...endIdx, with: float + neighbor)
        } else {
            var i = endIdx + 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            guard i < lines.count else { return text }
            var blockEnd = i
            while blockEnd + 1 < lines.count, !lines[blockEnd + 1].trimmingCharacters(in: .whitespaces).isEmpty { blockEnd += 1 }
            let neighbor = Array(lines[i...blockEnd])
            let float = Array(lines[startIdx...endIdx])
            lines.replaceSubrange(startIdx...blockEnd, with: neighbor + float)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Free positioning (textpos)

    static func hasTextposSupport(_ text: String) -> Bool {
        text.contains("{textpos}")
    }

    /// Idempotently adds textpos with absolute/mm-based coordinates to the preamble, right
    /// after \documentclass.
    static func ensureTextposPreamble(in text: String) -> String {
        guard !hasTextposSupport(text) else { return text }
        let insertion = """
        \\usepackage[absolute,overlay]{textpos}
        \\setlength{\\TPHorizModule}{1mm}
        \\setlength{\\TPVertModule}{1mm}
        \\textblockorigin{0mm}{0mm}
        """
        guard let range = text.range(of: #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#, options: .regularExpression) else {
            return insertion + "\n" + text
        }
        var result = text
        result.insert(contentsOf: "\n" + insertion, at: range.upperBound)
        return result
    }

    /// Wraps a found element's lines in an absolutely-positioned `textblock*`, so it can
    /// afterward be dragged freely — the wrap is a plain text-block insertion around the
    /// existing lines, so captions/labels inside a float keep working unmodified.
    ///
    /// Deliberately does *not* touch the preamble — `\usepackage` is only legal in the actual
    /// preamble of the main file, and the element being wrapped may live in an `\input`-ed
    /// sub-file. Callers must separately call `ensureTextposPreamble` on the *main* file's text
    /// (see `hasTextposSupport`/`ensureTextposPreamble`) before using this.
    static func wrapInFreePosition(in text: String, element: LaTeXElement, xMM: Double, yMM: Double, widthMM: Double) -> String {
        var lines = text.components(separatedBy: "\n")
        let startIdx = element.lineRange.lowerBound - 1
        let endIdx = element.lineRange.upperBound - 1
        guard startIdx >= 0, endIdx < lines.count, startIdx <= endIdx else { return text }

        let original = lines[startIdx...endIdx].joined(separator: "\n")
        let wrapped = """
        \\begin{textblock*}{\(formatted(widthMM))mm}(\(formatted(xMM))mm,\(formatted(yMM))mm)
        \(original)
        \\end{textblock*}
        """
        lines.replaceSubrange(startIdx...endIdx, with: wrapped.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    private static let textblockRegex = try! NSRegularExpression(
        pattern: #"\\begin\{textblock\*\}\{([0-9.]+)mm\}\(([0-9.\-]+)mm,([0-9.\-]+)mm\)"#
    )

    /// The nearest enclosing `\begin{textblock*}` line index (0-based) for a line at or after it,
    /// if `lineRange` is already wrapped in one — i.e. this element was previously converted to
    /// free positioning. Scans backward balancing nested begin/end pairs, since the clicked
    /// element can be anywhere inside a multi-line wrapped block, not just its first line.
    static func enclosingFreeBlockLine(in text: String, lineRange: ClosedRange<Int>) -> Int? {
        let lines = text.components(separatedBy: "\n")
        let start = lineRange.lowerBound - 1
        guard start >= 0, start < lines.count else { return nil }
        var depth = 0
        var i = start - 1
        while i >= 0 {
            if lines[i].contains("\\end{textblock*}") { depth += 1 }
            if lines[i].contains("\\begin{textblock*}") {
                if depth == 0 { return i }
                depth -= 1
            }
            i -= 1
        }
        return nil
    }

    static func currentFreePosition(in text: String, atLine index: Int) -> (x: Double, y: Double)? {
        let lines = text.components(separatedBy: "\n")
        guard index >= 0, index < lines.count else { return nil }
        let nsLine = lines[index] as NSString
        guard let match = textblockRegex.firstMatch(in: lines[index], range: NSRange(location: 0, length: nsLine.length)),
              let x = Double(nsLine.substring(with: match.range(at: 2))),
              let y = Double(nsLine.substring(with: match.range(at: 3))) else { return nil }
        return (x, y)
    }

    /// Moves an already-converted textblock* by a relative (dx, dy) in mm.
    static func nudgeFreePosition(in text: String, atLine index: Int, deltaXMM: Double, deltaYMM: Double) -> String {
        guard let current = currentFreePosition(in: text, atLine: index) else { return text }
        var lines = text.components(separatedBy: "\n")
        let nsLine = lines[index] as NSString
        guard let match = textblockRegex.firstMatch(in: lines[index], range: NSRange(location: 0, length: nsLine.length)) else { return text }
        let width = nsLine.substring(with: match.range(at: 1))
        let newX = current.x + deltaXMM
        let newY = current.y + deltaYMM
        let newLine = nsLine.replacingCharacters(
            in: match.range, with: "\\begin{textblock*}{\(width)mm}(\(formatted(newX))mm,\(formatted(newY))mm)"
        )
        lines[index] = newLine
        return lines.joined(separator: "\n")
    }

    // MARK: - Text wrapping (wrapfig) — image sits inline with paragraph text flowing around it,
    // as opposed to a normal float which breaks out into its own block.

    private static let wrapfigureBeginRegex = try! NSRegularExpression(
        pattern: #"\\begin\{wrapfigure\}\{([lLrR])\}\{([^}]*)\}"#
    )

    static func hasWrapfigSupport(_ text: String) -> Bool {
        text.contains("{wrapfig}")
    }

    /// Idempotently adds the wrapfig package to the preamble, right after \documentclass.
    static func ensureWrapfigPreamble(in text: String) -> String {
        guard !hasWrapfigSupport(text) else { return text }
        let insertion = "\\usepackage{wrapfig}"
        guard let range = text.range(of: #"\\documentclass(\[[^\]]*\])?\{[^}]*\}"#, options: .regularExpression) else {
            return insertion + "\n" + text
        }
        var result = text
        result.insert(contentsOf: "\n" + insertion, at: range.upperBound)
        return result
    }

    /// The nearest enclosing `\begin{wrapfigure}` line index (0-based) and its side, if
    /// `lineRange` already sits inside one.
    static func enclosingWrapfigure(in text: String, lineRange: ClosedRange<Int>) -> (line: Int, side: String)? {
        let lines = text.components(separatedBy: "\n")
        let start = lineRange.lowerBound - 1
        guard start >= 0, start < lines.count else { return nil }
        var depth = 0
        var i = start - 1
        while i >= 0 {
            if lines[i].contains("\\end{wrapfigure}") { depth += 1 }
            if lines[i].contains("\\begin{wrapfigure}") {
                if depth == 0 {
                    let nsLine = lines[i] as NSString
                    if let match = wrapfigureBeginRegex.firstMatch(in: lines[i], range: NSRange(location: 0, length: nsLine.length)) {
                        return (i, nsLine.substring(with: match.range(at: 1)).lowercased())
                    }
                    return (i, "r")
                }
                depth -= 1
            }
            i -= 1
        }
        return nil
    }

    /// Wraps an element (bare image, or an existing figure/table float) so its text flows
    /// around it on the given side ("l" or "r"), converting a float in place or wrapping a bare
    /// image line. Callers must separately call `ensureWrapfigPreamble` on the *main* file first
    /// (same reasoning as `wrapInFreePosition` — `\usepackage` only belongs in the true preamble).
    static func setWrapText(in text: String, element: LaTeXElement, side: String, widthFraction: Double = 0.4) -> String {
        var lines = text.components(separatedBy: "\n")
        let startIdx = element.lineRange.lowerBound - 1
        let endIdx = element.lineRange.upperBound - 1
        guard startIdx >= 0, endIdx < lines.count, startIdx <= endIdx else { return text }
        let widthSpec = "\(formatted(widthFraction))\\linewidth"

        switch element.kind {
        case .float:
            // Floats already have \begin{kind}[..]/\end{kind} as their first/last line —
            // swap those two lines for wrapfigure's begin/end, keeping everything between.
            lines[startIdx] = "\\begin{wrapfigure}{\(side)}{\(widthSpec)}"
            lines[endIdx] = "\\end{wrapfigure}"
        case .image:
            let original = lines[startIdx...endIdx].joined(separator: "\n")
            let wrapped = """
            \\begin{wrapfigure}{\(side)}{\(widthSpec)}
            \\centering
            \(original)
            \\end{wrapfigure}
            """
            lines.replaceSubrange(startIdx...endIdx, with: wrapped.components(separatedBy: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// The line (0-based) of the `\end{wrapfigure}` matching a `\begin{wrapfigure}` at `beginLine`.
    static func matchingWrapfigureEnd(in text: String, beginLine: Int) -> Int? {
        let lines = text.components(separatedBy: "\n")
        guard beginLine >= 0, beginLine < lines.count else { return nil }
        for j in beginLine..<lines.count {
            if lines[j].contains("\\end{wrapfigure}") { return j }
            if j - beginLine > 200 { break }
        }
        return nil
    }

    private static let anyEnvBeginRegex = try! NSRegularExpression(pattern: #"\\begin\{[a-zA-Z*]+\}"#)
    private static let anyEnvEndRegex = try! NSRegularExpression(pattern: #"\\end\{[a-zA-Z*]+\}"#)

    /// Finds a line (1-based) at or before `line` where inserting new content is structurally
    /// safe — i.e. not in the middle of some other `\begin{...}/\end{...}` environment (align,
    /// equation, tabular, ...). If `line` sits inside one or more open environments, walks
    /// outward to just before the outermost one's `\begin`, so a relocated block never lands
    /// inside someone else's math/table block.
    private static func safeInsertionLine(in lines: [String], nearLine line: Int) -> Int {
        func matchCount(_ regex: NSRegularExpression, _ text: String) -> Int {
            regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }

        var depth = 0
        for i in 0..<min(max(line - 1, 0), lines.count) {
            depth += matchCount(anyEnvBeginRegex, lines[i])
            depth -= matchCount(anyEnvEndRegex, lines[i])
        }
        guard depth > 0 else { return line }

        var openDepth = depth
        var j = line - 2
        while j >= 0 {
            openDepth += matchCount(anyEnvEndRegex, lines[j])
            let begins = matchCount(anyEnvBeginRegex, lines[j])
            if begins > 0 {
                openDepth -= begins
                if openDepth <= 0 { return j + 1 }
            }
            j -= 1
        }
        return 1
    }

    /// Moves a line block to sit immediately before `targetLine` (1-based, in the *original*
    /// numbering) — used to relocate a dragged wrapfigure near wherever it was dropped, while
    /// keeping it a real wrapfigure (so text still reflows around it and reserves its space,
    /// unlike absolute/overlay positioning). The insertion point is snapped outside any
    /// existing environment it would otherwise land inside (see `safeInsertionLine`) — verified
    /// necessary by an actual failed compile during development, where a naive insertion landed
    /// mid-`align` and broke the document.
    static func relocateBlock(in text: String, lineRange: ClosedRange<Int>, toBeforeLine targetLine: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        let startIdx = lineRange.lowerBound - 1
        let endIdx = lineRange.upperBound - 1
        guard startIdx >= 0, endIdx < lines.count, startIdx <= endIdx else { return text }
        guard !(targetLine - 1 >= startIdx && targetLine - 1 <= endIdx + 1) else { return text } // dropped on itself

        let block = Array(lines[startIdx...endIdx])
        lines.removeSubrange(startIdx...endIdx)

        var targetIdx = targetLine - 1
        if targetIdx > endIdx {
            targetIdx -= block.count
        }
        targetIdx = max(0, min(targetIdx, lines.count))
        let safeLine = safeInsertionLine(in: lines, nearLine: targetIdx + 1)
        targetIdx = max(0, min(safeLine - 1, lines.count))

        lines.insert(contentsOf: block, at: targetIdx)
        return lines.joined(separator: "\n")
    }

    /// Flips an existing wrapfigure's side (left/right) in place.
    static func setWrapSide(in text: String, atLine index: Int, side: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard index >= 0, index < lines.count else { return text }
        let nsLine = lines[index] as NSString
        guard let match = wrapfigureBeginRegex.firstMatch(in: lines[index], range: NSRange(location: 0, length: nsLine.length)) else { return text }
        lines[index] = nsLine.replacingCharacters(in: match.range(at: 1), with: side)
        return lines.joined(separator: "\n")
    }

    /// Removes wrapping, converting the wrapfigure back to a plain `figure` environment (so
    /// captions/labels are preserved) — placement and free-position toggles still apply to a
    /// plain figure afterward.
    static func removeWrapText(in text: String, atLine beginIndex: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        guard beginIndex >= 0, beginIndex < lines.count else { return text }
        var endIndex: Int?
        for j in beginIndex..<lines.count {
            if lines[j].contains("\\end{wrapfigure}") { endIndex = j; break }
            if j - beginIndex > 200 { break }
        }
        guard let end = endIndex else { return text }
        lines[beginIndex] = "\\begin{figure}[htbp]"
        lines[end] = "\\end{figure}"
        return lines.joined(separator: "\n")
    }
}
