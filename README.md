<p align="center">
  <img src="Sources/Maziar/Resources/Logo.png" alt="Maziar logo" width="360">
</p>

# Maziar

A native macOS LaTeX editor modeled on Overleaf: a projects list screen and a
project screen with a file tree, code editor, and live PDF preview.

Maziar organizes and manages your paper submissions end to end: pick the
conference or journal, write the paper, submit it, then rewrite through
rebuttal rounds until it's ready for the conference.

Built with SwiftUI + Swift Package Manager (no Xcode project needed).

## Features

- **Branding** (`AppBranding.swift`) — the logo (`Sources/Maziar/Resources/Logo.png`,
  bundled as an SPM resource) appears in the header of every top-level page
  (Projects/Conferences/Journals) and Settings, as a low-opacity watermark
  behind the Projects page, and in Settings → About and the native "About
  Maziar" menu panel (hooked via `.commands { CommandGroup(replacing: .appInfo) }`
  so it shows the logo + description instead of the generic default). The
  `.app` icon itself (`Resources/AppIcon.icns`, generated once via `sips` +
  `iconutil` from the source PNG padded to a square canvas, then bundled by
  `build_app.sh`) uses the same artwork. Default accent color
  (`AppSettings.ThemeRegion.buttonColor`) is a turquoise matching the logo's
  palette rather than the earlier green — still fully overridable in
  Settings → Appearance.
- **Text selection everywhere** — `.textSelection(.enabled)` is applied once
  at the top of `ContentView`/`SettingsView` rather than tagged onto
  individual `Text` views one by one; SwiftUI cascades it to every plain
  `Text` in the subtree (titles, deadlines, labels — TextField/TextEditor
  were already selectable on their own), so titles and info across the app
  are copyable without a per-view sweep.
- **Top-level navigation** (`Views/ContentView.swift`, `AppState.swift`) — a
  persistent left icon rail (Projects / Editor / Conferences / Journals) at
  the dashboard level, switching `AppState.section`. It's hidden once a
  project is open — the editor still takes the whole window, unchanged.
  **Projects** (`AppSection.papers` — the case name is unchanged internally,
  only the label moved from "Papers" to "Projects") is the default first
  section; **Editor** is the original Projects list screen, relabeled to
  stop the two from being confused for the same thing (same screen, same
  `.projects` case) — see below.
- **Projects** (`Views/PapersView.swift`, `Views/PaperDetailView.swift`,
  `PaperModels.swift`, `PaperStore.swift`, left rail) — the hub for a paper's
  whole lifecycle from picking a venue through rebuttal. The list page has
  the same low-opacity logo watermark as the Editor's Projects list, a
  divider between cards, and each section on a project's own page has a
  visible border (`SectionCard`'s `.overlay(RoundedRectangle...stroke(...))`)
  so the page reads as distinct sections rather than one long scroll:
  - **New Project** creates the tracking entry and, in the same sheet, can
    add a LaTeX project too via **Add LaTeX Project** — the exact same menu
    as the Editor page's own "New Project" button (Blank, Templates, Import
    zip/Word/Markdown/GitHub/Overleaf, "Browse for Existing Folder...", plus
    "Choose from Editor's Recents" to pick one already sitting in the Editor's
    list without browsing again) — shared as one component,
    `Views/ProjectCreationMenu.swift`, so both places stay in sync by
    construction rather than by two copies of the same menu drifting apart.
    Whichever way a project is created/imported/picked, it goes through the
    same `ProjectStore` calls, so it shows up in the Editor's recents list
    either way. A project not yet linked shows this same "Add LaTeX Project"
    menu on its own page too; once linked, that's replaced by "Open in
    Editor" — and creating/attaching a project from a project's own page
    opens it in the editor immediately, since the point of adding one is to
    start writing. This view doesn't re-implement LaTeX editing itself, it
    orchestrates around the existing editor. Once linked, **Download Zip...**
    / **Download PDF...** (same `ProjectStore.exportZip`/`exportPDF` the
    Editor's list uses) are right there too, plus **Replace Project** (pick
    a different one via the same menu) and **Remove** (unlinks only — never
    deletes the project's files, since that's a destructive action a button
    on a tracking page shouldn't casually trigger).
  - Conference/journal name, linked to a tracked `ConferenceEntry` by name
    when there's a match (auto-shows its next deadline in red, bold, with a
    small pulsing dot next to it — `BlinkingDot`, an ever-repeating opacity
    animation, no `Timer` — since the most important date on the page
    shouldn't blend in), otherwise a free-text name with an independent
    deadline field.
  - A task checklist (add/tick done/remove).
  - **Reviewer comments & rebuttal**: papers usually have several reviewers,
    so comments are kept as separate, editable, removable cards (one per
    reviewer, each with its own label and text — `ReviewerComment` in
    `PaperModels.swift`) rather than one undifferentiated text blob. Click
    "Organize & Draft Rebuttal" and all non-empty reviewers' comments (each
    tagged with its label) go to AI along with the linked project's LaTeX
    source; it groups concerns by reviewer and drafts a rebuttal point for
    each, referencing the paper's own content where it already answers a
    concern (`PaperRebuttalService.swift`). The per-reviewer filtering/
    formatting logic is covered by a standalone headless test.
  - **Decision**: Poster & Slides and Code Page are hidden until a decision
    is recorded — they only make sense once a paper's actually accepted
    somewhere (`PaperDecision` in `PaperModels.swift`: pending/accepted/
    rejected). **Accept** shows a congratulations banner and reveals both
    sections. **Reject** instead offers "Get AI Suggestions for Improving
    the Paper" — sends the linked paper plus any reviewer comments to AI,
    which reviews it and suggests concrete strengthening points for
    resubmission (`PaperImprovementService.swift`, distinct from the
    rebuttal service above: framed around improvement, not responding to
    reviewers). Either outcome has an "Undo" back to pending. On the
    Projects list, a small dot to the left of each title
    (`BlinkingDot.swift`, shared with the deadline indicator above) shows
    green normally, turns red once the next deadline is within 24 hours (or
    already past), and disappears once a paper's marked rejected — nothing
    left to race against at that point. Verified with a standalone headless
    test of the color-selection thresholds.
  - **Poster & Slides**: a "Generate using" provider + model picker sits
    above the generate buttons — same override pattern as Conferences'
    "Update Using" (`AISettings.deckProvider`/`deckModel`,
    `effectiveDeckProvider`/`effectiveDeckModel()`), defaulting to "Same as
    AI Assistant" but swappable per-feature since a provider good at chat
    isn't necessarily good at "restructure this paper into slide bullets as
    JSON." "Generate Poster (.pptx)" / "Generate Slides (.pptx)" then have
    AI restructure the paper into slide/poster sections
    (`PaperDeckService.swift`, JSON via `JSONExtraction`), then
    `PPTXBuilder.swift` hand-writes real OOXML into a `.pptx` (no library —
    `[Content_Types].xml`, relationships, slide master/layout/theme, and
    per-slide XML, zipped with `/usr/bin/zip`). A poster is one large
    custom-canvas slide (default 48×36in, the same way academic posters are
    normally authored directly in PowerPoint) with sections laid out in a
    grid; slides are a normal 16:9 multi-slide deck. **Verified for real**:
    generated output was round-tripped through `python-pptx` (all XML parts
    parse, all text — including `&`/`<`/`>`/quotes — decodes back correctly,
    every shape's position/size is within the slide bounds), not just
    assumed correct from writing the XML.
  - **Code page**: a GitHub repo URL field, its own "Generate using"
    provider + model picker (`AISettings.codePageProvider`/`codePageModel`),
    and "Generate Project Page (.html)" — a small self-contained static HTML
    page (title, conference, description, a link to the repo). The
    description paragraph is now AI-written from the linked paper's content
    (`ProjectPageContentService.swift`) rather than mechanically extracted —
    if the chosen provider isn't configured or the request fails, it falls
    back to the paper's own `\begin{abstract}` non-fatally (a soft warning,
    not a blocked generation) rather than requiring an API key for a feature
    that used to work fully offline.
  - **Model version pickers**: every per-feature model field (Poster &
    Slides, Code Page — Conferences' predates this) is a `ModelPickerField`:
    a plain editable text field plus a small chevron menu of known versions
    for the selected provider (`AIProviderKind.knownModelVersions`), so
    "pick a version" is a list, not blind typing — while staying editable
    for whatever new model a provider ships next that isn't on the list yet.
  - None of the AI-driven pieces here (rebuttal drafting, deck content, the
    Code Page description) have been run against a live API key — the OOXML
    packaging is verified independently of that, but the actual AI output
    quality isn't.
- **Editor / Projects list** (`Views/ProjectListView.swift`) — recent local
  projects, search, Overleaf-style sidebar with an affiliation card, and a
  "New Project" menu: Blank Project, Import (zip / Word / Markdown via
  `pandoc` / GitHub repo via `git clone`), Templates (Article/Report/Beamer/CV),
  Example Project. Right-click a project for **Download as Zip...** or
  **Download PDF...** (the latter needs at least one successful compile —
  `ProjectStore.exportZip`/`exportPDF`).
- **Project editor** (`Views/ProjectEditorView.swift`) — file tree sidebar
  (create/rename/delete files & folders via context menu or the "+" menu,
  delete moves to Trash not permanent), LaTeX-aware text editor with syntax
  highlighting (colors customizable per role in Settings), spell-check, PDF
  preview pane with zoom controls (Cmd+/Cmd-/Cmd+0), compile log, autosave.
  Selecting an image or PDF asset in the tree shows a read-only preview
  (`Views/AssetPreviewViews.swift`) instead of trying to open it as text.
  A **Download PDF** toolbar button saves the current in-memory compiled
  PDF (`vm.pdfData`, so it's always the latest, not whatever's on disk) via
  a save panel; the file sidebar shows the logo at the bottom.
- **File History** (clock icon in the editor header) — every save is
  snapshotted (deduped, capped at 100/file) outside the project folder so it
  never pollutes your own git history (`FileHistoryManager.swift`); browse
  and restore a previous version of the current file.
- **Undo/Redo** (toolbar buttons, `EditorUndoController.swift`) — visible
  buttons work regardless of which pane has focus (Cmd+Z alone only reaches
  the text view when it's first responder), and cover typed edits, AI-applied
  fixes, and Dynamic PDF edits alike, since all three now go through
  `shouldChangeText`/`didChangeText` instead of a bare `textView.string =`
  assignment (which silently bypasses NSTextView's undo manager). Switching
  files clears the undo stack (`CodeEditorView` tracks a `fileID`) — the
  same `NSTextView` is reused across files, so without this, undoing after
  switching files could revert the wrong file's content.
- **Find** (Cmd+F) — a find bar appears over whichever pane you last clicked
  into: the editor (plain text search, native find-indicator flash) or the
  PDF (`PDFDocument.findString`, jumps + highlights matches). Focus is
  tracked via `FocusTrackingTextView`/`FocusTrackingPDFView`
  (`SearchControllers.swift`, `Views/FindBarView.swift`).
- **SyncTeX (Cmd+Click)** (`SyncTeXService.swift`) — Cmd+Click a line in the
  editor to jump the PDF to that spot (forward search); Cmd+Click text in the
  PDF to jump the editor there, switching files if the target is in a
  different one (inverse search). Wraps the `synctex` CLI (installed
  alongside pdflatex/latexmk — TinyTeX needs `tlmgr install synctex`
  explicitly, MacTeX includes it); compiles run with `-synctex=1`. The
  TeX-native (top-left, Y-down) vs. PDFKit-native (bottom-left, Y-up)
  coordinate flip was verified against a real compiled PDF, but the actual
  click UX hasn't been visually verified (no GUI access in the environment
  that built this) — worth a real click-test.
- **Dynamic PDF editing** (`LaTeXElementFinder.swift`, `DynamicEditController.swift`,
  "Dynamic" toolbar toggle) — click an image, figure, or table in the PDF
  (routed through SyncTeX inverse search + regex source scanning) to get a
  HUD with:
  - **Resize** (images) — rewrites `\includegraphics[width=...]`, adding a
    `width=` option if none existed.
  - **Nudge placement** (floats) — cycles the `[htbp]`-style placement
    specifier, or swaps the float's line block with the adjacent
    paragraph/block above or below (an approximation of "earlier/later in
    the flow" — LaTeX floats have no literal position to move).
  - **Wrap Text** (either) — converts the element to a `wrapfigure` (left or
    right), so paragraph text flows around it and reserves its space,
    instead of the element breaking out into its own full-width block or
    (Free Position, below) floating over text with no space reserved at
    all. **Once wrapped, the element is also draggable**: dropping it picks
    a new side from which half of the page it landed in, and relocates the
    `wrapfigure` block to just before whichever paragraph a fresh SyncTeX
    lookup resolves the drop point to — it stays a real `wrapfigure`
    throughout the drag, so text keeps wrapping around it rather than
    switching to the overlay behavior Free Position uses. "Flip Side" and
    "Remove" once applied (removal converts back to a plain `figure`, not
    back to whatever it was before, so captions/labels survive).
  - **Enable Free Position** (either) — wraps the element in an
    absolutely-positioned `textblock*` (adding `textpos` to the *main*
    file's preamble specifically, even if the element lives in an
    `\input`-ed sub-file — `\usepackage` is only legal in the true preamble,
    which was a real bug caught by actually compiling the mutated output).
    Once converted, dragging the element in the PDF commits a new position
    on mouse-up and recompiles. **This is a genuinely different mechanism
    from Wrap Text, not a fancier version of it**: `textblock*` is an
    absolute overlay — it has no awareness of surrounding text, so nothing
    reflows around it and no space is reserved for it. Standard LaTeX has
    no third option that's simultaneously freely-draggable *and*
    text-reflowing; wrapfigure only offers left/right + vertical position
    in the document flow, which is what its own drag (above) moves.

  All mutation paths (resize, placement-cycle, block-move, text-wrap +
  wrap-drag-relocate, free-position wrap+drag) were unit-tested against
  this repo's own real multi-file project content, and the riskier
  conversions were verified by actually compiling the mutated output
  end-to-end — which caught two real bugs no amount of reading the code
  would have: `\usepackage` landing in a sub-file instead of the true
  preamble, and a naive block-relocation once landing mid-`align`, corrupting
  a matrix. Both are fixed and now covered by a real `latexmk` compile in
  the test, not just unit assertions. What *isn't* verified is the live
  click/drag feel in the running
  app (no GUI access here).

  This is deliberately not full free-form WYSIWYG — LaTeX floats don't have
  literal coordinates, so "drag anywhere" only becomes real once an element
  is converted to absolute positioning; until then, placement is nudged via
  the hints LaTeX actually supports.
- **Compiler** (`SystemLaTeXCompiler.swift`) — shells out to `latexmk`
  (falling back to two `pdflatex` passes) from a local TeX distribution.
  Missing packages (common with TinyTeX's minimal set) are detected from the
  log and installed automatically via `tlmgr`, then compilation retries —
  same idea as the official `tinytex` R package's auto-install.
- **AI Assistant** (`Views/AIAssistantPanelView.swift`, sparkles button in
  the project editor toolbar) — a chat panel (logo watermarked faintly in
  its background) that sees the current file and the latest compile error,
  for explaining/fixing LaTeX errors and general questions. When it proposes
  a full rewritten file (fenced ` ```latex `
  block), an "Apply to Editor" button on that message writes it into the
  open file. Supports OpenAI, Claude, Gemini, DeepSeek, and Kimi — configure
  API keys/models per provider in Settings → AI (`AISettings.swift`,
  `AIClient.swift`); keys live in the Keychain. The three request formats
  (OpenAI-compatible for OpenAI/DeepSeek/Kimi, Anthropic Messages, Gemini
  generateContent) are built to each provider's documented API, and base
  URLs are editable per-provider in case a default has moved. **Found via a
  real API key, not just code review**: `sendOpenAICompatible` used to send
  a hardcoded `"temperature": 0.3` — newer "reasoning" models like GPT-5
  reject any non-default temperature via Chat Completions ("Only the
  default (1) value is supported", HTTP 400). Fixed by not sending
  `temperature` at all rather than trying to track which model names do or
  don't accept a custom value. **Also found live**: requests were timing out
  ("The request timed out") on slower/search-augmented responses because
  `URLRequest` defaults to a 60s timeout — bumped to 150s across all three
  provider paths (`aiRequestTimeout` in `AIClient.swift`).
  - **Usage & Cost** (Settings → AI → each provider → "Usage & Cost") — every
    `AIClient.send` call (chat, prompt tasks, conference lookups — all of
    them, tracked centrally at the network layer) records prompt/completion
    tokens into `TokenUsageStore`, a persisted per-provider running total.
    Each provider section shows tokens used and an estimated cost, computed
    from an editable $/1M-tokens input/output rate (seeded with rough
    defaults). These defaults are **not fetched live and will drift** —
    they're a starting point to edit to match your actual plan, not
    authoritative pricing; a "Reset Usage" button clears a provider's
    counter. Cost math is covered by a standalone headless test.
  - **Prompt tasks** (Settings → AI → Prompt Tasks) — save a reusable prompt
    under a short label, then trigger it in the chat by typing `#label`
    (e.g. `#typo`). Anything typed after the label is appended to the saved
    prompt as extra instructions. A task can optionally set "Include PDF
    pages," which renders the compiled PDF's pages to PNGs
    (`PDFPage.thumbnail`, capped at 8 pages / 1400px) and attaches them as
    image content parts (OpenAI `image_url`, Anthropic `image`/base64,
    Gemini `inline_data`) — for questions the LaTeX source alone can't
    answer, like whether text inside a figure overflows. The chat transcript
    always shows what you actually typed (`#typo`, not the expanded prompt);
    only the API request carries the expansion. Three tasks are seeded by
    default: `#typo` (spelling/typos in the prose), `#imgtext` (vision —
    checks figures/images in the compiled PDF for overflowing or cut-off
    text), and `#bibcheck` (cross-checks every `\cite{}` key against the
    `.bib` file for missing or incomplete entries, and flags unused
    entries). Logic in `AISettings.expandPromptTask` is covered by a
    standalone headless test (case-insensitive match, unknown-label
    passthrough, extra-instructions appending) — the vision path itself
    can't be verified without a live API key.
- **Settings** (`Views/SettingsView.swift`, Cmd+,) — tabbed (Appearance /
  LaTeX Compiler / AI), resizable window.
  - Appearance: light/dark/system, independent background colors per UI
    region, independent editor syntax-highlighting colors.
  - LaTeX Compiler: choose TinyTeX or MacTeX; if the chosen one isn't
    installed, a button installs it with a live log. TinyTeX runs its
    official install script directly. MacTeX is trickier — Homebrew's own
    `brew install --cask` calls `sudo` internally, which fails with no TTY,
    and simply wrapping the whole `brew install` in an admin-privileged
    shell doesn't work either (confirmed empirically: Homebrew refuses to
    run as root). So it's a two-step process instead: `brew fetch --cask`
    unprivileged (no root needed), then only the final `installer -pkg`
    step is elevated via a native macOS authorization dialog.
  - AI: see below.
  - Conferences: add/remove tracked conference names — see below.
  - Journals: add/remove tracked journal names — same shape as Conferences,
    see below.
- **Sharing / collaboration** (`Views/ShareSheetView.swift`, "Share" button
  in the project editor toolbar) — see below.
- **Conferences** (`Views/ConferencesView.swift`, left rail) — see below.
- **Journals** (`Views/JournalsView.swift`, left rail) — a full mirror of
  the Conferences page/feature set (own model, store, AI lookup, chat,
  export, Settings tab), with prompts and field labels adjusted for how
  journals actually work: rolling submission by default, `deadlines` holds
  any dated special-issue windows the AI finds rather than one fixed
  annual date, and `rank` covers whatever ranking/impact metric the
  journal is known by (JCR/Scimago quartile, impact factor, or a
  CORE/CCF-style letter some journals also carry). See below.
- **Library** (`LibraryStore.swift`, `Views/LibraryView.swift`, left rail) —
  a Mendeley-style personal collection of papers you've read/collected
  (distinct from **Projects**, which tracks papers *you're* writing and
  submitting). See below.

## Conferences

Add a conference by name in Settings → Conferences, then, on the Conferences
page (left rail), click **Update** on its card. That sends a lookup request
to whichever AI provider is active in Settings → AI, asking it to find the
conference's official site and report back:

- Submission deadline(s) for this year and next year (the "next deadline" is
  shown first, in bold; further upcoming ones and clearly-undated ones like
  "TBA" below it; past deadlines are tucked into a collapsible section)
- A link to its author/submission guide (opens in your browser)
- A link to its official LaTeX template (a **Use LaTeX Template** button —
  confirms before downloading, then creates a new project from it: a `.zip`
  URL is downloaded and extracted the same way as manual zip import, anything
  else is treated as a git URL and cloned the same way as GitHub import)
- Its page limit, single/double-column format, and ranking (CORE/CCF-style
  letters or a journal quartile), all free text since these vary in how
  they're phrased — page limit/format show as small badges lower on the
  card; rank gets its own small badge card (`RankBadgeCard`) directly under
  the **Update** button, since a ranking is often the first thing worth
  glancing at
- An **Open Website** button (whichever of next/this year's site is set)

Each card also has a border so the list reads as distinct entries, and a
**short name + optional full name** (Settings → Conferences — e.g. "CVPR" /
"IEEE/CVF Conference on Computer Vision and Pattern Recognition") — the full
name disambiguates the acronym for the AI lookup and shows in small text
under the short name on the card.

**Status lights**: a green pulsing dot appears next to a conference's name
whenever some tracked paper on the Projects page targets it, has a LaTeX
project actually attached, and hasn't been decided yet — it disappears once
that paper is accepted or rejected (`ConferencesView.hasActiveSubmission`,
shared `BlinkingDot`). Verified with a standalone headless test of the
matching logic (case-insensitive name match, project-required, decided
papers excluded).

**Sorting**: My Order (manual — the persisted array order, reorder with the
chevron up/down buttons) / Deadline (soonest next deadline first) / Rank
(best rank first, unranked last). Reorder buttons only show in My Order,
since dragging a card in a computed sort would silently reorder the
*underlying* manual list rather than the two cards you're actually looking
at. Rank matching (`ConferenceEntry.rankSortPriority`) uses word-boundary
regex, not substring `contains` — a naive substring check would misfire on
a scheme name like "CCF B" matching the embedded "C" in "CCF" before ever
reaching the real "B", found and fixed via a headless test that runs the
check several times (dictionary/regex ordering isn't guaranteed, so a
one-shot pass could pass by luck).

**Quick navigation & export** (top of the Conferences page): a **Jump to
Conference** menu scrolls straight to any card (`ScrollViewReader`), and an
**Export / Import** menu saves the whole tracked list as either a
pretty-printed JSON file (every field, for feeding into another app) or a
formatted PDF table (`ConferenceExportService.swift` — builds an HTML
table, same escaping approach as the Code Page generator, then renders it
via `WKWebView.createPDF`, which paginates automatically across pages the
way Safari's own "Export as PDF" does — verified the HTML/JSON generation
with headless tests, but couldn't click-test the actual PDF render in this
sandbox since it has no screen access). The same menu's **Import JSON...**
reads a file in that exported shape back in
(`ConferenceExportService.importJSON`, `ConferenceStore.importEntries`) —
matches existing entries by name (case-insensitive) so re-importing the
same file twice is safe, appends anything new. Meant mainly for a fresh
install/new Mac: import a previously exported list instead of re-adding
and re-looking-up every conference by hand — the button is also on the
empty state for exactly that reason. The Journals page has the identical
menu (`JournalExportService.importJSON`, `JournalStore.importEntries`).

**Reordering**: chevron up/down buttons on each conference's card (and in
Settings → Conferences) swap it with its neighbor — array order is the
persisted, displayed order (`ConferenceStore.moveUp`/`moveDown`). Reorder
buttons only show when what's on screen is actually that manual order —
they're hidden under a sort mode or an active search filter, since the
visually-adjacent card in either case isn't necessarily adjacent in the
underlying array `moveUp`/`moveDown` swaps against.

**Search**: a search box next to the jump-to menu filters the visible list
by name or full name, live, without touching the underlying order — clear
it with the × button to see everything again.

**AI Chat** (`ConferenceChatViewModel.swift`, `Views/ConferenceChatPanelView.swift`,
toggleable side panel via the header's "AI Chat" button, same pattern as
the editor's AI Assistant toggle) — free-form Q&A about the tracked list:
every message includes a compact summary of all tracked conferences (name,
rank, next deadline) as context, so questions like "which of mine has the
closest deadline?" work directly, and general conference questions get
web-searched where the provider supports it. It doesn't attempt to have the
model edit the tracked list itself (fragile tool-calling for questionable
gain) — instead, typing `update <name>` or `refresh <name>` is matched in
Swift against the tracked list and hands off to the exact same
`ConferenceInfoService` flow the **Update** button already uses, so "chat to
trigger an update" is a real action, not a simulated one. Both the command
matching (case-insensitive, ignores plain questions, rejects unknown names)
and the search filter are covered by standalone headless tests.

**Discovering conferences to track**, two ways, both landing in the same
picker sheet (checkboxes, all selected by default, add just the ones you
want) — Settings → Conferences:
- **Import from a listing website**: paste a URL for a page that lists many
  conferences (e.g. `https://www.thecvf.com`) and click **Find Conferences**.
  `WebPageFetcher.fetchLinks` scrapes every `<a href>` on the page
  (regex-based, not a full DOM parser — won't see JS-rendered links), then
  `ConferenceListImportService` asks AI to pick out which links are actual
  conferences (filtering nav/social/contact links) and their URL. The last
  URL you used is remembered (`@AppStorage`).
- **Suggest by keyword**: type a research area (e.g. "computer vision,
  medical imaging") and `ConferenceKeywordSuggestionService` asks AI to
  suggest well-known relevant venues, skipping anything already tracked.
- Both services share JSON-extraction logic (`JSONExtraction.swift`: strips
  an optional ` ```json ` fence, falls back to grabbing the first balanced
  `[...]`/`{...}` span) and a common `ConferenceCandidate` model.

**Helper websites** (Settings → Conferences → "Helper Websites", seeded with
WikiCFP/CORE rankings/DBLP): general reference sites — not a specific
conference's own page — that get named in the lookup prompt as suggested
search starting points on every Update, alongside (not instead of) the
conference's own site. Deliberately *named*, not fetched: an aggregator's
homepage doesn't show one conference's specific info, so fetching it the
way `WebPageFetcher` fetches a conference's own site would just waste a
request — better to point a web-search-capable provider (Claude, Gemini) at
where to look. Providers without search still see the list in the prompt
but can't act on it, since they have no way to actually browse anywhere.

**HTTP-only sites**: `NSAppTransportSecurity`/`NSAllowsArbitraryLoads` is set
in the built `Info.plist` (`build_app.sh`) — without it, macOS blocks plain
`http://` fetches outright before even attempting the connection, which is
what broke a real user-supplied `http://` listing URL whose `https://` also
turned out to have a self-signed certificate (confirmed with `curl`, not
guessed) and so couldn't be used either way.

**Known website URLs (faster, more reliable)**: in Settings → Conferences,
each tracked conference has optional "Website (this year)" / "Website (next
year)" fields. When set, `WebPageFetcher.swift` fetches those pages directly
(regex-based tag stripping, not a full HTML parser — good enough to hand the
model readable text) and puts the content straight into the prompt, so the
model reads the deadlines off the real page instead of relying on its own
(slower, sometimes-timing-out) search tool. If both years' pages are fetched
successfully, live web search is skipped entirely for that update; if only
one is set (or a fetch fails), search stays on to fill the gap.

**Live web search**: Claude and Gemini both expose a server-side web-search
tool (`web_search_20250305` / `google_search`) that Maziar enables
automatically for this lookup (`ConferenceInfoService.swift`,
`AIClient.swift`'s `webSearch` parameter) — the provider does its own
searching and folds the results into its answer, no extra API needed on our
end. OpenAI only supports this via specific "search-preview" chat-completions
models, so it's passed through best-effort (`web_search_options`) — if your
configured OpenAI model doesn't support it, the API returns a normal,
readable error rather than crashing. DeepSeek and Kimi have no known
equivalent, so an update on those providers falls back to the model's own
training-data knowledge, which can be stale for future-year deadlines.

The model is asked to respond with a single strict JSON object (deadlines +
links + notes); `ConferenceInfoService.parseJSON` strips an optional
` ```json ` fence before decoding, and if that still doesn't parse (a model
adding prose around the JSON without fencing it — the most common real-world
failure), falls back to grabbing the first balanced `{...}` span in the
reply. Deadline bucketing (next / upcoming / past / undated) and JSON parsing
(plain, fenced, and prose-wrapped) are all covered by a standalone headless
test — the actual live lookups can't be verified without real API keys.

**Import from a listing website** (Settings → Conferences → "Import From a
Listing Website") — for a page that lists many conferences rather than being
one (e.g. `https://www.thecvf.com`), enter its URL and click **Find
Conferences**. `WebPageFetcher.fetchLinks` scrapes every `<a href>` on the
page (regex-based, not a full DOM parser — works for typical static listing
pages, not ones that render their links via JavaScript), then
`ConferenceListImportService` hands the whole link list to the AI and asks
it to pick out which links are actual individual conferences (filtering out
nav/social/contact links) and their name + URL. Results open in a picker
sheet — everything's checked by default, uncheck anything you don't want,
then **Add N Conferences** adds them all at once, seeding each one's "this
year" website from the discovered link so its next Update can fetch that
page directly instead of searching. Both the link-scraping regex (including
relative-URL resolution and icon-only-link filtering) and the JSON-array
response parsing (plain and prose-wrapped) are covered by a standalone
headless test; the actual AI extraction quality on a real page like
thecvf.com can't be verified without a live API key.

If an update still fails, the error on that conference's card is selectable
and has a one-click copy button (`CopyableErrorView` in
`Views/ConferencesView.swift`) — copy it and it'll say exactly what went
wrong (missing API key, a bad model name, an HTTP error from the provider,
or "couldn't parse as JSON" with a preview of the raw reply).

**Per-feature provider/model override** (Settings → Conferences → "Update
Using") — if your AI Assistant's usual provider/model doesn't handle this
lookup well, point Conference updates at a different provider and/or model
string without changing what the chat panel uses
(`AISettings.conferenceProvider`/`conferenceModel`,
`AIClient.send(...modelOverride:)`). Defaults to "Same as AI Assistant";
reuses whichever API key is already configured for the chosen provider.

## Journals

The Journals page (`Views/JournalsView.swift`, left rail) is a parallel
implementation of everything Conferences does — own model (`JournalEntry`
in `JournalModels.swift`), own persisted store (`JournalStore.swift`), own
AI lookup service (`JournalInfoService.swift`), listing-website import
(`JournalListImportService.swift`), keyword suggestions
(`JournalKeywordSuggestionService.swift`), JSON/PDF export
(`JournalExportService.swift`, sharing the `WKWebView`-based `PDFRenderer`
now factored out into its own file so both features use one copy), AI chat
panel with the same `update <name>` command (`JournalChatViewModel.swift` /
`Views/JournalChatPanelView.swift`), and its own Settings tab
(`JournalsSettingsTab` in `Views/SettingsView.swift`) — add/reorder tracked
journals, import from a listing page, suggest by keyword, manage helper
websites, per-feature provider/model override.

The two features share the page layout (borders around every card, sort
modes, jump menu, search box, rank badge) and the same underlying
`JournalEntry` shape as `ConferenceEntry`, but the AI prompt and field
framing are adjusted for how journals actually work rather than reusing
conference wording as-is:

- Journals are rolling-submission, not fixed-deadline — `JournalEntry` has
  no `deadlines` at all (unlike `ConferenceEntry`). In its place, Update
  fetches `reviewTime` (typical time to a first decision, e.g. "~8-12
  weeks") and `publicationTime` (typical time from acceptance to
  publication, e.g. "~2-3 months") — these plus `rank` are what actually
  distinguish one journal from another the way a deadline distinguishes
  conferences, and both the AI prompt and the sort modes are built around
  them instead. **Sort** on the Journals page is My Order / Rank / Review
  Speed (fastest first) rather than Conferences' My Order / Deadline /
  Rank — `reviewSpeedSortWeeks` in `JournalModels.swift` does a best-effort
  regex extraction of the first number+unit in `reviewTime`'s free text
  (converting days/months to weeks) so it can sort on it at all; a journal
  with no parseable estimate sorts last rather than being excluded.
- `rank` covers whatever ranking/impact metric a journal is known by (a
  JCR/Scimago quartile like "Q1", an impact factor like "IF 5.2", or a
  CORE/CCF-style letter some journals also carry) instead of assuming a
  CORE/CCF-only scale.
- Default helper websites are journal-oriented (Scimago, JCR, DOAJ) rather
  than the conference-oriented defaults (WikiCFP, CORE, DBLP).

Tracked journals aren't currently linked from the Projects page the way
conferences are (no active-submission indicator light) — `Paper` only
carries `conferenceName` today, not a journal equivalent, so that
cross-linking would need a model change beyond this page; noted here as a
known gap rather than built speculatively.

**Settings deep-link** — each page's own "Setting" button (and the
"Open Settings"/"Open AI Settings" buttons inside its empty state and chat
panel) opens the Settings window directly on that page's own tab rather
than always landing on Appearance, via a shared `AppState.settingsTab`
(`SettingsTab` enum in `AppState.swift`) that `SettingsView`'s `TabView`
binds its selection to — set the tab, then call `openSettings()`.

## Library

A Mendeley-style personal reference library (`LibraryStore.swift`,
`LibraryModels.swift`, `LibraryMetadataService.swift`, `Views/LibraryView.swift`) —
papers you've collected/read, each with title/authors/year/venue/DOI/first-author's-institution/tags/notes,
backed by a plain folder of PDFs rather than a database Maziar owns.

**No Google Drive API integration, deliberately.** The brief was "connect
Google Drive for backup, upload new files there, always update from what's
there" — implemented via **Google Drive for Desktop** instead of OAuth:
once that's installed, your Drive is already a real folder on disk
(`~/Library/CloudStorage/GoogleDrive-.../My Drive/...`), so "connect" is
just picking a folder inside it (`LibraryStore.suggestedDriveRoots()`
detects `GoogleDrive-*` accounts there and offers them as shortcuts in the
connect sheet), and "create a folder for backup" is just `NSOpenPanel`'s
own built-in "New Folder" button (`canCreateDirectories = true`) — no
custom UI needed for either. This avoids the same category of dead-end
this session already hit once with SwiftLaTeX's WASM engine (see
"Why not the in-app WASM engine?" below) — a direct Drive API integration
would need a Google Cloud OAuth client only the user can set up, for a
feature Drive's own desktop app already solves for free. The connect/
change/disconnect folder controls (plus the detected-Drive-account
shortcuts) live both inline on the Library page's own "Folder" menu and in
a dedicated **Settings → Library** tab (`LibrarySettingsTab` in
`SettingsView.swift`) — same "Setting" deep-link button as every other
page, and the same underlying `LibraryStore.connect`/`disconnect` either
way, just two entry points to it.

**"Upload new files"** — the **Add Paper…** button copies a chosen PDF
straight into the connected folder; once it's sitting inside a
Drive-synced directory, Google's own app pushes it up like any other new
file there. **"Always update from there"** — since there's no live push
notification without the Drive API, `LibraryStore.scan()` just re-lists
the folder: on the page appearing, every 20s while it's open
(`Timer.publish`), and via a manual Refresh button. Any PDF not already
tracked becomes a new stub entry (titled from its filename); any tracked
entry whose file has disappeared is flagged missing rather than
silently dropped (`isFileMissing`), so a Drive sync hiccup doesn't
destroy notes/tags you'd already written for it.

**Extract Info with AI** (per-entry, in its expanded card) — pulls the
first page's text via PDFKit (`PDFDocument`/`PDFPage.string`) and asks
the AI Assistant's current provider to pull out title/authors/year/venue/
DOI as JSON (`LibraryMetadataService.swift`, same `JSONExtraction`
fenced/prose-wrapped-JSON handling as every other AI-JSON consumer in the
app). Deliberately reuses the AI Assistant's own provider/model rather
than adding a fourth per-feature override (Conferences/Journals/Deck/Code
Page already each have one) — extracting fields from a page of plain text
doesn't need the web-search grounding those lookups do, so a dedicated
override would be one more Settings row for no real benefit.

Verified with a standalone headless test (`LibraryStore` compiled and run
outside the full app, real temp-directory filesystem, no mocking):
connecting a folder correctly picks up pre-existing PDFs and ignores
non-PDFs, `scan()` picks up a file added externally to the folder and is
idempotent when nothing's changed, `addFiles()` really copies into the
connected folder and handles a filename collision (`"MyDownload.pdf"` →
`"MyDownload 2.pdf"`), edits made via `update()` persist, and
`remove(deleteFile: true)` both untracks the entry and moves the real
file to the Trash. (Caught one real bug writing this test: the first
version deadlocked using a `DispatchSemaphore` to block on an `async`
`@MainActor` test function from a plain `main.swift` — that pattern
can't work in a bare CLI binary with no run loop pumping Main Actor work;
fixed by switching to a `@main struct { static func main() async }`
entry point, which Swift's concurrency runtime sets up correctly.) Not
exercised: an actual Google Drive for Desktop sync round-trip (needs a
real Drive account), and the AI extraction call itself (needs a live API
key) — though the JSON-parsing path it shares with Conferences/Journals
is already covered by their own tests.

**Groups** — a Mendeley-"folders"-style way to organize papers, shown as cards
at the top of the page (`groupsRow` in `LibraryView.swift`, a `LazyHGrid`
inside a horizontal `ScrollView` — a fixed row count grows sideways instead of
endlessly down once there are more groups than fit, scrolling left/right for
the rest). Defaults to **one row**; a "Two-row group bar" toggle in
**Settings → Library → Groups** (`libraryStore.groupsTwoRowLayout`) switches
it to two rows for anyone who'd rather scroll less and see more groups at
once — off by default so the common case (a handful of groups) doesn't waste
vertical space on a mostly-empty second row. A Group **is** a real subfolder of the
library root (`LibraryGroup.folderName`), not a separate database concept —
creating one (`LibraryStore.createGroup`) makes the folder on disk at the same
time, same as the brief asked for; renaming a group renames its folder too, so
the two can't drift apart. Each card's icon is either a picked SF Symbol or a
custom image (resized to a small PNG thumbnail and stored inline in the
group's own JSON, `LibraryGroup.customIconData` — groups are few and thumbnails
are small, so this avoids managing a separate images-on-disk location).
Deleting a group asks whether to move its papers back to the library root
first or trash them along with the folder — nothing about a tracked paper
disappears just because you removed the group around it. Same "always update
from there" philosophy as the root folder: `scan()` now also walks one level
into every subfolder, so a folder created directly in Finder/Drive (not
through Maziar) is auto-adopted as a new Group on the next refresh, using its
existing folder name.

**Bulk folder import** — **Add Paper… → Add Folder…** recursively finds every
PDF under a chosen folder (any depth, source structure not preserved — they
all land flat in the destination) and copies them all into the current scope
(the library root, or the selected Group) in one action.

Verified with a second standalone headless test, same real-filesystem/no-mocking
approach: creating a group makes a real subfolder immediately; `addFiles(toGroup:)`
lands the file inside that subfolder and tags the entry with the right group;
`addFolder()` recursively found exactly the 3 PDFs in a nested fixture
directory and correctly skipped a `.txt` file; a subfolder created without
going through Maziar (simulating Finder/Drive) was correctly auto-adopted as
a new Group with one new entry on `scan()`; `renameGroup()` renamed the
actual folder and the old name no longer existed afterward; and both
`deleteGroup()` paths were checked — `deleteFiles: false` moved every
affected paper's file back to the root (verified each remaining entry's
file genuinely exists at its new location, not just that the metadata says
so), while `deleteFiles: true` removed tracking for its papers along with
the folder. (This test predates multi-group membership below, so it only
exercises the original one-group-or-root shape — the newer test covers the
rest.)

**Every part of a group is editable after creation, not just at creation** —
right-click a group's card → **Rename / Change Icon…** reopens the same
sheet used to create it (`GroupEditorSheet`), prefilled: name, icon, an
icon **color** (`ColorPicker`, stored via the same `Color.toHex()`/
`init?(hex:)` the rest of the app's custom colors already use — reused
rather than reinvented), a custom image, and the hover-tooltip **info**
(free text), **keywords** (comma-separated), and **links** (one per line).
Hovering a group's card shows all of it via SwiftUI's native `.help()`
tooltip — no custom popover state needed, and it's genuinely "on hover,"
not a click.

**A paper can belong to several groups at once** — since each group is a
real folder, that means a real *copy* of the file in each one, not a
symlink: Google Drive's sync doesn't resolve a macOS symlink into "the same
file in multiple places," it just uploads the tiny symlink file itself,
which would silently break the backup for every group but the file's actual
location. So `LibraryEntry` tracks `rootFileName` and `groupFileNames:
[UUID: String]` independently — a paper can be root-only, in one or more
groups, or both — and `LibraryStore.setGroups(for:groupIDs:alsoRoot:)`
reconciles a paper's desired membership by copying the file into any
newly-added group's folder and trashing the copy for any group taken away.
It guarantees at least one physical copy always survives: if removing a
group would leave zero locations, the root copy is created/kept regardless,
so unchecking every group can never silently delete the only copy of a
paper. Each paper's card shows which groups it's in as small colored
capsules, and its expanded view has a toggleable chip per group (plus
"Library root") to change membership on the spot — implemented with a
small custom `FlowLayout` (`Layout` protocol, macOS 13+) since the chip
count is unbounded and a plain `HStack` won't wrap.

Verified with a third headless test, same approach: putting one already-root
paper into two groups at once produced three real, independent files on
disk (root + both group folders); `entries(in:)` correctly listed that one
paper under *both* groups' filtered views and under "All Papers"; removing
it from just one group deleted only that copy and left the other two
untouched; a paper is correctly reported as *not* missing as long as any
one of its copies survives, and only reported missing once literally every
copy is gone (checked by deleting copies one at a time, not just asserting
the end state); and `deleteGroup(deleteFiles: false)` correctly
distinguishes a paper that has another surviving copy elsewhere (just drops
that one copy) from a paper whose *only* copy was in the deleted group
(rescues it to the root instead of losing it).

**A dynamic keyword strip sits under the group bar** (`Views/LibraryKeywordStrip.swift`), cycling
every 6 seconds through four categories — **Venue**, **First Author**, **Year**, **Institution** —
each shown as a continuously auto-scrolling row of chips (a looping marquee built on
`TimelineView(.animation)`: two copies of the row placed side by side, shifted left by a
wall-clock-driven offset that wraps at the measured row width, rather than the more fragile
"animate to an offset then jump back" approach — this stays perfectly in sync with no restart
logic needed). Tapping the category label on the left jumps to the next category immediately
instead of waiting out the timer. The chip values themselves come from whatever's actually in the
currently-scoped papers (`libraryDistinctValues`, `LibraryKeywordField.swift` — pure logic, no
SwiftUI, so it's headlessly testable on its own): every distinct venue, first author, year, and
institution, case-insensitively deduplicated (keeping whichever casing was seen first) and sorted
alphabetically. "First Author" is a best-effort parse of the free-text `authors` field — split on
the separators an author list commonly uses (`,` / `;` / " and " / " & ") and take whatever comes
before the first one; it's not a real name parser, just enough to group papers by their first
author. **Institution** is a new field, `LibraryEntry.affiliation` — the first author's university
or company — filled in by hand or by **Extract Info with AI**, which now also asks for it
alongside title/authors/year/venue/DOI/abstract.

**Clicking a chip filters the paper list** to just the papers matching that value
(`libraryEntries(matching:value:in:)`) — shown as a dismissable "Venue: NeurIPS ✕"-style pill next
to the search bar, same visual language as the selected-group label beside it. Clicking the same
chip again (or its ✕) clears the filter. It composes with the existing group scope and search box
rather than replacing them — the strip's own chip values are computed from whichever group is
currently selected, so switching groups (or "All Papers") updates what the strip offers,
matching what the list below it can actually show.

Verified with a headless test of the pure logic in `LibraryKeywordField.swift` (16 cases, no
SwiftUI): first-author parsing across comma/semicolon/"and"/"&" separators, a single unseparated
author, blank/nil input, and leading-whitespace trimming; distinct-value extraction correctly
dedupes case-insensitive variants ("Alice Smith" / "alice smith") while keeping the first-seen
casing, sorts alphabetically, skips entries with no value for that field, and returns an empty
list for an empty library; and matching filters correctly by venue and first author (case-
insensitively) and returns nothing for a value that doesn't exist in the data. The marquee's actual
on-screen motion, the category auto-rotation's visual cross-fade, and the click-to-filter
interaction couldn't be click-tested in this environment — no Screen Recording/Accessibility
permission here — so, same caveat as the rest of this app's UI throughout this README, that part
rests on the build succeeding and the filtering/dedup logic underneath it being verified for real.

**Notes are a real file, not app-only metadata** — every paper gets a companion `.txt` file the
moment it's added (`LibraryStore.notesFileURL`/`readNotes`/`writeNotes`, created eagerly in both
`addFiles()` and `scan()`, same base name as the PDF, same folder as its primary copy — e.g.
`Attention.pdf` -> `Attention.txt`). It's a real, independently Drive-backed-up file: editing it
outside Maziar (Finder, TextEdit, another device) is picked up on next read, not overwritten by a
stale in-app copy. `LibraryEntry.notes` still exists but only as a one-time migration fallback for
entries tracked before this existed — the first read of a legacy entry's notes materializes the
real file from it. One canonical copy per paper (next to whichever location `primaryURL` resolves
to), not duplicated into every group folder the way the PDF itself is — notes are personal
annotations, not the paper's actual content, so duplicating them would just risk silent
edit-drift between copies for no real benefit.

**Several titled notes, not one blob** (`PaperNotesDocument.swift`, `Views/PaperNotesEditor.swift`)
— the notes page/section lets you add any number of separate notes, each with its own title
(rendered bold and larger, a real visual heading) and body. They still all save into the *one*
companion `.txt` file per paper described above — `PaperNotesDocument.encode`/`decode` is the
plain-text format in between: each note is a `## Title` line followed by its body, blank-line
separated, so the raw file still reads sensibly as Markdown if opened outside Maziar (Finder Quick
Look, a text editor). A file written before this feature existed (or `LibraryEntry.notes`'
migration fallback) has no `## ` lines, so it decodes as a single untitled note rather than losing
anything. `PaperNotesEditor` is the one shared editor view used identically in both windows below,
so adding/editing/deleting a note behaves the same regardless of which one you're in.

Verified with a dedicated headless test for the encode/decode format itself: several titled notes
round-trip exactly (title and multi-line body both preserved); an empty file decodes to zero
notes; legacy freeform text with no `## ` headers migrates into one untitled note with its content
byte-for-byte intact (the exact scenario a pre-existing user's notes file would hit); a title-only
note with an empty body round-trips correctly; `encode(decode(x)) == x` for idempotency; and one
documented edge case is explicitly asserted rather than left as a silent surprise — a body line
that itself happens to start with `## ` is, by design, read back as a new note boundary on the
next load, since the format has no escaping mechanism for that.

**A newer paper's notes are a real `.ipynb` notebook instead** (`NotebookDocument.swift`,
`Views/NotebookEditorView.swift`, `Views/NotebookCellWebView.swift`) — every paper added *after*
this feature shipped gets this; papers that already had a `.txt` notes file keep that format
forever (`LibraryStore.notesFormat(for:)` decides purely from what's actually on disk — whichever
file already exists — so there's no separate flag that could drift out of sync). Each cell is a
real Jupyter markdown cell (`NotebookDocument`'s JSON codec matches enough of the real `nbformat`
4.5 shape — `cells`/`cell_type`/`id`/`source`-as-line-array/`metadata`/`nbformat_minor` — that the
file opens correctly in actual Jupyter/VS Code/Kaggle too, not just Maziar); no code execution by
design, since these are paper notes, not a coding notebook. Cell content is treated as
Markdown-with-HTML-passthrough exactly like a real Jupyter markdown cell, rendered via
`NotebookCellWebView` (a `WKWebView` bridge — needed because a cell can contain arbitrary styled
HTML, which SwiftUI's own limited Markdown rendering can't render) — so raw HTML a user pastes in
renders exactly as authored. The **Add Cell** menu includes three ready-made Kaggle/Jupyter-style
colored box templates (Title/Main Text/Subtitle — verbatim HTML+inline-CSS snippets) alongside a
blank cell. `$...$`/`$$...$$` LaTeX formulas within a cell still render to their real typeset shape
(shared `NoteContentParser`/`PaperFormulaRenderer` with the plain-notes format below), substituted
into the generated HTML as base64 `<img>` tags before handing it to the web view.

Verified with a headless test of the JSON codec (round-tripping multi-line/HTML/empty cell content
exactly, decoding a *genuinely external* minimal `.ipynb` shaped the way a real notebook tool would
produce one, and the `source`-array line-splitting convention) and of the HTML-assembly logic
(plain text and raw HTML both pass through untouched, inline/display formulas substituted with
their pre-rendered image when available and falling back to escaped raw source when not) — plus a
real-filesystem test of the format-selection rule itself: a paper with a pre-existing `.txt` stays
`.legacyText` and never gets an `.ipynb` created alongside it (content byte-for-byte untouched); a
genuinely new paper added via `addFiles()` — the actual "Add Paper…" code path, not just `scan()`'s
auto-discovery — gets `.notebook` with a real empty `.ipynb` file and no `.txt`; and both stay
correctly classified across a re-scan. The cell editor's actual on-screen rendering, the WKWebView
content, and the template-insertion UI couldn't be click-tested in this environment — no Screen
Recording/Accessibility permission here — so that part rests on the build succeeding and the
codec/format-selection logic being verified for real, same caveat as the rest of this app's UI
throughout this README.

**Note/notebook-cell text fields auto-size to content, with a configurable max** (Settings →
Library → Notes) — both `NotebookEditorView`'s cell editor and the legacy `PaperNotesEditor`'s note
body switched from `TextEditor` to `TextField(_:text:axis: .vertical)` with `.lineLimit(1...
libraryStore.notesCellMaxLines)`: it shrinks to fit one short line instead of a forced minimum
height, grows with the text up to the configured line count, then scrolls internally rather than
pushing the rest of the page down further. This also fixed standard Cmd+C/Cmd+X/Cmd+V not working
inside a note/cell — a known SwiftUI quirk where a plain `TextEditor` embedded inside a `ScrollView`
of many other editors (exactly this layout: one editor per note/cell, several on screen at once)
doesn't reliably participate in Edit-menu-command validation, so the system never routes the
keyboard shortcut through; `TextField` doesn't have that problem. Verified with a headless test of
`LibraryStore.notesCellMaxLines`'s persistence: defaults to 20 when nothing's been set, a custom
value round-trips through `UserDefaults` and is read back by a completely fresh `LibraryStore`
instance, and `reloadFromDefaults()` correctly picks up whatever's currently persisted. The actual
on-screen auto-sizing behavior and the restored copy/paste couldn't be click-tested in this
environment — no Screen Recording/Accessibility permission here — so that part rests on the build
succeeding and the persistence logic underneath it being verified for real, same caveat as the rest
of this app's UI throughout this README.

**A notebook cell's *preview* (the rendered HTML/Markdown/formula view, not the edit box above)
also auto-sizes to its actual content now, like a real JupyterLab cell** — it used to be a fixed
220px box regardless of how little the cell actually rendered, leaving a large empty gap below
short content. `NotebookCellHTMLRenderer.fullDocument` now injects a small script into every
cell's page: a `ResizeObserver` on `document.body`, plus an explicit re-check on each `<img>`'s own
`load` event (the formula/box-template images decode slightly after the page's `load` event fires,
so relying on `load` alone would measure the height just *before* they appear), posting the live
height back through a `WKScriptMessageHandler` (`NotebookCellWebView`'s `Coordinator`) that
`NotebookCellPreview` applies directly as the cell's frame height — no cap, no internal scroll per
cell, matching real JupyterLab where the *notebook* scrolls, not each cell individually.

Verified with a genuine, non-mocked headless test — a real `WKWebView` loading the actual generated
HTML (no mocking of WebKit itself) and a real `WKScriptMessageHandler` receiving the posted
messages, run to completion with an explicit `RunLoop` pump since there's no `NSApplication` event
loop in a bare command-line harness: a short one-line cell reported ~65px (well under the old fixed
220px, and using `document.body.scrollHeight` — no cap), and a deliberately tall 500px block
reported ~520px (the 500px content plus the body's own 20px total padding), confirming the
measured height genuinely tracks the actual rendered content rather than returning some fixed or
default value regardless of what's on the page. The on-screen result (whether a cell visibly
resizes as its content/images load) couldn't be click-tested in this environment — no Screen
Recording/Accessibility permission here — so that part rests on the build succeeding and this real
WKWebView measurement behavior being verified for real, same caveat as the rest of this app's UI
throughout this README.

**Two companion windows, opened as real separate OS windows** (`openWindow(id:value:)`, macOS 13+,
declared as `WindowGroup(id:for: UUID.self)` scenes in `MaziarApp.swift` so a window can look its
paper back up live from `libraryStore` by ID rather than being handed a frozen snapshot):

- **Info** (`Views/PaperInfoWindow.swift`, the card's info-circle button) — replaces the old
  inline-expand editor: title/authors/year/venue/DOI/first-author's-institution/tags, an **Abstract** field (new — also
  filled in by **Extract Info with AI**, which now pulls the abstract out of the PDF's first page
  alongside the rest), and the multi-note `PaperNotesEditor` (saved on the window's own Save
  button, same as the other fields here — unlike the Reader window below, which autosaves).
- **Reader** (`Views/PaperReaderWindow.swift`, opened by the card's "Open in Reader" button) — the
  paper's actual PDF now opens *inside* this window rather than externally in Preview, in a
  resizable split view: the PDF on the **left**, a three-way **Translator / AI Chat / Notes**
  toggle on the **right**, each mode taking the whole right pane rather than being wedged into a
  shared layout (`LibraryTranslatorService.swift` for plain paste-and-translate;
  `PaperChatViewModel.swift` for a paper-scoped chat, seeded with title/authors/abstract as
  context, same shape as the Conference/Journal chat panels; Notes is the same companion `.txt`
  file as the Info window's, full-page here instead of a small box). The two windows aren't
  live-synced against each other while both are open at once (each loads/saves the notes file
  independently) — a reasonable simplification given they're not usually open and being typed into
  simultaneously; the file on disk is always the source of truth either way.

  **A highlighter toolbar sits above the PDF** (`Views/PDFKitView.swift` bridges AppKit's
  `PDFView` into SwiftUI, since there's no native SwiftUI PDF view and `PDFView` is what actually
  supports text selection and interactive zoom): select text in the PDF, then click a color swatch
  to highlight it — swatches gray out when there's nothing selected (tracked via PDFKit's
  `.PDFViewSelectionChanged` notification, not polling). The palette is a user-managed, named list
  (`HighlightColorOption` — name + hex color, `LibraryModels.swift`), not a fixed set: **+** adds a
  new one via a small sheet (name + `ColorPicker`), right-click a swatch to rename or remove it,
  starting from three defaults ("Important" / "Question" / "Definition") so it's not empty on first
  use but isn't preloaded with "a lot of colors" either, same reasoning as the Translator's
  language list. A multi-line selection gets one highlight rectangle per visual line
  (`selection.selectionsByLine()`), not one box spanning the gap between lines — the same technique
  Preview.app's own highlighter uses. Highlighting **writes the annotated PDF straight back to the
  real file** (`PDFDocument.write(to:)`) rather than keeping annotations in some Maziar-only
  overlay — same "the file itself is the source of truth" philosophy as the rest of the Library
  feature, so a highlight survives reopening the paper and rides along with whatever backs the
  folder up (e.g. Google Drive). **Zoom in/out** buttons (also in the toolbar) adjust
  `PDFView.scaleFactor` directly once you've used them (starts on `autoScales` fit-to-width).

  Verified with a genuine, non-mocked headless test against a real compiled PDF (a multi-line
  paragraph, via `pdflatex`, not a synthetic fixture): selecting the page's text and splitting it
  with `selectionsByLine()` produced multiple line-selections as expected; one highlight annotation
  was added per line; **after writing to disk and reloading from a completely fresh
  `PDFDocument` instance** (proving it's really in the file, not an in-memory illusion), the same
  number of highlight annotations were still there with the correct color (round-tripped RGB
  components within floating-point tolerance); and a second, differently-colored highlight added
  afterward coexisted with the first rather than replacing it. The toolbar's on-screen appearance,
  the actual click-to-select-then-highlight interaction, the add/rename/remove color sheets, and
  the zoom buttons' visible effect couldn't be click-tested in this environment — no Screen
  Recording/Accessibility permission here — so that part rests on the build succeeding and the
  underlying PDFKit annotation/persistence logic being verified for real, same caveat as the rest
  of this app's UI throughout this README.

Verified with a fourth headless test focused on the notes file specifically: adding a paper
creates a genuinely empty `.txt` immediately (not conjured on first edit); `writeNotes()` writes
the real file; `readNotes()` reflects an edit made *outside* Maziar rather than returning a stale
value (written directly to the file between the two calls, not through the API); a synthetic
"legacy" entry with only the old JSON `notes` field correctly migrates into a real file on first
read; `scan()` backfills a missing notes file for a PDF that was never added through Maziar; and
confirmed a `.txt` file is never itself mistaken for a paper. The two new windows' UI (opening
correctly, the mode toggle, live chat/translation) couldn't be click-tested in this environment —
no Screen Recording/Accessibility permission here — so that part rests on the build succeeding and
the store-level logic underneath it being verified, same caveat as the rest of this app's UI
throughout this README.

**The PDF/companion columns and the window's own size are user-resizable and remembered**
(`ResizableDivider` — a plain `DragGesture`-driven divider, not `HSplitView`: SwiftUI's
`HSplitView` doesn't expose its divider position to app state at all, so there'd be no way to
persist it) via `@AppStorage`, so the next Reader window opens at the split/size you left the last
one at. **Right-clicking a selection** in the PDF also offers **Highlight** (a color submenu),
**Translate** (jumps to the Translator tab and translates the selection immediately — the same
selection can be highlighted *or* translated, not just one or the other), and **Copy as LaTeX**
(crops the selection's region from the page, via a raw `CGContext` bitmap + `CGContext.drawPDFPage`
on the page's `CGPDFPage` — `PDFPage.draw(with:to:)` was tried first and silently ignored the crop
rectangle, always rendering the *whole* page scaled into the destination regardless of any
transform applied beforehand; a headless test against a real PDF caught this before it shipped —
then sends the cropped image to a vision-capable AI model, reusing `AIClient`'s existing multimodal
support, and copies the transcribed LaTeX to the clipboard).

Getting highlighting to actually work end-to-end surfaced a genuine SwiftUI bug worth recording:
the live `PDFView` instance was held in `@State private var pdfView: PDFView?`, set via a closure
handed to `PDFKitView`'s `onViewCreated` — but a write to that `@State` from inside a closure
invoked by `NSViewRepresentable.makeNSView` (i.e. from AppKit's own view-creation callback, outside
SwiftUI's normal view-body update cycle) wasn't reliably visible afterward, not even to an
*immediate* read in the same closure, confirmed with a plain-text debug logger writing straight to
a file (NSLog output turned out to be silently redacted to `<private>` in the unified log for
custom string content, useless for this without installing a log-privacy profile). The fix:
`pdfView` now lives in a small `@StateObject`-backed reference-type holder (`PDFViewHolder:
ObservableObject`) instead of `@State` — the closure mutates the same class instance regardless of
which struct "generation" of `PaperReaderWindow` created it, with no value-type/closure-capture
ambiguity possible. Also fixed along the way: opening a Reader/Info window whose paper ID no longer
resolves (most commonly because macOS's own window-state restoration silently reopens a
`paper-reader`/`paper-info` window from a *past session* on every launch, pointing at whichever
paper was open back then) now closes the window immediately instead of leaving an empty,
confusing, toolbar-less window sitting around — which is what "highlighting doesn't do anything"
actually turned out to be for a good chunk of this debugging session, not a bug in the highlighter
at all.

**Adding papers now has three ways in** (`LibraryView.swift`'s "Add Paper…" menu): the original
**Add Files…**/**Add Folder…**, plus **Add via URL…** — paste a direct PDF link (arXiv, a
publisher, a paper-hosting/CDN link) and it's downloaded and added exactly like a locally-picked
file (`LibraryStore.downloadAndAddPaper`, verifying the response is really a PDF via its `%PDF`
magic bytes before doing anything with it — a paywall/login-redirect often still returns HTTP 200
with an HTML page, not the file you asked for). The saved filename prefers whatever the server
itself specified via `Content-Disposition` over the URL's own last path component, since
CDN/paper-hosting links are frequently just an opaque ID (verified against a real, live example
URL of exactly that shape: a cloudfront-hosted academia.edu link whose path has nothing to do with
the paper's actual name, correctly resolved to `An_overview_of_image_steganography.pdf` from the
response header).

**A new paper's title now comes from the PDF itself, not its filename** (`PDFTitleExtractor.swift`,
used by `scan()` and `addFiles()` alike, including the URL-download path above) — most academic
PDFs are named after an arXiv ID, a DOI, or whatever a browser happened to save them as, none of
which is the actual title. Tries the PDF's own embedded metadata title first (`PDFDocumentAttribute
.titleAttribute` — free, instant, no AI call), rejecting values that are obviously not a real title
(a bare ".pdf"/".docx" suffix, "Microsoft Word - ...", "untitled"); falls back to a first-page-text
heuristic (the first sufficiently long/short line near the top, skipping an arXiv watermark line or
a bare page number) when metadata is missing or implausible; falls back to the filename only if
neither yields anything usable. Verified with a headless test against real compiled PDFs covering
all three paths (a fixture with `\hypersetup{pdftitle=}` set, one without it relying purely on the
page-text heuristic, and one with no usable title anywhere genuinely falling back to the filename)
— plus the live URL-download test above independently confirmed the heuristic pulling "AN OVERVIEW
OF IMAGE STEGANOGRAPHY" out of that real paper's first page.

**"Look Up on Scholar"** (next to "Extract Info with AI" in the Info window) fills in/confirms a
paper's authors/year/venue/DOI/affiliation/abstract by searching the web — including Google
Scholar — for its title, via the currently configured AI provider (`PaperScholarLookupService.swift`).
Deliberately *not* scraping scholar.google.com directly: it has no public API, aggressively blocks
automated scraping, and doing so would violate its terms of service — instead this reuses the exact
"AI + live server-side web search" pattern already established for Conference/Journal info lookups
(`ConferenceInfoService`/`JournalInfoService`), where Claude and Gemini's own web-search tool does
the actual searching with no extra plumbing on our end, and other providers fall back to their
training-data knowledge. Needs a title to search by, so it makes the most sense run right after (or
instead of) "Extract Info with AI"/the automatic PDF-title extraction above.

**An actual Google Scholar search panel can open alongside the Library page** — a "Search
Scholar" button in the header toggles a resizable left-side panel (`Views/ScholarBrowserView.swift`,
same `ResizableDivider`-based persisted-width pattern as the Reader window's PDF/tools split,
extracted into its own shared file so both use it) with a real, live, JS-interactive
`scholar.google.com` loaded in an embedded `WKWebView` — back/forward/reload/home buttons plus a
search box that navigates straight to a Scholar query. This is a genuine browser, not a scraped
summary: you can click through to a paper, copy its title, and use **Add via URL…** or **"Look Up
on Scholar"** above with what you found, all without leaving the app. (Applies the same
reference-type-holder fix as the Reader window's `pdfView` from the start — the live `WKWebView`
instance is held in a `@StateObject`-backed `WebViewHolder` class rather than plain `@State`, since
that's exactly the pattern that silently failed to propagate writes in the highlighting bug above.)

**Every paper can copy its own BibTeX citation** (`BibTeXGenerator.swift`, pure formatting of a
paper's own tracked fields — no network call, no AI) — a "Copy BibTeX" button on each Library card,
and the generated entry is also shown live (with its own Copy button) in the Info window, right
below the Abstract. The citation key is `{FirstAuthorSurname}{Year}` (e.g. `Vaswani2017`); the
entry type is guessed as `@inproceedings` when the venue string contains a conference-sounding
keyword ("conference"/"proceedings"/"workshop"/"symposium") and `@article` otherwise — not a
perfect classifier, but the field *values* (title/author/venue/year/doi) matter far more for a
citation you're about to paste into a reference manager than getting the entry type exactly right.
Multi-author strings are split on comma, "and", and "&", handling the common "A, B, and C"
oxford-comma form without leaving a stray empty author behind.

Verified with a headless test of the pure generation logic: author-string splitting across all
three separator conventions including the oxford-comma case; cite-key generation with a normal
author+year, no author, and no year; entry-type classification for a conference-sounding venue, a
plain journal venue, and no venue at all; and the full assembled entry for both `@article` and
`@inproceedings` shapes, confirming venue correctly lands in `journal` vs. `booktitle`
respectively, and that a minimal entry (title only) never emits an empty `author =`/`year =` field
for data that isn't there. The Scholar panel's actual browsing (page rendering, navigation, the
search box) and the copy buttons' on-screen behavior couldn't be click-tested in this environment —
no Screen Recording/Accessibility permission here — so that part rests on the build succeeding and
the underlying WKWebView bridge/BibTeX logic being verified for real, same caveat as the rest of
this app's UI throughout this README.

**Translator target language is a configurable list, not free text** — the Reader window's
Translator panel used to take any typed language name; it's now a `Picker` backed by
`LibraryStore.translatorLanguages` (`["English", "Spanish", "French"]` by default), managed from
**Settings → Library → Translator Languages** (add/remove, mirroring the "Helper Websites" list
already used for Conferences/Journals). Deliberately not a long hardcoded language list — the brief
was explicitly "do not need add a lot of language, I can setup the language in setting," so the set
starts small and the user grows it to whatever they actually translate into. If a window's current
selection was since removed in Settings, it falls back to the first remaining language on appear
rather than pointing at a language that no longer exists.

**Library gets its own AI provider/model override**, added to **Settings → Library → AI Model**
(`aiSettings.libraryProvider`/`libraryModel`, `effectiveLibraryProvider`/`effectiveLibraryModel()`
in `AISettings.swift`) — the same per-feature-override pattern already used for
Conferences/Journals/Deck/Code Page, now covering all three Library AI call sites at once
(`LibraryMetadataService`'s Extract Info with AI, `LibraryTranslatorService`'s Translate, and
`PaperChatViewModel`'s per-paper chat), which previously all hardcoded the AI Assistant's own
active provider. Defaults to "Same as AI Assistant," so nothing changes for anyone who doesn't
touch the new setting.

**Notes render Markdown + LaTeX formulas to their real shape**, not raw source
(`NoteContentParser.swift`, `PaperFormulaRenderer.swift`, `Views/NoteRenderedView.swift`) — each
note in `PaperNotesEditor` now has a preview toggle (pencil/magnifying-glass button next to its
title) that swaps the plain `TextEditor` for a rendered view. `NoteContentParser.parse` splits a
note's body on `$...$` (inline) and `$$...$$` (display) — the same delimiter convention as
Markdown+MathJax/KaTeX — into plain-text and formula segments (`\$` escapes a literal dollar sign;
an unclosed `$` is left as literal text rather than swallowing the rest of the note).
`PaperFormulaRenderer` compiles each formula through the *same* `SystemLaTeXCompiler` used for full
LaTeX projects — a tiny `standalone` document (`\documentclass[preview,border=2pt]{standalone}`) is
compiled to a one-page PDF and rasterized via `PDFPage.thumbnail(of:for:)` — so a missing package on
a minimal TinyTeX install (e.g. `standalone.cls`) gets auto-installed via `tlmgr` exactly like it
would compiling a real paper; results are cached in memory by (formula, display-mode) so switching a
note in and out of preview doesn't recompile. `NoteRenderedView` renders plain-text segments as
inline Markdown (`AttributedString(markdown:)`, bold/italic/code/links) and stitches inline formula
images directly into the flowing sentence using SwiftUI's `Text + Text` concatenation (the same
mechanism behind text-with-icon labels), so an inline formula sits inline rather than breaking the
paragraph; display formulas get their own centered block. A formula still compiling shows a
`ProgressView`; one that fails to compile (e.g. unbalanced braces) shows its raw source in red
rather than silently vanishing.

Verified two ways: a headless test of `NoteContentParser` alone (8 cases — plain text, inline math,
display math, escaped `\$`, an unterminated `$` documented rather than crashing, multiple formulas
mixed with Markdown text, an empty note, and a formula-only note); and, since this Mac has a real
working MacTeX install, a *genuine end-to-end* headless test of `PaperFormulaRenderer` against the
actual `pdflatex`/`latexmk` binaries (no mocking) — an inline formula and a display formula both
compiled and rasterized to a non-empty `NSImage`, a repeat request for the same formula returned
near-instantly from cache rather than recompiling, and a deliberately malformed formula
(`\frac{1`, unbalanced braces) threw rather than producing garbage. The preview toggle's UI itself
(clicking it, the image actually appearing on screen, dark-mode legibility of formula images'
opaque white background) couldn't be click-tested in this environment — no Screen Recording/
Accessibility permission here — so that part rests on the build succeeding and the parser/renderer
logic underneath it being verified for real, same caveat as the rest of this app's UI throughout
this README.

**The Library page and Reader window each get their own color-customization section in Settings
→ Appearance** (`AppSettings.ThemeRegion`, extended with a `scope` — `.general`/`.library`/
`.reader` — used only to sort regions into the right settings section; storage/persistence is the
same `customColors` dictionary as every other custom color). Library: Header, Groups Row, Keyword
Strip, Paper List, and Paper Cards each get their own independent background, plus a Library-only
button/accent color. Reader: a PDF Background — the area behind/around the page itself (set via
`PDFView.backgroundColor`), not the page's own content, which always renders whatever the PDF
actually contains — a Panel Background (used only in Normal style, below), and a Reader-only
button/accent color. Both page-specific button colors
inherit the app-wide "Button / Accent Color" above them until explicitly overridden
(`AppSettings.libraryButtonColor()`/`readerButtonColor()` — `customColors[region] ?? color(for:
.buttonColor)`), the same "inherit unless set" pattern already used for the AI provider overrides,
so a page's buttons match the rest of the app by default rather than needing to be set everywhere
just to keep them consistent.

**The Reader window also has a "Glass" vs "Normal" chrome style** (`AppSettings.readerVisualStyle`,
a `Picker` right above the Reader color rows) — `.glass` gives the companion pane and highlight
toolbar a translucent, blurred SwiftUI `Material` background (`.regularMaterial`, the same effect
already used for the highlight-suggestion popup and the "Copy as LaTeX" status toast) instead of a
solid color, letting whatever's behind the window show through with a blur; `.normal` uses a plain
opaque background — the (possibly user-overridden) Panel Background color above. Deliberately kept
separate from the PDF's own background (`readerPDFBackground`), which the style toggle doesn't
touch — this is about the surrounding chrome, not the document itself. `AppSettings
.readerCompanionBackground()` resolves to the right `ShapeStyle` for whichever style is active,
erased to `AnyShapeStyle` since `Material` and `Color` are different concrete types.

Verified with a headless test: every new region reports the correct scope and the three scopes
exactly partition all of `ThemeRegion.allCases` with nothing double-counted or missing; with
nothing overridden, both page-specific button-color accessors equal the resolved global button
color; customizing the *global* button color flows through to both (since neither has its own
override yet); overriding *just* the Library button color stops it from following the global
color while leaving the Reader's untouched; resetting that override makes it follow the global
color again; and a background-region override genuinely persists to `UserDefaults` and is read
back correctly by a completely fresh `AppSettings` instance. A follow-up test covers the new Glass/
Normal style specifically: `readerCompanionBackground`'s scope, the reader scope now containing
exactly 3 regions (pdf background + companion background + button), `readerVisualStyle` defaulting
to `.normal` and correctly persisting a `.glass` override across a fresh `AppSettings` instance, and
a custom `readerCompanionBackground` color resolving correctly (and genuinely differing from the
pre-override default) under Normal style. The actual on-screen color changes (each section visibly
repainting, the PDF's matte background changing, the companion pane's blur under Glass style)
couldn't be click-tested in this environment — no Screen Recording/Accessibility permission here —
so that part rests on the build succeeding and the inheritance/persistence logic underneath it being
verified for real, same
caveat as the rest of this app's UI throughout this README.

**The Reader window can also remove an existing highlight/text annotation and write new free-text
directly onto the PDF**, both applying to the *real* PDF file on disk rather than app-only metadata,
consistent with the rest of the annotation system (`PDFKitView.swift`, `PaperReaderWindow.swift`).
Right-clicking directly on an existing highlight or free-text annotation (`MaziarPDFView
.annotation(at:)`, converting the click through view space into the target page's own space and
calling `PDFPage.annotation(at:)`) now prepends **Remove Highlight**/**Remove Text** — and, for
free-text specifically, **Edit Text** — to the same context menu that already offers Highlight/
Translate/Copy as LaTeX when there's a text selection instead. A new **Add Text** toggle in the
highlight toolbar puts the view into a click-to-place mode (`isAddingText`, guarded so normal text
selection is completely unaffected while it's off): the next click on the page opens a small sheet
to type the note, then creates a `PDFAnnotation(forType: .freeText)` anchored at that point (saving
with empty text is a no-op rather than leaving a blank box). Editing an existing note reuses the same
sheet; saving it back to empty text removes the annotation instead of leaving an empty one behind.
Every path — add, edit, remove — funnels through one shared `savePDF()` that writes the whole
`PDFDocument` back to the library file immediately, same as highlighting already did.

Verified with a headless test against a real `pdflatex`-compiled PDF (no mocking): add a highlight,
save, reload from a fresh `PDFDocument` instance, confirm it's present; confirm `PDFPage
.annotation(at:)` — the exact API the right-click handler relies on — finds it when queried at a
point genuinely inside its bounds; remove it, save, reload, confirm it's genuinely gone; add a
free-text annotation, save, reload, confirm its contents round-tripped; edit its contents in place,
save, reload, confirm the update stuck and it wasn't duplicated; remove it via the empty-text path,
save, reload, confirm it's gone. All 13 assertions passed. The on-screen parts — right-clicking an
annotation and seeing the new menu items, toggling Add Text and clicking to place a note, the sheet
appearing — couldn't be click-tested in this environment, no Screen Recording/Accessibility
permission here, same caveat as the rest of this app's UI throughout this README.

**The Reader window's companion pane also has References and Outline modes**, alongside Translator/
AI Chat/Notes (`PaperReferencesService.swift`, `PaperReaderWindow.swift`).

*References* extracts the paper's bibliography on demand (a "Find References" button, not
automatic) and lists each entry verbatim, one by one — plain strings, deliberately not split into
title/authors/year: a real reference list can run 50-100+ entries, and asking an AI to echo that
many back as structured multi-field JSON made the whole result far too likely to get cut off before
the closing bracket and fail to parse at all (the original design's actual failure mode in real
use). It now tries `BibliographySplitter.swift` first — a purely local, deterministic split with no
AI call, no API key, and no network at all: find the References/Bibliography heading (the *last*
match, since a paper's own table of contents can list "References" as a line too) via PDFKit's
per-page `PDFPage.string` text, then split everything after it on `[1]`/`[2]`/... numbered markers,
the dominant citation style for the CS/ML papers this app's users are most likely reading (IEEE, ACL,
ACM, arXiv). Only when that finds fewer than two entries — an unnumbered author-year bibliography, or
PDF text too garbled to find the heading — does it fall back to `PaperReferencesService
.extractReferences`, the AI-based path (now returning a plain `[String]` instead of structured
objects, for the same truncation-avoidance reason), on the document's last 20,000 characters. Each
listed reference gets its own **Download** button: `PaperReferencesService.findDownloadURL` asks the
AI (with live web search on Claude/Gemini, same as `PaperScholarLookupService`, and for the same
reason — no scraping Scholar directly) for a direct, freely-downloadable PDF link — explicitly
instructed to reject paywalled/landing-page links rather than guess — and on success feeds it
straight into the existing `LibraryStore.downloadAndAddPaper(from:toGroup:)` infrastructure, landing
in whichever group the paper being read is already in (or the library root). Each reference tracks
its own download state independently (searching → downloading → added, or a per-reference retryable
error) so one reference failing — no free copy exists, the found link turns out not to actually be a
PDF — doesn't block downloading the others.

*Outline* is unrelated to AI entirely — it walks the PDF's own embedded table of contents via
PDFKit's native `PDFDocument.outlineRoot`/`PDFOutline` (flattened into a plain `OutlineItem` tree
SwiftUI can recurse over), with a click on any entry jumping the PDF view there via `PDFView.go(to:
PDFDestination)`. This only works for PDFs whose LaTeX source used `hyperref`'s bookmark generation
(most modern papers do, but not guaranteed) — a PDF with no embedded outline shows an explanatory
placeholder instead of an empty panel.

`BibliographySplitter` in particular was verified against a *genuine end-to-end case*: a real
`\begin{thebibliography}`/`\bibitem`-based reference list compiled by real `pdflatex` (three actual
citations — Vaswani et al., Devlin et al., Brown et al.) — extracted, split, and confirmed to
produce exactly 3 entries whose text matches the real citations verbatim, each still carrying its
`[N]` marker and correctly collapsed to a single line despite the PDF's own line-wrap. Also confirmed
the heading search picks the section's *real* body heading rather than a same-looking line the
document's own `\tableofcontents` also lists (a synthetic ToC-plus-body fixture proved the *last*
match wins, not the first), that a section with a heading but only one `[N]` marker returns nothing
rather than guessing, that "Bibliography" is recognized as well as "References", and that text with
no heading at all returns an empty array rather than crashing. Separately, a real `pdflatex`-compiled
PDF using `\usepackage{hyperref}` and `\tableofcontents` confirmed `PDFDocument.outlineRoot`
genuinely reflects the document's real section/subsection structure (top-level entries matching
every `\section`, a subsection correctly nested as a child of its parent section, each entry
carrying a non-nil `PDFDestination`), that a document with no outline degrades to an empty list
rather than crashing, and that the tail-truncation helper returns exactly the requested length and
is genuinely a *suffix* of the full text, not some other slice. The AI-fallback path in
`PaperReferencesService` (now a plain `[String]` instead of structured objects) and the download-URL
lookup were checked only at the JSON-parsing level — realistic fenced-code-block-wrapped, empty-array,
and deliberately non-JSON replies decode (or correctly fail to decode) as expected — since the actual
live AI calls need real configured API keys and a paper open in a running window, and all on-screen
interaction — switching modes, clicking Find References/Download, watching the outline scroll to a
clicked section — couldn't be exercised in this environment: there's no Screen Recording/
Accessibility permission here for the click-testing, same caveat as the rest of this app's
UI throughout this README.

**Two follow-up fixes to the Outline/References modes above, both caught from real usage rather
than headless testing:**

The mode picker (Translator/AI Chat/Notes/References/Outline) switched from `.pickerStyle(.segmented)`
to `.pickerStyle(.menu)`. With only 3 modes a segmented control fit comfortably, but at 5 it doesn't
always — and a macOS segmented control that runs out of width **clips whichever segments don't fit
rather than shrinking all of them**, so a tab could become genuinely unreachable (not just visually
cramped) depending on how far the companion pane had been resized. This is exactly what made the
References tab disappear entirely for a real user while Outline (added in the same change) kept
working. A menu-style picker shows only the current mode's name plus a chevron, so it can't run out
of room no matter how many modes exist or how narrow the pane gets.

The Outline panel now highlights whichever entry corresponds to the page currently visible in the PDF
pane, in turquoise (`outlineCurrentSectionColor`, `#40E0D0`) — a "you are here" marker for a long
paper's table of contents. Tracked via the `.PDFViewPageChanged` notification PDFKit posts whenever
the visible page changes (mirroring the existing `.PDFViewSelectionChanged` observer pattern used for
text selection), filtered to the specific `PDFView` instance this window owns. The highlighted entry
is computed as the *last* item, in document order (parents before their own children), whose
destination page is at or before the current page — page-level granularity only, not exact scroll
offset within a page, which is enough to track "which section am I reading" without the extra
complexity of continuous scroll-position tracking. Verified headlessly against the same real
`hyperref`-generated PDF as the rest of the Outline feature: confirmed a subsection nested correctly
under its parent section, that every outline entry carries a usable `PDFDestination`, and that a
document with no outline at all resolves to no highlighted entry rather than crashing — the
highlight-selection logic itself (not yet re-run as a dedicated "which entry is currently highlighted"
test, since it's a straightforward reduction over already-verified data) rests on that same outline
data plus a simple page-index comparison. The two on-screen fixes themselves — the References tab
now reliably appearing in the dropdown, the turquoise highlight visibly tracking scroll position —
couldn't be click-tested in this environment, no Screen Recording/Accessibility permission here, same
caveat as the rest of this app's UI throughout this README; the picker-clipping root cause was
diagnosed from the user's own description of the symptom (the tab vanishing while a mode added in the
same change kept working) rather than something I could reproduce and confirm visually myself.

**The Reader window's companion pane also has a Videos mode**, for attaching YouTube videos (talks,
tutorials, author walkthroughs) to a paper (`YouTubeLinkParser.swift`, `YouTubeOEmbedService.swift`,
`PaperReaderWindow.swift`). Links are stored on `LibraryEntry.videoLinks` (`[String]`, always
normalized to the canonical `watch?v=` form before saving, so the same video pasted as a `youtu.be`
link, a `/shorts/` link, or a bare 11-character ID is recognized as a duplicate rather than added
twice). Add one by pasting a link into the panel's text field, or click **Search YouTube** to open
youtube.com in a new Safari window, then copy the video's URL back and paste it in. Each added video
shows its thumbnail (`img.youtube.com/vi/{id}/hqdefault.jpg`, no API key) and real title (fetched via
YouTube's public oEmbed endpoint, also no API key or signed-in account needed) rather than a bare
link; **▶** opens that video's real `youtube.com/watch` page in a new Safari window (same mechanism
as Search), and **Copy Link** (`NSPasteboard`, same copy-to-clipboard pattern as "Copy as LaTeX"
elsewhere in the Reader) grabs the URL without opening anything.

Both open via `openInNewSafariWindow(_:)`, AppleScript (`tell application "Safari" to make new
document with properties {URL:...}`) rather than `NSWorkspace.shared.open` — the latter only asks the
default browser to open a URL and leaves reuse-vs-new-window entirely up to that browser's own
settings, with no way to force an actual new window; AppleScript can. This exact approach was tried
once already and silently failed — Apple Events to another app require an
`NSAppleEventsUsageDescription` entry in Info.plist, which this ad-hoc-built app's generated bundle
didn't have, so macOS refused the request with no window opening and no visible error at all. That
key has since been added to `build_app.sh`'s Info.plist generation (`"Maziar opens links in Safari
… as a new browser window."`), so macOS now shows the normal one-time Automation permission prompt
on first use instead of silently failing.

This whole area (both Play and Search, plus a since-removed Settings → Library "Sign In to YouTube"
button) went through several iterations before landing here, each hitting a real, different
technical ceiling rather than being changed on a whim: an embedded `WKWebView` browsing sheet with a
live, Safari-style address bar worked for plain browsing but Google unconditionally blocks signing
into a Google account inside any embedded WKWebView, regardless of configuration — a deliberate
anti-phishing policy on Google's side with no client-side fix, even when the local Touch ID/Face
ID/passkey confirmation itself succeeds; a dedicated `ASWebAuthenticationSession`-based Settings
sign-in button (Apple's own API for exactly this "provider blocks embedded WebView sign-in"
situation) got sign-in itself working, but hit its *own* ceiling — Google's flow can need to open a
real second window mid-flow (an account-chooser step, a cross-device confirmation), and
`ASWebAuthenticationSession` is a sealed, single-window session with no way to handle that; a
chrome-less in-app player (`YouTubePlayerView`, a plain `WKWebView` loaded at the video's embed URL —
technically fine, since playing a public video needs no account and so was never actually blocked by
any of the above) was tried for Play specifically, then dropped once new-window Safari for *both*
Play and Search turned out to be the actually-wanted outcome, once the Info.plist gap above was found
and fixed. The embedded browsing sheet, the Settings sign-in button, and the in-app player were each
removed as they became unused, landing on the current shape: everything YouTube touches (searching,
watching, and — when needed — signing in) opens in real, new Safari windows.

**The remaining embedded browser panels present as real desktop Safari**, not WKWebView's own default
identification (`ScholarBrowserView.swift`) — even just *browsing/searching* a site inside an
embedded WKWebView (not signing in at all) can trigger a forced sign-in wall, a different failure
mode from the hard sign-in block covered above: sites can and do react to WKWebView's default,
generic-embedded-client user agent by gating ordinary browsing behind a wall too. `webView
.customUserAgent` is set to the same real Safari 17 desktop user-agent string already used for the
"Add via URL" paper download, on the shared `ScholarBrowserView` bridge underlying Scholar and Code
browsing (YouTube's own embedded browsing sheet was removed entirely, per the history above) —
presenting as a real, current browser avoids that class of false-positive wall for plain browsing.

**The Reader's companion pane also has a Code mode now**, alongside Translator/AI Chat/Notes/
References/Outline/Videos, added to the left quick-access icon column too (`GitHubLinkParser.swift`,
`Views/CodeBrowserPane.swift`, `PaperReaderWindow.swift`) — for attaching a paper's GitHub
repositories (official implementation, a reproduction, etc.). Structurally a near-twin of the Video
mode: links are stored on `LibraryEntry.codeLinks` (`[String]`, same Codable-safety fix applied as
`videoLinks` got — `codeLinks` added to the explicit `CodingKeys`/custom `init(from:)`/
`decodeIfPresent(...) ?? []`, verified with the same before/after-decode test this time built around
a `codeLinks`-shaped fixture), always normalized to the canonical `github.com/owner/repo` URL
regardless of which specific page (a file, a folder, an issue) the link pointed at (`GitHubLinkParser
.repository(from:)` reads `owner`/`repo` out of any github.com path, not just the bare repo root), so
two different deep links into the same repo are recognized as a duplicate. Add a repo by pasting any
GitHub URL (or a bare `owner/repo`) into the panel's field, or click **Browse GitHub** for the same
Safari-style embedded-browser sheet pattern as Video mode (`CodeBrowserPane.swift`, structurally a
twin of `YouTubeBrowserPane` pointed at github.com, search built as a GitHub repository search rather
than a YouTube search) with an **Add to Code List** button. Each added repo gets **View** (reopens
that same browser sheet pre-navigated to the repo, satisfying "I can see page there") and **Download
ZIP**: `GitHubLinkParser.zipDownloadURL(for:)` builds a `github.com/{owner}/{repo}/archive/HEAD.zip`
link — confirmed for real against a real public repo (`curl`, not assumed) that GitHub redirects
`HEAD.zip` to a codeload URL resolving to whatever the actual default branch is (`main`, `master`,
anything else) without Maziar ever needing to know its name — downloaded via `URLSession`, then saved
via a real `NSSavePanel` (asking where, rather than silently writing a potentially large file
somewhere in the library folder unasked).

Verified headlessly: 18 assertions covering `GitHubLinkParser` against every URL shape tested (bare
repo root, a `.git`-suffixed clone URL, a deep file-blob link, an issue link, `www.github.com`,
rejecting a github.com URL that isn't a repo at all — a profile page, GitHub's own search results
page), a bare `owner/repo` pasted with no URL, and confirming a file-blob link and an issue link into
the same repo normalize to the identical `Repository`; plus the `LibraryEntry` Codable
backward-compatibility test rebuilt around `codeLinks` specifically. All passed. The live embedded
browsing, the real ZIP download + save panel, and all on-screen interaction (the new left-column
icon, clicking View/Download ZIP) couldn't be exercised in this environment — no Screen Recording/
Accessibility permission here, same caveat as the rest of this app's UI throughout this README.

Also fixed in the same change: `LibraryEntry` had the identical Decodable fragility already caught
once this session in the `Paper` model — a plain Swift default value on a non-Optional stored
property (`var tags: [String] = []`, etc.) does **not** make that field optional to a synthesized
`Decodable` conformance; a JSON blob missing a key still throws `keyNotFound`, which would have
silently discarded every already-saved library entry the moment `videoLinks` was added, since
`LibraryStore` decodes entries with `try?`. Given a new field was being added here anyway, `LibraryEntry`
got the same fix already applied to `Paper`: an explicit `CodingKeys` and a custom `init(from:)` using
`decodeIfPresent(...) ?? default` for every field. Verified empirically before shipping, not assumed:
a standalone test round-tripped a JSON fixture built from the *old* struct shape (no `videoLinks` key
at all) through the real `LibraryEntry.self` decode — confirmed it threw under the old synthesized
behavior and decodes cleanly, with every pre-existing field intact and `videoLinks` correctly
defaulting to `[]`, under the new custom init. A second test suite covers `YouTubeLinkParser` against
every URL shape YouTube itself produces (`watch?v=`, a trailing `&t=` param, `youtu.be/`, `/embed/`,
`/shorts/`, `/live/`), a bare pasted video ID, whitespace-trimming, and confirms two different URL
shapes for the same video normalize to the same ID (the duplicate-prevention logic). All 20 assertions
across both suites passed. The AI-free parts of this feature (thumbnail/title fetching, the parser)
were tested for real; the live embedded browser, the sign-in flow actually persisting a session, and
all on-screen interaction couldn't be exercised in this environment — no Screen Recording/Accessibility
permission here, same caveat as the rest of this app's UI throughout this README.

**The companion pane also has a small icon-only quick-access column now**, alongside the mode
dropdown (`PaperReaderWindow.swift`). A narrow rail on the left edge of the companion pane holds
three small square buttons — icon only, no text — for the three most-used modes (Translator, AI
Chat, Notes), so switching to one of them is a single click instead of opening the dropdown first.
The dropdown itself is unchanged and still covers all six modes, including these three, for anyone
who prefers it or wants References/Outline/Videos. `ReaderCompanionMode` gained an `icon` property
(reusing the same SF Symbols already shown in each mode's own empty-state placeholder, so the
column's icons match what you'd see once you're actually in that mode) and the active mode's button
is tinted with the Reader's button color.

That same column is also focusable and answers the left/right arrow keys — pressing them steps
through all six modes in order (Translator → AI Chat → Notes → References → Outline → Videos,
wrapping around), without needing to click a specific icon or reopen the dropdown each time.
Deliberately scoped to just this column (`.focusable()` + `.onKeyPress` on the rail itself, not
the whole window) rather than a window-wide shortcut — a window-wide left/right arrow handler would
fight with left/right arrow moving the text cursor inside the Translator input, the chat box, Notes,
or the video-link field, which all live in the same companion pane. The tradeoff is that the arrow
keys only work while focus is actually on the rail (e.g. right after clicking one of its icons) —
switching modes via the dropdown instead moves focus there, not to the rail, so the shortcut doesn't
apply until you click back into the rail. On-screen behavior (the column's layout, the active-mode
tint, actually pressing the arrow keys) couldn't be click-tested in this environment — no Screen
Recording/Accessibility permission here, same caveat as the rest of this app's UI throughout this
README; this one rests on the build succeeding and the existing, already-verified `mode` state
machine underneath it (nothing new to test there — both additions just set the same `@State private
var mode` the dropdown already drives).

**The Reader window now shows the app's logo in two places**, matching a pattern already used
elsewhere in the app (`AppBranding.swift`'s `BrandMark`/`logo`, already used for page headers and as
a faint watermark behind the Conference/Journal/AI Assistant chat panels): the companion pane's
header now starts with a small `BrandMark(size: 28)` next to the paper's title, same as the Projects/
Conferences/Journals page headers already do; and the AI Chat panel specifically gained the same
low-opacity (`0.05`), non-interactive, `ZStack`-layered watermark logo those other chat panels
already have — the Reader's chat was simply the one chat panel in the app that hadn't gotten it yet.

**A real bug in the Glass style was found and fixed**: `AppSettings.readerCompanionBackground()`
returned an `AnyShapeStyle` so a single function could return either a `Material` (Glass) or a
`Color` (Normal) from one call site — but type-erasing a `Material` through `AnyShapeStyle` silently
defeats SwiftUI's specialized blurred/frosted rendering path for it. The erased value still satisfies
`ShapeStyle` and compiles fine, so nothing looked *broken*, but macOS was rendering it as a flat
translucent fill rather than a true `NSVisualEffectView`-backed blur — exactly "Glass doesn't look
like glass." Fixed with a new `View.readerPanelBackground(_:)` `@ViewBuilder` extension
(`PaperReaderWindow.swift`) that branches to a literal `.background(.regularMaterial)` or
`.background(Color)` call per case instead of funneling through one erased return value — each
branch's modifier now runs against a concrete type, keeping macOS on the specialized Material
rendering path. Applied at both of `readerCompanionBackground()`'s previous call sites (the
companion pane, the highlight toolbar); the old `AnyShapeStyle`-returning function stays in
`AppSettings.swift` as a still-valid general accessor, just no longer used for these two view
modifiers specifically.

**The Reader window can also have its own light/dark appearance now**, independent of the app-wide
one (`AppSettings.readerAppearanceMode`, a `Picker` next to the Glass/Normal style one in Settings →
Appearance → Reader). Reuses the existing `AppearanceMode` enum (System/Light/Dark) rather than a
near-duplicate type, with the same "inherit unless overridden" shape as the Reader's button/background
color overrides: `.system` means "just follow the app-wide appearance," any other value overrides it
specifically for the Reader window via `AppSettings.readerColorScheme()` (`readerAppearanceMode
.colorScheme ?? appearanceMode.colorScheme`), applied via `.preferredColorScheme(settings
.readerColorScheme())` on the `"paper-reader"` `WindowGroup` in `MaziarApp.swift` (previously hardcoded
to the app-wide `.preferredColorScheme(settings.appearanceMode.colorScheme)` there, same as every
other window). Verified headlessly: default is `.system` for both the new setting and its resulting
color scheme (nil, meaning "follow the OS"); with the app-wide appearance set to Dark and no Reader
override, the Reader correctly inherits Dark; setting the Reader's own override to Light while the
app-wide appearance stays Dark makes the Reader's override win; a fresh `AppSettings` instance reloads
a persisted override correctly from `UserDefaults`; and setting the Reader override back to `.system`
makes it correctly resume following the app-wide appearance again. All 7 assertions passed. The
logo placement, the Glass style's actual on-screen appearance (the fix rests on the documented
`AnyShapeStyle`/`Material` interaction being the real cause, not something I could visually confirm
myself), and the Reader window actually re-rendering in the chosen appearance couldn't be
click-tested in this environment — no Screen Recording/Accessibility permission here, same caveat as
the rest of this app's UI throughout this README.

**The quick-access icon rail is now user-configurable and no longer shows a stray focus ring.** The
rail — that's its name, the small column of square icon-only mode buttons on the left edge of the
Reader's companion pane — previously hardcoded to Translator/AI Chat/Notes/Code; it's now driven by
`AppSettings.readerQuickAccessModes` (`[ReaderCompanionMode]`, defaults to that same original set),
editable via a new Settings → Appearance → Reader → "Reader Quick-Access Icons" section listing all
seven modes as toggles — check or uncheck any combination, in any order added. `ReaderCompanionMode`
itself had to drop its `private` access level in `PaperReaderWindow.swift` so `SettingsView` could
reference it for this toggle list. Separately, the rail's `.focusable()` (added earlier for
left/right-arrow mode cycling) meant macOS drew its default system focus ring around whichever icon
was last clicked — a blue border that moved between icons as you clicked each one, on top of the
rail's own intentional flat highlight for the active mode, reported as "remove this border." Fixed
with `.focusEffectDisabled()` on both the rail container and each individual icon button — keeps the
arrow-key focusability working (that's unaffected) while suppressing just the visual ring macOS
draws for it.

Verified headlessly: the default `readerQuickAccessModes` is exactly the original four in the
original order; simulating the Settings toggle logic (append to add, `removeAll` to remove) against
a References-add/Notes-remove case produces the correct resulting list in the correct order; a fresh
`AppSettings` instance reloads a persisted custom set correctly from `UserDefaults`; and —
deliberately checking the edge case rather than assuming — emptying the rail entirely persists as a
genuinely empty list rather than silently falling back to the default on next load. All 4 assertions
passed. The Settings toggle UI itself and the focus-ring fix's actual on-screen appearance couldn't
be click-tested in this environment — no Screen Recording/Accessibility permission here, same caveat
as the rest of this app's UI throughout this README.

**Glass style now covers the whole Reader window, not just the companion pane and toolbar strip.**
The previous fix (the `AnyShapeStyle`/`Material` erasure bug) made Glass render correctly wherever it
was applied — but it was only ever applied to two relatively thin regions (the highlight toolbar, the
companion pane), leaving the single largest area of the window — the matte behind/around the actual
PDF page — always a flat, solid color no matter which style was selected, since that specific region
is painted by PDFKit itself (`PDFView.backgroundColor`, a plain `NSColor` property with no concept of
a blurred `Material`) rather than by any SwiftUI view. Reported back as "all window should get style."
Fixed in `PaperReaderWindow.swift`'s `pdfPane`: when `readerVisualStyle == .glass`, `PDFKitView` is
now given `Color.clear` for its `pageBackgroundColor` instead of the configured PDF-background color,
and the PDF's containing `ZStack` gained its own `.readerPanelBackground(settings)` — so `PDFView`
paints nothing for its own matte, letting the `.regularMaterial` now sitting directly behind it (in
the same NSView hierarchy SwiftUI manages for a `NSViewRepresentable`) show through instead. Under
Normal style this whole path is inert by construction, not just by an `if`-branch: `PDFKitView` keeps
painting its normal *opaque* configured color exactly as before, completely covering the new
background layer beneath it, so there is no visual or behavioral change to Normal style at all.

This was verified only by re-reading the render order carefully (the opaque-under-Normal, therefore
provably non-regressive argument above) and confirming the build succeeds — the actual visual result,
whether `PDFView`'s AppKit compositing genuinely lets a transparent `NSColor` reveal SwiftUI content
sitting behind it in a hosted view hierarchy, is architecturally sound and a known technique but not
something I could confirm by eye in this environment — no Screen Recording/Accessibility permission
here, same caveat as the rest of this app's UI throughout this README.

**Glass still wasn't visibly different from Normal after that fix** — reported back exactly as
predicted might happen, pointing at the flagged next suspect: `PDFView` isn't layer-backed by
default, and AppKit's default compositing for a view that only just became layer-backed can still
treat it as fully opaque regardless of what alpha the `NSColor` itself carries — silently discarding
the `Color.clear` from the previous fix rather than letting it produce real transparency. Fixed in
`PDFKitView.swift`: `backgroundColor` is now set through a new `applyBackground(_:to:)` helper that
also explicitly does `view.wantsLayer = true`, `view.layer?.isOpaque = false`, and mirrors the same
color onto `view.layer?.backgroundColor` (a `CALayer` property, separate from and not automatically
kept in sync with `PDFView.backgroundColor`, the `NSColor`-typed one) — removing the ambiguity around
whether the layer treats itself as opaque instead of leaving it to an AppKit default. Called from both
`makeNSView` and `updateNSView`, so it's reapplied correctly every time `readerVisualStyle` toggles
between Glass and Normal, not just at initial creation.

This is now the third layer of this specific fix (`AnyShapeStyle` erasure → `PDFView`'s own opaque
background → this layer-compositing adjustment), each addressing a real, distinct, defensible
mechanism — but I still have no way to visually confirm the *result* in this environment, so if Glass
still isn't visibly different after this one, the most useful next step is telling me specifically
what it looks like instead (identical to Normal, a solid gray/black instead of a blur, a visual
glitch, etc.) rather than just "still not working" — narrowing down the actual symptom would let me
diagnose the remaining gap far more precisely than guessing at a fourth mechanism blind.

**The Reader's PDF pane can now show an HTML rendering of the paper instead of the PDF** — a new
toggle button in the highlight toolbar (`doc.richtext`/`doc.richtext.fill`, next to the "Add Text"
toggle), backed by `PDFToHTMLConverter.swift` and `Views/HTMLDocumentView.swift`. This directly
answers a feasibility question asked earlier in this session about converting a PDF straight to
HTML (as opposed to compiling *LaTeX source* to HTML via LaTeXML, a different feature discussed for
the Editor and never built, since it needs the `.tex` source, which the Reader's library PDFs often
don't have at all): true PDF-to-HTML conversion is real and already possible, just not via any
Apple-native API — via `pdftohtml`, part of Homebrew's `poppler` package, which happens to already be
installed on this Mac. `PDFToHTMLConverter.convert(pdfURL:cacheKey:)` shells out to it with `-s
-noframes` (one combined HTML file per PDF, not a per-page/frame-based split that would need extra
plumbing to embed), resolving the binary from the standard Homebrew install locations
(`/opt/homebrew/bin`/`/usr/local/bin`, the same two-path check already used for `brew` itself in
`TeXInstallationManager`) rather than assuming it's on `PATH`; a clear, actionable error ("Run \"brew
install poppler\"...") surfaces inline in the Reader if it isn't found, rather than attempting an
automatic install — unlike the LaTeX toolchain, this is a secondary convenience feature, not core to
the app, so it didn't seem worth the considerably heavier auto-install UX `TeXInstallationManager`
has for TeX itself. The output is genuinely converted, not "PDF page rendered as an image with a nice
label": `pdftohtml`'s default mode extracts real, separately-positioned, selectable text as actual
HTML elements, with a background image per page used only for whatever vector art it can't express as
text (confirmed by inspecting a real converted background image before wiring this in at all — it was
nearly blank).

Toggling HTML mode doesn't unmount `PDFKitView` — the HTML view is layered on top of it in the same
`ZStack` (drawn last, so it fully covers the PDF while active) rather than swapping which view exists
in an `if`/`else` branch, so switching back to PDF doesn't lose the PDF view's own state (zoom, scroll
position). Conversion happens once per Reader window session and its result is cached in `@State`, so
toggling back and forth after the first conversion is instant. Verified with a real, non-mocked
end-to-end test: converted an actual `pdflatex`-compiled PDF via the real `pdftohtml` binary, confirmed
the resulting HTML file exists and is genuine HTML, confirmed it contains the real section-heading and
body text as text (not just an image reference), confirmed a background image is also present
alongside that text, confirmed re-converting with the same cache key reuses the same output path
rather than accumulating files, and confirmed converting a nonexistent PDF path throws a normal,
catchable error instead of crashing. All 10 assertions passed. The toolbar button itself, the visual
result of the HTML rendering, and the WKWebView correctly loading the converted file with its sibling
background images couldn't be click-tested in this environment — no Screen Recording/Accessibility
permission here, same caveat as the rest of this app's UI throughout this README; this genuinely is
labeled "experimental" in its own tooltip, since `pdftohtml`'s fidelity to complex layouts (multi-
column papers, dense math, figures) is real but not guaranteed to match the PDF closely for every
paper the way the PDF view itself always does.

**Cmd+C/Cmd+X/Cmd+V now work reliably throughout the Reader window**, reported broken everywhere in
it, not tied to one specific field or the PDF's own text selection. `MaziarApp.swift`'s `.commands`
only replaces the `.appInfo` group, leaving SwiftUI's automatic Edit-menu commands (which normally
provide Cut/Copy/Paste for free) otherwise intact — so something about *this* window's own key-event
handling was most likely interfering, plausibly the mode quick-access rail's `.focusable()` +
`.onKeyPress` pair added earlier for left/right-arrow mode cycling, which can change how a window
routes keyboard events more broadly, not just for the two arrow keys it explicitly claims. Rather
than chase that exact mechanism blind, `PaperReaderWindow.swift` gained a `editCommandBridge` — three
invisible buttons, each just a `.keyboardShortcut(_:modifiers: .command)` wired to `NSApp
.sendAction(_:to: nil, from: nil)` for the standard `copy(_:)`/`cut(_:)`/`paste(_:)` selectors. That
sends the action up the responder chain starting from whatever the *current* first responder actually
is — the same mechanism the system Edit menu itself uses — so it correctly reaches whichever text
field, or the PDF's own text selection, happens to have focus, independent of whatever was disrupting
the default path. This is an independent, additional binding, not a replacement for anything, so it's
safe even if the original default-Edit-menu path turns out to already work again for some fields.

The build succeeding confirms `NSText.copy(_:)`/`cut(_:)`/`paste(_:)` resolve as valid Objective-C
selectors for `#selector(...)`, but whether the shortcuts now genuinely work end to end — actually
pressing Cmd+C over selected PDF text or inside a field and seeing the clipboard update — couldn't be
click-tested in this environment, no Screen Recording/Accessibility permission here, same caveat as
the rest of this app's UI throughout this README.

**Highlight colors can now have their opacity set, both when adding a new one and editing an
existing one** — and this one surfaced a genuine, non-obvious PDFKit platform bug along the way,
caught by testing before it ever shipped rather than after. `HighlightColorOption.colorHex` was
already an RGBA hex string (`Color(hex:)`/`toHex()` in `AppSettings.swift` have always round-tripped
alpha, going back to whenever those helpers were first written) — so the storage layer needed no
changes at all. The gap was purely in the UI: `AddHighlightColorSheet`'s `ColorPicker` had
`supportsOpacity: false`, and the old `RenameHighlightColorSheet` only ever exposed a name field,
with no way to revisit a color's opacity — or its color at all — after creation. Fixed by flipping
`supportsOpacity` to `true` and turning the rename sheet into a proper **Edit Highlight Color** sheet
(the right-click menu item is now "Edit…") with its own opacity-capable `ColorPicker`, backed by a
new `LibraryStore.updateHighlightColor(_:name:colorHex:)` alongside the existing rename-only method.

While verifying this — rendering actual pixels before and after a real save-and-reload, not just
checking `PDFAnnotation.color.alphaComponent`, which turned out to be misleading — a real bug
surfaced: a translucent `NSColor` assigned to `PDFAnnotation.color` renders correctly translucent
*live*, immediately after highlighting, but PDF's `/C` annotation color entry has no alpha channel at
all, so the moment the file is saved to disk and reloaded, every highlight silently reverts to
full-strength opaque color — a real, confirmed data-loss bug that opacity as a feature would have
shipped with, invisible until the user actually closed and reopened a paper. Checked PDFKit's own
public header (`PDFAnnotation.h`) for a way around it: there is none — the common annotation-key list
has no supported "/CA" (PDF spec's actual constant-opacity key) entry at all, and attempting to set
one directly via `setValue(_:forAnnotationKey:)` fails outright, because PDFKit's own key namespace
already reserves the string `"/CA"` for an unrelated purpose (a widget's caption text). The real fix,
in `applyHighlight` (`PaperReaderWindow.swift`): flatten the chosen translucent color against a plain
white background — matching a typical page's own background, a different, unrelated color from the
Reader's own configurable "PDF Background" matte setting — into a new, already-blended, genuinely
*opaque* color (`blendedOpaqueColor(_:against:)`) before it's ever assigned to `annotation.color`, so
there's no alpha left for the save step to lose. Verified pixel-for-pixel with a real, non-mocked
end-to-end test: rendered a real compiled PDF's highlighted line to an actual bitmap and sampled the
literal pixel color at three points — no highlight at all (baseline white), a naively-translucent
highlight rendered *live* before saving (confirmed genuinely pale, not full-strength), and that same
annotation reloaded from a real saved file (confirmed it reverts to full-strength opaque — the bug,
caught in the act) — then did the same for the blended-color fix, confirming its reloaded-from-disk
pixel is still genuinely pale and matches the naive approach's correct live pixel almost exactly. All
assertions passed, including one the test itself caught before the fix ever reached the app: an
earlier version of the blending helper crashed on `NSColor.white`'s default (non-RGB) color space,
fixed by explicitly converting both colors via `.usingColorSpace(.deviceRGB)` first. The Settings UI
itself (dragging the opacity slider, seeing a highlight visually look paler) couldn't be click-tested
in this environment — no Screen Recording/Accessibility permission here, same caveat as the rest of
this app's UI throughout this README — but the underlying persistence bug this request surfaced, and
its fix, were both verified against real rendered pixels, not just code review.

**The highlight toolbar's background — the strip holding the highlight color circles — is now a
separately configurable region with its own, more transparent Glass material.** Previously it shared
`ThemeRegion.readerCompanionBackground` with the companion pane and the PDF pane's own matte, all
three always painted with the exact same color/material. `AppSettings.swift` gained a new
`ThemeRegion.readerToolbarBackground` case (scope `.reader`, so it automatically appears in Settings
→ Appearance → Reader's existing region list, no separate UI needed) with its own default color and
its own override storage — changing it doesn't touch the companion pane or PDF matte's colors at all.
`PaperReaderWindow.swift`'s `readerPanelBackground(_:region:material:)` extension (previously
hardcoded to always use `.readerCompanionBackground`/`.regularMaterial`) gained `region`/`material`
parameters with those exact values as defaults, so every *existing* call site is unaffected — only
the highlight toolbar's own call now explicitly passes `region: .readerToolbarBackground, material:
.ultraThinMaterial`, `.ultraThinMaterial` being SwiftUI's lightest, most see-through material (the
scale runs ultraThin → thin → regular → thick → ultraThick, most to least transparent), for a
visibly "more glass" look specifically on that strip in Glass style, distinct from the rest of the
window.

Verified headlessly: `readerToolbarBackground` has the correct `.reader` scope and shows up in the
same region list Settings already iterates (now 4 reader regions instead of 3); confirmed it's a
genuinely distinct case from `readerCompanionBackground`, not an alias; overriding the toolbar
background's color leaves the companion background's color completely unaffected; and a fresh
`AppSettings` instance reloads a persisted toolbar-background override correctly from `UserDefaults`.
All 6 assertions passed. The actual on-screen appearance — the toolbar visibly having its own color
in Normal style, and looking more transparent than the rest of the window in Glass style — couldn't
be click-tested in this environment, no Screen Recording/Accessibility permission here, same caveat
as the rest of this app's UI throughout this README.

## Diagrams

A new top-level page (`Views/DiagramsView.swift`, `AppSection.diagrams` — a sixth entry in the outer
sidebar alongside Projects/Editor/Conferences/Journals/Library) embedding
[diagrams.net](https://app.diagrams.net) (draw.io) directly in the app, for making flowcharts and
diagrams without leaving Maziar. Reuses the exact `ScholarBrowserView`/`WebViewHolder` bridge already
used for the Library page's Scholar panel and the Reader's Code mode — a plain back/forward/reload/
home toolbar plus an "Open in Safari" button (for the rare case something needs the real browser)
above the embedded page itself. Diagram editing works fully without signing into anything —
diagrams.net defaults to local, on-device storage with no account required — so unlike the YouTube/
Google sign-in situations elsewhere in this app, a plain embedded `WKWebView` is genuinely sufficient
here; there's no equivalent "embedded sign-in gets blocked" wall to design around for the core use
case. Adding this new `AppSection` case required no other code changes beyond the sidebar/switch
wiring itself — `AppState.section` is plain in-memory `@Published` state with no
`Codable`/persistence involved, so none of the backward-compatibility handling other model changes in
this README needed applies here.

A **Light/Dark** segmented toggle sits at the top of the page's own toolbar, right where the rest of
the toolbar lives — genuinely switching diagrams.net's own theme, not a filter or overlay layered on
top from Maziar's side. It works through diagrams.net's own real, documented `?dark=1`/`?dark=0` URL
parameter (confirmed against drawio.com's own "Supported URL parameters" reference, and against the
live server with a real `curl` request returning 200 for both, before wiring this up — not guessed);
toggling it reloads the embedded page at the new URL. The choice persists across launches via
`@AppStorage`. Verified headlessly: the light/dark URLs build to exactly the documented `?dark=0`/
`?dark=1` forms, the host is preserved correctly, and the two URLs are genuinely distinct so toggling
actually changes what loads — all 4 assertions passed, on top of the live 200-response check against
the real diagrams.net server. This is a thin, low-risk integration overall (an embedded page plus one
URL-parameter toggle, not custom logic) — build succeeded and the parameter is confirmed real and
live, but the page actually loading and the toggle visibly switching the editor's theme couldn't be
click-tested in this environment, no Screen Recording/Accessibility permission here, same caveat as
the rest of this app's UI throughout this README.

**Settings → Custom Pages generalizes Diagrams into a feature the user can extend themselves** —
add any URL as its own page/sidebar entry, without needing a hand-built view like `DiagramsView` per
site. New model `CustomWebPage` (`id`, `name`, `urlString`, `showInSidebar`) persisted as
`AppSettings.customPages` (JSON-encoded array under the `"maziar."`-prefixed key convention, so it's
automatically included in the existing export/import backup feature — that reads/writes every
`"maziar."`-prefixed `UserDefaults` key generically, no per-setting code needed there). A new
`CustomWebPageView.swift` is the same back/forward/reload/home-toolbar-plus-embedded-`ScholarBrowserView`
shape as `DiagramsView`, just parameterized by name/URL instead of hardcoded to diagrams.net.

Since `AppSection` is a fixed `CaseIterable` enum, it can't grow a case per custom page — `AppState`
instead gained a separate `selectedCustomPageID: UUID?`, non-nil exactly when a custom page (not a
built-in section) is the active sidebar selection; clicking any built-in section clears it back to
nil. The outer sidebar (`ContentView.swift`) renders the fixed section buttons as before, then —
below a divider, only if any exist — one button per custom page with `showInSidebar == true`; each
opens as `CustomWebPageView(page: page).id(page.id)`, the explicit `.id()` forcing a fresh view (and
so a fresh `WKWebView` loaded at the *new* page's URL) whenever the selected custom page actually
changes, rather than SwiftUI potentially reusing the old view's identity and its embedded browser's
already-loaded page.

New Settings → **Custom Pages** tab (`CustomPagesSettingsTab`): a name + URL field to add one —
`CustomWebPage.normalizedURLString(_:)` accepts a bare domain like `excalidraw.com` and assumes
`https://`, same convention as the Library's "Add via URL" flow — and a list of existing pages, each
with a **Show in Sidebar** switch (hide without deleting — the page stays defined and can be turned
back on) and a **Remove** button (deletes it outright). Verified headlessly: URL normalization across
a bare domain, an already-schemed URL, `http://` specifically (not just `https://`), and three
rejection cases (whitespace-only, empty, and unparseable garbage text); adding two pages, confirming
each is independent (hiding one doesn't affect the other's visibility or a fresh page's own default of
visible); a fresh `AppSettings` instance reloading both persisted pages with their correct hidden
state and URL intact; and removing one page leaving exactly the correct other page behind. All 18
assertions passed. The sidebar actually showing/hiding entries as pages are added, hidden, and
removed, and each embedded page loading its real target URL, couldn't be click-tested in this
environment — no Screen Recording/Accessibility permission here, same caveat as the rest of this
app's UI throughout this README.

**Custom pages can now have their own icon and color, and built-in pages can be hidden from the
sidebar too.** `CustomWebPage` gained `iconSystemName` (default `"globe"`) and `iconColorHex`
(hex-encoded the same way every other custom color in the app is, via `Color.toHex()`/`init?(hex:)`;
nil means "use the sidebar's normal selected/unselected coloring," the same inheritance pattern as
`LibraryGroup.iconColorHex`) — and, since this model may already have real persisted pages from
before this change, it got the same Codable-safety treatment as `LibraryEntry`/`Paper` applied
*before* shipping this time rather than as a follow-up fix: explicit `CodingKeys` and a custom
`init(from:)` with `decodeIfPresent(...) ?? default`, verified with a before/after decode test built
around a pre-icon-fields JSON fixture. `CustomWebPage.suggestedIcons` is a curated list of ~30 SF
Symbols (documents, charts, media, dev tools, communication, etc.) offered in a new `IconPickerButton`
— a small button showing the current icon that opens a popover grid to pick from, used both when
adding a page and when editing an existing one's icon inline in its row, each paired with a
`ColorPicker` for the icon's color. In the sidebar (`ContentView.swift`), a custom page's own color —
when set — is treated as its permanent identity color and shown whether or not that page is currently
selected, with the existing background-highlight pill still separately indicating "this is the active
page," rather than the color competing with the selected/unselected state the built-in sections use.

Separately, `AppSettings.hiddenSections: Set<AppSection>` lets any *built-in* page (Projects, Editor,
Conferences, Journals, Library, Diagrams) be hidden from the sidebar the same "hide without deleting"
way `CustomWebPage.showInSidebar` already worked for custom ones — just inverted, since built-in
sections always exist and can't be "removed" outright the way a custom page can. Both the icon-picker
Settings tab additions and this new section live together in the same **Custom Pages** tab, per how
the feature was asked for. Verified headlessly: the pre-existing Codable-compatibility test for the
new icon fields (above); adding a page with a specific icon/color and confirming both are stored;
editing an existing page's icon alone leaves its color untouched and vice versa; a fresh `AppSettings`
instance reloading a persisted icon/color edit correctly; `hiddenSections` starting empty, a single
insertion/removal being reflected immediately and independently of other sections, the filtered
visible-sections list (exactly what the sidebar renders) correctly excluding a hidden one, and a fresh
`AppSettings` instance reloading a persisted hidden-section set. All 19 assertions passed. The actual
on-screen icon picker popover, color pickers, and sidebar entries appearing/disappearing as sections
are hidden couldn't be click-tested in this environment — no Screen Recording/Accessibility permission
here, same caveat as the rest of this app's UI throughout this README.

**Diagrams no longer reloads every time you navigate away and back, and now supports multiple
simultaneously-open diagram tabs.** The reload issue was reported from real usage as "every time
move between them is refresh, it should not happen." Root cause: `ContentView`'s section area was a
plain `switch`/`if` — standard SwiftUI branching content, which fully destroys whichever branch isn't
currently selected and creates a brand-new instance when you navigate back to it. For the lightweight
native pages (Papers/Projects/Conferences/Journals/Library) that's cheap and invisible; for
`DiagramsView`, it meant destroying and recreating its embedded `WKWebView` on every single visit,
forcing a full reload each time — losing whatever the user was doing in diagrams.net. Fixed in
`ContentView.swift`: Diagrams (and, for the same reason, each individual custom page) is now tracked
by a `hasActivatedDiagrams`/`activatedCustomPageIDs` "visited at least once this session" flag —
once first opened, it's rendered permanently in a `ZStack` alongside the others, just toggling
`.opacity`/`.allowsHitTesting` based on whether it's the current selection, rather than being
destroyed and recreated by the switch. The native pages are deliberately left as a plain conditional
switch, unaffected — they hold no expensive session worth keeping alive off-screen.

Multiple diagram tabs (`DiagramsView.swift`, redesigned): a `DiagramTabModel` list plus an
`activeTabID`, rendered as a small tab bar (name, a close "×", a "+" to add another) above the
embedded browser — the former single-session `DiagramsView` body became `DiagramTabContentView`, one
per tab. Same "keep mounted, toggle visibility" fix applies *within* the tab bar too: every open
tab's `DiagramTabContentView` stays permanently rendered in its own `ZStack`, hidden via opacity when
not the active tab, so switching between tabs never reloads one that's already open — directly
answering "I should can open several pages (diagrams projects) in diagrams page." The Light/Dark
appearance preference (`@AppStorage`) is shared across tabs (one remembered choice for the next tab
you open) rather than tracked per tab; closing the very last remaining tab is a no-op, so there's
always at least one tab open. Verified headlessly by mirroring the exact tab-management logic
(`addTab`/`closeTab`) in a standalone test: starts with exactly one tab named "Diagram 1"; adding
tabs appends with the correct incrementing title and makes the new tab active; closing an *inactive*
tab removes it without disturbing which tab is currently active; closing the *active* tab correctly
moves the active selection to the remaining tab; and closing the last remaining tab is confirmed to
be a genuine no-op, not just assumed. All 15 assertions passed. The actual on-screen behavior — a
diagram genuinely not reloading when you navigate back to it, the tab bar rendering and switching
correctly — couldn't be click-tested in this environment, no Screen Recording/Accessibility
permission here, same caveat as the rest of this app's UI throughout this README.

**File downloads now work inside embedded pages** — reported as "website has option for that, but I
can not do it in Maziar," referring to diagrams.net's own File → Export/Download. Root cause:
`WKWebView` doesn't support triggering a file download *at all* by default — clicking a
download link/button inside any embedded page silently does nothing unless the app explicitly opts
the response into becoming a `WKDownload` and implements `WKDownloadDelegate` to actually save it,
and `ScholarBrowserView.swift`'s `Coordinator` (the one shared bridge behind every embedded page in
the app — Scholar, Code, Diagrams, custom pages) had never implemented any of that, so this wasn't
Diagrams-specific at all; it would have silently failed on every one of them. Fixed by having
`Coordinator` also conform to `WKDownloadDelegate`: `decidePolicyFor navigationResponse` now checks
for a real `Content-Disposition: attachment` header first — the actual, standard signal a server
uses to mean "save this, don't display it" — before falling back to `canShowMIMEType`, since relying
on MIME-showability alone would misfire for exports like PNG/SVG (`WKWebView` can render those
inline, and would just navigate to them instead of downloading, even when the server explicitly
marked them as an attachment). Once a response (or a JS/anchor-triggered navigation action) becomes
a `WKDownload`, `decideDestinationUsing` prompts a real `NSSavePanel` for where to save — same "ask,
don't silently write somewhere unasked" choice as every other download already in this app
(`LibraryStore.downloadAndAddPaper`, the Reader's Code-mode "Download ZIP").

A genuine end-to-end download (driving a live `WKWebView` through a real network download and an
interactive save panel) isn't something that can be exercised headlessly in this environment, so what
was actually verified is the pure decision logic behind it, extracted and tested standalone: a
`Content-Disposition: attachment` header forces the download path even for a MIME type `WKWebView`
could render inline (a PNG export, mirroring diagrams.net's own likely case); that matching is
case-insensitive; an explicit `"inline"` disposition on a renderable type allows normal navigation;
plain HTML with no disposition header navigates normally; and a non-renderable type with no
disposition header (a `.zip`, say) still correctly falls back to downloading. All 5 assertions
passed. The actual save panel appearing and a real file landing on disk when clicking Export inside
diagrams.net couldn't be click-tested in this environment — no Screen Recording/Accessibility
permission here, same caveat as the rest of this app's UI throughout this README.

**Sign-in popups now work inside embedded pages** — reported against a custom page added for
`prism.openai.com`, which needs to sign in and hit "Sign In Failed — We couldn't open the sign-in
window. Check your popup blocker and try again." This is a *different, genuinely fixable* problem
from Google's own embedded-WebView sign-in block covered earlier in this README (that one is the
server itself refusing the credential exchange outright — no client-side fix is possible there, ever)
— this one is a missing feature, not a policy: `WKWebView` has no built-in host for a JavaScript
`window.open()` call at all. Without a `WKUIDelegate` implementing `createWebViewWith`, the call just
silently fails, and it's the *site's own script* that then shows that exact "couldn't open the
sign-in window" message in response — the app genuinely wasn't letting the popup open, matching what
was reported precisely. Fixed in `ScholarBrowserView.swift`'s `Coordinator` (the one shared bridge
behind every embedded page in the app, so this fixes popup-based sign-in everywhere, not just for
this one page): now also conforms to `WKUIDelegate`, creating a real second `WKWebView` using the
exact `configuration` WebKit hands in (required — reusing it rather than building a new one is what
makes the popup share the parent page's session/cookies, letting an OAuth-style popup flow actually
complete), hosted in a genuine separate `NSWindow` titled "Sign In." A `popupWindows` dictionary keeps
each popup's window (and its `WKWebView`) alive for as long as it's open, since nothing else in the
view hierarchy holds a strong reference to either; `webViewDidClose` (called when the popup's own
page calls `window.close()`, the normal way an OAuth popup finishes) closes the window and releases
that reference.

On saving the login so it doesn't need repeating every launch: checked rather than assumed — grepped
the whole codebase for any `.nonPersistent()`/ephemeral `websiteDataStore` usage, and there is none;
every `WKWebViewConfiguration()` in the app (Scholar, Code, Diagrams, custom pages, this popup
included) is left at its default, which is the shared, on-disk, genuinely persistent
`WKWebsiteDataStore.default()`. That means a session should already survive an app relaunch with no
extra code needed — the actual, sole blocker was that sign-in could never complete in the first place
because the popup itself couldn't open, so there was never a session to persist. Fixing the popup
should resolve both parts of the request together.

This is real AppKit window creation in direct response to a live JavaScript event from a real page —
not something with a pure-logic core that can be extracted and tested standalone the way the download
decision logic above was, and not something that can be exercised at all without a real windowed run
loop and a real popup-based sign-in flow to trigger it. The build succeeding does confirm the
`WKUIDelegate` method signatures are implemented correctly against Apple's real API (a wrong signature
simply wouldn't compile as an override), but the actual popup window appearing, sign-in completing
inside it, and the session surviving a relaunch could not be click-tested in this environment — no
Screen Recording/Accessibility permission here, same caveat as the rest of this app's UI throughout
this README.

**A real gap in that popup fix**: clicking "Continue with Google" inside the new popup window hit a
different error, "JSON Parse error: Unexpected EOF" — Google's sign-in library's own JS choking on an
empty or rejected response from its backend. The popup's `WKWebView` (created fresh in
`createWebViewWith`) had never been given the real-Safari `customUserAgent` string already applied to
the *main* embedded view — it was defaulting back to WKWebView's generic embedded-client identity, a
strong candidate for exactly this kind of "backend detects a non-standard browser and returns
something unexpected" failure. Fixed by extracting that UA string into a shared top-level constant
(`embeddedBrowserUserAgent`, `ScholarBrowserView.swift`) and applying it to every `WKWebView` this
file creates — the main view and every popup, including any nested popup a popup itself might spawn,
since they all funnel through the same `createWebViewWith` implementation. I can't be certain this is
the *complete* fix for this specific error without live network-level debugging (no way to inspect
the actual failing request in this environment), but it's a real, previously-missing piece directly in
line with the error's likely cause, not a guess unrelated to the symptom.

On using the Mac's saved passwords/Safari to help sign in: basic saved-password AutoFill for
username/password fields should already work with no code needed — `WKWebView` integrates with the
system's Keychain-backed AutoFill by default in a normal app window, and this app was never doing
anything to disable it. Passkeys (WebAuthn) are a separate, less certain story: full passkey/iCloud
Keychain integration inside a third-party embedded `WKWebView` can be gated by the hosting app's code
signing, and this app is only ad-hoc signed (`codesign --sign -` in `build_app.sh`, not a real Apple
Developer Program certificate) — whether that restricts passkey support here isn't something I could
verify or fix from code alone; it would need real developer signing/provisioning, which is outside
what changed in this session.

## Projects

The Projects page (`Views/PapersView.swift`/`PaperDetailView.swift`, model `Paper`, store
`PaperStore` — note the UI label "Projects" is unrelated to `ProjectStore`/`Views/ProjectListView
.swift`, which is the *LaTeX Editor*'s folder list) originally only ever tracked one kind of
project: a paper submission, from picking a venue through rebuttal. It now supports a second
**kind** (`ProjectKind`, `PaperModels.swift`) — **Developing**, for a software/idea project instead
— plus, for either kind, an arbitrary number of **nested sub-projects** and an **auto-created
Library group**.

**Two kinds, picked at creation** (`Views/NewProjectSheet.swift`, a segmented `Picker`, shared by
both top-level and sub-project creation so the flow is identical either way): **Paper Submission**
keeps the exact original page — LaTeX project link, venue/deadline, tasks, reviewer comments &
AI-drafted rebuttal, decision, and (once accepted) Poster/Slides generation and the Code Page.
**Developing** instead gets an **Idea** section (free-text description) and a **Links & References**
section (a GitHub repo field plus a free-text list — the same "one per entry" shape already used
for `LibraryGroup.links`) — no venue/reviewer/decision workflow, since none of that applies to a
software project. Both kinds keep the (already-generic) task checklist.

**Every project — either kind, top-level or nested — gets its own Library group**
(`LibraryStore.createGroup(name:)`, reusing the exact call already used by the Library page's own
"New Group", `try?`-wrapped so a project still gets created successfully even with no library
folder connected yet — the group is just skipped, not forced) so each project can collect its own
reference papers independently, without the papers you're reading for three different projects
piling into one undifferentiated library. The Library group's name and a "Reveal in Finder" button
live in a "Library Group" section on the project's own page; "Create Library Group" appears there
too for a project that didn't get one at creation time (no folder connected back then).

**Sub-projects can be either kind, nested arbitrarily deep** — a "Sub-Projects" section lists a
project's direct children (`PaperStore.children(of:)`, computed by filtering the flat `papers`
array on `parentID` rather than stored inline, so there's one source of truth regardless of nesting
depth) with an "Add Sub-Project" button opening the same `NewProjectSheet` used at the top level,
parented to the current project. Opening a sub-project recurses `PaperDetailView` into itself
(`selectedChild`, its own `onBack` popping back to *this* level, not all the way to the top list) —
so a "Developing" project can have a "Paper Submission" sub-project for writing it up, which could
itself have further sub-projects, and so on. The Projects page's main list only ever shows top-level
projects (`PaperStore.topLevelPapers()`); a sub-project is reachable only from inside its parent.
Deleting a project cascades to every descendant beneath it (`PaperStore.remove(_:)` walks the tree
level by level) rather than leaving orphaned sub-projects with a dangling `parentID` and no way to
reach them. Reordering (`moveUp`/`moveDown`) operates within siblings specifically, not raw adjacent
array indices — new projects are always prepended at index 0 regardless of nesting depth, so the
backing array freely interleaves top-level and nested entries, and a plain adjacent-index swap could
otherwise silently swap a top-level project past an unrelated sub-project sitting between them.

Verified with a headless test of `PaperStore`'s new hierarchy logic against a real store instance
(23 cases): kind defaults/explicit values and per-kind blank-title fallbacks ("Untitled Project" vs
"Untitled Paper"); `children(of:)`/`topLevelPapers()` correctly navigate a 3-level tree (including
returning an empty array, not nil, for a childless project); cascading delete removes a project and
every descendant beneath it while leaving unrelated projects untouched; sibling-aware reordering
correctly skips a sub-project sitting between two top-level projects in the raw array, verified by
asserting the actual resulting order rather than just "it didn't crash"; and boundary moveUp/moveDown
calls are safe no-ops.

One genuine bug this test caught before it shipped: `Paper`'s new fields (`kind`, `dateCreated`,
`ideaDescription`, `links`, `parentID`, `libraryGroupID`) all have ordinary Swift default values —
which do **not** provide a fallback for synthesized `Decodable` conformance. A missing JSON key for
a non-Optional property still throws `keyNotFound` regardless of its declared default, and
`PaperStore.loadPapers()` silently discards everything on any decode failure (`try?` returning
`[]`) — meaning every already-persisted project would have vanished the next time the app launched.
Caught by decoding a hand-written pre-this-change JSON fixture (no `kind`/`parentID`/etc. keys at
all) and confirmed it failed before the fix; `Paper` now has a custom `init(from:)` using
`decodeIfPresent(...) ?? default` for every field added after the struct's first release, verified
against that same fixture decoding successfully with the expected defaults afterward. The actual
on-screen kind picker, the sub-project drill-down navigation, and the Library-group "Reveal in
Finder" button couldn't be click-tested in this environment — no Screen Recording/Accessibility
permission here — so that part rests on the build succeeding and the store-level logic underneath
it being verified for real, same caveat as the rest of this app's UI throughout this README.

## Backup & restore

Settings → Backup — **Export Settings...** saves everything configurable in
Maziar to one file: Appearance, LaTeX Compiler options, every AI
provider/model choice (including the per-feature overrides for Conferences/
Poster & Slides/Code Page), Prompt Tasks, token pricing, Conference Helper
Websites, and your tracked Conferences and Papers. **Import Settings...**
loads one back, after a confirmation since it overwrites what's currently
there.

`AppSettingsBackupService.swift` doesn't know or care about any individual
setting's field names — every settings class in the app already persists
through `UserDefaults` with keys consistently prefixed `"maziar."`
(`maziar.ai.activeProvider`, `maziar.conferences`, `maziar.papers`, etc., a
convention that's held across the whole codebase), so export is just
"filter `UserDefaults.standard.dictionaryRepresentation()` down to that
prefix and serialize as a property list" — no parallel struct mirroring
every field that could quietly drift out of sync as new settings get added
(which, over the course of this app's development, has been often). Import
reverses that, then calls a `reloadFromDefaults()` method added to each
settings class (`AppSettings`, `AISettings`, `TeXInstallationManager`,
`ConferenceStore`, `PaperStore`) so the already-running app reflects the
restored values immediately — no restart needed. **API keys are never
included** — those live in the Keychain, not `UserDefaults`, and the export
code has no path to them at all.

Verified with a standalone headless test that round-trips every UserDefaults
value type the app actually stores (`String`, `Bool`, nested `[String:
String]`/`[String: Double]` dictionaries, `[String]` arrays, and raw `Data`
blobs like the JSON-encoded prompt-task/conference/paper lists) through the
same export-then-import path, confirming byte-for-byte restoration — not
just that the file writes without crashing.

## Sharing & collaboration

Maziar has no accounts or backend of its own, so "sharing a project" means
one of three things, each with a different tradeoff. All three are in the
Share popup (project editor toolbar → **Share**); Overleaf import is also
in the projects list under **New Project → Import → Overleaf Project**.

1. **Cloud Folder Sync (zero build)** — move the project folder into
   iCloud Drive / Dropbox / Google Drive (auto-detected on this Mac; a
   "Choose Folder..." option covers anything else). Collaborators who have
   that folder shared to them get near-real-time file sync for free, since
   Maziar just reads/writes plain folders. No live cursors or conflict UI —
   whatever the sync provider does with simultaneous edits (usually a
   "conflicted copy" file).

2. **Git Collaboration (moderate build)** — Initialize Repo / set a remote /
   Push / Pull, with a live log (`GitService.swift`). Collaborators clone the
   same remote and push their own commits, like any code project. Real
   history, mergeable diffs (it's plain text), but not simultaneous live
   editing — someone has to pull before they see your changes.

3. **Overleaf Git Bridge** — the one legitimate way to link a Maziar project
   to an actual Overleaf project. Requires an Overleaf paid plan with Git
   integration. Enter the Overleaf project ID (from the project's URL) and a
   git token (generate one at Overleaf → Account Settings → Git), then
   Link/Pull/Push. This is sync-on-demand against `git.overleaf.com/<id>`,
   **not** simultaneous live typing alongside Overleaf's own web editor —
   Overleaf doesn't expose a public real-time API for third-party clients to
   plug into that. The token is stored in the macOS Keychain
   (`KeychainHelper.swift`), never written to `.git/config` or any project
   file — it's embedded in the remote URL only for the duration of one
   push/pull, then stripped back out.

   Not tested against a live Overleaf account/token — built to Overleaf's
   documented Git Bridge behavior, but worth confirming the URL/auth format
   still matches if it doesn't work first try.

True simultaneous live co-editing (like Overleaf's own web editor) isn't
implemented — it would need a hosted CRDT/OT sync backend (e.g. Yjs +
websockets), accounts, and a rewrite of the editor to be CRDT-aware. Options
2 and 3 above were chosen instead because they need no backend to run or pay
for.

## Why not the in-app WASM engine?

An earlier version hosted the SwiftLaTeX WASM `pdfTeX` engine inside a hidden
`WKWebView` for a zero-install, fully bundled compiler. That's a legitimate
approach and the WebKit plumbing (Worker loading needs a custom
`WKURLSchemeHandler` — `loadFileURL` does not work for Worker scripts) was
validated with a headless test harness. It was dropped because the engine
fetches its base LaTeX format and any packages on demand from a
SwiftLaTeX-hosted CDN (`texlive.swiftlatex.com`), and that CDN is currently
unreachable (DNS does not resolve) — so no document, however trivial, could
compile. Self-hosting a replacement (`TeXlyre/texlive-ondemand-server`) turned
out to be a Python/Docker service with a local package cache roughly the same
size as just installing TinyTeX, so shelling out to a real local TeX
distribution won out on reliability and simplicity.

## Build & run

```bash
./build_app.sh debug   # or: ./build_app.sh release
open dist/Maziar.app
```

Or `swift build && swift run` for development.

First run: open Settings (Cmd+,) and install TinyTeX (or MacTeX) if you
haven't got a TeX distribution yet — Maziar will prompt you the moment you
try to compile without one.

## Project layout

```
Sources/Maziar/
  MaziarApp.swift              App entry point (WindowGroup + Settings scene)
  AppState.swift                Navigation (project list <-> editor)
  Models.swift                   Project + FileNode models
  ProjectStore.swift             Recents, create/open/import projects, cloud-folder move, Overleaf clone
  EditorViewModel.swift          Per-project editor state, autosave, compile orchestration
  SystemLaTeXCompiler.swift      Shells out to latexmk/pdflatex
  TeXInstallationManager.swift   Detects/installs TinyTeX or MacTeX
  GitService.swift               Thin `git` CLI wrapper (init/remote/push/pull/clone)
  KeychainHelper.swift           Generic Keychain get/set (Overleaf token, AI API keys)
  ShareViewModel.swift           State/actions behind the Share popup
  SearchControllers.swift        Editor/PDF find state + match navigation
  AppSettings.swift              Appearance mode + per-region custom colors
  AISettings.swift               Per-provider API key/model/base URL
  AIClient.swift                 Network calls for OpenAI-compatible/Anthropic/Gemini APIs
  AIAssistantViewModel.swift     Chat state, sends messages, extracts proposed file edits
  SyncTeXService.swift            Wraps the `synctex` CLI for forward/inverse search
  PDFZoomController.swift         PDF zoom state, bound to PDFView.scaleFactor
  LaTeXElementFinder.swift        Regex-based source scanning + mutation for Dynamic PDF editing
  DynamicEditController.swift     UI state for the Dynamic PDF editing HUD/drag
  FileHistoryManager.swift        Per-file save snapshots (outside the project folder) + restore
  EditorUndoController.swift      Exposes the editor's undo manager to toolbar Undo/Redo buttons
  Views/AssetPreviewViews.swift   Read-only image/PDF asset preview for the file tree
  Views/                         SwiftUI views (incl. SettingsView, ShareSheetView, FindBarView, AIAssistantPanelView)
  Resources/Templates/           Starter project templates
```
