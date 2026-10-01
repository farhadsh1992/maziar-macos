import SwiftUI

/// Renders one note's body as Markdown text with LaTeX formulas (`$...$` inline, `$$...$$`
/// display) typeset to their real visual shape, instead of raw source. Inline formulas flow
/// within the surrounding sentence (built as one concatenated `Text`, the same trick SwiftUI uses
/// for text-with-icon labels); display formulas get their own centered block. Formula images come
/// from `PaperFormulaRenderer`, which compiles+caches them — this view just kicks off rendering
/// for whatever isn't cached yet and shows a small progress/error state meanwhile.
struct NoteRenderedView: View {
    let text: String
    @EnvironmentObject var texManager: TeXInstallationManager
    @ObservedObject private var renderer = PaperFormulaRenderer.shared

    @State private var images: [String: NSImage] = [:]
    @State private var failedFormulas: Set<String> = []

    private enum RenderBlock {
        case flow([NoteSegment])
        case display(String)
    }

    var body: some View {
        let segments = NoteContentParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks(from: segments).enumerated()), id: \.offset) { _, block in
                switch block {
                case .flow(let pieces):
                    flowText(pieces)
                case .display(let formula):
                    displayFormula(formula)
                }
            }
        }
        .task(id: text) {
            for segment in segments {
                switch segment {
                case .inlineMath(let formula): await renderOne(formula, displayMode: false)
                case .displayMath(let formula): await renderOne(formula, displayMode: true)
                case .text: break
                }
            }
        }
    }

    private func blocks(from segments: [NoteSegment]) -> [RenderBlock] {
        var result: [RenderBlock] = []
        var current: [NoteSegment] = []
        for segment in segments {
            if case .displayMath(let formula) = segment {
                if !current.isEmpty { result.append(.flow(current)); current = [] }
                result.append(.display(formula))
            } else {
                current.append(segment)
            }
        }
        if !current.isEmpty { result.append(.flow(current)) }
        return result
    }

    private func flowText(_ pieces: [NoteSegment]) -> some View {
        var combined = Text("")
        for piece in pieces {
            switch piece {
            case .text(let string):
                combined = combined + markdownText(string)
            case .inlineMath(let formula):
                let key = cacheKey(formula, displayMode: false)
                if let image = images[key] {
                    combined = combined + Text(Image(nsImage: image))
                } else if failedFormulas.contains(key) {
                    combined = combined + Text("$\(formula)$").foregroundColor(.red)
                } else {
                    combined = combined + Text("$\(formula)$").italic().foregroundColor(.secondary)
                }
            case .displayMath:
                break
            }
        }
        return combined.font(.system(size: 12.5)).textSelection(.enabled)
    }

    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    private func displayFormula(_ formula: String) -> some View {
        let key = cacheKey(formula, displayMode: true)
        return Group {
            if let image = images[key] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 60)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if failedFormulas.contains(key) {
                Text("$$\(formula)$$")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func renderOne(_ formula: String, displayMode: Bool) async {
        let key = cacheKey(formula, displayMode: displayMode)
        guard images[key] == nil, !failedFormulas.contains(key) else { return }
        do {
            images[key] = try await renderer.image(for: formula, displayMode: displayMode, texManager: texManager)
        } catch {
            failedFormulas.insert(key)
        }
    }

    private func cacheKey(_ formula: String, displayMode: Bool) -> String {
        (displayMode ? "D::" : "I::") + formula
    }
}
