import SwiftUI
import AppKit

/// Reports focus changes and Cmd+Click (SyncTeX forward search) so the host view can know
/// which pane is active and jump the PDF preview to the clicked line.
final class FocusTrackingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onCommandClick: ((Int) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChange?(true) }
        return result
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            let line = (string as NSString).substring(to: min(charIndex, (string as NSString).length))
                .reduce(1) { count, char in char == "\n" ? count + 1 : count }
            onCommandClick?(line)
        }
        super.mouseDown(with: event)
    }
}

struct CodeEditorView: NSViewRepresentable {
    @EnvironmentObject var settings: AppSettings
    @Binding var text: String
    /// Identity of the file currently shown (e.g. FileNode.id) — used to tell "switched to a
    /// different file" apart from "this file's content changed in place" (typing, AI edits,
    /// Dynamic PDF edits), since only the latter should register as an undoable operation.
    let fileID: String
    @ObservedObject var searchController: EditorSearchController
    @ObservedObject var syncTeX: SyncTeXBridge
    @ObservedObject var undoController: EditorUndoController
    var onChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusTrackingTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.insertionPointColor = .labelColor
        textView.string = text
        textView.onFocusChange = { focused in
            if focused { onFocus?() }
        }
        textView.onCommandClick = { line in
            onCommandClick?(line)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        applyBackground(textView: textView, scrollView: scrollView)
        context.coordinator.highlight(textView, settings: settings)
        context.coordinator.lastFileID = fileID
        searchController.textView = textView
        undoController.attach(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        applyBackground(textView: textView, scrollView: nsView)
        searchController.textView = textView
        undoController.attach(textView)

        if textView.string != text {
            if context.coordinator.lastFileID != fileID {
                // A different file, not an in-place edit — plain replace, no undo entry, and
                // clear prior undo history so Cmd+Z can't cross between files.
                textView.string = text
                textView.undoManager?.removeAllActions()
                context.coordinator.lastFileID = fileID
            } else {
                let ranges = textView.selectedRanges
                // Go through the Cocoa text-editing hooks (not a bare `.string =`) so this
                // registers with NSTextView's undo manager — otherwise programmatic replacements
                // (AI-applied fixes, Dynamic PDF edits) would be invisible to Cmd+Z.
                let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
                if textView.shouldChangeText(in: fullRange, replacementString: text) {
                    textView.textStorage?.replaceCharacters(in: fullRange, with: text)
                    textView.didChangeText()
                } else {
                    textView.string = text
                }
                textView.selectedRanges = ranges
            }
        }
        context.coordinator.lastFileID = fileID
        context.coordinator.highlight(textView, settings: settings)

        if let line = syncTeX.pendingEditorLine {
            scrollToLine(line, in: textView)
            DispatchQueue.main.async { syncTeX.pendingEditorLine = nil }
        }
    }

    private func scrollToLine(_ line: Int, in textView: NSTextView) {
        let nsString = textView.string as NSString
        var currentLine = 1
        var index = 0
        while currentLine < line, index < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            index = lineRange.location + lineRange.length
            currentLine += 1
        }
        let targetRange = nsString.lineRange(for: NSRange(location: min(index, nsString.length), length: 0))
        textView.scrollRangeToVisible(targetRange)
        textView.setSelectedRange(targetRange)
        textView.showFindIndicator(for: targetRange)
        textView.window?.makeFirstResponder(textView)
    }

    private func applyBackground(textView: NSTextView, scrollView: NSScrollView) {
        let backgroundColor = NSColor(settings.color(for: .editorBackground))
        textView.backgroundColor = backgroundColor
        scrollView.backgroundColor = backgroundColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var lastFileID: String?
        private static let commandRegex = try? NSRegularExpression(pattern: "\\\\[a-zA-Z]+\\*?")
        private static let commentRegex = try? NSRegularExpression(pattern: "%[^\n]*")
        private static let braceRegex = try? NSRegularExpression(pattern: "[{}\\[\\]]")
        private static let mathRegex = try? NSRegularExpression(pattern: "\\$[^$\n]*\\$")

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView, settings: parent.settings)
            parent.onChange?(textView.string)
        }

        func highlight(_ textView: NSTextView, settings: AppSettings) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            textView.textColor = NSColor(settings.syntaxColor(for: .mainText))
            guard fullRange.length > 0 else { return }

            storage.beginEditing()
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor(settings.syntaxColor(for: .mainText)), range: fullRange)

            apply(Self.braceRegex, storage: storage, range: fullRange, color: NSColor(settings.syntaxColor(for: .brace)))
            apply(Self.mathRegex, storage: storage, range: fullRange, color: NSColor(settings.syntaxColor(for: .math)))
            apply(Self.commandRegex, storage: storage, range: fullRange, color: NSColor(settings.syntaxColor(for: .command)))
            apply(Self.commentRegex, storage: storage, range: fullRange, color: NSColor(settings.syntaxColor(for: .comment)))

            storage.endEditing()
        }

        private func apply(_ regex: NSRegularExpression?, storage: NSTextStorage, range: NSRange, color: NSColor) {
            guard let regex else { return }
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
    }
}
