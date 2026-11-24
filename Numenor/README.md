<p align="center">
  <img src="apps/frontend/public/numenor-logo.png" alt="Numenor logo" width="160">
</p>

# Numenor

A local LaTeX writing workspace: a project file tree, a code editor and a live PDF preview side by side,
with AI help for writing. It runs on your own computer — your projects stay in a local folder.

Numenor is based on [OpenPrism](https://github.com/OpenDCAI/OpenPrism) (MIT) and adds an Overleaf-style
reading and editing workflow on top of it. It is also the second LaTeX editor inside
[Maziar](https://github.com/farhadsh1992/maziar-macos), the macOS paper-writing app it was built for,
but it runs perfectly well on its own.

## What it does

- **Look** — midnight-navy dark theme and warm off-white light theme with antique-gold accents (serif
  headings, monospaced source, white PDF paper in both). It follows the system appearance, or the app
  embedding it (Maziar sets `data-theme` on the page). Theme tokens live in `apps/frontend/src/app/theme.css`.

- **Projects** — create projects from templates (ACL, CVPR, NeurIPS, ICML …), import a zip or an arXiv
  source, organize files and folders, upload images by drag-and-drop into any folder.
- **Project folders** — the Projects page shows where projects are stored; add more folders (e.g. one
  inside Google Drive, iCloud or Dropbox — detected automatically) or remove them, filter by folder, and
  choose where new projects go. Removing a folder only stops listing it; nothing is deleted.
- **Changes from other computers** — when a project lives in a synced folder (Google Drive, iCloud…) and
  is edited on another computer, the open editor picks up the new version within a few seconds (the
  cursor stays put), new and removed files appear in the file tree, and the Projects page refreshes when
  you return to it. If you had unsaved edits to that same file, nothing is overwritten: a bar asks whether
  to load the new version or keep yours.
- **Same project in two folders** — e.g. an old copy in this computer's own folder and the live one in a
  Google Drive folder: Numenor uses the most recently changed copy and says where the older one is (editor
  settings). The round **↻** next to each folder path on the Projects page (and next to the path in the
  editor settings) checks that folder again right away.
- **Move, download, delete** — **Move…** puts a project in another projects folder (moving it into a
  Google Drive folder uploads it to Google Drive; moving it out removes it from there); **Download**
  saves it as a .zip you can import again; **Delete** moves it to Trash (with Undo), and **Delete
  forever** in Trash removes it from disk.
- **Compile and preview** — pdfLaTeX, XeLaTeX, LuaLaTeX, latexmk or Tectonic, with bibliography passes.
  BibTeX runs from the project folder like on Overleaf, so paths such as `\bibliography{./references}` work.
  The main file can be any `.tex` file, or a `.txt` / `.ltx` file that starts with `\documentclass` (as some
  Overleaf projects have); the choice is saved in the project, so it is the same for everyone.
  Opening a project compiles it and shows the PDF where you last left it.
- **PDF viewer** — keeps your page, position and zoom across recompiles; pinch or Cmd/Ctrl + scroll zooms
  around the pointer; fit width / fit page; Space + drag to pan.
- **Source ↔ PDF (SyncTeX)** — the **→** button (or Cmd/Ctrl + Shift + J) shows the selected LaTeX in the
  PDF; **←** (or double-click the PDF) jumps from the PDF back to the right `.tex` file and line.
- **Search (Cmd/Ctrl + F)** — searches where you last clicked: in the source (`.tex`, `.txt`, `.bib` … with
  next / previous / replace) or in the compiled PDF (every match highlighted, the current one in orange,
  Enter / Shift + Enter to move, Esc to close; text selected in the PDF is searched right away).
- **Missing files** — if a compile can't find a file the document uses (an `\input`, an image, a `.bib` —
  say one was dragged into the wrong folder or deleted by mistake), a red box above the PDF names it and
  says what happened according to the project's history (moved where, or deleted, by whom and when), with
  **Move it back** for moved files and folders. Moving a file onto one that already exists is refused.
- **Problems panel** — errors and warnings with file and line; click one to jump there. Problem lines
  glow in the editor.
- **Editor** — LaTeX highlighting, folding, autocompletion, Cmd/Ctrl + / to comment lines, `%%%` notes
  shown in bold green, zoom with Cmd/Ctrl + scroll or Cmd/Ctrl + = / −.
- **Writing status** — use the trailing button on a TXT file in Project Files to mark it To do, In progress, or Done. The optional note and date live in project metadata and follow in-project renames and moves.
- **Source comments** — select text and choose **Add Comment** from the editor menu. The bottom-bar **Comments** button shows this file or the whole project, and note rows and gutter bubbles jump back to the passage. Comments live in project metadata.
- **LaTeX structure** — the file sidebar's **Outline** follows the cursor through sections, subsections,
  and subsubsections. Drag the divider above Outline to resize it, or open it in a floating window in Maziar. TXT files use LaTeX syntax colors and tools by default. The **LaTeX mode** button beside a TXT tab toggles extra heading, note, equation, and table highlighting.
  Display equations and tables have gutter folds and right-click previews. **View in PDF** uses the
  last compiled PDF for project macros and complex table formatting. Use **Insert → Insert Table**
  to choose the number of data rows and columns and add an optional header.
- **LaTeX editor settings** — under **Numenor Settings → Editor / LaTeX**, control heading, equation,
  table, and note styling, equation and table folds and previews, and the Outline independently.
  Comment headings such as `%%h1/g> Experiments` support sizes `h1` through `h5` and green, red,
  blue, purple, and orange (`g`, `r`, `b`, `p`, `o`). Use `%%h2/>` for the normal editor text color.
- **AI & Models** — open **Numenor Settings → AI & Models** to configure a provider. Click the glowing star
  in the editor toolbar to open **Chat**. AI starts Off. Choose a managed Qwen3 model, Apple's system model, Ollama, an OpenAI-compatible endpoint
  such as a llama.cpp server, or Gemini. Provider selection and remote connection tests are explicit.
  Credentials are stored in macOS Keychain. Re-enter credentials from older Numenor releases here.
- **Managed models** — on Apple Silicon with macOS 14+, **Download & Install** prepares the pinned
  [llama.cpp runtime](https://github.com/ggml-org/llama.cpp/releases/tag/b6500) and verifies a Qwen3
  GGUF model before installation. Files live in Application Support. The catalog lists download size.
  The model uses additional memory while running, starts on demand at 2,048 tokens of context, and
  unloads after two idle minutes. Interrupted downloads can be retried. Removing the active model
  switches AI Off. Apple Foundation Models requires macOS 26+ and an available Apple Intelligence model.
  Standalone Numenor uses the macOS Swift tools to prepare its Keychain and Apple Intelligence helper.
- **Share a project with people** — **Share** in the editor's top bar: add each person by name and
  email, choose **Can edit** or **Can view**, and they get their own link (copied, or sent with
  **Email**; set up **Email invites** once in the Share dialog — Gmail, Outlook, iCloud or any SMTP server,
  with an app password kept only on this computer in `mail-settings.json` — and Numenor emails each person
  their link itself when you invite them). Each person also gets an **8-character access code** (shown next to
  their name, included in the email and in the copied text; **New code** replaces it). The link alone opens
  nothing: in a browser the code is asked each time the link is opened (the sign-in lasts 12 hours in that
  tab), while their own Numenor asks once and remembers it. Ten wrong codes lock that link for 15 minutes. The list shows who has access and when they last opened it; change anyone's rights or
  **remove their access** at any time — their link stops working at once, even in an open editor. Sharing
  goes through a public link (Cloudflare Tunnel if `cloudflared` is installed, else ngrok if you have an
  ngrok account token, else localtunnel) while Numenor runs. Invited people only ever reach that one
  project — not your other projects, your folders or your AI key. Temporary tunnel addresses change each
  time sharing starts; under **Same link every time** in the Share dialog, paste the fixed address your free
  ngrok account includes (dashboard.ngrok.com/domains) and links keep working after a restart (saved in
  `share-settings.json` in the state folder). If sharing was on when Numenor stopped (a restart, an update,
  quitting Maziar), it starts again by itself; only **Stop sharing** turns it off for good.
- **See who's here** — everyone who has the project open shows in the editor's top bar (initials and name
  in a coloured ring; hover for their access and the file they're in). Their cursor in the text has the
  same colour and their name on it, and the owner joins live editing automatically as soon as someone else
  is in. Click someone's name to jump to them: Numenor opens the file they're in and scrolls to their
  cursor, which flashes.
- **Shared with me** — on the Projects page, click **Add shared link** (left sidebar) and paste an invite
  someone sent you with its access code (asked only this once); the project stays listed under Shared with me, showing whether its owner's computer is reachable; **Open** opens it in the owner's Numenor.
- **Copies in Google Drive, SharePoint and other folders** — **Copies** in the editor's top bar keeps the
  project copied into any number of folders: a Google Drive folder, a SharePoint / Teams library or
  OneDrive (synced to the Mac by the OneDrive app — in SharePoint click **Sync** or **Add shortcut to My
  files**), Dropbox, iCloud or any other folder. Every save (yours or an invited person's) and every new PDF
  updates all copies a few seconds later, and the cloud apps upload them with the account they're signed
  in with — Numenor stores no cloud passwords. A copy only removes files it put there itself, so other
  files in a shared folder are left alone. Kept per computer in `sync-targets.json` in the state folder.
- **Version and updates** — the version (e.g. *Beta 1.0.5*) is shown at the bottom of the Projects page.
  Numenor checks GitHub when it opens and every few hours; when a newer version is there it shows
  **Update available**, and **Update now** downloads it (`git pull` in a git clone, otherwise the source
  archive), installs, rebuilds and restarts — projects and settings are not touched. Every update published
  to GitHub raises the version.
- **History** — every save, by you or by the people you share with, is recorded per project
  (`.numenor-history/` inside the project): who changed which file, when, and the exact lines added and
  removed, with **Restore** for any version.
- **PDF in its own window** — the pop-out button in the PDF toolbar moves the preview into a separate
  window and gives the editor the full width; sync, compile and "Back to editor" work from both windows.
- **Spelling and grammar** — LaTeX-aware (commands, math, citations and paths are skipped). This uses
  macOS's own checker and is available when Numenor runs inside Maziar. **Spelling** in the bottom bar
  turns red when there are mistakes; click it for the list (word, suggestions, line — click to jump),
  your spelling vocabulary, and *Turn off spelling*. Right-click an underlined word → *Add to spelling
  vocabulary* to treat it as correct from then on (kept on this computer in `spell-vocabulary.json`).

## Requirements

- Node.js 18 or newer (with npm)
- A TeX distribution for compiling: TeX Live / MacTeX (recommended, includes `latexmk` and `synctex`)
  or Tectonic
  - macOS: `brew install --cask mactex` · Ubuntu/Debian: `sudo apt-get install texlive-full`

## Run it

```bash
git clone https://github.com/farhadsh1992/numenor.git
cd numenor
npm install
npm run build
npm start
```

Then open <http://localhost:8787>. On macOS, open **Settings → LaTeX compilers** to check
which engines Numenor can use. With Homebrew available, **Install MacTeX** installs the full
TeX Live distribution without the GUI apps and macOS requests administrator authorization.
**Install Tectonic** installs Tectonic separately. Use **Refresh compiler status** after a
manual installation.

For development with hot reload use `npm run dev`
(frontend on <http://localhost:5173>, backend on 8787).

## Configuration

Set these as environment variables before `npm start` (all optional):

| Variable | Meaning |
|---|---|
| `NUMENOR_DATA_DIR` | Where projects are stored (default `./data`) |
| `PORT` | Server port (default `8787`) |
| `NUMENOR_HOST` | Address to listen on (default `0.0.0.0`; `127.0.0.1` = this computer only) |
| `NUMENOR_MINERU_API_BASE`, `NUMENOR_MINERU_TOKEN` | MinerU service for PDF → LaTeX template transfer |
| `NUMENOR_TUNNEL` | Start a share link at launch: `auto`, `cloudflared`, `ngrok` or `localtunnel` (or use the Collab tab) |
| `NUMENOR_COLLAB_TOKEN_SECRET` | Secret for signing invite links (default: a random one created per install) |
| `NUMENOR_STATE_DIR` | Where per-computer sharing state lives (`invites.json`, `shared-with-me.json`); default: the data folder |
| `NUMENOR_OWNER_NAME` | Your name in project history (default: `Owner`) |
| `NUMENOR_UPDATE_REPO` | GitHub repository updates come from (default `farhadsh1992/numenor`) |
| `NUMENOR_SUPERVISED` | `1` = after an update, exit with code 75 and let the app running Numenor (Maziar) restart it |

The AI endpoint, key and model can also be entered in the Settings panel in the browser. Older
`OPENPRISM_*` variable names still work.

## Project layout

```
apps/frontend   React + Vite interface (editor, PDF viewer, panels)
apps/backend    Fastify server: projects, compile, SyncTeX, AI, collaboration
templates       Conference templates
```

## Credits and license

Numenor is a modified version of OpenPrism by OpenDCAI and contributors, used under the MIT License.
See [LICENSE](LICENSE). The Numenor changes are by Farhad Shadmand and are released under the same
license.
