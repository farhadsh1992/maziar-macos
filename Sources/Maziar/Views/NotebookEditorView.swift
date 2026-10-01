import SwiftUI
import AppKit

/// A paper's notes as a real `.ipynb` notebook of markdown cells (`NotebookDocument.swift`,
/// `LibraryStore.writeNotebook`/`readNotebook`) — every paper added after this feature shipped
/// gets this instead of the older single-file `PaperNotesDocument` format (existing papers keep
/// their `.txt` notes untouched; see `LibraryStore.notesFormat(for:)`). Each cell can hold plain
/// text, Markdown, raw HTML (rendered via `NotebookCellWebView`/WKWebView, since arbitrary styled
/// HTML like the built-in box templates is beyond what SwiftUI's own Markdown rendering supports),
/// and `$...$`/`$$...$$` LaTeX formulas, same as the plain-notes editor.
struct NotebookEditorView: View {
    @Binding var cells: [NotebookCell]
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var libraryStore: LibraryStore
    @State private var previewingCellIDs: Set<String> = []
    @State private var cellHeights: [String: CGFloat] = [:]
    @State private var collapsedCellIDs: Set<String> = []

    /// User-editable versions of the three box templates below (Settings → Reader → Notebook
    /// Templates) — `@AppStorage` directly, rather than routing through `AppSettings`, since these
    /// are plain strings with no other app state depending on them. Falls back to the original
    /// built-in markup (`Self.defaultTitleTemplate` etc.) until the user customizes one.
    @AppStorage("maziar.notebook.titleTemplate") private var titleTemplate = NotebookEditorView.defaultTitleTemplate
    @AppStorage("maziar.notebook.mainTextTemplate") private var mainTextTemplate = NotebookEditorView.defaultMainTextTemplate
    @AppStorage("maziar.notebook.subtitleTemplate") private var subtitleTemplate = NotebookEditorView.defaultSubtitleTemplate

    /// The original, built-in templates — used as `@AppStorage`'s default value above, and as the
    /// "Reset to Default" target in Settings. Kaggle/Jupyter-style colored rounded boxes for a
    /// title, a body-text card, and a smaller subtitle band.
    static let defaultTitleTemplate = """
    <div id="1" style="width:100%;height:atuo;border: 4px solid #660033;background-color:#660033;color:white;text-align:center;border-radius: 25px;padding:3px">
    <div style="box-shadow: 0 1px 4px 0 #00264D, 0 60px 20px 0 rgba(1, 1, 1, 1);padding:0.5%;margin:6px;border-radius: 25px">

    <h4><b>
    title </b></h4>
    </div></div>
    """
    static let defaultMainTextTemplate = """
    <div style="border: 4px solid #660033;background-color:white;color:black;border-radius: 5px;padding:7px;box-shadow: 0 1px 1px 0 #00264D, 0 6px 20px 0 rgba(1, 1, 1, 1)">
    <div style="box-shadow: 0 1px 12px 0 #00264D, 0 6px 20px 0 rgba(0, 0, 0, 0.19);padding:1%;margin:6px;border-radius: 25px;margin-top:8px">



    </div>
    </div>
    """
    static let defaultSubtitleTemplate = """
    <div id="1" style="width:100%;height:atuo;border: 1px solid #660033;background-color:#660033;color:white;text-align:center;border-radius: 15px;padding:3px">

    <h4>  </h4>
    </div>
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notebook").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Title Box") { insertCell(titleTemplate) }
                    Button("Main Text Box") { insertCell(mainTextTemplate) }
                    Button("Subtitle Box") { insertCell(subtitleTemplate) }
                    Divider()
                    Button("Blank Cell") { insertCell("") }
                } label: {
                    Label("Add Cell", systemImage: "plus")
                }
                .tint(settings.color(for: .buttonColor))
            }

            if cells.isEmpty {
                Text("No cells yet \u{2014} Add Cell above (Title/Main Text/Subtitle boxes, or a blank cell).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            }

            ScrollView {
                // `VStack`, not `LazyVStack`: a lazy stack only measures/lays out its children as
                // they scroll into view, and doesn't reliably re-measure a child whose *own*
                // intrinsic size grows afterward (typing more into a `TextField(axis: .vertical)`
                // cell) — the result was a cell's editing box getting stuck after ~2 lines,
                // ignoring further Enter presses/typed lines even though the underlying text was
                // still being entered. A plain `VStack` re-lays-out normally on every state change,
                // which fixes the growth at the cost of the "lazy" optimization — a fine trade here
                // since a paper's notebook is a handful to a few dozen cells, not thousands.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($cells) { $cell in
                        cellBlock($cell)
                    }
                }
            }

            Text("Saved as a real .ipynb notebook file next to the paper.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func cellBlock(_ cell: Binding<NotebookCell>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cell").font(.caption2)
                Button {
                    moveCell(cell.wrappedValue.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveCell(cell.wrappedValue.id, by: -1))
                .help("Move cell up")
                Button {
                    moveCell(cell.wrappedValue.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveCell(cell.wrappedValue.id, by: 1))
                .help("Move cell down")
                Spacer()
                Menu {
                    Button("None") { cell.wrappedValue.setBorderColorName(nil) }
                    ForEach(Self.borderColorOptions, id: \.name) { option in
                        Button(option.label) { cell.wrappedValue.setBorderColorName(option.name) }
                    }
                } label: {
                    Circle()
                        .fill(Self.color(for: cell.wrappedValue.borderColorName) ?? Color.secondary.opacity(0.25))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Cell border color")
                Menu {
                    Button("Default") { cell.wrappedValue.setBackgroundColorName(nil) }
                    Button("White") { cell.wrappedValue.setBackgroundColorName("white") }
                    Button("Black") { cell.wrappedValue.setBackgroundColorName("black") }
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.backgroundColor(for: cell.wrappedValue.backgroundColorName) ?? Color(nsColor: .controlBackgroundColor))
                        .frame(width: 12, height: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Cell background color")
                Button {
                    toggle(cell.wrappedValue.id)
                } label: {
                    Image(systemName: isPreviewing(cell.wrappedValue.id) ? "pencil" : "text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(isPreviewing(cell.wrappedValue.id) ? "Edit" : "Preview (or Shift+Return while editing)")
                Button {
                    insertCell("", after: cell.wrappedValue.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add cell below")
                Button {
                    toggleCollapsed(cell.wrappedValue.id)
                } label: {
                    Image(systemName: isCollapsed(cell.wrappedValue.id) ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .help(isCollapsed(cell.wrappedValue.id) ? "Show full size" : "Shrink this cell")
                Button {
                    cells.removeAll { $0.id == cell.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove cell")
            }
            .foregroundStyle(Self.headerForeground(forBackground: cell.wrappedValue.backgroundColorName))
            if isPreviewing(cell.wrappedValue.id) {
                NotebookCellPreview(source: cell.wrappedValue.source)
                    .frame(height: isCollapsed(cell.wrappedValue.id) ? Self.collapsedCellHeight : nil)
                    .clipped()
            } else {
                GrowingTextEditor(
                    text: cell.source,
                    height: cellHeightBinding(for: cell.wrappedValue.id),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    maxLines: libraryStore.notesCellMaxLines,
                    textColor: Self.textColor(forBackground: cell.wrappedValue.backgroundColorName),
                    onShiftEnter: { toggle(cell.wrappedValue.id) }
                )
                // Forces SwiftUI to fully recreate this `NSViewRepresentable`'s underlying
                // `NSTextView` whenever it's now standing in for a *different* cell (after a
                // reorder moves cells to new array positions), instead of reusing the same AppKit
                // view and just calling `updateNSView` on it. Without an explicit `.id()` here,
                // SwiftUI can keep the same `NSTextView` instance across the reorder purely because
                // it's still at the same row *position* — and `updateNSView`'s own "never overwrite
                // a focused text view" guard (added earlier for a different bug: other cells' edits
                // stomping on the one you're typing in) would then block the new cell's real text
                // from ever loading into it if that view happened to have focus at the moment of
                // the reorder, silently leaving it showing/editing the *previous* cell's content —
                // so typing in what looks like cell B's box was actually still writing into cell
                // A's `source` binding. Keying identity to the cell's own id instead of its
                // position guarantees a fresh, correctly-bound view every time the data it
                // represents actually changes.
                .id(cell.wrappedValue.id)
                // Still fully selectable/scrollable while collapsed — this only caps the visible
                // frame height, the same way `maxLines` already caps it before scrolling kicks in;
                // it doesn't touch the text content or the "full size" height remembered for when
                // it's expanded again.
                .frame(height: isCollapsed(cell.wrappedValue.id) ? Self.collapsedCellHeight : (cellHeights[cell.wrappedValue.id] ?? Self.defaultCellHeight))
            }
        }
        .padding(10)
        .background(Self.backgroundColor(for: cell.wrappedValue.backgroundColorName) ?? Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    Self.color(for: cell.wrappedValue.borderColorName) ?? Color.secondary.opacity(0.2),
                    lineWidth: cell.wrappedValue.borderColorName == nil ? 1 : 2
                )
        )
    }

    /// `after` is nil for the toolbar's "Add Cell" menu (appends to the end, as before); each
    /// cell's own "+" button passes its own id, inserting the new cell right below it instead of
    /// always at the bottom of a possibly-long notebook.
    private func insertCell(_ source: String, after id: String? = nil) {
        guard let id, let index = cells.firstIndex(where: { $0.id == id }) else {
            cells.append(NotebookCell(source: source))
            return
        }
        cells.insert(NotebookCell(source: source), at: index + 1)
    }

    private func canMoveCell(_ id: String, by offset: Int) -> Bool {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        return target >= 0 && target < cells.count
    }

    private func moveCell(_ id: String, by offset: Int) {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard target >= 0, target < cells.count else { return }
        cells.swapAt(index, target)
    }

    private func isPreviewing(_ id: String) -> Bool { previewingCellIDs.contains(id) }

    private func toggle(_ id: String) {
        if previewingCellIDs.contains(id) {
            previewingCellIDs.remove(id)
        } else {
            previewingCellIDs.insert(id)
        }
    }

    private func isCollapsed(_ id: String) -> Bool { collapsedCellIDs.contains(id) }

    private func toggleCollapsed(_ id: String) {
        if collapsedCellIDs.contains(id) {
            collapsedCellIDs.remove(id)
        } else {
            collapsedCellIDs.insert(id)
        }
    }

    private static let defaultCellHeight: CGFloat = 28
    private static let collapsedCellHeight: CGFloat = 32

    private static let borderColorOptions: [(name: String, label: String)] = [
        ("red", "Red"), ("green", "Green"), ("yellow", "Yellow"), ("blue", "Blue")
    ]

    private static func color(for name: String?) -> Color? {
        switch name {
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        case "blue": return .blue
        default: return nil
        }
    }

    private static func backgroundColor(for name: String?) -> Color? {
        switch name {
        case "white": return .white
        case "black": return .black
        default: return nil
        }
    }

    /// The header row's own icon/label color, paired with the cell's background the same way
    /// `textColor(forBackground:)` pairs the editor's text color — plain `.secondary` on a
    /// White-forced cell in Dark Mode (or Black-forced in Light Mode) rendered too close to the
    /// card's own color to see, which is exactly what made the row buttons disappear.
    private static func headerForeground(forBackground name: String?) -> Color {
        switch name {
        case "white": return .black.opacity(0.65)
        case "black": return .white.opacity(0.85)
        default: return .secondary
        }
    }

    /// Explicit black/white pairing rather than leaving "White" background paired with the system's
    /// own `.textColor` — `.textColor` follows Dark Mode, so a cell forced to a white background
    /// while the app is in Dark Mode would otherwise get white *text* too (from `.textColor`
    /// resolving light-on-dark as usual), landing on invisible white-on-white.
    private static func textColor(forBackground name: String?) -> NSColor {
        switch name {
        case "white": return .black
        case "black": return .white
        default: return .textColor
        }
    }

    private func cellHeightBinding(for id: String) -> Binding<CGFloat> {
        Binding(
            get: { cellHeights[id] ?? Self.defaultCellHeight },
            set: { cellHeights[id] = $0 }
        )
    }
}

/// Renders one cell's Markdown+HTML(+LaTeX) source, kicking off formula rendering for whatever
/// isn't cached yet — same `.task(id:)`-driven pattern as `NoteRenderedView` for plain notes.
private struct NotebookCellPreview: View {
    let source: String
    @EnvironmentObject var texManager: TeXInstallationManager
    @ObservedObject private var renderer = PaperFormulaRenderer.shared

    @State private var formulaImagesBase64: [String: String] = [:]
    @State private var contentHeight: CGFloat = 32

    var body: some View {
        let html = NotebookCellHTMLRenderer.fullDocument(
            bodyHTML: NotebookCellHTMLRenderer.bodyHTML(source: source, formulaImages: formulaImagesBase64)
        )
        // No fixed height and no internal scrolling — like a real JupyterLab cell, this grows (or
        // shrinks) to fit its actual rendered content; the notebook's own outer ScrollView handles
        // scrolling the whole page, not each cell individually.
        NotebookCellWebView(html: html, contentHeight: $contentHeight)
            .frame(height: contentHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: source) {
                for segment in NoteContentParser.parse(source) {
                    switch segment {
                    case .inlineMath(let formula): await renderOne(formula, displayMode: false)
                    case .displayMath(let formula): await renderOne(formula, displayMode: true)
                    case .text: break
                    }
                }
            }
    }

    private func renderOne(_ formula: String, displayMode: Bool) async {
        let key = NotebookCellHTMLRenderer.cacheKey(formula, displayMode: displayMode)
        guard formulaImagesBase64[key] == nil else { return }
        guard let image = try? await renderer.image(for: formula, displayMode: displayMode, texManager: texManager),
              let base64 = pngBase64(from: image) else { return }
        formulaImagesBase64[key] = base64
    }

    private func pngBase64(from image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        return pngData.base64EncodedString()
    }
}
