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
- **Move, download, delete** — **Move…** puts a project in another projects folder (moving it into a
  Google Drive folder uploads it to Google Drive; moving it out removes it from there); **Download**
  saves it as a .zip you can import again; **Delete** moves it to Trash (with Undo), and **Delete
  forever** in Trash removes it from disk.
- **Compile and preview** — pdfLaTeX, XeLaTeX, LuaLaTeX, latexmk or Tectonic, with bibliography passes.
  Opening a project compiles it and shows the PDF where you last left it.
- **PDF viewer** — keeps your page, position and zoom across recompiles; pinch or Cmd/Ctrl + scroll zooms
  around the pointer; fit width / fit page; Space + drag to pan.
- **Source ↔ PDF (SyncTeX)** — the **→** button (or Cmd/Ctrl + Shift + J) shows the selected LaTeX in the
  PDF; **←** (or double-click the PDF) jumps from the PDF back to the right `.tex` file and line.
- **Problems panel** — errors and warnings with file and line; click one to jump there. Problem lines
  glow in the editor.
- **Editor** — LaTeX highlighting, folding, autocompletion, Cmd/Ctrl + / to comment lines, `%%%` notes
  shown in bold green, zoom with Cmd/Ctrl + scroll or Cmd/Ctrl + = / −.
- **AI** (any OpenAI-compatible endpoint) — chat and agent editing with diff review, autocomplete,
  compile-error diagnosis, paper search, charts from tables, formula/table recognition from images, and
  template transfer between venues.
- **Share a project with people** — **Share** in the editor's top bar: add each person by name and
  email, choose **Can edit** or **Can view**, and they get their own link (copied, or sent with
  **Email**). The list shows who has access and when they last opened it; change anyone's rights or
  **remove their access** at any time — their link stops working at once, even in an open editor. Sharing
  goes through a public link (Cloudflare Tunnel if `cloudflared` is installed, else ngrok if you have an
  ngrok account token, else localtunnel) while Numenor runs. Invited people only ever reach that one
  project — not your other projects, your folders or your AI key. Temporary tunnel addresses change each
  time sharing starts; under **Same link every time** in the Share dialog, paste the fixed address your free
  ngrok account includes (dashboard.ngrok.com/domains) and links keep working after a restart (saved in
  `share-settings.json` in the state folder).
- **Shared with me** — on the Projects page, paste an invite someone sent you and the project stays listed
  there, showing whether its owner's computer is reachable; **Open** opens it in the owner's Numenor.
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

Then open <http://localhost:8787>. For development with hot reload use `npm run dev`
(frontend on <http://localhost:5173>, backend on 8787).

## Configuration

Set these as environment variables before `npm start` (all optional):

| Variable | Meaning |
|---|---|
| `NUMENOR_LLM_ENDPOINT` | OpenAI-compatible chat completions URL (default OpenAI) |
| `NUMENOR_LLM_API_KEY` | API key for that endpoint |
| `NUMENOR_LLM_MODEL` | Model name (default `gpt-4o-mini`) |
| `NUMENOR_DATA_DIR` | Where projects are stored (default `./data`) |
| `PORT` | Server port (default `8787`) |
| `NUMENOR_HOST` | Address to listen on (default `0.0.0.0`; `127.0.0.1` = this computer only) |
| `NUMENOR_LLM_LOCKED` | `1` = use only the server's AI settings, ignore ones entered in the browser |
| `NUMENOR_MINERU_API_BASE`, `NUMENOR_MINERU_TOKEN` | MinerU service for PDF → LaTeX template transfer |
| `NUMENOR_TUNNEL` | Start a share link at launch: `auto`, `cloudflared`, `ngrok` or `localtunnel` (or use the Collab tab) |
| `NUMENOR_COLLAB_TOKEN_SECRET` | Secret for signing invite links (default: a random one created per install) |
| `NUMENOR_STATE_DIR` | Where per-computer sharing state lives (`invites.json`, `shared-with-me.json`); default: the data folder |
| `NUMENOR_OWNER_NAME` | Your name in project history (default: `Owner`) |

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
