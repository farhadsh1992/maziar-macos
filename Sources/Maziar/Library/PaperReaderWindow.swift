import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import AVFoundation

extension View {
    /// Applies the Reader's companion-pane/toolbar background for the active `readerVisualStyle`,
    /// branching to a concrete `.background(.regularMaterial)` or `.background(Color)` call per
    /// case via `@ViewBuilder` rather than going through `AppSettings.readerCompanionBackground()`'s
    /// `AnyShapeStyle`-erased return value. Erasing `Material` to `AnyShapeStyle` was silently
    /// defeating SwiftUI's specialized frosted/blurred rendering path for `Material` — the erased
    /// value still satisfies `ShapeStyle` and compiles fine, but macOS was rendering it as a flat
    /// translucent fill instead of a true `NSVisualEffectView`-backed blur, which is exactly "Glass
    /// style doesn't look like glass." Keeping each branch's call on a concrete type (as this
    /// `@ViewBuilder` does, since each `if`/`else` arm gets its own literal `.background(...)` call
    /// rather than a shared value being erased and passed around) keeps macOS on that specialized
    /// path.
    /// - Parameters:
    ///   - region: which `ThemeRegion` supplies the Normal-style color. Defaults to the shared
    ///     companion-pane/PDF-matte region; the highlight toolbar passes `.readerToolbarBackground`
    ///     instead so its background can be configured independently from everything else.
    ///   - material: which `Material` Glass style uses. Defaults to `.regularMaterial`; the
    ///     highlight toolbar passes `.ultraThinMaterial` for a visibly lighter, more transparent
    ///     glass look specifically there, distinct from the rest of the window.
    @ViewBuilder
    func readerPanelBackground(_ settings: AppSettings, region: ThemeRegion = .readerCompanionBackground, material: Material = .regularMaterial) -> some View {
        switch settings.readerVisualStyle {
        case .glass:
            self.background(material)
        case .normal:
            self.background(settings.color(for: region))
        }
    }
}

/// Holds the live `PDFView` instance created by `PDFKitView.makeNSView`, as a reference type
/// (`@StateObject`) rather than `@State` — a plain `@State private var pdfView: PDFView?` written
/// to from inside `onViewCreated`'s closure (itself invoked from `NSViewRepresentable.makeNSView`,
/// outside SwiftUI's normal view-body update cycle) was not reliably visible to later reads, even
/// an immediate read in the very same closure. A `@StateObject`-backed reference type sidesteps
/// that: the closure captures and mutates the same class instance regardless of which struct
/// "generation" of `PaperReaderWindow` it was created from, with no value-type/closure-capture
/// ambiguity possible.
@MainActor
final class PDFViewHolder: ObservableObject {
    @Published var view: PDFView?
    /// Local `NSEvent` monitor backing the reader window's Cmd+C/X/V fallback — see
    /// `PaperReaderWindow.installKeyboardShortcutMonitor()`. Stored here, on a persistent reference
    /// type, rather than as `@State` on the view struct, so install/remove can mutate it safely
    /// from inside an escaping closure regardless of which struct "generation" is executing.
    var keyboardShortcutMonitor: Any?
}

/// Not `private` — `SettingsView` also references this to build the "which modes appear in the
/// Reader's quick-access icon rail" toggle list.
enum ReaderCompanionMode: String, CaseIterable, Identifiable {
    case translator
    case chat
    case notes
    case references
    case outline
    case videos
    case code

    var id: String { rawValue }
    var label: String {
        switch self {
        case .translator: return "Translator"
        case .chat: return "AI Chat"
        case .notes: return "Notes"
        case .references: return "References"
        case .outline: return "Outline"
        case .videos: return "Videos"
        case .code: return "Code"
        }
    }

    var icon: String {
        switch self {
        case .translator: return "character.bubble"
        case .chat: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        case .references: return "text.book.closed"
        case .outline: return "list.bullet.indent"
        case .videos: return "play.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Which of the three surfaces the reader's left pane currently shows — the original PDF, the
/// AI-reconstructed LaTeX source (editable), or the PDF freshly compiled from that LaTeX.
private enum ReaderPDFViewMode: String, CaseIterable, Identifiable {
    case original
    case latex
    case compiled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "PDF"
        case .latex: return "LaTeX"
        case .compiled: return "New PDF"
        }
    }
}

/// One item of a PDF's embedded table of contents, flattened from `PDFOutline` into a plain,
/// `Identifiable` value type SwiftUI can diff and recurse over directly.
private struct OutlineItem: Identifiable {
    let id = UUID()
    let label: String
    let destination: PDFDestination?
    let children: [OutlineItem]
}

private func buildOutlineItems(_ outline: PDFOutline?) -> [OutlineItem] {
    guard let outline else { return [] }
    var items: [OutlineItem] = []
    for i in 0..<outline.numberOfChildren {
        guard let child = outline.child(at: i) else { continue }
        items.append(OutlineItem(
            label: child.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? child.label! : "Untitled",
            destination: child.destination,
            children: buildOutlineItems(child)
        ))
    }
    return items
}

/// The color of whichever outline entry the reader is currently scrolled to — a fixed, literal
/// turquoise rather than a themeable/settings color, since this is a transient "you are here"
/// marker rather than a piece of the app's chrome.
private let outlineCurrentSectionColor = Color(hex: "#40E0D0") ?? .teal

private struct OutlineRowView: View {
    let item: OutlineItem
    let level: Int
    let currentItemID: UUID?
    let onSelect: (PDFDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let destination = item.destination { onSelect(destination) }
            } label: {
                Text(item.label)
                    .font(.system(size: max(13 - CGFloat(level), 11)))
                    .fontWeight(item.id == currentItemID ? .semibold : .regular)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        item.id == currentItemID ? outlineCurrentSectionColor.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(level) * 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .disabled(item.destination == nil)

            ForEach(item.children) { child in
                OutlineRowView(item: child, level: level + 1, currentItemID: currentItemID, onSelect: onSelect)
            }
        }
    }
}

/// Reader window — opened alongside the paper (`openWindow(id: "paper-reader", value: entry.id)`),
/// the paper's PDF now opens *inside* this window (left pane, via PDFKit) rather than externally in
/// Preview, so highlighting and the Translator/AI Chat/Notes tools on the right can be used against
/// it directly. Above the PDF sits a small toolbar: a user-managed palette of named highlight
/// colors (select PDF text, click a color) and zoom in/out. The two columns are user-resizable via
/// a draggable divider, and both the divider position and the window's own size are remembered
/// (`@AppStorage`) so the next Reader window opens at the size/split you left it at.
struct PaperReaderWindow: View {
    let paperID: UUID
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var aiSettings: AISettings
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var texManager: TeXInstallationManager
    @Environment(\.dismiss) private var dismiss
    /// The Reader window's actual, resolved appearance — already reflects `settings
    /// .readerColorScheme()` (applied as `.preferredColorScheme` at the window's root in
    /// `MaziarApp`), so reading it here always matches what's really on screen, whether that came
    /// from an explicit Reader override or just the system default. Passed to the AI Chat mode's
    /// embedded ChatGPT/Claude page so it visually matches the Reader instead of defaulting to its
    /// own independent light/dark choice.
    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: ReaderCompanionMode = .chat
    @State private var notes: [PaperNote] = []
    @State private var notesFormat: LibraryStore.NotesFormat = .notebook
    @StateObject private var chatVM = PaperChatViewModel()

    @State private var translatorInput = ""
    @State private var translatorOutput = ""
    @State private var targetLanguage = "English"
    @State private var isTranslating = false
    @State private var translatorError: String?
    /// Persists as the same instance across body re-evaluations (that's what `@State` does for a
    /// reference type too, not just value types) rather than a fresh, un-warmed-up synthesizer per
    /// render — matters here since a re-render mid-speech shouldn't cut it off.
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    @State private var pdfDocument: PDFDocument?
    @State private var pdfFileURL: URL?
    @StateObject private var pdfViewHolder = PDFViewHolder()
    private var pdfView: PDFView? {
        get { pdfViewHolder.view }
        nonmutating set { pdfViewHolder.view = newValue }
    }
    @State private var pdfSelection: PDFSelection?
    @StateObject private var pdfSearch = PDFSearchController()
    @State private var showPDFFind = false

    // -- PDF → LaTeX -----------------------------------------------------------
    @State private var pdfViewMode: ReaderPDFViewMode = .original
    @State private var latexSource = ""
    @State private var isConvertingToLatex = false
    @State private var latexConversionProgress: (done: Int, total: Int)?
    @State private var latexConversionError: String?
    @State private var latexPageBackgroundHex = "FFFFFF"
    @State private var latexTextColorHex = "000000"
    @State private var compiledPDFDocument: PDFDocument?
    @State private var compiledPDFSelection: PDFSelection?
    @State private var isCompilingLatex = false
    @State private var latexCompileError: String?
    @StateObject private var latexEditorSearch = EditorSearchController()
    @StateObject private var latexEditorUndo = EditorUndoController()
    @StateObject private var latexSyncTeX = SyncTeXBridge()

    @State private var focusedColorIndex = 0
    @State private var activeHighlightColorID: UUID?
    @State private var zoomPercent = 100
    @State private var showAddColorSheet = false
    @State private var renamingColor: HighlightColorOption?
    @State private var isCopyingLatex = false
    @State private var latexCopyStatus: String?
    @State private var isAddingText = false
    @State private var pendingTextAnnotation: PendingTextAnnotation?

    @State private var references: [String] = []
    @State private var referencesLoadState: ReferencesLoadState = .idle
    @State private var referenceDownloadStatus: [String: ReferenceDownloadStatus] = [:]

    @State private var outlineItems: [OutlineItem] = []
    @State private var currentOutlinePage: PDFPage?

    @State private var videoTitles: [String: String] = [:]
    @State private var videoAddLinkText = ""
    @State private var videoAddError: String?

    @State private var codeAddLinkText = ""
    @State private var codeAddError: String?
    @State private var showGitHubSearchSheet = false
    @State private var viewingRepo: ViewingRepo?
    @State private var codeDownloadStatus: [String: CodeDownloadStatus] = [:]

    @AppStorage("maziar.readerWindow.pdfPaneWidth") private var pdfPaneWidth: Double = 520
    @AppStorage("maziar.readerWindow.width") private var storedWindowWidth: Double = 900
    @AppStorage("maziar.readerWindow.height") private var storedWindowHeight: Double = 680
    /// A semi-transparent black overlay drawn directly on top of the PDF page content — unlike
    /// `.readerPDFBackground`, which only tints the matte *around* the page, this actually dims the
    /// page itself, closer to a real reading-light dimmer than a background-color change.
    @AppStorage("maziar.readerWindow.pdfCurtainOpacity") private var pdfCurtainOpacity: Double = 0

    private let minPaneWidth: CGFloat = 320
    private let dividerWidth: CGFloat = 6

    private var entry: LibraryEntry? { libraryStore.entries.first { $0.id == paperID } }

    var body: some View {
        Group {
            if let entry {
                GeometryReader { geo in
                    let clampedWidth = min(
                        max(pdfPaneWidth, minPaneWidth),
                        max(geo.size.width - minPaneWidth - dividerWidth, minPaneWidth)
                    )
                    HStack(spacing: 0) {
                        readerLeftPane(entry)
                            .frame(width: clampedWidth)
                        ResizableDivider(width: $pdfPaneWidth, minWidth: minPaneWidth, maxWidth: max(geo.size.width - minPaneWidth - dividerWidth, minPaneWidth))
                            .frame(width: dividerWidth)
                        companionPane(entry)
                            .frame(maxWidth: .infinity)
                    }
                }
                .onAppear {
                    notesFormat = libraryStore.notesFormat(for: entry)
                    if notesFormat == .legacyText {
                        notes = PaperNotesDocument.decode(libraryStore.readNotes(for: entry))
                    }
                    loadPDF(for: entry)
                    installKeyboardShortcutMonitor()
                }
                .onDisappear {
                    removeKeyboardShortcutMonitor()
                }
                .onChange(of: notes) { _, newValue in
                    guard notesFormat == .legacyText else { return }
                    libraryStore.writeNotes(PaperNotesDocument.encode(newValue), for: entry)
                }
                .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged)) { note in
                    guard let view = note.object as? PDFView, view === pdfView else { return }
                    currentOutlinePage = view.currentPage
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.size) { _, newSize in
                                storedWindowWidth = newSize.width
                                storedWindowHeight = newSize.height
                            }
                    }
                )
            } else {
                // Reachable either because the paper was genuinely removed, or — far more often in
                // practice — because macOS restored this window from a past session's saved state,
                // pointing at a paper ID from that old session. Either way there's nothing useful to
                // show, so close immediately rather than leave an empty "reader" window sitting
                // around with no PDF, no toolbar, nothing to interact with.
                Color.clear
                    .onAppear { dismiss() }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle(entry.map { "Maziar-Reader \u{2014} \($0.title)" } ?? "Maziar-Reader")
        .sheet(isPresented: $showAddColorSheet) {
            AddHighlightColorSheet(
                onSave: { name, hex in
                    libraryStore.addHighlightColor(name: name, colorHex: hex)
                    showAddColorSheet = false
                },
                onCancel: { showAddColorSheet = false }
            )
        }
        .sheet(item: $renamingColor) { color in
            RenameHighlightColorSheet(
                color: color,
                onSave: { newName, newColorHex in
                    libraryStore.updateHighlightColor(color, name: newName, colorHex: newColorHex)
                    renamingColor = nil
                },
                onCancel: { renamingColor = nil }
            )
        }
        .sheet(item: $pendingTextAnnotation) { pending in
            TextAnnotationSheet(
                initialText: pending.initialText,
                onSave: { text in saveTextAnnotation(text) },
                onCancel: { pendingTextAnnotation = nil }
            )
        }
    }

    /// A robust fallback for Cmd+C/Cmd+X/Cmd+V, reported not to work anywhere in this window from
    /// real usage — SwiftUI's automatic Edit-menu commands should reach every window by default
    /// (the app doesn't override `.pasteboard`/`.textEditing` in `MaziarApp.swift`'s `.commands`),
    /// but something about this window's own key-event handling was preventing that from working
    /// reliably. Two SwiftUI-native attempts were tried and ruled out first: hidden `Button`s with
    /// `.keyboardShortcut` (didn't fire — `.hidden()` marks the underlying `NSView` `isHidden`, and
    /// AppKit's `performKeyEquivalent` dispatch, which is what makes `.keyboardShortcut` work at
    /// all, skips hidden views), and the same buttons with `.opacity(0)` instead (still didn't fire,
    /// meaning something deeper than the hidden-view case is blocking `performKeyEquivalent` from
    /// ever reaching this window's key-equivalent responders — never fully pinned down).
    ///
    /// This installs a local `NSEvent` keyDown monitor instead, which sidesteps SwiftUI's shortcut
    /// machinery entirely: local monitors get first look at every keyDown AppKit delivers to any of
    /// the app's windows, *before* `performKeyEquivalent`/SwiftUI's own key handling ever sees it,
    /// so it works regardless of whatever is going wrong with this window's normal routing. On a
    /// plain Cmd+C/X/V it calls `NSApp.sendAction(_:to: nil, from: nil)` — the same `copy(_:)`/
    /// `cut(_:)`/`paste(_:)` dispatch the system Edit menu itself performs — up the responder chain
    /// from whatever the current first responder actually is, so it reaches whichever text field or
    /// the PDF's own text selection currently has focus, and swallows the event (returns `nil`) so
    /// it isn't also double-delivered through the normal path. Cmd+F rides along on the same monitor
    /// (opening the PDF find bar, `showPDFFind`) since it's exactly the same "shortcuts don't reach
    /// this window normally" problem. Filtered to this window specifically via `NSApp.keyWindow` so
    /// multiple simultaneously open reader windows don't act on each other's key presses.
    private func installKeyboardShortcutMonitor() {
        guard pdfViewHolder.keyboardShortcutMonitor == nil else { return }
        pdfViewHolder.keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Checked against `NSApp.keyWindow` rather than `event.window` — at this early
            // interception point (local monitors run before AppKit's own dispatch), `event.window`
            // isn't reliably populated yet for every key event, so it's a shakier signal than the
            // app's own authoritative notion of which window is currently active.
            guard let window = pdfView?.window, NSApp.keyWindow === window else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            switch (key, mods) {
            case ("c", .command), ("x", .command):
                // Reading `currentSelection` straight off `pdfView` and writing it to the pasteboard
                // directly — instead of just always going through `sendAction`/first-responder —
                // covers the case where the PDF selection was made but focus then moved to a
                // companion-pane control without clearing it (so `copy:` sent to *that* control
                // wouldn't reach the PDF text at all). That direct read is skipped only when some
                // *other* real text editor (a notebook cell, the Translator input — all backed by a
                // genuine `NSTextView`) currently has focus, so it correctly gets its own copy
                // instead of a stale, leftover PDF selection hijacking it. Gating this on
                // `pdfView === firstResponder` instead (an earlier version of this fix) was too
                // strict: `PDFView` doesn't reliably become the literal first responder in this app
                // even while its own text genuinely is selected, which broke copying from the PDF
                // entirely rather than just fixing the notebook-cell case. `cut` has no meaning
                // against read-only PDF text, so it's treated the same as copy.
                let otherTextViewFocused = (pdfView?.window?.firstResponder as? NSTextView) != nil
                if !otherTextViewFocused, let text = pdfView?.currentSelection?.string, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } else {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                return nil
            case ("v", .command):
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                return nil
            case ("f", .command):
                showPDFFind = true
                return nil
            case ("z", .command):
                // `undo:`/`redo:` aren't formally declared on any class `#selector` can point at —
                // they work purely via `NSResponder`'s own default implementation, which checks
                // whatever's first responder for a non-nil `.undoManager` (e.g. `GrowingTextEditor`'s
                // `NSTextView`, which has one since it sets `allowsUndo = true`) and calls undo/redo
                // on it. `Selector((...))`, not `#selector`, is the standard way to reference such an
                // informal/no-Swift-declaration selector.
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                return nil
            case ("z", [.command, .shift]):
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardShortcutMonitor() {
        if let monitor = pdfViewHolder.keyboardShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            pdfViewHolder.keyboardShortcutMonitor = nil
        }
    }

    private func loadPDF(for entry: LibraryEntry) {
        guard let url = libraryStore.primaryURL(for: entry) else { return }
        pdfDocument = PDFDocument(url: url)
        pdfFileURL = url
        outlineItems = buildOutlineItems(pdfDocument?.outlineRoot)
        currentOutlinePage = pdfDocument?.page(at: 0)
    }

    /// The outline entry to highlight as "you are here" — the last one (in document/reading order,
    /// parents before their own children) whose destination page is at or before the page currently
    /// visible in the PDF pane. Page-level granularity only (no exact scroll offset within a page):
    /// good enough to track which section you're reading without needing continuous scroll tracking.
    private func flattenOutline(_ items: [OutlineItem]) -> [OutlineItem] {
        items.flatMap { [$0] + flattenOutline($0.children) }
    }

    private var currentOutlineItemID: UUID? {
        guard let pdfDocument, let currentOutlinePage else { return nil }
        let currentIndex = pdfDocument.index(for: currentOutlinePage)
        var best: OutlineItem?
        for item in flattenOutline(outlineItems) {
            guard let page = item.destination?.page else { continue }
            if pdfDocument.index(for: page) <= currentIndex {
                best = item
            }
        }
        return best?.id
    }

    private func header(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 10) {
            BrandMark(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(2)
                if let authors = entry.authors, !authors.isEmpty {
                    Text(authors).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func companionPane(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 0) {
            modeQuickAccessColumn
            Divider()
            VStack(spacing: 0) {
                header(entry)
                Divider()
                // `.menu` rather than `.segmented`: with 6 modes now (Translator/AI Chat/Notes/
                // References/Outline/Videos), a segmented control silently CLIPS whichever
                // segments don't fit the companion pane's current width instead of shrinking
                // them — so a narrowed pane could make a tab genuinely unreachable, not just
                // visually cramped. A menu-style picker shows only the current mode plus a
                // chevron, so it's immune to that regardless of how many modes exist or how
                // narrow the pane gets.
                Picker("Mode", selection: $mode) {
                    ForEach(ReaderCompanionMode.allCases) { m in
                        Text(companionModeLabel(m)).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .padding(10)

                Group {
                    switch mode {
                    case .translator: translatorPanel
                    case .chat: chatPanel(entry)
                    case .notes: notesFullPage
                    case .references: referencesPanel(entry)
                    case .outline: outlinePanel
                    case .videos: videosPanel(entry)
                    case .code: codePanel(entry)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .readerPanelBackground(settings)
    }

    /// A narrow rail of small square icon-only buttons — fast one-click access to the four modes
    /// used most — configurable in Settings → Appearance → Reader (`AppSettings
    /// .readerQuickAccessModes`, defaults to Translator/AI Chat/Notes/Code) — without going through
    /// the mode picker's dropdown, which still lists every mode regardless of what's in this rail.
    /// Also focusable on its own so the left/right arrow keys can step through all seven modes in
    /// order (same order as the dropdown, independent of this rail's own configured order) without
    /// needing to click a specific icon or reopen the dropdown each time — scoped to this column
    /// rather than the whole window so it doesn't fight with left/right arrow moving the text
    /// cursor inside the Translator/Chat/Notes/Videos/Code text fields elsewhere in the pane.
    /// `.focusEffectDisabled()` suppresses the default system focus ring macOS draws around a
    /// focused `.focusable()` view — it moved between icons as you clicked each one, which read as
    /// a stray blue border rather than the intended flat highlight `quickAccessButton` already
    /// draws for the active mode.
    private var modeQuickAccessColumn: some View {
        VStack(spacing: 6) {
            ForEach(settings.readerQuickAccessModes) { target in
                quickAccessButton(target)
            }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.horizontal, 6)
        .frame(width: 44)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { cycleMode(by: -1); return .handled }
        .onKeyPress(.rightArrow) { cycleMode(by: 1); return .handled }
    }

    private func cycleMode(by delta: Int) {
        let cases = ReaderCompanionMode.allCases
        guard let currentIndex = cases.firstIndex(of: mode) else { return }
        let newIndex = (currentIndex + delta + cases.count) % cases.count
        mode = cases[newIndex]
    }

    private func quickAccessButton(_ target: ReaderCompanionMode) -> some View {
        Button {
            mode = target
        } label: {
            Image(systemName: target.icon)
                .font(.system(size: 15))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(
            mode == target ? settings.readerButtonColor().opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .foregroundStyle(mode == target ? settings.readerButtonColor() : .secondary)
        .help(companionModeLabel(target))
    }

    /// `ReaderCompanionMode.label` for `.chat` is just the generic fallback name — the mode's
    /// *actual* tab/button title depends on which source `settings.readerAIChatSource` currently
    /// points at ("AI Chat" for the built-in panel, "ChatGPT"/"Claude" for a website source), per
    /// `ReaderAIChatSource.buttonLabel`. Every other mode's label is source-independent.
    private func companionModeLabel(_ mode: ReaderCompanionMode) -> String {
        mode == .chat ? settings.readerAIChatSource.buttonLabel : mode.label
    }

    // -- pdf → latex ------------------------------------------------------------

    /// Wraps `pdfPane` (unchanged) with a mode switcher above it, so switching to LaTeX or the
    /// recompiled PDF doesn't disturb the original PDF pane's own toolbar/state at all — only one
    /// of the three panes is actually in the view tree at a time.
    private func readerLeftPane(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            modeSwitcherBar(entry)
                .readerPanelBackground(settings, region: .readerToolbarBackground, material: .ultraThinMaterial)
            Divider()
            switch pdfViewMode {
            case .original: pdfPane(entry)
            case .latex: latexEditorPane(entry)
            case .compiled: compiledPDFPane
            }
        }
    }

    private func modeSwitcherBar(_ entry: LibraryEntry) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $pdfViewMode) {
                ForEach(ReaderPDFViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            if let latexConversionProgress {
                Text("Page \(latexConversionProgress.done)/\(latexConversionProgress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                convertPDFToLatex(entry)
            } label: {
                if isConvertingToLatex {
                    ProgressView().controlSize(.small)
                } else {
                    Label(latexSource.isEmpty ? "Convert to LaTeX" : "Re-convert to LaTeX", systemImage: "doc.text")
                }
            }
            .disabled(isConvertingToLatex || pdfDocument == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func latexEditorPane(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ColorPicker("", selection: latexBackgroundColorBinding, supportsOpacity: false)
                    .labelsHidden()
                Text("Page background").font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 14)
                ColorPicker("", selection: latexTextColorBinding, supportsOpacity: false)
                    .labelsHidden()
                Text("Text color").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    compileLatex(entry)
                } label: {
                    if isCompilingLatex {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Compile to PDF", systemImage: "hammer")
                    }
                }
                .disabled(isCompilingLatex || latexSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)

            if let latexConversionError {
                CopyableErrorView(message: latexConversionError)
                    .padding(.horizontal, 8)
            }
            if let latexCompileError {
                CopyableErrorView(message: latexCompileError)
                    .padding(.horizontal, 8)
            }

            Divider()

            if latexSource.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(isConvertingToLatex ? "Converting…" : "Click \u{201c}Convert to LaTeX\u{201d} above to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                CodeEditorView(
                    text: $latexSource,
                    fileID: "reader-latex-\(paperID.uuidString)",
                    searchController: latexEditorSearch,
                    syncTeX: latexSyncTeX,
                    undoController: latexEditorUndo
                )
            }
        }
    }

    private var compiledPDFPane: some View {
        Group {
            if let compiledPDFDocument {
                PDFKitView(
                    document: compiledPDFDocument,
                    onViewCreated: { _ in },
                    onCopyAsLatex: {},
                    highlightColors: [],
                    onHighlight: { _ in },
                    onTranslate: {},
                    onRemoveAnnotation: { _ in },
                    onEditText: { _ in },
                    onChangeAnnotationColor: { _, _ in },
                    isAddingText: false,
                    onTextClick: { _, _ in },
                    pageBackgroundColor: .white,
                    selection: $compiledPDFSelection
                )
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Compile the LaTeX to see the new PDF here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }

    /// Round-trips through the 6-digit `RRGGBB` LaTeX/`xcolor` needs (no alpha channel support in
    /// its `[HTML]` color model) rather than the app's usual 8-digit `RRGGBBAA` `Color.toHex()` —
    /// `latexPageBackgroundHex` stores exactly what goes in `\pagecolor[HTML]{...}`, and setting it
    /// rewrites that line directly in `latexSource` so the editor and the picker never disagree.
    private var latexBackgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: latexPageBackgroundHex + "FF") ?? .white },
            set: { newColor in
                guard let hex8 = newColor.toHex() else { return }
                let hex6 = String(hex8.prefix(6))
                latexPageBackgroundHex = hex6
                if let range = latexSource.range(of: #"\\pagecolor\[HTML\]\{[0-9A-Fa-f]{6}\}"#, options: .regularExpression) {
                    latexSource.replaceSubrange(range, with: "\\pagecolor[HTML]{\(hex6)}")
                }
            }
        )
    }

    /// Same round-trip as `latexBackgroundColorBinding`, for the `\color[HTML]{...}` line right
    /// after `\begin{document}` that sets the default text color for the whole compiled page —
    /// added specifically so a dark/black page background doesn't leave the (still-default-black)
    /// text unreadably invisible against it.
    private var latexTextColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: latexTextColorHex + "FF") ?? .black },
            set: { newColor in
                guard let hex8 = newColor.toHex() else { return }
                let hex6 = String(hex8.prefix(6))
                latexTextColorHex = hex6
                if let range = latexSource.range(of: #"\\color\[HTML\]\{[0-9A-Fa-f]{6}\}"#, options: .regularExpression) {
                    latexSource.replaceSubrange(range, with: "\\color[HTML]{\(hex6)}")
                }
            }
        )
    }

    /// Renders every page to an image and sends each, one at a time, to `PDFToLaTeXService` — a
    /// vision AI call per page, since the PDF has no LaTeX left in it to recover (only compiled
    /// glyphs/paths), the same reasoning as the equation-copy feature above, just for a whole
    /// document instead of one selection. Pages whose transcription mentions a figure get their
    /// own full-page render saved to disk as that figure's `\includegraphics` target — not a crop
    /// of just the figure (extracting an arbitrary sub-region of a PDF's painted content without
    /// knowing its bounds ahead of time isn't reliable), so the compiled result may show more of
    /// the page than just the figure there; good enough to keep the layout recognizable without a
    /// second AI pass per figure to localize it.
    private func convertPDFToLatex(_ entry: LibraryEntry) {
        guard let pdfDocument else { return }
        latexConversionError = nil
        isConvertingToLatex = true
        let pageCount = pdfDocument.pageCount
        latexConversionProgress = (0, pageCount)
        Task {
            var bodies: [String] = []
            var figureImages: [(page: Int, image: NSImage)] = []
            for index in 0..<pageCount {
                defer { latexConversionProgress = (index + 1, pageCount) }
                guard let page = pdfDocument.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                guard let image = croppedImage(of: page, bounds: bounds), let base64 = pngBase64(from: image) else {
                    bodies.append("% -- page \(index + 1): couldn't render this page --")
                    continue
                }
                do {
                    let result = try await PDFToLaTeXService.convertPage(imageBase64: base64, settings: aiSettings)
                    var body = result.body
                    if body.contains("PLACEHOLDER") {
                        let filename = "page-\(index + 1).png"
                        body = body.replacingOccurrences(of: "PLACEHOLDER", with: filename)
                        figureImages.append((index + 1, image))
                    }
                    bodies.append(body)
                } catch {
                    bodies.append("% -- page \(index + 1) failed: \(error.localizedDescription) --")
                }
            }
            latexSource = PDFToLaTeXService.assembleDocument(pageBodies: bodies, pageBackgroundHex: latexPageBackgroundHex, pageTextColorHex: latexTextColorHex)
            saveLatexFigures(figureImages, for: entry)
            isConvertingToLatex = false
            latexConversionProgress = nil
            pdfViewMode = .latex
        }
    }

    private func compileLatex(_ entry: LibraryEntry) {
        guard let pdflatexURL = texManager.pdflatexURL() else {
            latexCompileError = "No LaTeX installation found. Set one up in Settings first."
            return
        }
        let directory = latexScratchDirectory(for: entry)
        let mainFile = "paper.tex"
        do {
            try latexSource.write(to: directory.appendingPathComponent(mainFile), atomically: true, encoding: .utf8)
        } catch {
            latexCompileError = error.localizedDescription
            return
        }
        isCompilingLatex = true
        latexCompileError = nil
        Task {
            do {
                let output = try await SystemLaTeXCompiler.compile(pdflatexURL: pdflatexURL, projectDirectory: directory, mainFile: mainFile)
                if output.succeeded, let document = PDFDocument(data: output.pdf) {
                    compiledPDFDocument = document
                    pdfViewMode = .compiled
                } else {
                    latexCompileError = "Compilation failed — check the LaTeX for errors and try again."
                }
            } catch {
                latexCompileError = error.localizedDescription
            }
            isCompilingLatex = false
        }
    }

    private func latexScratchDirectory(for entry: LibraryEntry) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Maziar/ReaderLaTeX/\(entry.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func saveLatexFigures(_ images: [(page: Int, image: NSImage)], for entry: LibraryEntry) {
        guard !images.isEmpty else { return }
        let directory = latexScratchDirectory(for: entry)
        for (page, image) in images {
            guard let base64 = pngBase64(from: image), let data = Data(base64Encoded: base64) else { continue }
            try? data.write(to: directory.appendingPathComponent("page-\(page).png"))
        }
    }

    // -- pdf + highlighter ----------------------------------------------------

    private func pdfPane(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            highlightToolbar
                .readerPanelBackground(settings, region: .readerToolbarBackground, material: .ultraThinMaterial)
            Divider()
            ZStack(alignment: .topLeading) {
                if let pdfDocument {
                    PDFKitView(
                        document: pdfDocument,
                        onViewCreated: { view in
                            pdfView = view
                            pdfSearch.pdfView = view
                        },
                        onCopyAsLatex: { copySelectionAsLatex() },
                        highlightColors: libraryStore.highlightColors,
                        onHighlight: { option in applyHighlight(with: option) },
                        onTranslate: { translateSelection() },
                        onRemoveAnnotation: { annotation in removeAnnotation(annotation) },
                        onEditText: { annotation in pendingTextAnnotation = .edit(annotation) },
                        onChangeAnnotationColor: { annotation, option in changeAnnotationColor(annotation, to: option) },
                        isAddingText: isAddingText,
                        onTextClick: { point, page in
                            pendingTextAnnotation = .new(pagePoint: point, page: page)
                            isAddingText = false
                        },
                        pageBackgroundColor: settings.readerVisualStyle == .glass ? Color.clear : settings.color(for: .readerPDFBackground),
                        selection: $pdfSelection
                    )
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(libraryStore.isFileMissing(entry) ? "PDF file not found in the connected folder." : "Couldn't open this PDF.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }

                // The "curtain" — a plain dark scrim painted directly over the page content, not
                // just the matte around it (`.readerPDFBackground` only reaches that, never the
                // PDF's own rendered white page). Sits above `PDFKitView` but below the selection
                // popup/status toasts/find bar below it, so those stay fully legible through the
                // dim; `allowsHitTesting(false)` keeps it from intercepting clicks meant for the
                // PDF underneath (selecting text, right-clicking a highlight, etc.).
                if pdfCurtainOpacity > 0 {
                    Color.black.opacity(pdfCurtainOpacity)
                        .allowsHitTesting(false)
                }

                if !libraryStore.highlightColors.isEmpty, let pdfSelection, let anchor = selectionAnchor(for: pdfSelection) {
                    HighlightSuggestionPopup(
                        colors: libraryStore.highlightColors,
                        focusedIndex: $focusedColorIndex,
                        onSelect: { option in applyHighlight(with: option) },
                        onDismiss: { dismissSelection() }
                    )
                    .position(x: anchor.x, y: anchor.y)
                }

                if let latexCopyStatus {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            if isCopyingLatex { ProgressView().controlSize(.small) }
                            Text(latexCopyStatus).font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 10)
                    }
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                }

            }
            .readerPanelBackground(settings)
            .onChange(of: pdfSelection?.string) { _, _ in focusedColorIndex = 0 }
            // `.overlay(alignment:)` rather than making `FindBarView` itself a `ZStack` child sized
            // with `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)` —
            // that earlier version put an invisible, but still fully hit-testable, layer over the
            // *entire* PDF pane (SwiftUI's `.frame(maxWidth:maxHeight:)` reports its full expanded
            // size as its hit-test bounds, regardless of where content actually renders inside it),
            // silently swallowing every click anywhere on the page for as long as the find bar
            // stayed open — which, since nothing auto-closes it, could be indefinitely. `.overlay`
            // sizes and positions its content at its own natural size instead, so only `FindBarView`'s
            // small, actually-visible bounds stay clickable; everything else passes through to the PDF.
            .overlay(alignment: .bottomLeading) {
                if showPDFFind {
                    FindBarView(
                        query: $pdfSearch.query,
                        matchCount: pdfSearch.matchCount,
                        currentIndex: pdfSearch.currentIndex,
                        onNext: { pdfSearch.next() },
                        onPrevious: { pdfSearch.previous() },
                        onClose: {
                            showPDFFind = false
                            pdfSearch.clear()
                        }
                    )
                }
            }
        }
    }

    private var highlightToolbar: some View {
        HStack(spacing: 8) {
            ForEach(libraryStore.highlightColors) { option in
                Button {
                    applyHighlight(with: option)
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(activeHighlightColorID == option.id ? 0.9 : 0.2),
                                lineWidth: activeHighlightColorID == option.id ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(pdfSelection == nil)
                .opacity(pdfSelection == nil ? 0.35 : 1)
                .help(pdfSelection == nil ? "\(option.name) — select text in the PDF, then click a color" : "Highlight selected text: \(option.name)")
                .contextMenu {
                    Button("Edit…") { renamingColor = option }
                    Button("Remove", role: .destructive) { libraryStore.removeHighlightColor(option) }
                }
            }
            Button {
                showAddColorSheet = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a highlight color")

            Divider().frame(height: 16)

            Button {
                isAddingText.toggle()
            } label: {
                Image(systemName: isAddingText ? "text.badge.checkmark" : "text.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAddingText ? settings.readerButtonColor() : .secondary)
            .help(isAddingText ? "Click anywhere on the PDF to place text there" : "Write text directly on the PDF")

            Spacer()

            Menu {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background Brightness").font(.caption).foregroundStyle(.secondary)
                    Slider(value: pdfBackgroundBrightnessBinding, in: 0...1)
                    Button("Reset to Default") {
                        settings.resetColor(for: .readerPDFBackground)
                    }
                }
                .padding(10)
                .frame(width: 200)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Adjust the PDF page background brightness")

            // The curtain gets the same always-visible "-, bar, +" layout as zoom just to its
            // right, rather than being tucked a click away inside the menu above — it's meant to be
            // nudged often while actually reading, not set once and forgotten.
            Button {
                pdfCurtainOpacity = max(pdfCurtainOpacity - 0.1, 0)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            Slider(value: $pdfCurtainOpacity, in: 0...0.7)
                .frame(width: 70)
                .help("Curtain \u{2014} dims the PDF page itself")
            Button {
                pdfCurtainOpacity = min(pdfCurtainOpacity + 0.1, 0.7)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Button { zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.plain)
                .disabled(pdfView == nil)
            Text("\(zoomPercent)%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40)
            Button { zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.plain)
                .disabled(pdfView == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Converts the selection's page-space bounds into a point in the PDF pane's own local
    /// coordinate space (top-left origin, matching SwiftUI), so the color-suggestion popup can be
    /// positioned right above whatever was just selected. `PDFView.convert(_:from:)` gives the
    /// rect in the view's own (bottom-left-origin, AppKit-standard) bounds space, which is flipped
    /// here to match SwiftUI's coordinate convention.
    private func selectionAnchor(for selection: PDFSelection) -> CGPoint? {
        guard let pdfView, let page = selection.pages.first else { return nil }
        let pageBounds = selection.bounds(for: page)
        let viewRect = pdfView.convert(pageBounds, from: page)
        let x = viewRect.midX
        let y = max(pdfView.bounds.height - viewRect.maxY - 26, 24)
        return CGPoint(x: x, y: y)
    }

    /// Highlights the PDF view's current text selection (one rectangle per visual line, so a
    /// selection wrapped across several lines gets one highlight per line rather than one giant
    /// box) and writes the annotated PDF straight back to the real file — same "the file itself is
    /// the source of truth" approach as the rest of the Library feature, so a highlight survives
    /// reopening the paper and rides along with whatever backs the folder up (e.g. Drive).
    private func applyHighlight(with option: HighlightColorOption) {
        activeHighlightColorID = option.id
        guard let pdfView, let selection = pdfView.currentSelection else { return }
        let nsColor = Self.blendedOpaqueColor(NSColor(option.color))
        for lineSelection in selection.selectionsByLine() {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = nsColor
            page.addAnnotation(annotation)
        }
        savePDF()
        dismissSelection()
    }

    /// PDF's `/C` annotation color entry has no alpha channel — `PDFAnnotation.color`'s alpha
    /// component is honored for *live* rendering (the highlight looks correctly translucent right
    /// after applying it), but is silently dropped the moment the PDF is saved to disk and
    /// reloaded, permanently reverting to full-strength opaque color. Confirmed by rendering actual
    /// pixels before/after a real save+reload — PDFKit's own public API has no supported "/CA"
    /// (constant alpha) annotation key to set instead (PDFAnnotation.h's key list only has `/C`
    /// for common annotations, and the "/CA" string is separately reserved for a widget's caption
    /// text). The fix: flatten the chosen translucent color against a plain white background
    /// (matching a typical page's own background, not `readerPDFBackground`, an unrelated app
    /// setting for the matte area around the page — not the page content) into a new, already-
    /// blended, genuinely opaque color *before* it's ever assigned to `annotation.color`, so
    /// there's no alpha for the save step to lose in the first place. Verified pixel-for-pixel: the
    /// reloaded-from-disk rendering of a highlight using this blended color exactly matches the
    /// live (pre-save) rendering of the same color applied the naive way.
    private static func blendedOpaqueColor(_ color: NSColor, against background: NSColor = NSColor(red: 1, green: 1, blue: 1, alpha: 1)) -> NSColor {
        guard let rgbColor = color.usingColorSpace(.deviceRGB), let rgbBackground = background.usingColorSpace(.deviceRGB) else { return color }
        let alpha = rgbColor.alphaComponent
        guard alpha < 1.0 else { return rgbColor }
        let r = rgbColor.redComponent * alpha + rgbBackground.redComponent * (1 - alpha)
        let g = rgbColor.greenComponent * alpha + rgbBackground.greenComponent * (1 - alpha)
        let b = rgbColor.blueComponent * alpha + rgbBackground.blueComponent * (1 - alpha)
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    private func dismissSelection() {
        pdfView?.clearSelection()
        pdfSelection = nil
    }

    /// Writes the current in-memory `pdfDocument` (which highlight/text-annotation edits mutate
    /// directly via `PDFPage.addAnnotation`/`removeAnnotation`) straight back to the real file —
    /// same "the file itself is the source of truth" approach as the rest of the Library feature,
    /// so an edit survives reopening the paper and rides along with whatever backs the folder up.
    private func savePDF() {
        guard let entry, let pdfDocument, let url = libraryStore.primaryURL(for: entry) else { return }
        pdfDocument.write(to: url)
    }

    private func removeAnnotation(_ annotation: PDFAnnotation) {
        annotation.page?.removeAnnotation(annotation)
        savePDF()
    }

    /// Right-click a highlight → Change Color — swaps `annotation.color` on the same annotation
    /// object in place, rather than removing it and adding a fresh one, so it keeps its exact
    /// original bounds/position untouched by the change.
    private func changeAnnotationColor(_ annotation: PDFAnnotation, to option: HighlightColorOption) {
        annotation.color = Self.blendedOpaqueColor(NSColor(option.color))
        savePDF()
    }

    /// Confirms whatever's currently in the text-annotation sheet — creates a new free-text
    /// annotation at the clicked page point, or updates the contents of one already being edited.
    private func saveTextAnnotation(_ text: String) {
        defer { pendingTextAnnotation = nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pendingTextAnnotation else { return }
        switch pendingTextAnnotation {
        case .new(let pagePoint, let page):
            guard !trimmed.isEmpty else { return }
            let width: CGFloat = 220
            let height: CGFloat = 60
            let bounds = CGRect(x: pagePoint.x, y: pagePoint.y - height, width: width, height: height)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = trimmed
            annotation.font = NSFont.systemFont(ofSize: 12)
            annotation.fontColor = .black
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.35)
            page.addAnnotation(annotation)
        case .edit(let annotation):
            if trimmed.isEmpty {
                annotation.page?.removeAnnotation(annotation)
            } else {
                annotation.contents = trimmed
            }
        }
        savePDF()
    }

    private func zoomIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(pdfView.scaleFactor * 1.15, 5)
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    private func zoomOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = max(pdfView.scaleFactor / 1.15, 0.2)
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    /// Nudges `.readerPDFBackground`'s brightness up/down by `delta` (clamped to 0...1) — the matte
    /// area around/behind the page, same setting Settings → Appearance → Reader's own color picker
    /// edits, just a quick one-click adjustment here instead of opening Settings for it. Goes
    /// through HSB rather than adjusting RGB components directly so the color's actual hue/
    /// saturation (if the user picked something other than plain gray) survives the adjustment.
    /// Reads/writes `.readerPDFBackground`'s brightness (HSB) as a plain 0...1 value for the
    /// toolbar's slider — going through HSB rather than adjusting RGB components directly so the
    /// color's actual hue/saturation (if the user picked something other than plain gray) survives
    /// the adjustment instead of just fading toward white/black.
    private var pdfBackgroundBrightnessBinding: Binding<Double> {
        Binding(
            get: {
                guard let hsb = NSColor(settings.color(for: .readerPDFBackground)).usingColorSpace(.deviceRGB) else { return 1 }
                return Double(hsb.brightnessComponent)
            },
            set: { newValue in
                guard let hsb = NSColor(settings.color(for: .readerPDFBackground)).usingColorSpace(.deviceRGB) else { return }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                hsb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                let adjusted = NSColor(hue: hue, saturation: saturation, brightness: CGFloat(newValue), alpha: alpha)
                settings.setColor(Color(nsColor: adjusted), for: .readerPDFBackground)
            }
        )
    }

    // -- copy equation as latex ------------------------------------------------

    /// Crops just the selection's region out of the page (translating a small bitmap context so
    /// the selection's origin lands at (0,0), the standard technique for rendering a sub-rect of a
    /// `PDFPage`) and sends it to a vision-capable AI model to transcribe back into LaTeX — the PDF
    /// itself has no LaTeX left in it to recover, only the compiled glyphs/paths.
    private func copySelectionAsLatex() {
        guard let selection = pdfSelection ?? pdfView?.currentSelection,
              let page = selection.pages.first else {
            latexCopyStatus = "Select the equation first."
            scheduleStatusClear()
            return
        }
        let bounds = selection.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0, let image = croppedImage(of: page, bounds: bounds),
              let base64 = pngBase64(from: image) else {
            latexCopyStatus = "Couldn't capture that selection as an image."
            scheduleStatusClear()
            return
        }
        isCopyingLatex = true
        latexCopyStatus = "Reading equation…"
        Task {
            do {
                let latex = try await EquationLatexService.extract(imageBase64: base64, settings: aiSettings)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(latex, forType: .string)
                latexCopyStatus = "Copied LaTeX to clipboard."
            } catch {
                latexCopyStatus = error.localizedDescription
            }
            isCopyingLatex = false
            scheduleStatusClear()
        }
    }

    /// Renders just `bounds` of the page, not the whole thing — `PDFPage.draw(with:to:)` always
    /// scales the *entire* page to fit its destination context regardless of any transform applied
    /// beforehand, so it can't be used for a sub-rect crop. `CGContext.drawPDFPage(_:)` on the
    /// page's raw `CGPDFPage`, by contrast, genuinely respects the context's current transform —
    /// scaling then translating by `-bounds.origin` before drawing leaves only the requested
    /// region inside the (bounds-sized) bitmap, everything else falls outside it and is clipped
    /// away for free. A plain `CGContext` bitmap is used rather than `NSImage.lockFocus()` for an
    /// unambiguous bottom-left-origin, y-up coordinate space matching PDF space exactly.
    private func croppedImage(of page: PDFPage, bounds: CGRect) -> NSImage? {
        guard let cgPage = page.pageRef else { return nil }
        let scale: CGFloat = 3
        let pixelWidth = Int(bounds.width * scale)
        let pixelHeight = Int(bounds.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        context.drawPDFPage(cgPage)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
    }

    private func pngBase64(from image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return pngData.base64EncodedString()
    }

    private func scheduleStatusClear() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            latexCopyStatus = nil
        }
    }

    // -- translator ---------------------------------------------------------

    private var translatorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Translate to:").font(.caption)
                Picker("", selection: $targetLanguage) {
                    ForEach(libraryStore.translatorLanguages, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
                Button {
                    translate()
                } label: {
                    if isTranslating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Translate", systemImage: "character.bubble")
                    }
                }
                .tint(settings.readerButtonColor())
                .disabled(isTranslating || translatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !aiSettings.isConfigured(aiSettings.effectiveLibraryProvider))
            }

            HStack(spacing: 6) {
                Text("Paste text from the paper:").font(.caption).foregroundStyle(.secondary)
                Button {
                    pronounceTranslatorInput()
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(translatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Pronounce (US English)")
            }
            PasteDetectingTextEditor(text: $translatorInput, font: .systemFont(ofSize: 12)) {
                guard !translatorInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !isTranslating,
                      aiSettings.isConfigured(aiSettings.effectiveLibraryProvider) else { return }
                translate()
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            if let translatorError {
                CopyableErrorView(message: translatorError)
            }

            Text("Translation:").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(translatorOutput)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        .padding(12)
        .onAppear {
            // Falls back to whatever's actually configured if the language this window started
            // with (or its "English" default) was since removed in Settings.
            if !libraryStore.translatorLanguages.contains(targetLanguage) {
                targetLanguage = libraryStore.translatorLanguages.first ?? "English"
            }
        }
    }

    private func translate() {
        translatorError = nil
        isTranslating = true
        let text = translatorInput
        let language = targetLanguage
        Task {
            do {
                translatorOutput = try await LibraryTranslatorService.translate(text, to: language, settings: aiSettings)
            } catch {
                translatorError = error.localizedDescription
            }
            isTranslating = false
        }
    }

    /// Speaks whatever's in the translator's input box using the system's own US English voice —
    /// local, offline, and instant (`AVSpeechSynthesizer`), unlike the AI-backed translation itself,
    /// so there's no reason to route this through an API call.
    private func pronounceTranslatorInput() {
        let text = translatorInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
    }

    /// "Translate" from the PDF's own right-click menu — switches straight to the Translator tab
    /// with the selected text already in the input box and translation already kicked off, rather
    /// than making you switch tabs and re-paste it yourself.
    private func translateSelection() {
        guard let text = pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        translatorInput = text
        mode = .translator
        translate()
    }

    // -- chat -----------------------------------------------------------------

    /// `.builtIn` shows Maziar's own in-app chat (`chatPanelContent`, using the configured AI
    /// provider); a website source (ChatGPT/Claude) instead opens that site directly, reusing
    /// `CustomWebPageView` exactly like a user-added custom page — same back/forward/reload/
    /// download/dark-light behavior, just pointed at a fixed URL instead of a user-configured one.
    @ViewBuilder
    private func chatPanel(_ entry: LibraryEntry) -> some View {
        switch settings.readerAIChatSource {
        case .builtIn:
            ZStack {
                if let logo = AppBranding.logo {
                    logo
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220)
                        .opacity(0.05)
                        .allowsHitTesting(false)
                }
                chatPanelContent(entry)
            }
        case .chatGPT, .claude:
            if let urlString = settings.readerAIChatSource.websiteURLString {
                CustomWebPageView(
                    page: CustomWebPage(name: settings.readerAIChatSource.buttonLabel, urlString: urlString),
                    matchAppearance: colorScheme,
                    showOpenInSafari: false,
                    showAddressText: false
                )
            }
        }
    }

    private func chatPanelContent(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            if !aiSettings.isConfigured(aiSettings.effectiveLibraryProvider) {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "key.slash").foregroundStyle(.secondary)
                    Text("No API key set for \(aiSettings.effectiveLibraryProvider.displayName).")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if chatVM.messages.isEmpty {
                                Text("Ask about this paper — its contribution, a section, how it compares to something else.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                            }
                            ForEach(chatVM.messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .user ? "You" : aiSettings.effectiveLibraryProvider.displayName)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                    Text(message.content)
                                        .font(.system(size: 12.5))
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(message.role == .user ? Color.gray.opacity(0.15) : Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 10)
                                .id(message.id)
                            }
                            if chatVM.isSending {
                                ProgressView().controlSize(.small).padding(.horizontal, 10)
                            }
                            if let error = chatVM.errorMessage {
                                CopyableErrorView(message: error).padding(.horizontal, 10)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: chatVM.messages.count) { _, _ in
                        if let last = chatVM.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about this paper...", text: $chatVM.inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit { sendChat(entry) }
                    Button(action: { sendChat(entry) }) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.readerButtonColor())
                    .disabled(chatVM.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatVM.isSending)
                }
                .padding(10)
            }
        }
    }

    private func sendChat(_ entry: LibraryEntry) {
        Task { await chatVM.send(about: entry, settings: aiSettings) }
    }

    // -- references -------------------------------------------------------------

    private func referencesPanel(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("This paper's bibliography").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    findReferences(entry)
                } label: {
                    if referencesLoadState == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(references.isEmpty ? "Find References" : "Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .tint(settings.readerButtonColor())
                .disabled(referencesLoadState == .loading || pdfDocument == nil)
            }
            .padding(10)
            Divider()

            if case .failed(let message) = referencesLoadState {
                CopyableErrorView(message: message).padding(10)
            }

            if references.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.book.closed").foregroundStyle(.secondary)
                    Text("Click \u{201c}Find References\u{201d} to read this paper's bibliography section and list its papers here, one by one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                            referenceRow(reference, entry: entry)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func referenceRow(_ reference: String, entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reference)
                .font(.system(size: 12.5))
                .lineLimit(4)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                switch referenceDownloadStatus[reference] {
                case nil:
                    Button {
                        downloadReference(reference, entry: entry)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.readerButtonColor())
                case .searching:
                    ProgressView().controlSize(.small)
                    Text("Finding a PDF\u{2026}").foregroundStyle(.secondary)
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("Downloading\u{2026}").foregroundStyle(.secondary)
                case .done:
                    Label("Added to Library", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Button {
                        downloadReference(reference, entry: entry)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.readerButtonColor())
                    Text(message).foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.caption2)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Tries a purely local, deterministic split first (`BibliographySplitter` — finds the
    /// References/Bibliography heading and splits on `[1]`-style numbered markers, the dominant
    /// citation style for the CS/ML papers this app's users are most likely reading), which needs
    /// no AI provider, no API key, and can't fail from a truncated/malformed model response. Only
    /// falls back to the AI-based extraction (`PaperReferencesService`) when that finds fewer than
    /// two entries — an unnumbered author-year bibliography, or a PDF whose text extraction is too
    /// garbled for the regex to find the heading at all.
    private func findReferences(_ entry: LibraryEntry) {
        guard let pdfDocument else { return }
        referencesLoadState = .loading

        let fullText = Self.fullText(of: pdfDocument)
        let localEntries = BibliographySplitter.referenceEntries(from: fullText)
        if localEntries.count >= 2 {
            references = localEntries
            referencesLoadState = .loaded
            return
        }

        guard aiSettings.isConfigured(aiSettings.effectiveLibraryProvider) else {
            referencesLoadState = .failed("Couldn't automatically split this PDF's bibliography (it may not use numbered [1]-style citations). Set an AI provider API key in Settings \u{2192} AI to try a smarter extraction instead.")
            return
        }
        let tail = Self.tailText(of: fullText)
        Task {
            do {
                let aiEntries = try await PaperReferencesService.extractReferences(fromDocumentText: tail, settings: aiSettings)
                if aiEntries.isEmpty {
                    referencesLoadState = .failed("Couldn't find a references section in this PDF.")
                } else {
                    references = aiEntries
                    referencesLoadState = .loaded
                }
            } catch {
                referencesLoadState = .failed(error.localizedDescription)
            }
        }
    }

    /// Downloads land wherever the paper being read already lives — its first group, or the
    /// library root if it's not in any group — same "no extra picker, just do the sensible thing"
    /// choice as the rest of this per-reference flow (search failing, or the found link turning out
    /// not to be an actual PDF, are both shown inline rather than blocking the rest of the list).
    private func downloadReference(_ reference: String, entry: LibraryEntry) {
        referenceDownloadStatus[reference] = .searching
        Task {
            do {
                let url = try await PaperReferencesService.findDownloadURL(for: reference, settings: aiSettings)
                referenceDownloadStatus[reference] = .downloading
                let group = libraryStore.groups.first { entry.groupFileNames[$0.id] != nil }
                try await libraryStore.downloadAndAddPaper(from: url, toGroup: group)
                referenceDownloadStatus[reference] = .done
            } catch {
                referenceDownloadStatus[reference] = .failed(error.localizedDescription)
            }
        }
    }

    private static func fullText(of document: PDFDocument) -> String {
        var text = ""
        for i in 0..<document.pageCount {
            if let pageText = document.page(at: i)?.string {
                text += pageText + "\n"
            }
        }
        return text
    }

    /// Bibliographies sit near the end of a paper, so capping to the *tail* keeps the AI-fallback
    /// call's input a reasonable size on long papers while still giving it enough surrounding
    /// context (not just the reference list in isolation) to reliably find the References heading.
    private static func tailText(of fullText: String, characterLimit: Int = 20_000) -> String {
        fullText.count > characterLimit ? String(fullText.suffix(characterLimit)) : fullText
    }

    // -- outline ------------------------------------------------------------------

    private var outlinePanel: some View {
        Group {
            if outlineItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "list.bullet.indent").foregroundStyle(.secondary)
                    Text("This PDF doesn't have an embedded table of contents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(outlineItems) { item in
                            OutlineRowView(item: item, level: 0, currentItemID: currentOutlineItemID) { destination in
                                pdfView?.go(to: destination)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    // -- videos -----------------------------------------------------------------

    private func videosPanel(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Paste a YouTube link…", text: $videoAddLinkText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addVideoLink(entry) }
                Button("Add") { addVideoLink(entry) }
                    .disabled(videoAddLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    openInNewSafariWindow("https://www.youtube.com")
                } label: {
                    Label("Search YouTube", systemImage: "magnifyingglass")
                }
                .tint(settings.readerButtonColor())
            }
            .padding(10)

            if let videoAddError {
                CopyableErrorView(message: videoAddError).padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()

            if entry.videoLinks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "play.rectangle").foregroundStyle(.secondary)
                    Text("Paste a YouTube link above, or search in Safari and paste the link here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.videoLinks, id: \.self) { link in
                            videoRow(link, entry: entry)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func videoRow(_ link: String, entry: LibraryEntry) -> some View {
        let videoID = URL(string: link).flatMap { YouTubeLinkParser.videoID(from: $0) }
        return HStack(spacing: 10) {
            if let videoID, let thumbnailURL = YouTubeLinkParser.thumbnailURL(videoID: videoID) {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(16.0 / 9.0, contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.15)
                    }
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .clipped()
            }
            Text(videoID.flatMap { videoTitles[$0] } ?? link)
                .font(.system(size: 12.5))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                openInNewSafariWindow(link)
            } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.readerButtonColor())
            .disabled(videoID == nil)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy Link")
            Button(role: .destructive) {
                removeVideoLink(link, entry: entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: videoID) {
            guard let videoID, videoTitles[videoID] == nil else { return }
            if let info = try? await YouTubeOEmbedService.fetch(videoID: videoID) {
                videoTitles[videoID] = info.title
            }
        }
    }

    /// Opens a URL in a genuinely *new* Safari window via AppleScript —
    /// `NSWorkspace.shared.open` only asks the default browser to open a URL and leaves
    /// reuse-vs-new-window entirely up to that browser's own tab settings, with no way to force a
    /// new window through that API. This was tried once already and silently failed because the
    /// app's Info.plist was missing `NSAppleEventsUsageDescription` (required before macOS will
    /// let an app send Apple Events to another app at all) — that key has since been added to
    /// `build_app.sh`'s generated Info.plist, so macOS now shows a one-time Automation permission
    /// prompt on first use instead of silently refusing.
    private func openInNewSafariWindow(_ urlString: String) {
        let script = """
        tell application "Safari"
            activate
            make new document with properties {URL:"\(urlString)"}
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }

    /// Videos are stored as their canonical `watch?v=` URL regardless of what form the link was
    /// pasted in (`youtu.be/`, a `/shorts/` link, a bare ID) — so the same video pasted two
    /// different ways is recognized as a duplicate rather than added twice.
    private func addVideoLink(_ entry: LibraryEntry) {
        videoAddError = nil
        guard let id = YouTubeLinkParser.videoID(fromPastedText: videoAddLinkText) else {
            videoAddError = "That doesn't look like a YouTube link."
            return
        }
        let canonicalURL = YouTubeLinkParser.watchURL(videoID: id).absoluteString
        videoAddLinkText = ""
        guard !entry.videoLinks.contains(canonicalURL) else { return }
        var updated = entry
        updated.videoLinks.append(canonicalURL)
        libraryStore.update(updated)
    }

    private func removeVideoLink(_ link: String, entry: LibraryEntry) {
        var updated = entry
        updated.videoLinks.removeAll { $0 == link }
        libraryStore.update(updated)
    }

    // -- code -------------------------------------------------------------------

    private func codePanel(_ entry: LibraryEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Paste a GitHub link…", text: $codeAddLinkText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCodeLink(entry) }
                Button("Add") { addCodeLink(entry) }
                    .disabled(codeAddLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    showGitHubSearchSheet = true
                } label: {
                    Label("Browse GitHub", systemImage: "magnifyingglass")
                }
                .tint(settings.readerButtonColor())
            }
            .padding(10)

            if let codeAddError {
                CopyableErrorView(message: codeAddError).padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()

            if entry.codeLinks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.secondary)
                    Text("Paste a GitHub link above, or browse GitHub directly.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(entry.codeLinks, id: \.self) { link in
                            codeRow(link, entry: entry)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .sheet(isPresented: $showGitHubSearchSheet) {
            VStack(spacing: 0) {
                HStack {
                    Text("Browse GitHub").font(.headline)
                    Spacer()
                    Button("Done") { showGitHubSearchSheet = false }
                }
                .padding(10)
                Divider()
                CodeBrowserPane(onAddRepository: { url in
                    addCodeLink(entry, urlOverride: url)
                    showGitHubSearchSheet = false
                })
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .sheet(item: $viewingRepo) { repo in
            VStack(spacing: 0) {
                HStack {
                    Text(repo.url.absoluteString).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Done") { viewingRepo = nil }
                }
                .padding(10)
                Divider()
                CodeBrowserPane(initialURL: repo.url)
            }
            .frame(minWidth: 720, minHeight: 520)
        }
    }

    private func codeRow(_ link: String, entry: LibraryEntry) -> some View {
        let repo = URL(string: link).flatMap { GitHubLinkParser.repository(from: $0) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                Text(repo?.fullName ?? link)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(role: .destructive) {
                    removeCodeLink(link, entry: entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button {
                    if let url = URL(string: link) { viewingRepo = ViewingRepo(url: url) }
                } label: {
                    Label("View", systemImage: "safari")
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.readerButtonColor())

                switch codeDownloadStatus[link] {
                case nil:
                    Button {
                        downloadCode(link)
                    } label: {
                        Label("Download ZIP", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.readerButtonColor())
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("Downloading\u{2026}").foregroundStyle(.secondary)
                case .done:
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Button {
                        downloadCode(link)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(settings.readerButtonColor())
                    Text(message).foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.caption2)
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Repos are stored as their canonical `github.com/owner/repo` URL regardless of which specific
    /// page (file, folder, issue) the link was captured from, so different deep links into the same
    /// repo are recognized as a duplicate rather than added twice.
    private func addCodeLink(_ entry: LibraryEntry, urlOverride: URL? = nil) {
        codeAddError = nil
        let repo = urlOverride.flatMap { GitHubLinkParser.repository(from: $0) }
            ?? GitHubLinkParser.repository(fromPastedText: codeAddLinkText)
        guard let repo else {
            codeAddError = "That doesn't look like a GitHub link."
            return
        }
        let canonicalURL = GitHubLinkParser.repoURL(for: repo).absoluteString
        codeAddLinkText = ""
        guard !entry.codeLinks.contains(canonicalURL) else { return }
        var updated = entry
        updated.codeLinks.append(canonicalURL)
        libraryStore.update(updated)
    }

    private func removeCodeLink(_ link: String, entry: LibraryEntry) {
        var updated = entry
        updated.codeLinks.removeAll { $0 == link }
        libraryStore.update(updated)
    }

    /// Downloads the repo's default branch as a ZIP (`archive/HEAD.zip` — resolves to whichever
    /// branch is actually the default, `main`/`master`/anything else, no need to know its name),
    /// then asks where to save it via a real save panel rather than silently dropping a
    /// potentially large file somewhere in the library folder unasked.
    private func downloadCode(_ link: String) {
        guard let url = URL(string: link), let repo = GitHubLinkParser.repository(from: url) else { return }
        codeDownloadStatus[link] = .downloading
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: GitHubLinkParser.zipDownloadURL(for: repo))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "Maziar", code: 75, userInfo: [
                        NSLocalizedDescriptionKey: "Download failed (server responded with HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."
                    ])
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(repo.name).zip"
                panel.allowedContentTypes = [.zip]
                guard panel.runModal() == .OK, let destination = panel.url else {
                    codeDownloadStatus[link] = nil
                    return
                }
                try data.write(to: destination)
                codeDownloadStatus[link] = .done
            } catch {
                codeDownloadStatus[link] = .failed(error.localizedDescription)
            }
        }
    }

    // -- notes ----------------------------------------------------------------

    private var notesFullPage: some View {
        Group {
            switch notesFormat {
            case .legacyText:
                PaperNotesEditor(notes: $notes)
            case .notebook:
                if let entry {
                    NotebookTabsView(entry: entry)
                }
            }
        }
        .padding(12)
    }
}

/// Appears near a fresh PDF text selection offering the highlight palette right there, so applying
/// a color doesn't require looking away to the toolbar. Move focus with the left/right arrow keys
/// or the mouse scroll wheel (`ScrollWheelCatcher`, since SwiftUI has no scroll-wheel modifier for
/// a plain view), Return/click to apply, Escape to dismiss without highlighting.
private struct HighlightSuggestionPopup: View {
    let colors: [HighlightColorOption]
    @Binding var focusedIndex: Int
    var onSelect: (HighlightColorOption) -> Void
    var onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(colors.enumerated()), id: \.element.id) { index, option in
                Button {
                    focusedIndex = index
                    onSelect(option)
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary, lineWidth: focusedIndex == index ? 2 : 0))
                        .scaleEffect(focusedIndex == index ? 1.15 : 1.0)
                }
                .buttonStyle(.plain)
                .help(option.name)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 6)
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { confirmFocused(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .background(
            ScrollWheelCatcher { delta in
                if delta > 0 { move(-1) } else if delta < 0 { move(1) }
            }
        )
    }

    private func move(_ delta: Int) {
        focusedIndex = cyclicIndex(focusedIndex, movedBy: delta, count: colors.count)
    }

    private func confirmFocused() {
        guard colors.indices.contains(focusedIndex) else { return }
        onSelect(colors[focusedIndex])
    }
}

private enum ReferencesLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

private enum ReferenceDownloadStatus: Equatable {
    case searching
    case downloading
    case done
    case failed(String)
}

private struct ViewingRepo: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private enum CodeDownloadStatus: Equatable {
    case downloading
    case done
    case failed(String)
}

/// Either placing a brand-new free-text annotation at a just-clicked page point, or editing the
/// contents of one that already exists — `TextAnnotationSheet` doesn't need to know which.
private enum PendingTextAnnotation: Identifiable {
    case new(pagePoint: CGPoint, page: PDFPage)
    case edit(PDFAnnotation)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let annotation): return "edit-\(ObjectIdentifier(annotation))"
        }
    }

    var initialText: String {
        switch self {
        case .new: return ""
        case .edit(let annotation): return annotation.contents ?? ""
        }
    }
}

private struct TextAnnotationSheet: View {
    let initialText: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var text: String

    init(initialText: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(initialText.isEmpty ? "Add Text to PDF" : "Edit Text").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(width: 300, height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct AddHighlightColorSheet: View {
    var onSave: (_ name: String, _ colorHex: String) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var color: Color = .yellow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Highlight Color").font(.headline)
            TextField("Name (e.g. \u{201c}Key idea\u{201d})", text: $name).textFieldStyle(.roundedBorder)
            ColorPicker("Color", selection: $color, supportsOpacity: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add") {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), color.toHex() ?? "FFEB3BFF")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct RenameHighlightColorSheet: View {
    let color: HighlightColorOption
    var onSave: (_ newName: String, _ newColorHex: String) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var pickerColor: Color

    init(color: HighlightColorOption, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.color = color
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: color.name)
        _pickerColor = State(initialValue: color.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Highlight Color").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            ColorPicker("Color", selection: $pickerColor, supportsOpacity: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(name, pickerColor.toHex() ?? color.colorHex) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// A `TextEditor` stand-in for the Translator panel's input box that additionally reports when text
/// was pasted into it (Cmd+V or the Edit menu's Paste), so the panel can start translating right
/// away instead of also requiring a click on "Translate" afterward. Plain SwiftUI has no paste
/// notification for `TextEditor`/`TextField` — the same reasoning as `PDFKitView`/`MaziarPDFView`
/// applies here: subclass the real `NSTextView` and override `paste(_:)`, keeping its normal
/// behavior (`super.paste(sender)` still does the actual insert) while adding a side-effect on top.
/// Using `onChange(of: text)` instead and guessing "paste" from a large jump in length was
/// considered and rejected — fast typing can produce the same kind of jump, which would auto-fire a
/// real AI translation call on ordinary typing.
struct PasteDetectingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var onPaste: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PasteAwareTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = text
        textView.onPaste = onPaste
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.onPaste = onPaste
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }

    final class PasteAwareTextView: NSTextView {
        var onPaste: (() -> Void)?

        override func paste(_ sender: Any?) {
            super.paste(sender)
            onPaste?()
        }
    }
}
