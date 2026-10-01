import SwiftUI
import AppKit

/// A `TextField(axis: .vertical)` alternative for notebook/notes cells. `TextField(axis: .vertical)`
/// was tried first and never reliably grew past its very first measured height in this card-styled
/// (background + clipShape + overlay) context — switching the enclosing `LazyVStack` to a plain
/// `VStack` (a documented, unrelated SwiftUI re-measurement gotcha) didn't fix it either, meaning
/// the growth itself, not list laziness, was the real problem. This sidesteps SwiftUI's own
/// auto-sizing entirely: a real `NSTextView` measures its own content height via `NSLayoutManager`
/// and reports it back through a height binding — the same "measure directly, report back" approach
/// `NotebookCellWebView` already uses for the read-only HTML preview, just via `NSLayoutManager`
/// instead of a page `ResizeObserver` — clamped between one line and `maxLines`; past that it
/// scrolls internally instead of growing further. The caller applies the reported height with its
/// own `.frame(height:)`.
struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont
    var maxLines: Int
    /// Defaults to the system's normal (light/dark-adapting) text color; callers offering a
    /// non-default cell background (e.g. a black cell) pass an explicit color so the text stays
    /// readable against it instead of following the system appearance independently.
    var textColor: NSColor = .textColor
    /// Shift+Return — the Jupyter convention for "run this cell" (rendering a markdown cell, since
    /// these cells have no code to execute), rather than inserting a newline like plain Return.
    var onShiftEnter: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, maxLines: maxLines)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ShiftEnterTextView()
        textView.onShiftEnter = onShiftEnter
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        // Matches `CodeEditorView`'s own text view setup — a plain `NSTextView()` defaults to
        // macOS's system-wide smart-quote/dash/spelling/text-replacement substitutions, which
        // would silently rewrite characters as you type (e.g. straight quotes into curly ones)
        // instead of storing exactly what was typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.string = text
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.lastKnownText = text
        context.coordinator.measure(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? ShiftEnterTextView else { return }
        textView.onShiftEnter = onShiftEnter
        context.coordinator.maxLines = maxLines
        // Compares against what *this coordinator itself* last echoed into the binding (set right
        // below, and in `textDidChange`), not against `textView.string` or first-responder status —
        // an earlier version of this check skipped the reload while the view had focus, reasoning
        // that `text` not yet matching `.string` just meant a stale echo from a lagging render pass
        // (true for ordinary typing in *this* cell while *other* cells re-render). But this view
        // sits in a `ForEach` of a reorderable array, and SwiftUI can reuse the very same
        // `NSTextView` for a logically *different* cell after a reorder swaps array positions — it
        // only has the row's position to go on, not which cell now belongs there. When that
        // happened, the focus-based guard wrongly treated the new cell's real content as "just an
        // echo" and refused to load it, leaving the view silently still bound to the old cell's
        // text — so two visually separate cells appeared to edit in lockstep, because one of them
        // was secretly still writing into the other's data. Tracking "did *we* last produce this
        // exact value" instead of "does this view currently have focus" fixes both cases correctly:
        // a real echo still matches (no reset, no fighting the cursor), but a genuine identity/
        // content change no longer gets mistaken for one, focused or not.
        if text != context.coordinator.lastKnownText {
            textView.string = text
            context.coordinator.lastKnownText = text
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        context.coordinator.measure(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        var maxLines: Int
        /// The last value this coordinator itself pushed into `text`, whether from a user edit
        /// (`textDidChange`) or a programmatic load (`makeNSView`/`updateNSView`) — see the long
        /// comment in `updateNSView` for why this, not first-responder status, is the correct signal
        /// for "is an incoming `text` update a real external change."
        var lastKnownText: String?

        init(text: Binding<String>, height: Binding<CGFloat>, maxLines: Int) {
            _text = text
            _height = height
            self.maxLines = maxLines
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            lastKnownText = textView.string
            measure(textView)
        }

        func measure(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            let font = textView.font ?? .systemFont(ofSize: 13)
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let minHeight = lineHeight + textView.textContainerInset.height * 2
            let maxHeight = lineHeight * CGFloat(maxLines) + textView.textContainerInset.height * 2
            let clamped = min(max(usedHeight, minHeight), maxHeight)
            if abs(height - clamped) > 0.5 {
                height = clamped
            }
        }
    }

    /// Plain Return and Shift+Return both resolve to the same `insertNewline:` command selector in
    /// AppKit's default key bindings, so `NSTextViewDelegate.textView(_:doCommandBy:)` can't tell
    /// them apart — overriding `keyDown` directly, and checking the raw event's modifier flags, is
    /// the only reliable way to catch Shift+Return specifically before it inserts a newline.
    final class ShiftEnterTextView: NSTextView {
        var onShiftEnter: (() -> Void)?

        /// Every cell in a notebook/notes list is its own `NSTextView` instance, but `NSResponder`'s
        /// default `.undoManager` walks up to whatever the *window* provides — one shared
        /// `UndoManager` for every view in it that doesn't supply its own. Left at that default,
        /// Cmd+Z in one cell could undo an edit made in a *different* cell, if that edit happened to
        /// be the most recent one registered anywhere in the window. Overriding this to a private,
        /// per-instance `UndoManager` makes Cmd+Z/Cmd+Shift+Z strictly local to whichever cell
        /// currently has focus, regardless of what was typed elsewhere.
        private lazy var privateUndoManager = UndoManager()
        override var undoManager: UndoManager? { privateUndoManager }

        override func keyDown(with event: NSEvent) {
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76 // Return, keypad Enter
            if isReturnKey, event.modifierFlags.contains(.shift) {
                onShiftEnter?()
                return
            }
            super.keyDown(with: event)
        }
    }
}
