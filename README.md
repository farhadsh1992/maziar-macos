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
