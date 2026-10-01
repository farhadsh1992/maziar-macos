import Foundation

/// One piece of a note's body: plain (Markdown) text, or a LaTeX formula to be typeset.
enum NoteSegment: Equatable {
    case text(String)
    case inlineMath(String)
    case displayMath(String)
}

/// Splits note text on `$...$` (inline) and `$$...$$` (display) LaTeX delimiters, the same
/// convention as Markdown+MathJax/KaTeX renderers, leaving everything else as plain Markdown text.
/// `\$` escapes a literal dollar sign; an unterminated `$` is left as literal text rather than
/// swallowing the rest of the note.
enum NoteContentParser {
    static func parse(_ text: String) -> [NoteSegment] {
        var segments: [NoteSegment] = []
        var textBuffer = ""
        let chars = Array(text)
        var i = 0

        func flushText() {
            if !textBuffer.isEmpty {
                segments.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                textBuffer.append("$")
                i += 2
                continue
            }

            if c == "$" {
                let isDisplay = i + 1 < chars.count && chars[i + 1] == "$"
                let start = i + (isDisplay ? 2 : 1)
                var j = start
                var closeIndex: Int?

                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "$" {
                        j += 2
                        continue
                    }
                    if isDisplay {
                        if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "$" {
                            closeIndex = j
                            break
                        }
                    } else if chars[j] == "$" {
                        closeIndex = j
                        break
                    }
                    j += 1
                }

                if let closeIndex {
                    let formula = String(chars[start..<closeIndex]).replacingOccurrences(of: "\\$", with: "$")
                    if !formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flushText()
                        segments.append(isDisplay ? .displayMath(formula) : .inlineMath(formula))
                        i = closeIndex + (isDisplay ? 2 : 1)
                        continue
                    }
                }
            }

            textBuffer.append(c)
            i += 1
        }

        flushText()
        return segments
    }
}
