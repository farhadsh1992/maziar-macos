import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

private enum ActivePane {
    case editor
    case preview
}

struct ProjectEditorView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var texManager: TeXInstallationManager
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @StateObject private var vm: EditorViewModel
    @StateObject private var editorSearch = EditorSearchController()
    @StateObject private var pdfSearch = PDFSearchController()
    @StateObject private var pdfZoom = PDFZoomController()
    @StateObject private var syncTeX = SyncTeXBridge()
    @StateObject private var editorUndo = EditorUndoController()
    @StateObject private var dynamicEdit = DynamicEditController()
    @State private var selection: FileNode?
    @State private var showLog = false
    @State private var showShareSheet = false
    @State private var showAIPanel = false
    @State private var activePane: ActivePane = .editor
    @State private var showEditorFind = false
    @State private var showPDFFind = false
    @State private var newItemParent: FileNode?
    @State private var showNewFileSheet = false
    @State private var showNewFolderSheet = false
    @State private var newItemName = ""
    @State private var renameTarget: FileNode?
    @State private var renameText = ""
    @State private var deleteTarget: FileNode?
    @State private var fileOpError: String?
    @State private var showHistoryPopover = false

    init(project: Project) {
        _vm = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 320)
            editorPane
                .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
            previewPane
                .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
            if showAIPanel {
                AIAssistantPanelView(
                    fileName: vm.selectedNode?.name ?? vm.project.mainFile,
                    fileContent: vm.openFileText,
                    compileLog: vm.compileError != nil ? vm.compileLog : "",
                    pdfDocument: vm.pdfData.flatMap { PDFDocument(data: $0) },
                    onApply: { newContent in
                        vm.openFileText = newContent
                        vm.flushPendingSave()
                        Task { await vm.compile(using: texManager) }
                    }
                )
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(shortcutCatcher)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.closeProject()
                } label: {
                    Label("Projects", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                Text(vm.project.name).font(.headline)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editorUndo.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!editorUndo.canUndo)
                .help("Undo (\u{2318}Z)")

                Button {
                    editorUndo.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!editorUndo.canRedo)
                .help("Redo (\u{21e7}\u{2318}Z)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.compile(using: texManager) }
                } label: {
                    if vm.isCompiling {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Recompile", systemImage: "play.fill")
                    }
                }
                .disabled(vm.isCompiling)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    dynamicEdit.isEnabled.toggle()
                    if !dynamicEdit.isEnabled { dynamicEdit.clear() }
                } label: {
                    Label("Dynamic", systemImage: dynamicEdit.isEnabled ? "hand.draw.fill" : "hand.draw")
                }
                .tint(dynamicEdit.isEnabled ? .orange : nil)
                .help("Click images/figures/tables in the PDF to resize, nudge, or freely reposition them")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAIPanel.toggle()
                } label: {
                    Label("AI Assistant", systemImage: "sparkles")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    downloadPDF()
                } label: {
                    Label("Download PDF", systemImage: "arrow.down.doc")
                }
                .disabled(vm.pdfData == nil)
                .help(vm.pdfData == nil ? "Compile the project first" : "Save the compiled PDF")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "person.2.badge.gearshape")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .task {
            if let mainNode = vm.findMainNode() {
                selection = mainNode
                vm.selectFile(mainNode)
            }
            await vm.compile(using: texManager)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheetView(project: vm.project) { movedProject in
                appState.open(movedProject)
            }
        }
        .sheet(isPresented: $showNewFileSheet) { newItemSheet(title: "New File", placeholder: "untitled.tex", isFolder: false) }
        .sheet(isPresented: $showNewFolderSheet) { newItemSheet(title: "New Folder", placeholder: "New Folder", isFolder: true) }
        .sheet(item: $renameTarget) { target in renameSheet(for: target) }
        .confirmationDialog(
            "Move \"\(deleteTarget?.name ?? "")\" to Trash?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let target = deleteTarget { vm.deleteNode(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .alert("Couldn't Complete Action", isPresented: Binding(get: { fileOpError != nil }, set: { if !$0 { fileOpError = nil } })) {
            Button("OK") { fileOpError = nil }
        } message: {
            Text(fileOpError ?? "")
        }
    }

    // MARK: - File/folder management sheets

    private func newItemSheet(title: String, placeholder: String, isFolder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $newItemName, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .onSubmit { createNewItem(isFolder: isFolder) }
            HStack {
                Spacer()
                Button("Cancel") {
                    showNewFileSheet = false
                    showNewFolderSheet = false
                }
                Button("Create") { createNewItem(isFolder: isFolder) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { newItemName = isFolder ? "" : "" }
    }

    private func downloadPDF() {
        guard let pdfData = vm.pdfData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(vm.project.name).pdf"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            fileOpError = error.localizedDescription
        }
    }

    private func createNewItem(isFolder: Bool) {
        guard let parent = newItemParent else { return }
        let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let result = isFolder ? vm.createFolder(named: name, in: parent) : vm.createFile(named: name, in: parent)
        switch result {
        case .success:
            showNewFileSheet = false
            showNewFolderSheet = false
            newItemName = ""
        case .failure(let error):
            fileOpError = error.localizedDescription
        }
    }

    private func renameSheet(for target: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(target) }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") { commitRename(target) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { renameText = target.name }
    }

    private func commitRename(_ target: FileNode) {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch vm.renameNode(target, to: name) {
        case .success:
            renameTarget = nil
        case .failure(let error):
            fileOpError = error.localizedDescription
        }
    }

    /// Invisible buttons that just exist to claim window-scoped keyboard shortcuts,
    /// routed by which pane was last clicked (`activePane`).
    private var shortcutCatcher: some View {
        Group {
            Button("") { handleFindShortcut() }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { if activePane == .preview { pdfZoom.zoomIn() } }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { if activePane == .preview { pdfZoom.zoomOut() } }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { if activePane == .preview { pdfZoom.resetZoom() } }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func handleFindShortcut() {
        switch activePane {
        case .editor: showEditorFind = true
        case .preview: showPDFFind = true
        }
    }

    // MARK: - SyncTeX

    private var compiledPDFURL: URL {
        let pdfName = (vm.project.mainFile as NSString).deletingPathExtension + ".pdf"
        return vm.project.url.appendingPathComponent(pdfName)
    }

    private func performForwardSearch(line: Int) {
        guard let pdflatexURL = texManager.pdflatexURL(),
              let synctexURL = SyncTeXService.binaryURL(alongside: pdflatexURL),
              let relativePath = vm.selectedFileRelativePath,
              let pdfData = vm.pdfData,
              let document = PDFDocument(data: pdfData) else { return }
        guard let result = SyncTeXService.forwardSearch(
            synctexURL: synctexURL, sourceRelativePath: relativePath, line: line, pdfURL: compiledPDFURL
        ) else { return }
        let pageIndex = result.page - 1
        guard pageIndex >= 0, pageIndex < document.pageCount, let page = document.page(at: pageIndex) else { return }
        let pageHeight = page.bounds(for: .mediaBox).height
        syncTeX.pendingPDFTarget = (page: result.page, point: CGPoint(x: result.x, y: pageHeight - result.y))
        activePane = .preview
    }

    private func performInverseSearch(page: Int, point: CGPoint) {
        guard let pdflatexURL = texManager.pdflatexURL(),
              let synctexURL = SyncTeXService.binaryURL(alongside: pdflatexURL),
              let pdfData = vm.pdfData,
              let document = PDFDocument(data: pdfData),
              let pdfPage = document.page(at: page - 1) else { return }
        let pageHeight = pdfPage.bounds(for: .mediaBox).height
        let texY = pageHeight - point.y
        guard let result = SyncTeXService.inverseSearch(
            synctexURL: synctexURL, page: page, x: point.x, y: texY, pdfURL: compiledPDFURL
        ) else { return }
        guard let node = vm.findNode(forAbsolutePath: result.file) else { return }
        selection = node
        vm.selectFile(node)
        syncTeX.pendingEditorLine = result.line
        activePane = .editor
    }

    // MARK: - Dynamic PDF editing

    /// Resolves a PDF click to a source element (switching the open file if the click resolves
    /// elsewhere), then either starts a drag (if already free-positioned) or selects it for the HUD.
    private func handleDynamicMouseDown(page: Int, pagePoint: CGPoint, hudPoint: CGPoint) {
        guard let pdflatexURL = texManager.pdflatexURL(),
              let synctexURL = SyncTeXService.binaryURL(alongside: pdflatexURL),
              let pdfData = vm.pdfData,
              let document = PDFDocument(data: pdfData),
              let pdfPage = document.page(at: page - 1) else { return }
        let pageHeight = pdfPage.bounds(for: .mediaBox).height
        let texY = pageHeight - pagePoint.y
        guard let result = SyncTeXService.inverseSearch(
            synctexURL: synctexURL, page: page, x: pagePoint.x, y: texY, pdfURL: compiledPDFURL
        ) else {
            dynamicEdit.clear()
            return
        }

        if vm.selectedNode?.url.standardizedFileURL.path != URL(fileURLWithPath: result.file).standardizedFileURL.path {
            guard let node = vm.findNode(forAbsolutePath: result.file) else { dynamicEdit.clear(); return }
            selection = node
            vm.selectFile(node)
        }

        guard let relativePath = vm.selectedFileRelativePath,
              let element = LaTeXElementFinder.findElement(in: vm.openFileText, sourceFile: relativePath, nearLine: result.line) else {
            dynamicEdit.clear()
            return
        }

        let wrapfigure = LaTeXElementFinder.enclosingWrapfigure(in: vm.openFileText, lineRange: element.lineRange)
        if let freeLine = LaTeXElementFinder.enclosingFreeBlockLine(in: vm.openFileText, lineRange: element.lineRange) {
            dynamicEdit.selectForHUD(element, viewPoint: hudPoint, pagePoint: pagePoint, pageHeight: pageHeight, isFree: true, wrapfigure: wrapfigure)
            dynamicEdit.beginDrag(.freePosition(lineIndex: freeLine), pagePoint: pagePoint, viewPoint: hudPoint)
        } else if let wrap = wrapfigure, let endLine = LaTeXElementFinder.matchingWrapfigureEnd(in: vm.openFileText, beginLine: wrap.line) {
            dynamicEdit.selectForHUD(element, viewPoint: hudPoint, pagePoint: pagePoint, pageHeight: pageHeight, isFree: false, wrapfigure: wrap)
            dynamicEdit.beginDrag(.wrapReposition(beginLine: wrap.line, endLine: endLine), pagePoint: pagePoint, viewPoint: hudPoint)
        } else {
            dynamicEdit.selectForHUD(element, viewPoint: hudPoint, pagePoint: pagePoint, pageHeight: pageHeight, isFree: false, wrapfigure: wrapfigure)
        }
    }

    private func handleDynamicMouseUp(page: Int, pagePoint: CGPoint) {
        guard let (kind, deltaPoints) = dynamicEdit.endDrag(currentPagePoint: pagePoint) else { return }
        switch kind {
        case .freePosition(let lineIndex):
            let deltaXmm = Double(deltaPoints.x) * 25.4 / 72.0
            let deltaYmm = -Double(deltaPoints.y) * 25.4 / 72.0
            vm.openFileText = LaTeXElementFinder.nudgeFreePosition(in: vm.openFileText, atLine: lineIndex, deltaXMM: deltaXmm, deltaYMM: deltaYmm)
            commitDynamicEdit()
        case .wrapReposition(let beginLine, let endLine):
            relocateWrapfigure(beginLine: beginLine, endLine: endLine, droppedAt: pagePoint, page: page)
        }
    }

    /// Relocates a dragged wrapfigure near wherever it was dropped: a fresh SyncTeX inverse
    /// search at the drop point finds the nearest source line to relocate before, and the side
    /// (left/right) follows which half of the page the drop landed in. Stays a real wrapfigure
    /// throughout — text keeps flowing around it and reserving its space, unlike free-position
    /// dragging (absolute overlay, no space reservation).
    private func relocateWrapfigure(beginLine: Int, endLine: Int, droppedAt pagePoint: CGPoint, page: Int) {
        guard let pdflatexURL = texManager.pdflatexURL(),
              let synctexURL = SyncTeXService.binaryURL(alongside: pdflatexURL),
              let pdfData = vm.pdfData,
              let document = PDFDocument(data: pdfData),
              let pdfPage = document.page(at: page - 1) else { return }
        let pageBounds = pdfPage.bounds(for: .mediaBox)
        let texY = pageBounds.height - pagePoint.y
        guard let result = SyncTeXService.inverseSearch(
            synctexURL: synctexURL, page: page, x: pagePoint.x, y: texY, pdfURL: compiledPDFURL
        ) else { return }

        var text = vm.openFileText
        text = LaTeXElementFinder.relocateBlock(
            in: text, lineRange: (beginLine + 1)...(endLine + 1), toBeforeLine: result.line
        )
        let newSide = pagePoint.x < pageBounds.width / 2 ? "l" : "r"
        // The block may have shifted if it moved past its own former location; re-find it fresh
        // near the target line rather than trusting the old line numbers for the side flip.
        if let refoundWrap = LaTeXElementFinder.findElement(in: text, sourceFile: "", nearLine: result.line),
           let wrap = LaTeXElementFinder.enclosingWrapfigure(in: text, lineRange: refoundWrap.lineRange) {
            text = LaTeXElementFinder.setWrapSide(in: text, atLine: wrap.line, side: newSide)
        }
        vm.openFileText = text
        commitDynamicEdit()
    }

    private func resizeActiveElement(factor: Double) {
        guard let element = dynamicEdit.activeElement else { return }
        vm.openFileText = LaTeXElementFinder.resizeImage(in: vm.openFileText, lineRange: element.lineRange, factor: factor)
        if let refreshed = LaTeXElementFinder.findElement(in: vm.openFileText, sourceFile: element.sourceFile, nearLine: element.lineRange.lowerBound) {
            dynamicEdit.activeElement = refreshed
        }
        commitDynamicEdit(closeHUD: false)
    }

    private func cyclePlacementForActiveElement() {
        guard let element = dynamicEdit.activeElement, case .float(let env, _) = element.kind else { return }
        vm.openFileText = LaTeXElementFinder.cyclePlacement(in: vm.openFileText, lineRange: element.lineRange, environment: env)
        if let refreshed = LaTeXElementFinder.findElement(in: vm.openFileText, sourceFile: element.sourceFile, nearLine: element.lineRange.lowerBound) {
            dynamicEdit.activeElement = refreshed
        }
        commitDynamicEdit(closeHUD: false)
    }

    private func moveActiveElement(direction: Int) {
        guard let element = dynamicEdit.activeElement else { return }
        vm.openFileText = LaTeXElementFinder.moveBlock(in: vm.openFileText, lineRange: element.lineRange, direction: direction)
        commitDynamicEdit()
    }

    private func convertActiveElementToFreePosition() {
        guard let element = dynamicEdit.activeElement, let (xMM, yMM) = dynamicEdit.clickPointInMM() else { return }
        // \usepackage is only legal in the true preamble — the element's own file may be an
        // \input-ed sub-file, so the preamble edit always targets the actual main file.
        ensureTextposSupportInMainFile()
        vm.openFileText = LaTeXElementFinder.wrapInFreePosition(in: vm.openFileText, element: element, xMM: xMM, yMM: yMM, widthMM: 80)
        commitDynamicEdit()
    }

    private func ensureTextposSupportInMainFile() {
        ensureMainFilePreamble(has: LaTeXElementFinder.hasTextposSupport, add: LaTeXElementFinder.ensureTextposPreamble)
    }

    private func ensureWrapfigSupportInMainFile() {
        ensureMainFilePreamble(has: LaTeXElementFinder.hasWrapfigSupport, add: LaTeXElementFinder.ensureWrapfigPreamble)
    }

    /// \usepackage is only legal in the true preamble — the element being edited may live in an
    /// \input-ed sub-file, so preamble edits always target the actual main file.
    private func ensureMainFilePreamble(has: (String) -> Bool, add: (String) -> String) {
        let mainURL = vm.project.url.appendingPathComponent(vm.project.mainFile)
        guard let mainText = try? String(contentsOf: mainURL, encoding: .utf8), !has(mainText) else { return }
        let updated = add(mainText)
        if vm.selectedNode?.url.standardizedFileURL == mainURL.standardizedFileURL {
            vm.openFileText = updated
        } else {
            try? updated.write(to: mainURL, atomically: true, encoding: .utf8)
        }
    }

    private func setWrapText(side: String) {
        guard let element = dynamicEdit.activeElement else { return }
        ensureWrapfigSupportInMainFile()
        vm.openFileText = LaTeXElementFinder.setWrapText(in: vm.openFileText, element: element, side: side)
        commitDynamicEdit()
    }

    private func flipWrapSide() {
        guard let wrap = dynamicEdit.activeWrapfigure else { return }
        let newSide = wrap.side == "l" ? "r" : "l"
        vm.openFileText = LaTeXElementFinder.setWrapSide(in: vm.openFileText, atLine: wrap.line, side: newSide)
        commitDynamicEdit()
    }

    private func removeWrapText() {
        guard let wrap = dynamicEdit.activeWrapfigure else { return }
        vm.openFileText = LaTeXElementFinder.removeWrapText(in: vm.openFileText, atLine: wrap.line)
        commitDynamicEdit()
    }

    private func commitDynamicEdit(closeHUD: Bool = true) {
        vm.flushPendingSave()
        Task { await vm.compile(using: texManager) }
        if closeHUD { dynamicEdit.clear() }
    }

    // MARK: - Panes

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FILES")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New File...") { newItemParent = vm.rootNode; newItemName = ""; showNewFileSheet = true }
                    Button("New Folder...") { newItemParent = vm.rootNode; newItemName = ""; showNewFolderSheet = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    vm.rootNode.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            FileTreeView(
                root: vm.rootNode,
                selection: $selection,
                onNewFile: { parent in newItemParent = parent; newItemName = ""; showNewFileSheet = true },
                onNewFolder: { parent in newItemParent = parent; newItemName = ""; showNewFolderSheet = true },
                onRename: { node in renameTarget = node },
                onDelete: { node in deleteTarget = node }
            )
            .onChange(of: selection) { _, newValue in
                if let newValue { vm.selectFile(newValue) }
            }

            Spacer(minLength: 0)
            Divider().opacity(0.3)
            HStack {
                Spacer()
                BrandMark(size: 20)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .background(settings.color(for: .sidebarBackground))
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(vm.selectedNode?.name ?? "No file selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.selectedFileKind == .text {
                    Text("\u{2318}-click a line to jump to it in the PDF")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button {
                        showHistoryPopover = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("File History")
                    .popover(isPresented: $showHistoryPopover) {
                        historyPopoverContent
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(settings.color(for: .panelBackground))

            ZStack(alignment: .top) {
                switch vm.selectedFileKind {
                case .text where vm.selectedNode != nil:
                    CodeEditorView(
                        text: $vm.openFileText,
                        fileID: vm.selectedNode?.id ?? "",
                        searchController: editorSearch,
                        syncTeX: syncTeX,
                        undoController: editorUndo
                    ) { _ in
                        vm.scheduleSave()
                        vm.scheduleAutoCompile(using: texManager)
                    } onFocus: {
                        activePane = .editor
                    } onCommandClick: { line in
                        performForwardSearch(line: line)
                    }
                case .image:
                    if let node = vm.selectedNode {
                        AssetImageView(url: node.url)
                    }
                case .pdf:
                    if let node = vm.selectedNode {
                        AssetPDFView(url: node.url)
                    }
                case .unsupported where vm.selectedNode != nil:
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.questionmark").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No preview available for this file type").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                default:
                    VStack {
                        Spacer()
                        Text("Select a file to start editing")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }

                if showEditorFind && vm.selectedFileKind == .text {
                    FindBarView(
                        query: $editorSearch.query,
                        matchCount: editorSearch.matchCount,
                        currentIndex: editorSearch.currentIndex,
                        onNext: { editorSearch.next() },
                        onPrevious: { editorSearch.previous() },
                        onClose: {
                            showEditorFind = false
                            editorSearch.clear()
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { activePane = .editor })
    }

    private var historyPopoverContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File History").font(.headline).padding(12)
            Divider()
            if let node = vm.selectedNode {
                let snapshots = FileHistoryManager.shared.snapshots(for: node.url)
                if snapshots.isEmpty {
                    Text("No earlier versions yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(snapshots) { snapshot in
                                HStack {
                                    Text(snapshot.date, format: .relative(presentation: .named))
                                        .font(.caption)
                                    Spacer()
                                    Button("Restore") {
                                        vm.restoreSnapshot(snapshot, for: node)
                                        showHistoryPopover = false
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .frame(width: 260)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if dynamicEdit.isEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "hand.draw.fill").foregroundStyle(.orange)
                    Text("Dynamic editing on \u{2014} click an image, figure, or table below")
                        .font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.orange.opacity(0.12))
            }

            ZStack(alignment: .topLeading) {
                if let pdfData = vm.pdfData {
                    PDFPreviewView(
                        data: pdfData,
                        searchController: pdfSearch,
                        zoomController: pdfZoom,
                        syncTeX: syncTeX,
                        dynamicModeEnabled: dynamicEdit.isEnabled
                    ) {
                        activePane = .preview
                    } onCommandClick: { page, point in
                        performInverseSearch(page: page, point: point)
                    } onDynamicMouseDown: { page, pagePoint, hudPoint in
                        handleDynamicMouseDown(page: page, pagePoint: pagePoint, hudPoint: hudPoint)
                    } onDynamicMouseDragged: { viewPoint in
                        dynamicEdit.updateDrag(viewPoint: viewPoint)
                    } onDynamicMouseUp: { page, pagePoint in
                        handleDynamicMouseUp(page: page, pagePoint: pagePoint)
                    }
                } else if vm.isCompiling {
                    VStack {
                        Spacer()
                        HStack { Spacer(); ProgressView("Compiling..."); Spacer() }
                        Spacer()
                    }
                } else {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                                Text(vm.compileError ?? "No PDF yet. Click Recompile.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                }

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
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if vm.pdfData != nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            zoomControls
                        }
                    }
                }

                if let previewPoint = dynamicEdit.dragPreviewViewPoint {
                    Circle()
                        .strokeBorder(Color.orange, lineWidth: 2)
                        .background(Circle().fill(Color.orange.opacity(0.15)))
                        .frame(width: 28, height: 28)
                        .position(previewPoint)
                        .allowsHitTesting(false)
                }

                dynamicHUD
            }
            .simultaneousGesture(TapGesture().onEnded { activePane = .preview })

            if showLog {
                Divider()
                HStack {
                    Text("Compile Log").font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer()
                    copyButton(vm.compileLog)
                }
                .padding(.horizontal, 8).padding(.top, 6)
                ScrollView {
                    Text(vm.compileLog.isEmpty ? "No log yet." : vm.compileLog)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(settings.color(for: .panelBackground))
            }

            HStack {
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error = vm.compileError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    copyButton(vm.compileLog.isEmpty ? error : vm.compileLog)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(settings.color(for: .panelBackground))
        }
    }

    @ViewBuilder
    private var dynamicHUD: some View {
        if let element = dynamicEdit.activeElement, let point = dynamicEdit.hudViewPoint, !dynamicEdit.isActiveElementFree {
            VStack(alignment: .leading, spacing: 8) {
                switch element.kind {
                case .image:
                    Text("Image").font(.caption.bold())
                    HStack(spacing: 10) {
                        Button { resizeActiveElement(factor: 0.9) } label: { Image(systemName: "minus.circle") }
                        Button { resizeActiveElement(factor: 1.1) } label: { Image(systemName: "plus.circle") }
                    }
                    .buttonStyle(.plain)
                case .float(let env, _):
                    Text(env.capitalized.replacingOccurrences(of: "*", with: "")).font(.caption.bold())
                    Button("Cycle Placement") { cyclePlacementForActiveElement() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    HStack(spacing: 10) {
                        Button { moveActiveElement(direction: -1) } label: { Image(systemName: "arrow.up.circle") }
                        Button { moveActiveElement(direction: 1) } label: { Image(systemName: "arrow.down.circle") }
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                Text("Text Wrap").font(.caption2.bold()).foregroundStyle(.secondary)
                if let wrap = dynamicEdit.activeWrapfigure {
                    Text("Wrapping (\(wrap.side == "l" ? "left" : "right")) \u{2014} drag it to move")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Flip Side") { flipWrapSide() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        Button("Remove") { removeWrapText() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                } else {
                    Text("Let text flow around it, instead of a full-width block.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Wrap Left") { setWrapText(side: "l") }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        Button("Wrap Right") { setWrapText(side: "r") }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }

                Divider()
                Button("Enable Free Position") { convertActiveElementToFreePosition() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Close") { dynamicEdit.clear() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .frame(width: 190)
            .position(x: min(max(point.x, 100), 490), y: max(point.y - 110, 90))
        } else if dynamicEdit.isActiveElementFree, dynamicEdit.activeElement != nil {
            Text("Drag to reposition")
                .font(.caption2)
                .padding(6)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .position(x: min(max((dynamicEdit.hudViewPoint?.x ?? 100), 90), 500), y: max((dynamicEdit.hudViewPoint?.y ?? 100) - 30, 40))
                .allowsHitTesting(false)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { pdfZoom.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(pdfZoom.scalePercent) },
                    set: { pdfZoom.setScale(percent: $0) }
                ),
                in: Double(pdfZoom.minScalePercent)...Double(pdfZoom.maxScalePercent)
            )
            .frame(width: 90)

            Text("\(pdfZoom.scalePercent)%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 38)

            Button { pdfZoom.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
        .padding(10)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.blue)
        .help("Copy to clipboard")
        .disabled(text.isEmpty)
    }
}
