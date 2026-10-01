import PDFKit
import SwiftUI

/// Bridges AppKit's `PDFView` into SwiftUI — no native SwiftUI PDF view exists, and `PDFView` is
/// what actually supports text selection (needed for highlighting) and interactive zoom.
/// `onViewCreated` hands the live `PDFView` instance back up to the SwiftUI parent so its toolbar
/// can call zoom/highlight actions directly on it, and `selection` mirrors the view's current text
/// selection (nil when empty) so the highlight toolbar can disable itself and the color-suggestion
/// popup knows when to appear and where.
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    var onViewCreated: (PDFView) -> Void
    var onCopyAsLatex: () -> Void
    var highlightColors: [HighlightColorOption]
    var onHighlight: (HighlightColorOption) -> Void
    var onTranslate: () -> Void
    /// Right-clicking an existing highlight or free-text annotation offers to remove it.
    var onRemoveAnnotation: (PDFAnnotation) -> Void
    /// Right-clicking an existing free-text annotation offers to edit its contents.
    var onEditText: (PDFAnnotation) -> Void
    /// Right-clicking an existing highlight annotation offers to change its color, from the same
    /// palette as making a brand-new highlight.
    var onChangeAnnotationColor: (PDFAnnotation, HighlightColorOption) -> Void
    /// While true, a click on the page places a new free-text annotation there instead of
    /// starting a normal text selection.
    var isAddingText: Bool
    var onTextClick: (CGPoint, PDFPage) -> Void
    /// The color shown behind/around the page itself — not the page content, which stays
    /// whatever the PDF actually renders. Settings → Appearance → Reader → "PDF Background".
    var pageBackgroundColor: Color
    @Binding var selection: PDFSelection?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = MaziarPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        applyBackground(pageBackgroundColor, to: view)
        applyCallbacks(to: view)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: view
        )
        onViewCreated(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
        applyBackground(pageBackgroundColor, to: nsView)
        applyCallbacks(to: nsView)
    }

    /// Sets `backgroundColor` (what `PDFView` itself actually paints behind page content) *and*
    /// puts the view on a layer with `isOpaque = false` and a matching, separately-set
    /// `CALayer.backgroundColor`. `PDFView` isn't layer-backed by default, and AppKit's default
    /// compositing for a newly-layer-backed view can still treat it as opaque regardless of the
    /// `NSColor`'s own alpha — meaning a `Color.clear` passed in for Glass style (see `pdfPane` in
    /// `PaperReaderWindow.swift`, intended to let a SwiftUI `Material` sitting behind this view
    /// show through) could silently get composited as if fully opaque instead of genuinely
    /// transparent. Explicitly forcing the layer non-opaque with its own clear/matching background
    /// color removes that ambiguity.
    private func applyBackground(_ color: Color, to view: PDFView) {
        let nsColor = NSColor(color)
        view.backgroundColor = nsColor
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = nsColor.cgColor
    }

    private func applyCallbacks(to view: PDFView) {
        guard let view = view as? MaziarPDFView else { return }
        view.onCopyAsLatex = onCopyAsLatex
        view.highlightColors = highlightColors
        view.onHighlight = onHighlight
        view.onTranslate = onTranslate
        view.onRemoveAnnotation = onRemoveAnnotation
        view.onEditText = onEditText
        view.onChangeAnnotationColor = onChangeAnnotationColor
        view.isAddingText = isAddingText
        view.onTextClick = onTextClick
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        @Binding var selection: PDFSelection?

        init(selection: Binding<PDFSelection?>) {
            _selection = selection
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            let current = view.currentSelection
            let text = current?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            selection = (text?.isEmpty ?? true) ? nil : current
        }
    }
}

/// Bundles a right-clicked highlight annotation with the color the user picked for it in the
/// **Change Color** submenu, since an `NSMenuItem.representedObject` only carries one object —
/// `handleChangeAnnotationColor(_:)` needs both.
private struct AnnotationColorChange {
    let annotation: PDFAnnotation
    let option: HighlightColorOption
}

/// `PDFView` subclass that extends the view's normal right-click menu with **Highlight** (a
/// submenu of named colors, Mendeley/Preview-style: select text, right-click, pick a color),
/// **Translate**, **Copy as LaTeX** (all shown only with an active text selection), and — when
/// right-clicking directly on an existing highlight or free-text annotation instead — **Change
/// Color**/**Remove Highlight**/**Edit Text**/**Remove Text**. Also supports a click-to-place
/// free-text annotation mode (`isAddingText`), the "write on the PDF" tool, via a `mouseDown`
/// override that intercepts clicks only while that mode is active so normal text selection is
/// unaffected otherwise. Subclassing and overriding `menu(for:)`/`mouseDown(with:)` is the standard
/// AppKit way to extend a view's interaction without losing its built-in behavior (Copy, Look Up,
/// text selection, etc.).
final class MaziarPDFView: PDFView {
    var onCopyAsLatex: (() -> Void)?
    var highlightColors: [HighlightColorOption] = []
    var onHighlight: ((HighlightColorOption) -> Void)?
    var onTranslate: (() -> Void)?
    var onRemoveAnnotation: ((PDFAnnotation) -> Void)?
    var onEditText: ((PDFAnnotation) -> Void)?
    var onChangeAnnotationColor: ((PDFAnnotation, HighlightColorOption) -> Void)?
    var isAddingText = false
    var onTextClick: ((CGPoint, PDFPage) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        if let annotation = annotation(at: event) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            if annotation.type == "FreeText" {
                let editItem = NSMenuItem(title: "Edit Text", action: #selector(handleEditText(_:)), keyEquivalent: "")
                editItem.target = self
                editItem.representedObject = annotation
                menu.addItem(editItem)
            } else if !highlightColors.isEmpty {
                let changeColorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for option in highlightColors {
                    let colorItem = NSMenuItem(title: option.name, action: #selector(handleChangeAnnotationColor(_:)), keyEquivalent: "")
                    colorItem.target = self
                    colorItem.image = Self.swatchImage(for: NSColor(option.color))
                    colorItem.representedObject = AnnotationColorChange(annotation: annotation, option: option)
                    submenu.addItem(colorItem)
                }
                changeColorItem.submenu = submenu
                menu.addItem(changeColorItem)
            }
            let label = annotation.type == "FreeText" ? "Remove Text" : "Remove Highlight"
            let removeItem = NSMenuItem(title: label, action: #selector(handleRemoveAnnotation(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = annotation
            menu.addItem(removeItem)
        }

        guard currentSelection != nil else { return menu }
        if menu.numberOfItems > 0 {
            menu.addItem(.separator())
        }

        if !highlightColors.isEmpty {
            let highlightItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for option in highlightColors {
                let colorItem = NSMenuItem(title: option.name, action: #selector(handleHighlight(_:)), keyEquivalent: "")
                colorItem.target = self
                colorItem.image = Self.swatchImage(for: NSColor(option.color))
                colorItem.representedObject = option
                submenu.addItem(colorItem)
            }
            highlightItem.submenu = submenu
            menu.addItem(highlightItem)
        }

        let translateItem = NSMenuItem(title: "Translate", action: #selector(handleTranslate), keyEquivalent: "")
        translateItem.target = self
        menu.addItem(translateItem)

        let latexItem = NSMenuItem(title: "Copy as LaTeX", action: #selector(handleCopyAsLatex), keyEquivalent: "")
        latexItem.target = self
        menu.addItem(latexItem)

        return menu
    }

    /// The topmost highlight/free-text annotation at the event's location, if any — `PDFPage
    /// .annotation(at:)` takes page-space coordinates, so the event's window location is converted
    /// to view space, then to whichever page is under the click, then to that page's own space.
    private func annotation(at event: NSEvent) -> PDFAnnotation? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        guard let annotation = page.annotation(at: pagePoint) else { return nil }
        return annotation.type == "Highlight" || annotation.type == "FreeText" ? annotation : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isAddingText else {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        onTextClick?(pagePoint, page)
    }

    @objc private func handleHighlight(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? HighlightColorOption else { return }
        onHighlight?(option)
    }

    @objc private func handleTranslate() {
        onTranslate?()
    }

    @objc private func handleCopyAsLatex() {
        onCopyAsLatex?()
    }

    @objc private func handleRemoveAnnotation(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onRemoveAnnotation?(annotation)
    }

    @objc private func handleEditText(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? PDFAnnotation else { return }
        onEditText?(annotation)
    }

    @objc private func handleChangeAnnotationColor(_ sender: NSMenuItem) {
        guard let change = sender.representedObject as? AnnotationColorChange else { return }
        onChangeAnnotationColor?(change.annotation, change.option)
    }

    private static func swatchImage(for color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }
}

/// A near-invisible full-size overlay that just forwards scroll-wheel deltas — SwiftUI has no
/// modifier for raw scroll-wheel events on a plain view (only inside a `ScrollView`), so the
/// highlight-suggestion popup's "move between colors with the mouse scroll wheel" behavior needs
/// this small AppKit bridge, the same reasoning as `PDFKitView` itself.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatchingView {
        let view = CatchingView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatchingView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatchingView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event.scrollingDeltaY)
        }
    }
}
