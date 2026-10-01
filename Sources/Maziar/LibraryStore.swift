import Foundation

/// Backs the Library page — a folder of PDFs (meant to live inside a Google Drive–synced
/// directory, e.g. from Google Drive for Desktop) plus metadata about each one, optionally
/// organized into Groups. There's no Google API integration here at all: since a Drive-synced
/// folder is just a normal folder on disk once Google's own desktop app is installed, "connecting"
/// it is just picking that folder, and "backing up"/"uploading" a new paper is just copying it
/// in — Drive's own sync client does the rest, the same way saving into any other synced folder
/// would. Groups follow the same idea one level down: a Group IS a subfolder of the library root,
/// not a separate database concept, so creating one really does "make a folder in storage" the
/// way the feature was asked for.
///
/// A paper can belong to several groups at once — since each group is a real folder, that's
/// implemented as a real copy of the file in each group's folder (not a symlink: Google Drive's
/// sync doesn't resolve macOS symlinks into the same file living in multiple places, it just
/// uploads the tiny symlink itself, which defeats the point). This costs extra Drive storage
/// (one copy per group a paper is in) in exchange for every group actually being a real,
/// independently browsable/backed-up folder, which is what was asked for.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var folderPath: String? {
        didSet { UserDefaults.standard.set(folderPath, forKey: Self.folderKey) }
    }
    @Published var entries: [LibraryEntry] {
        didSet { persistEntries() }
    }
    @Published var groups: [LibraryGroup] {
        didSet { persistGroups() }
    }
    @Published var lastScanDate: Date?
    @Published var scanError: String?
    /// The Translator's target-language picker is built from this — deliberately not preloaded
    /// with "a lot of languages", just a small starter set; add/remove your own in Settings →
    /// Library.
    @Published var translatorLanguages: [String] {
        didSet { UserDefaults.standard.set(translatorLanguages, forKey: Self.translatorLanguagesKey) }
    }
    /// The group bar defaults to a single row (scrolling sideways once groups overflow it); this
    /// opts into the old two-row grid instead, for someone who'd rather scroll less and see more
    /// groups at once. Off by default.
    @Published var groupsTwoRowLayout: Bool {
        didSet { UserDefaults.standard.set(groupsTwoRowLayout, forKey: Self.groupsTwoRowLayoutKey) }
    }
    /// The Reader window's highlighter palette — user-managed (add/rename/remove) rather than a
    /// long fixed set, same reasoning as `translatorLanguages`.
    @Published var highlightColors: [HighlightColorOption] {
        didSet { persistHighlightColors() }
    }
    /// The Library page's paper-label color palette — user-managed, same reasoning as
    /// `highlightColors`.
    @Published var paperLabels: [PaperLabelOption] {
        didSet { persistPaperLabels() }
    }
    /// The reading-order numbers offered in a paper's label right-click menu, independent of
    /// `paperLabels` — a paper picks its color and its number separately.
    @Published var paperLabelNumbers: [Int] {
        didSet { UserDefaults.standard.set(paperLabelNumbers, forKey: Self.paperLabelNumbersKey) }
    }
    /// Caps how tall a note/notebook-cell text editor can grow before it starts scrolling
    /// internally instead of pushing the rest of the page down — the *minimum* is not similarly
    /// configurable, since a `TextField(axis: .vertical)` (what the note/cell editors use) already
    /// shrinks to fit short content on its own; there's nothing to configure there.
    @Published var notesCellMaxLines: Int {
        didSet { UserDefaults.standard.set(notesCellMaxLines, forKey: Self.notesCellMaxLinesKey) }
    }

    private static let folderKey = "maziar.library.folderPath"
    private static let entriesKey = "maziar.library.entries"
    private static let groupsKey = "maziar.library.groups"
    private static let translatorLanguagesKey = "maziar.library.translatorLanguages"
    private static let groupsTwoRowLayoutKey = "maziar.library.groupsTwoRowLayout"
    private static let highlightColorsKey = "maziar.library.highlightColors"
    private static let paperLabelsKey = "maziar.library.paperLabels"
    private static let paperLabelNumbersKey = "maziar.library.paperLabelNumbers"
    private static let notesCellMaxLinesKey = "maziar.library.notesCellMaxLines"

    static let defaultTranslatorLanguages = ["English", "Spanish", "French"]
    static let defaultHighlightColors = [
        HighlightColorOption(name: "Important", colorHex: "FFEB3BFF"),
        HighlightColorOption(name: "Question", colorHex: "4FC3F7FF"),
        HighlightColorOption(name: "Definition", colorHex: "81C784FF"),
    ]
    static let defaultPaperLabels = [
        PaperLabelOption(name: "Important", colorHex: "F44336FF"),
        PaperLabelOption(name: "To Read", colorHex: "4FC3F7FF"),
        PaperLabelOption(name: "Reference", colorHex: "81C784FF"),
    ]
    static let defaultPaperLabelNumbers = [1, 2, 3]
    static let defaultNotesCellMaxLines = 20

    init() {
        folderPath = UserDefaults.standard.string(forKey: Self.folderKey)
        entries = Self.loadEntries()
        groups = Self.loadGroups()
        translatorLanguages = UserDefaults.standard.stringArray(forKey: Self.translatorLanguagesKey) ?? Self.defaultTranslatorLanguages
        groupsTwoRowLayout = UserDefaults.standard.bool(forKey: Self.groupsTwoRowLayoutKey)
        highlightColors = Self.loadHighlightColors()
        paperLabels = Self.loadPaperLabels()
        paperLabelNumbers = UserDefaults.standard.array(forKey: Self.paperLabelNumbersKey) as? [Int] ?? Self.defaultPaperLabelNumbers
        let storedMaxLines = UserDefaults.standard.integer(forKey: Self.notesCellMaxLinesKey)
        notesCellMaxLines = storedMaxLines > 0 ? storedMaxLines : Self.defaultNotesCellMaxLines
    }

    /// Re-reads everything from UserDefaults — used after a settings backup is imported.
    func reloadFromDefaults() {
        folderPath = UserDefaults.standard.string(forKey: Self.folderKey)
        entries = Self.loadEntries()
        groups = Self.loadGroups()
        translatorLanguages = UserDefaults.standard.stringArray(forKey: Self.translatorLanguagesKey) ?? Self.defaultTranslatorLanguages
        groupsTwoRowLayout = UserDefaults.standard.bool(forKey: Self.groupsTwoRowLayoutKey)
        highlightColors = Self.loadHighlightColors()
        paperLabels = Self.loadPaperLabels()
        paperLabelNumbers = UserDefaults.standard.array(forKey: Self.paperLabelNumbersKey) as? [Int] ?? Self.defaultPaperLabelNumbers
        let storedMaxLines = UserDefaults.standard.integer(forKey: Self.notesCellMaxLinesKey)
        notesCellMaxLines = storedMaxLines > 0 ? storedMaxLines : Self.defaultNotesCellMaxLines
    }

    private static func loadPaperLabels() -> [PaperLabelOption] {
        guard let data = UserDefaults.standard.data(forKey: Self.paperLabelsKey) else {
            return defaultPaperLabels
        }
        guard let decoded = try? JSONDecoder().decode([PaperLabelOption].self, from: data) else {
            return defaultPaperLabels
        }
        return decoded
    }

    private func persistPaperLabels() {
        guard let data = try? JSONEncoder().encode(paperLabels) else { return }
        UserDefaults.standard.set(data, forKey: Self.paperLabelsKey)
    }

    @discardableResult
    func addPaperLabel(name: String, colorHex: String) -> PaperLabelOption {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let option = PaperLabelOption(name: trimmed.isEmpty ? "Label" : trimmed, colorHex: colorHex)
        paperLabels.append(option)
        return option
    }

    func updatePaperLabel(_ option: PaperLabelOption, name: String, colorHex: String) {
        guard let index = paperLabels.firstIndex(where: { $0.id == option.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        paperLabels[index].name = trimmed
        paperLabels[index].colorHex = colorHex
    }

    /// Removing a color doesn't touch any paper's `labelColorID` — a paper pointing at a now-deleted
    /// color is just treated as uncolored by `labelColor(for:)` below, no cleanup pass needed.
    func removePaperLabel(_ option: PaperLabelOption) {
        paperLabels.removeAll { $0.id == option.id }
    }

    func labelColor(for entry: LibraryEntry) -> PaperLabelOption? {
        guard let labelColorID = entry.labelColorID else { return nil }
        return paperLabels.first { $0.id == labelColorID }
    }

    func setLabelColor(_ labelColorID: UUID?, for entry: LibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].labelColorID = labelColorID
    }

    func setLabelNumber(_ number: Int?, for entry: LibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].labelNumber = number
    }

    @discardableResult
    func addPaperLabelNumber(_ number: Int) -> Bool {
        guard !paperLabelNumbers.contains(number) else { return false }
        paperLabelNumbers.append(number)
        paperLabelNumbers.sort()
        return true
    }

    func removePaperLabelNumber(_ number: Int) {
        paperLabelNumbers.removeAll { $0 == number }
    }

    private static func loadHighlightColors() -> [HighlightColorOption] {
        guard let data = UserDefaults.standard.data(forKey: Self.highlightColorsKey) else {
            return defaultHighlightColors
        }
        guard let decoded = try? JSONDecoder().decode([HighlightColorOption].self, from: data) else {
            return defaultHighlightColors
        }
        return decoded
    }

    private func persistHighlightColors() {
        guard let data = try? JSONEncoder().encode(highlightColors) else { return }
        UserDefaults.standard.set(data, forKey: Self.highlightColorsKey)
    }

    @discardableResult
    func addHighlightColor(name: String, colorHex: String) -> HighlightColorOption {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let option = HighlightColorOption(name: trimmed.isEmpty ? "Highlight" : trimmed, colorHex: colorHex)
        highlightColors.append(option)
        return option
    }

    func renameHighlightColor(_ option: HighlightColorOption, to newName: String) {
        guard let index = highlightColors.firstIndex(where: { $0.id == option.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        highlightColors[index].name = trimmed
    }

    /// Updates both the name and the color/opacity (`colorHex` is already RGBA — see `Color
    /// .toHex()`/`init?(hex:)` in `AppSettings.swift` — so opacity round-trips through the same
    /// hex string a plain color does, no separate field needed) of an existing highlight color.
    func updateHighlightColor(_ option: HighlightColorOption, name: String, colorHex: String) {
        guard let index = highlightColors.firstIndex(where: { $0.id == option.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        highlightColors[index].name = trimmed
        highlightColors[index].colorHex = colorHex
    }

    func removeHighlightColor(_ option: HighlightColorOption) {
        highlightColors.removeAll { $0.id == option.id }
    }

    @discardableResult
    func addTranslatorLanguage(_ language: String) -> Bool {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !translatorLanguages.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        translatorLanguages.append(trimmed)
        return true
    }

    func removeTranslatorLanguage(_ language: String) {
        translatorLanguages.removeAll { $0 == language }
    }

    private static func loadEntries() -> [LibraryEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([LibraryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.entriesKey)
    }

    private static func loadGroups() -> [LibraryGroup] {
        guard let data = UserDefaults.standard.data(forKey: Self.groupsKey),
              let decoded = try? JSONDecoder().decode([LibraryGroup].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: Self.groupsKey)
    }

    var folderURL: URL? {
        guard let folderPath else { return nil }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// The directory a given group's papers actually live in — nil (meaning "the library root
    /// itself") when `group` is nil.
    func directoryURL(for group: LibraryGroup?) -> URL? {
        guard let folderURL else { return nil }
        guard let group else { return folderURL }
        return folderURL.appendingPathComponent(group.folderName, isDirectory: true)
    }

    func group(_ id: UUID?) -> LibraryGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func entries(in group: LibraryGroup?) -> [LibraryEntry] {
        guard let group else { return entries }
        return entries.filter { $0.groupFileNames[group.id] != nil }
    }

    func connect(_ url: URL) {
        folderPath = url.path
        scanError = nil
        scan()
    }

    func disconnect() {
        folderPath = nil
    }

    /// Any `~/Library/CloudStorage/GoogleDrive-*` directories found — used to point the folder
    /// picker somewhere useful right away instead of starting at the home directory, since that's
    /// where Google Drive for Desktop actually mounts a signed-in account's Drive.
    static func suggestedDriveRoots() -> [URL] {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }
    }

    /// Every physical copy of a paper: its root copy (if any) first, then one per group it
    /// belongs to.
    func locationURLs(for entry: LibraryEntry) -> [URL] {
        var urls: [URL] = []
        if let rootFileName = entry.rootFileName, let folderURL {
            urls.append(folderURL.appendingPathComponent(rootFileName))
        }
        for (groupID, fileName) in entry.groupFileNames {
            if let dir = directoryURL(for: group(groupID)) {
                urls.append(dir.appendingPathComponent(fileName))
            }
        }
        return urls
    }

    /// The URL to actually open/read — whichever copy exists first (root preferred), so Open/AI
    /// extraction/Reveal-in-Finder all have one to work with regardless of which group filtered
    /// view the user found this paper in.
    func primaryURL(for entry: LibraryEntry) -> URL? {
        locationURLs(for: entry).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// True only when *none* of a paper's copies can be found — a paper missing from just one of
    /// several groups isn't "missing", since it's still reachable through the others.
    func isFileMissing(_ entry: LibraryEntry) -> Bool {
        primaryURL(for: entry) == nil
    }

    /// Where this paper's notes companion file lives — same folder as its primary PDF copy, same
    /// base name, `.txt` extension (e.g. "Attention.pdf" -> "Attention.txt"). One canonical notes
    /// file per paper rather than one per group copy (unlike the PDF itself): notes are personal
    /// annotations, not the paper's actual content, so duplicating them into every group folder
    /// would just create sync-drift risk (edit one copy, the others go stale) for no real benefit.
    func notesFileURL(for entry: LibraryEntry) -> URL? {
        guard let pdfURL = primaryURL(for: entry) else { return nil }
        return pdfURL.deletingPathExtension().appendingPathExtension("txt")
    }

    /// Reads the notes companion file if one exists; falls back to (and transparently migrates)
    /// `entry.notes` for entries tracked before this file existed.
    func readNotes(for entry: LibraryEntry) -> String {
        guard let notesURL = notesFileURL(for: entry) else { return entry.notes }
        if let text = try? String(contentsOf: notesURL, encoding: .utf8) {
            return text
        }
        if !entry.notes.isEmpty {
            try? entry.notes.write(to: notesURL, atomically: true, encoding: .utf8)
        }
        return entry.notes
    }

    func writeNotes(_ text: String, for entry: LibraryEntry) {
        guard let notesURL = notesFileURL(for: entry) else { return }
        try? text.write(to: notesURL, atomically: true, encoding: .utf8)
        if let index = entries.firstIndex(where: { $0.id == entry.id }), entries[index].notes != text {
            entries[index].notes = text
        }
    }

    enum NotesFormat: Equatable {
        /// The original `## Title` plain-text companion file (`PaperNotesDocument`).
        case legacyText
        /// A real `.ipynb` notebook of markdown cells (`NotebookDocument`) — what every paper
        /// added after this feature shipped gets, since it had no notes file of either kind yet.
        case notebook
    }

    /// A paper that already has a legacy `.txt` notes file keeps using it forever; a paper with
    /// neither file yet (added after this feature shipped) uses the newer notebook format. Checked
    /// against the real file on disk rather than some separate stored flag, so it can't drift.
    func notesFormat(for entry: LibraryEntry) -> NotesFormat {
        if let legacyURL = notesFileURL(for: entry), FileManager.default.fileExists(atPath: legacyURL.path) {
            return .legacyText
        }
        return .notebook
    }

    /// One of a paper's possibly-several notebook tabs — see `notebookTabs(for:)`.
    struct NotebookTab: Identifiable, Equatable {
        var id: String { fileName }
        var name: String
        var fileName: String
    }

    /// Where a paper's notebook *tabs* live — a folder named after the paper, next to its PDF (e.g.
    /// "Attention.pdf" -> "Attention/"), holding one `.ipynb` file per tab.
    func notebookFolderURL(for entry: LibraryEntry) -> URL? {
        guard let pdfURL = primaryURL(for: entry) else { return nil }
        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        return pdfURL.deletingLastPathComponent().appendingPathComponent(baseName, isDirectory: true)
    }

    /// Lists every notebook tab for this paper, migrating an older single flat `<Paper>.ipynb` file
    /// (from before multi-tab notebooks existed) into the folder as the first tab the first time
    /// it's called — so existing notes move, rather than being duplicated or lost, the moment
    /// multi-tab notebooks are used. The folder's actual `.ipynb` files *are* the tab list; there's
    /// no separate index that could drift out of sync with what's really on disk. The first tab
    /// always keeps the paper's own base filename (pinned first in the returned list); any other
    /// tab is just another `.ipynb` file the user named when adding it, sorted alphabetically after.
    func notebookTabs(for entry: LibraryEntry) -> [NotebookTab] {
        guard let pdfURL = primaryURL(for: entry), let folderURL = notebookFolderURL(for: entry) else { return [] }
        let fm = FileManager.default
        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        let legacyFlatURL = pdfURL.deletingPathExtension().appendingPathExtension("ipynb")
        let firstTabURL = folderURL.appendingPathComponent(baseName).appendingPathExtension("ipynb")

        if !fm.fileExists(atPath: folderURL.path) {
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: legacyFlatURL.path), !fm.fileExists(atPath: firstTabURL.path) {
            try? fm.moveItem(at: legacyFlatURL, to: firstTabURL)
        }

        let files = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        var tabs = files
            .filter { $0.pathExtension.lowercased() == "ipynb" }
            .map { NotebookTab(name: $0.deletingPathExtension().lastPathComponent, fileName: $0.lastPathComponent) }
        tabs.sort { lhs, rhs in
            if lhs.name == baseName { return true }
            if rhs.name == baseName { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        guard !tabs.isEmpty else {
            // Brand new paper, nothing written to this tab yet — still surface it so the UI has a
            // tab to show and create on first write, rather than an empty tab bar.
            return [NotebookTab(name: baseName, fileName: firstTabURL.lastPathComponent)]
        }
        return tabs
    }

    func readNotebook(for entry: LibraryEntry, tab: NotebookTab) -> NotebookDocument {
        guard let folderURL = notebookFolderURL(for: entry) else { return NotebookDocument() }
        let url = folderURL.appendingPathComponent(tab.fileName)
        guard let data = try? Data(contentsOf: url), let document = NotebookDocument.decode(data) else {
            return NotebookDocument()
        }
        return document
    }

    func writeNotebook(_ document: NotebookDocument, for entry: LibraryEntry, tab: NotebookTab) {
        guard let folderURL = notebookFolderURL(for: entry), let data = document.encoded() else { return }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? data.write(to: folderURL.appendingPathComponent(tab.fileName), options: .atomic)
    }

    /// Creates a new, empty tab named `name` (e.g. "Questions" -> "Questions.ipynb") and returns
    /// it, or `nil` for a blank/whitespace-only name or if a tab with that name already exists.
    @discardableResult
    func addNotebookTab(named name: String, for entry: LibraryEntry) -> NotebookTab? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let folderURL = notebookFolderURL(for: entry) else { return nil }
        let fileName = "\(trimmed).ipynb"
        let url = folderURL.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard let data = NotebookDocument().encoded() else { return nil }
        try? data.write(to: url, options: .atomic)
        return NotebookTab(name: trimmed, fileName: fileName)
    }

    func removeNotebookTab(_ tab: NotebookTab, for entry: LibraryEntry) {
        guard let folderURL = notebookFolderURL(for: entry) else { return }
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(tab.fileName))
    }

    /// Every PDF gets a notes companion file the moment it's known to Maziar — whether it arrived
    /// through `addFiles()` or was just found sitting in the folder by `scan()` — leaving an
    /// existing one alone (whichever format it's in) and only filling in a missing one. A paper
    /// that already has a legacy `.txt` file keeps that format forever; a genuinely new paper
    /// (neither file exists yet) gets the newer `.ipynb` notebook format instead — this is the
    /// entire "new papers only" switch, driven by what's actually on disk rather than a separate
    /// flag that could drift out of sync with it. Also checks for the paper's notebook *folder*
    /// (`notebookTabs(for:)`'s multi-tab storage) — without that check, a paper whose flat
    /// `<Paper>.ipynb` was already migrated into its folder would look like it has neither file,
    /// and get a brand new, blank flat `.ipynb` created right next to the real, already-in-use
    /// folder-based notebook.
    private func ensureNotesFile(besides pdf: URL) {
        let legacyURL = pdf.deletingPathExtension().appendingPathExtension("txt")
        let notebookURL = pdf.deletingPathExtension().appendingPathExtension("ipynb")
        let baseName = pdf.deletingPathExtension().lastPathComponent
        let folderURL = pdf.deletingLastPathComponent().appendingPathComponent(baseName, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: legacyURL.path), !fm.fileExists(atPath: notebookURL.path),
              !fm.fileExists(atPath: folderURL.path) else { return }
        if let data = NotebookDocument().encoded() {
            try? data.write(to: notebookURL, options: .atomic)
        }
    }

    /// Picks up any PDFs that showed up in the folder (root or a group subfolder) since the last
    /// scan — added directly in Finder, synced down from another device via Drive, etc. — as new
    /// stub entries, and any subfolder not already tracked as a Group as a new Group. This is what
    /// "always update from there" means in practice: there's no live push notification without the
    /// Drive API, just re-checking the directory listing (root, then one level into each
    /// subfolder — groups don't nest further). A file that appears in two different locations
    /// outside Maziar (e.g. manually copied into both the root and a group folder) is picked up as
    /// two separate entries — there's no reliable way to know they're "the same paper" from a
    /// filename alone.
    @discardableResult
    func scan() -> Int {
        guard let folderURL else { return 0 }
        let fm = FileManager.default
        guard let rootContents = try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            scanError = "Couldn't read \(folderURL.path). It may have been moved or unmounted."
            return 0
        }

        var added = 0

        // Root-level PDFs.
        let rootPDFs = rootContents.filter { $0.pathExtension.lowercased() == "pdf" }
        let knownRootNames = Set(entries.compactMap(\.rootFileName))
        for pdf in rootPDFs where !knownRootNames.contains(pdf.lastPathComponent) {
            entries.append(LibraryEntry(
                title: PDFTitleExtractor.title(forPDFAt: pdf, fallback: pdf.deletingPathExtension().lastPathComponent),
                dateAdded: creationDate(of: pdf),
                rootFileName: pdf.lastPathComponent
            ))
            ensureNotesFile(besides: pdf)
            added += 1
        }

        // Subfolders: each one is a Group (auto-adopted if not already tracked).
        let subfolders = rootContents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        for folder in subfolders {
            let folderName = folder.lastPathComponent
            let activeGroup: LibraryGroup
            if let existingGroup = groups.first(where: { $0.folderName == folderName }) {
                activeGroup = existingGroup
            } else {
                let newGroup = LibraryGroup(name: folderName, folderName: folderName, dateCreated: creationDate(of: folder))
                groups.append(newGroup)
                activeGroup = newGroup
            }

            guard let groupFiles = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            let groupPDFs = groupFiles.filter { $0.pathExtension.lowercased() == "pdf" }
            let knownGroupNames = Set(entries.compactMap { $0.groupFileNames[activeGroup.id] })
            for pdf in groupPDFs where !knownGroupNames.contains(pdf.lastPathComponent) {
                var newEntry = LibraryEntry(
                    title: PDFTitleExtractor.title(forPDFAt: pdf, fallback: pdf.deletingPathExtension().lastPathComponent),
                    dateAdded: creationDate(of: pdf)
                )
                newEntry.groupFileNames[activeGroup.id] = pdf.lastPathComponent
                entries.append(newEntry)
                ensureNotesFile(besides: pdf)
                added += 1
            }
        }

        lastScanDate = Date()
        scanError = nil
        return added
    }

    private func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    }

    /// Copies files in as new papers, distributed across whichever locations are requested — the
    /// "upload" half: once they land inside a Drive-synced directory, Google's own app pushes them
    /// up like any other new file there. At least one destination is required.
    func addFiles(_ urls: [URL], toGroups groupTargets: [LibraryGroup] = [], alsoRoot: Bool = false) throws {
        let effectiveAlsoRoot = alsoRoot || groupTargets.isEmpty
        guard effectiveAlsoRoot || !groupTargets.isEmpty else { return }
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            var entry = LibraryEntry(title: PDFTitleExtractor.title(forPDFAt: url, fallback: url.deletingPathExtension().lastPathComponent))
            if effectiveAlsoRoot, let folderURL {
                let dest = uniqueURL(in: folderURL, name: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                entry.rootFileName = dest.lastPathComponent
            }
            for group in groupTargets {
                guard let dir = directoryURL(for: group) else { continue }
                let dest = uniqueURL(in: dir, name: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: dest)
                entry.groupFileNames[group.id] = dest.lastPathComponent
            }
            guard entry.rootFileName != nil || !entry.groupFileNames.isEmpty else {
                throw NSError(domain: "Maziar", code: 70, userInfo: [NSLocalizedDescriptionKey: "Connect a folder first."])
            }
            // A real, empty notes companion file from the moment the paper's added — so it's
            // there in Finder/Drive right away, not just conjured into existence the first time
            // someone happens to type a note.
            if let primaryFileURL = primaryURL(for: entry) {
                ensureNotesFile(besides: primaryFileURL)
            }
            entries.append(entry)
        }
    }

    /// Convenience wrapper for the common case: one destination, matching the page's current scope
    /// ("All Papers" -> root, a specific group selected -> that group).
    func addFiles(_ urls: [URL], toGroup group: LibraryGroup?) throws {
        if let group {
            try addFiles(urls, toGroups: [group], alsoRoot: false)
        } else {
            try addFiles(urls, toGroups: [], alsoRoot: true)
        }
    }

    enum DownloadError: LocalizedError {
        case invalidURL
        case notAPDF
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "That doesn't look like a valid URL."
            case .notAPDF: return "That URL didn't return a PDF file."
            case .http(let code): return "Download failed (server responded with HTTP \(code))."
            }
        }
    }

    /// Downloads whatever's at `urlString` and adds it the same way a locally-picked file would be
    /// — reuses `addFiles(_:toGroup:)` entirely (same copy-into-the-connected-folder, same
    /// notes-file creation, same PDF-title extraction) by downloading to a throwaway temp file
    /// first and handing that off as the "source" to copy from. Verifies the response is actually
    /// a PDF (`%PDF` magic bytes) before doing anything with it — a paywall/login-redirect page
    /// often still returns HTTP 200 with HTML, not the file you asked for.
    func downloadAndAddPaper(from urlString: String, toGroup group: LibraryGroup?) async throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            throw DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.starts(with: [0x25, 0x50, 0x44, 0x46]) else { // "%PDF"
            throw DownloadError.notAPDF
        }

        var filename = Self.suggestedFilename(from: http, fallbackURL: url)
        if !filename.lowercased().hasSuffix(".pdf") { filename += ".pdf" }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let tempPDFURL = scratchDir.appendingPathComponent(filename)
        try data.write(to: tempPDFURL)

        try addFiles([tempPDFURL], toGroup: group)
    }

    /// Prefers the filename the server itself supplied via `Content-Disposition` (common for
    /// paper-hosting/CDN links whose URL path is just an opaque ID, e.g. academia.edu/cloudfront
    /// links) over the URL's own last path component.
    private static func suggestedFilename(from response: HTTPURLResponse, fallbackURL: URL) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filename(fromContentDisposition: disposition) {
            return name
        }
        let lastComponent = fallbackURL.lastPathComponent
        return lastComponent.isEmpty ? "Downloaded Paper" : lastComponent
    }

    private static func filename(fromContentDisposition header: String) -> String? {
        let parts = header.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for part in parts where part.lowercased().hasPrefix("filename*=") {
            let value = String(part.dropFirst("filename*=".count))
            let stripped = value.replacingOccurrences(of: "UTF-8''", with: "")
            if let decoded = stripped.removingPercentEncoding {
                return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        for part in parts where part.lowercased().hasPrefix("filename=") {
            let value = String(part.dropFirst("filename=".count))
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// "Add all papers in a folder at once": recursively finds every PDF under `sourceFolder` and
    /// copies each one in — the source folder's own subfolder structure isn't preserved, they all
    /// land flat in the destination.
    @discardableResult
    func addFolder(_ sourceFolder: URL, toGroup group: LibraryGroup? = nil) throws -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourceFolder, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "Maziar", code: 72, userInfo: [NSLocalizedDescriptionKey: "Couldn't read \(sourceFolder.path)."])
        }
        var pdfURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "pdf" {
            pdfURLs.append(url)
        }
        try addFiles(pdfURLs, toGroup: group)
        return pdfURLs.count
    }

    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        repeat {
            candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(ext)
            suffix += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    func update(_ entry: LibraryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
    }

    /// `deleteFiles` also moves every one of the paper's physical copies to the Trash (not just
    /// untracking it) — the Remove button on the Library page asks first, same as removing a
    /// project.
    func remove(_ entry: LibraryEntry, deleteFile: Bool) {
        if deleteFile {
            for url in locationURLs(for: entry) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        entries.removeAll { $0.id == entry.id }
    }

    /// Reconciles a paper's group memberships (and root presence) to match exactly what's passed
    /// in — copies the file into any newly-added group's folder (from whichever copy already
    /// exists), and removes the copy for any group taken away. Guarantees at least one location
    /// survives: if the requested state would leave zero, the root copy is kept regardless, so a
    /// paper can never be silently orphaned by unchecking every group.
    func setGroups(for entry: LibraryEntry, groupIDs desiredGroupIDs: Set<UUID>, alsoRoot desiredRoot: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var working = entries[index]
        let keepRoot = desiredRoot || (desiredGroupIDs.isEmpty && working.rootFileName == nil && working.groupFileNames.isEmpty)

        // Additions first, so there's always a source copy to copy from.
        for groupID in desiredGroupIDs where working.groupFileNames[groupID] == nil {
            guard let sourceURL = primaryURL(for: working), let dir = directoryURL(for: group(groupID)) else { continue }
            let dest = uniqueURL(in: dir, name: sourceURL.lastPathComponent)
            if (try? FileManager.default.copyItem(at: sourceURL, to: dest)) != nil {
                working.groupFileNames[groupID] = dest.lastPathComponent
            }
        }
        if keepRoot, working.rootFileName == nil, let sourceURL = primaryURL(for: working), let folderURL {
            let dest = uniqueURL(in: folderURL, name: sourceURL.lastPathComponent)
            if (try? FileManager.default.copyItem(at: sourceURL, to: dest)) != nil {
                working.rootFileName = dest.lastPathComponent
            }
        }

        // Removals.
        for groupID in Array(working.groupFileNames.keys) where !desiredGroupIDs.contains(groupID) {
            if let fileName = working.groupFileNames[groupID], let dir = directoryURL(for: group(groupID)) {
                try? FileManager.default.trashItem(at: dir.appendingPathComponent(fileName), resultingItemURL: nil)
            }
            working.groupFileNames[groupID] = nil
        }
        if !keepRoot, let rootFileName = working.rootFileName, let folderURL {
            try? FileManager.default.trashItem(at: folderURL.appendingPathComponent(rootFileName), resultingItemURL: nil)
            working.rootFileName = nil
        }

        entries[index] = working
    }

    // -- groups ---------------------------------------------------------------

    private static func sanitizedFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Group" : cleaned
    }

    private func uniqueFolderURL(in parent: URL, name: String) -> URL {
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        var suffix = 2
        repeat {
            candidate = parent.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Creates a new Group — and, at the same moment, its backing subfolder in storage.
    @discardableResult
    func createGroup(
        name: String, iconSystemName: String = "folder.fill", iconColorHex: String? = nil, customIconData: Data? = nil,
        info: String = "", keywords: [String] = [], links: [String] = []
    ) throws -> LibraryGroup {
        guard let folderURL else {
            throw NSError(domain: "Maziar", code: 73, userInfo: [NSLocalizedDescriptionKey: "Connect a library folder first."])
        }
        let dest = uniqueFolderURL(in: folderURL, name: Self.sanitizedFolderName(name))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let group = LibraryGroup(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? dest.lastPathComponent : name,
            folderName: dest.lastPathComponent,
            iconSystemName: iconSystemName,
            iconColorHex: iconColorHex,
            customIconData: customIconData,
            info: info,
            keywords: keywords,
            links: links
        )
        groups.append(group)
        return group
    }

    /// Renaming a group renames its folder on disk too, so the two never drift apart.
    func renameGroup(_ group: LibraryGroup, to newName: String) throws {
        guard let index = groups.firstIndex(where: { $0.id == group.id }), let folderURL else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oldURL = folderURL.appendingPathComponent(group.folderName, isDirectory: true)
        let newURL = uniqueFolderURL(in: folderURL, name: Self.sanitizedFolderName(trimmed))
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        groups[index].name = trimmed
        groups[index].folderName = newURL.lastPathComponent
    }

    /// Every visual/descriptive part of a group is editable after creation, same as before — icon,
    /// color, image, name (via `renameGroup`), plus the hover-tooltip info/keywords/links.
    func updateGroupAppearance(
        _ group: LibraryGroup, iconSystemName: String, iconColorHex: String?, customIconData: Data?,
        info: String, keywords: [String], links: [String]
    ) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].iconSystemName = iconSystemName
        groups[index].iconColorHex = iconColorHex
        groups[index].customIconData = customIconData
        groups[index].info = info
        groups[index].keywords = keywords
        groups[index].links = links
    }

    /// `deleteFiles`: trash the whole subfolder (its copy of every paper in it goes with it —
    /// papers that are *also* in another group or the root are unaffected there). Otherwise, any
    /// paper whose *only* copy was in this group has that copy moved up to the library root first,
    /// so nothing tracked disappears just because its group did; a paper with another copy
    /// elsewhere just loses this one (the other copy already preserves it).
    func deleteGroup(_ group: LibraryGroup, deleteFiles: Bool) {
        guard let folderURL else { return }
        let groupURL = folderURL.appendingPathComponent(group.folderName, isDirectory: true)
        if !deleteFiles {
            for index in entries.indices {
                guard let fileName = entries[index].groupFileNames[group.id] else { continue }
                let remainingLocations = (entries[index].rootFileName != nil ? 1 : 0) + entries[index].groupFileNames.count - 1
                if remainingLocations == 0 {
                    let source = groupURL.appendingPathComponent(fileName)
                    let dest = uniqueURL(in: folderURL, name: fileName)
                    if (try? FileManager.default.moveItem(at: source, to: dest)) != nil {
                        entries[index].rootFileName = dest.lastPathComponent
                    }
                }
                entries[index].groupFileNames[group.id] = nil
            }
        } else {
            for index in entries.indices {
                entries[index].groupFileNames[group.id] = nil
            }
        }
        try? FileManager.default.trashItem(at: groupURL, resultingItemURL: nil)
        entries.removeAll { $0.rootFileName == nil && $0.groupFileNames.isEmpty }
        groups.removeAll { $0.id == group.id }
    }
}
