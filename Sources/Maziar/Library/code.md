# CLAUDE.md — Maziar Library

Guidance for Claude Code when working on Maziar's **Library** (the "Library" section in Maziar's left rail).
The repo-wide `CLAUDE.md` and its Maziar notes still apply; this file covers the Library only.

## What it is

A Mendeley-style personal reference library inside Maziar (SwiftUI/AppKit, Swift Package Manager, no Xcode
project): the papers you've collected and read — PDFs with title/authors/year/venue/DOI/institution, tags,
labels, groups, notes and notebooks, plus a Reader window (translator, references, outline, videos,
highlights). It is **not** `Paper` (a paper *you're writing*), which belongs to Maziar's Projects section.

## Files

In this folder:

| File | Role |
|---|---|
| `LibraryModels.swift` | `LibraryEntry`, `LibraryGroup`, `LibrarySubgroup`, label/highlight options |
| `LibraryStore.swift` | `@MainActor ObservableObject` behind everything: folder, scan, add/remove, groups, notes files, settings lists |
| `LibraryView.swift` | the Library page (group bar, keyword strip, paper cards, Scholar side pane) |
| `LibraryKeywordStrip.swift` / `LibraryKeywordField.swift` | the rotating Venue / Author / Year / Institution chips (field logic is pure, no SwiftUI) |
| `PaperReaderWindow.swift` | the Reader: a separate OS window per paper (`openWindow(id:value:)`, opened from `MaziarApp.swift`) |
| `LibraryMetadataService.swift` | "Extract Info with AI" from the first page's text |
| `LibraryTranslatorService.swift` | the Reader's Translator |
| `LibraryExportService.swift` | zip of PDF + notes + info.txt/info.json + citation.bib |

Library code that lives elsewhere (shared with other sections or older): `PaperNotesDocument.swift`,
`NotebookDocument.swift`, `NotebookCellHTMLRenderer.swift`, `PDFTitleExtractor.swift`,
`PaperScholarLookupService.swift`, `PaperReferencesService.swift`, `BibTeXGenerator.swift`,
`Views/PaperInfoWindow.swift`, `Views/PaperNotesEditor.swift`, `Views/PaperNotesWindow.swift`,
`Views/NotebookEditorView.swift`, `Views/NotebookTabsView.swift`, `Views/ScholarBrowserView.swift`,
`Views/PDFKitView.swift`, and `LibrarySettingsTab` in `Views/SettingsView.swift`.

## Design rules (keep them)

- **The folder is the model.** The library is a plain folder of PDFs the user picks — normally inside Google
  Drive for desktop (`~/Library/CloudStorage/GoogleDrive-…/My Drive/…`). There is deliberately **no Google
  Drive API**: copying a file into the folder *is* uploading; Drive's own app syncs it.
- **Groups are real subfolders.** A paper in several groups is a **real copy** in each group folder — not a
  symlink (Drive uploads the symlink itself, not the file). `rootFileName` / `groupFileNames` record each
  copy's file name. Removing a paper from its last group must never delete the only copy: it is rescued to
  the root.
- **Nothing is dropped silently.** `scan()` re-lists the folder (on appear, every 20 s, and Refresh); new PDFs
  become entries, entries whose file vanished are flagged `isFileMissing` (notes and tags are kept).
- **Notes are real files next to the PDF.** Older papers: `<Paper>.txt` (legacy, left byte-for-byte alone).
  Newer papers: a `<Paper>/` folder with one `.ipynb` notebook per tab. Don't create an `.ipynb` beside a paper
  that already uses `.txt`, and follow the migration rules in `LibraryStore` before changing either format.
- AI (metadata, translator, references) uses the AI Assistant's provider via `AISettings` unless the Library's
  own override in Settings → Library → AI Model is set. Parse model JSON with the shared `JSONExtraction`.

## Persistence and Google Drive account sync

- State is in `UserDefaults` under `maziar.library.*` (entries, groups, labels, highlight colours, translator
  languages, layout…). Maziar's Google Drive account sync (`GoogleDriveAccount`, `AppSettingsBackupService`)
  copies **every `maziar.` key to the user's other Macs** except machine-specific ones:
  `maziar.library.folderPath` (each Mac has its own path to the Drive folder) and the prefixes
  `maziar.readerWindow.`, `maziar.ai.`, `maziar.googleDrive.`, `maziar.updater.`. A new per-Mac setting must
  use one of those; a new shared one just uses `maziar.library.<name>`.
- Snapshots don't propagate deleting a key: clear a value by saving an empty one, not `removeObject`.
- Adding a field to a `Codable` model (`LibraryEntry`, `LibraryGroup`…): decode it with `decodeIfPresent` in a
  custom `init(from:)` so JSON saved by older versions still loads. A plain Swift default doesn't do that.

## UI traps already hit here

- Don't erase `Material` to `AnyShapeStyle` (the Reader's glass style lost its blur); branch with `@ViewBuilder`.
- A macOS segmented control clips segments that don't fit instead of shrinking — check narrow widths.
- The Reader window's size is remembered (`maziar.readerWindow.width/height`, per Mac); keep companion panes
  resizable.

## Build and verify

- `swift build` from `maziar/` (compile check). Runnable app: `./build_app.sh release` → `dist/Maziar.app`,
  then `pkill -x Maziar; open dist/Maziar.app --args -MaziarOpenSection library`.
- Nothing here can be click-tested from Claude Code: verification is build + launch (say so) plus headless
  tests of pure logic — compile the pure files (e.g. `LibraryKeywordField.swift`, `BibTeXGenerator.swift`,
  `LibraryStore` against a temp folder) into a small standalone test with `swiftc` and run it.
- Every rebuild is ad-hoc signed, so macOS asks for Keychain access again on first launch, and Maziar
  waits on that prompt (no window, nothing starts) until the user clicks **Always Allow**. Expect it, and tell
  the user, rather than debugging a "hung" app.
- Update the **Library** section of `maziar/README.md` when behaviour changes.
