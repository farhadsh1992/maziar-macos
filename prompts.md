# Maziar — development prompts

The prompts used to drive each development phase of Maziar, kept verbatim so the reasoning behind a
feature can be traced back to what was asked. Phases 1–9 predate this file and weren't recorded here.

---

## Phase 10 — OpenPrism editor: file management, PDF navigation and editing

Update the OpenPrism editor to improve project file management, PDF navigation, and editing:

1. Fix image uploads
   * Allow users to upload images directly into any project folder or subfolder.
   * Support drag-and-drop uploads and a file picker.
   * Show uploaded images in the project tree and make them available to LaTeX through their relative paths.
   * Display clear upload errors when an operation fails.
2. Preserve the PDF position after compilation
   * Keep the current page, scroll position, and zoom level when the PDF refreshes after compilation.
   * Avoid returning to the first page after every compilation.
   * If the document changes significantly, restore the closest valid position.
3. Add bidirectional LaTeX–PDF navigation
   * Implement SyncTeX support so users can jump from a location in the LaTeX editor to the corresponding position in the PDF.
   * Allow users to jump from the PDF back to the corresponding source file and line.
   * Open the correct source file automatically when the project contains multiple `.tex` files.
   * Highlight the destination briefly and provide clear mouse gestures or shortcuts for both directions.
4. Improve PDF zoom and movement
   * Provide smooth scrolling, responsive panning, and mouse-based zooming, similar to Overleaf.
   * Support trackpad pinch-to-zoom and Ctrl/Cmd + mouse wheel, keeping the zoom focused around the pointer.
   * Include zoom-in, zoom-out, fit-to-width, and fit-to-page controls.
   * Let users resize the editor and PDF panels by dragging the divider.
   * Preserve normal scrolling when the zoom modifier is not pressed.
5. Show LaTeX errors and warnings
   * Display compilation errors and warnings in a clear, collapsible panel.
   * Include the source filename, line number, and a readable message whenever available.
   * Clicking an error should open the relevant file and highlight the affected line.
   * Mark reported errors in the editor and keep the full compilation log accessible.
6. Add spelling and grammar checking
   * Check natural-language text while respecting LaTeX syntax.
   * Exclude commands, equations, citation keys, labels, file paths, and code blocks.
   * Underline issues and offer suggestions with options to ignore a suggestion or add a word to a dictionary.
   * Provide controls to enable or disable checking and select the document language.

Inspect the existing implementation first, then implement these improvements using the current app
architecture. Verify the complete workflow with a project containing multiple source files, nested
image folders, and several PDF pages. Confirm that uploads, compilation, position preservation,
source–PDF navigation, zoom controls, error links, and grammar suggestions work together.

### Status

Done (2026-11-20). Shipped as `Sources/Maziar/Resources/OpenPrism/maziar-openprism.patch`, applied by
`OpenPrismServer` on start, plus the `MaziarSpell` helper target. Verified in a browser against a test
project (main.tex + two `\input` chapters, images in `figures/plots/` and `figures/photos/2024/`, 4–5
PDF pages): nested drag-and-drop and picker uploads, upload error message, uploaded images compiling by
relative path, position kept across recompiles and clamped when the PDF shrank, pointer-anchored zoom,
fit modes, divider resize, SyncTeX both ways across files with highlight, error links opening the right
file and line, and spelling/grammar suggestions with LaTeX excluded. See README → "OpenPrism editor
improvements (Phase 10)".
