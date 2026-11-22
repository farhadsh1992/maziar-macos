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

- **Projects** — create projects from templates (ACL, CVPR, NeurIPS, ICML …), import a zip or an arXiv
  source, organize files and folders, upload images by drag-and-drop into any folder.
- **Project folders** — the Projects page shows where projects are stored; add more folders (e.g. one
  inside Google Drive, iCloud or Dropbox — detected automatically) or remove them, filter by folder, and
  choose where new projects go. Removing a folder only stops listing it; nothing is deleted.
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
- **Collaboration** — real-time multi-user editing via an invite link.
- **Spelling and grammar** — LaTeX-aware (commands, math, citations and paths are skipped). This uses
  macOS's own checker and is available when Numenor runs inside Maziar.

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
| `NUMENOR_TUNNEL` | `localtunnel`, `cloudflared` or `ngrok` to share a public link for collaboration |

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
