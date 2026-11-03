import SwiftUI
import AppKit

/// The choices offered by the text tools (Projects → Idea and Notes).
enum TextFormatPalette {
    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: Color { Color(nsColor: nsColor) }
        var nsColor: NSColor {
            var value: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&value)
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1
            )
        }
    }

    static let colors: [Swatch] = [
        Swatch(name: "Red", hex: "E53935"), Swatch(name: "Orange", hex: "FB8C00"), Swatch(name: "Gold", hex: "C79100"),
        Swatch(name: "Green", hex: "2E9E4F"), Swatch(name: "Teal", hex: "00897B"), Swatch(name: "Blue", hex: "1E6FE0"),
        Swatch(name: "Purple", hex: "8E3FB5"), Swatch(name: "Pink", hex: "D81B8A"), Swatch(name: "Brown", hex: "8D6E63"),
        Swatch(name: "Gray", hex: "757575"),
    ]

    /// "System" is the app's normal font; the rest are installed on every Mac.
    static let fonts = ["System", "Helvetica Neue", "Arial", "Avenir Next", "Georgia", "Times New Roman", "Palatino", "Menlo", "Courier New"]
    static let sizes = [10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32]
    static let defaultSize = 13
}

/// Bold / italic / underline, font, size and color buttons. It only draws the buttons — what they do
/// is up to the closures, so the same bar drives the rich-text Idea box and the Markdown notes.
struct TextFormatBar: View {
    var onBold: () -> Void
    var onItalic: () -> Void
    var onUnderline: () -> Void
    var onFont: (String) -> Void
    var onSize: (Int) -> Void
    /// nil = back to the default text color.
    var onColor: (TextFormatPalette.Swatch?) -> Void

    @State private var showColors = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBold) { Text("B").bold().frame(width: 18) }.help("Bold")
            Button(action: onItalic) { Text("I").italic().frame(width: 18) }.help("Italic")
            Button(action: onUnderline) { Text("U").underline().frame(width: 18) }.help("Underline")
            Divider().frame(height: 16)
            Menu {
                ForEach(TextFormatPalette.fonts, id: \.self) { name in
                    Button(name) { onFont(name) }
                }
            } label: {
                Label("Font", systemImage: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Font of the selected text")
            Menu {
                ForEach(TextFormatPalette.sizes, id: \.self) { size in
                    Button("\(size)") { onSize(size) }
                }
            } label: {
                Label("Size", systemImage: "textformat.size")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Font size of the selected text")
            Button { showColors.toggle() } label: {
                Image(systemName: "paintpalette")
            }
            .help("Text color")
            .popover(isPresented: $showColors, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 5), spacing: 8) {
                        ForEach(TextFormatPalette.colors) { swatch in
                            Button {
                                onColor(swatch)
                                showColors = false
                            } label: {
                                Circle().fill(swatch.color).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                    }
                    Button("Default color") {
                        onColor(nil)
                        showColors = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(12)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Notes (Markdown cells)

/// Text tools for the Markdown notes: they wrap whatever is selected in the cell being edited with
/// Markdown (`**bold**`, `*italic*`) or the small HTML subset `MarkdownBlockRenderer` lets through
/// (`<u>`, `<span style="color/font-family/font-size">`), so the formatting shows when the cell is
/// rendered and stays plain text in the saved notebook.
struct NotesFormatBar: View {
    var body: some View {
        TextFormatBar(
            onBold: { NotesMarkup.toggleWrap("**", "**") },
            onItalic: { NotesMarkup.toggleWrap("*", "*") },
            onUnderline: { NotesMarkup.wrap("<u>", "</u>") },
            onFont: { name in
                let family = name == "System" ? "-apple-system, Helvetica Neue" : "'\(name)'"
                NotesMarkup.wrap("<span style=\"font-family:\(family)\">", "</span>")
            },
            onSize: { NotesMarkup.wrap("<span style=\"font-size:\($0 + 1)px\">", "</span>") },
            onColor: { swatch in
                guard let swatch else { return }
                NotesMarkup.wrap("<span style=\"color:#\(swatch.hex)\">", "</span>")
            }
        )
    }
}

@MainActor
enum NotesMarkup {
    /// The Markdown cell being edited: the focused text view in the main window (not a TextField's
    /// field editor). Clicking a toolbar button doesn't move focus away from it.
    private static func focusedTextView() -> NSTextView? {
        let responder = NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        guard let textView = responder as? NSTextView, textView.isEditable, !textView.isFieldEditor else { return nil }
        return textView
    }

    static func wrap(_ open: String, _ close: String) {
        guard let textView = focusedTextView() else {
            NSSound.beep()
            return
        }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        replace(range, with: open + selected + close, in: textView)
        textView.setSelectedRange(NSRange(location: range.location + (open as NSString).length, length: (selected as NSString).length))
    }

    /// Like `wrap`, but removes the markers again when the selection is already wrapped in them.
    static func toggleWrap(_ open: String, _ close: String) {
        guard let textView = focusedTextView() else {
            NSSound.beep()
            return
        }
        let text = textView.string as NSString
        let range = textView.selectedRange()
        let openLength = (open as NSString).length
        let closeLength = (close as NSString).length
        if range.location >= openLength, range.location + range.length + closeLength <= text.length,
           text.substring(with: NSRange(location: range.location - openLength, length: openLength)) == open,
           text.substring(with: NSRange(location: range.location + range.length, length: closeLength)) == close {
            let outer = NSRange(location: range.location - openLength, length: range.length + openLength + closeLength)
            replace(outer, with: text.substring(with: range), in: textView)
            textView.setSelectedRange(NSRange(location: outer.location, length: range.length))
        } else {
            wrap(open, close)
        }
    }

    private static func replace(_ range: NSRange, with string: String, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }
}

// MARK: - Idea box (rich text)

/// Lets the toolbar act on the `NSTextView` of one `RichTextEditor`.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?

    private static let baseFont = NSFont.systemFont(ofSize: CGFloat(TextFormatPalette.defaultSize))

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let current: Int
        if range.length > 0, let storage = textView.textStorage {
            current = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int) ?? 0
        } else {
            current = (textView.typingAttributes[.underlineStyle] as? Int) ?? 0
        }
        setAttribute(.underlineStyle, current == 0 ? NSUnderlineStyle.single.rawValue : 0)
    }

    func setFont(family: String) {
        modifyFonts { font in
            let manager = NSFontManager.shared
            let traits = manager.traits(of: font)
            var result: NSFont
            if family == "System" {
                result = NSFont.systemFont(ofSize: font.pointSize)
                if traits.contains(.boldFontMask) { result = manager.convert(result, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { result = manager.convert(result, toHaveTrait: .italicFontMask) }
            } else {
                result = manager.convert(font, toFamily: family)
            }
            return result
        }
    }

    func setSize(_ size: Int) {
        modifyFonts { NSFontManager.shared.convert($0, toSize: CGFloat(size)) }
    }

    func setColor(_ color: NSColor?) {
        setAttribute(.foregroundColor, color ?? NSColor.textColor)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let manager = NSFontManager.shared
        let range = textView.selectedRange()
        let sample: NSFont
        if range.length > 0, let storage = textView.textStorage {
            sample = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? Self.baseFont
        } else {
            sample = (textView.typingAttributes[.font] as? NSFont) ?? Self.baseFont
        }
        let turnOn = !manager.traits(of: sample).contains(trait)
        modifyFonts { font in
            turnOn ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
        }
    }

    private func modifyFonts(_ transform: (NSFont) -> NSFont) {
        guard let textView, let storage = textView.textStorage else { return }
        textView.window?.makeFirstResponder(textView)
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes[.font] = transform((attributes[.font] as? NSFont) ?? Self.baseFont)
            textView.typingAttributes = attributes
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            storage.addAttribute(.font, value: transform((value as? NSFont) ?? Self.baseFont), range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func setAttribute(_ key: NSAttributedString.Key, _ value: Any) {
        guard let textView, let storage = textView.textStorage else { return }
        textView.window?.makeFirstResponder(textView)
        let range = textView.selectedRange()
        if range.length == 0 {
            textView.typingAttributes[key] = value
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(key, value: value, range: range)
        textView.didChangeText()
    }
}

/// An editable rich-text box stored as RTF. Dark mode needs care: the default text color is dynamic,
/// but RTF can't hold a dynamic color, so it's saved as black and mapped back to the dynamic color on
/// load — your own colors round-trip as chosen.
struct RichTextEditor: NSViewRepresentable {
    let initialRTF: Data?
    let initialPlainText: String
    @ObservedObject var controller: RichTextController
    /// Called after every edit with the RTF data and the plain-text version.
    var onChange: (Data?, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: CGFloat(TextFormatPalette.defaultSize))
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor

        if let initialRTF, let loaded = NSAttributedString(rtf: initialRTF, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(Self.withDynamicDefaultColor(loaded))
        } else {
            textView.string = initialPlainText
        }
        // Text typed into an empty box starts from the default look, not whatever the last run had.
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: CGFloat(TextFormatPalette.defaultSize)),
            .foregroundColor: NSColor.textColor,
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        controller.textView = nsView.documentView as? NSTextView
    }

    private static func withDynamicDefaultColor(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else {
                result.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                return
            }
            if color.redComponent < 0.01, color.greenComponent < 0.01, color.blueComponent < 0.01 {
                result.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            }
        }
        return result
    }

    static func rtfData(from text: NSAttributedString) -> Data? {
        let result = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if let color = value as? NSColor, color == NSColor.textColor {
                result.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
        return try? result.data(from: full, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (Data?, String) -> Void
        init(onChange: @escaping (Data?, String) -> Void) { self.onChange = onChange }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let attributed = NSAttributedString(attributedString: textView.attributedString())
            onChange(attributed.length == 0 ? nil : RichTextEditor.rtfData(from: attributed), textView.string)
        }
    }
}
