# CLAUDE.md — Numenor

Guidance for Claude Code when working in `maziar/Numenor/`. (The repo-wide `CLAUDE.md` two levels up still
applies; this file covers Numenor only.)

## What it is

Numenor is a local LaTeX workspace (Overleaf-style): project file tree, CodeMirror editor, live PDF preview,
SyncTeX, AI help, sharing with invited people, history. It is a heavily extended fork of
[OpenPrism](https://github.com/OpenDCAI/OpenPrism) (MIT).

- **This folder is the single source of truth.** It is tracked in the maziar repo
  (`github.com/farhadsh1992/maziar-macos`) and mirrored to `github.com/farhadsh1992/numenor`.
  **Never edit the numenor repo directly** — the next sync overwrites it.
- It runs on its own (`npm start`) **and** inside Maziar (the macOS app), which copies this folder into
  `~/Library/Application Support/Maziar/Numenor/app` and starts it (see "Inside Maziar" below).

## Publishing (do this every time Numenor changes and the user wants it pushed)

1. Commit in the maziar repo (`git -C maziar …`, end the message with the Co-Authored-By line).
2. Run `maziar/scripts/push-numenor.sh`. It: clones numenor, mirrors this folder, **raises the version**
   (`package.json` + `package-lock.json`, e.g. Beta 1.0.17 → 1.0.18, via `scripts/bump-version.mjs`) unless
   it was already raised by hand, commits that bump in maziar, pushes maziar, then commits + pushes numenor.
3. The maziar working tree must be clean first (the script refuses otherwise).

Version = root `package.json` `version` + `releaseLabel` ("Beta"). Installed copies compare it with
GitHub's `package.json` and offer **Update** (`services/updateService.js`, `app/UpdateNotice.tsx`).
`node scripts/bump-version.mjs [x.y.z]` sets it by hand (keeps the lockfile in step so npm doesn't rewrite it).

## Layout

```
apps/backend/src/        Fastify server (ESM, plain JS — no TypeScript, no tests)
  index.js               routes + auth preHandler + static frontend + listen (retries after an update)
  config/constants.js    DATA_DIR, STATE_DIR, PORT, secrets, OWNER_NAME
  routes/                one file per area (projects, compile, collab, invites, share, mail, sync, update,
                         presence, folders, sharedWithMe, history, spell, synctex, compilerSetup
                         (checks for / installs a TeX compiler, local-only), …)
  services/              logic (projectService, compileService, historyService, syncService,
                         updateService, missingFiles, inviteService, mailService, shareService, tunnel,
                         collab/docStore + tokenService, projectEvents, …)
  utils/authUtils.js     isLocalRequest / remoteRequestAllowed — the security boundary (read it first)
apps/frontend/src/       React + Vite + TypeScript
  app/EditorPage.tsx     the editor (~6.7k lines; most features live here)
  app/ProjectPage.tsx    Projects page;  app/ShareDialog.tsx, SyncDialog.tsx, UpdateNotice.tsx, PdfViewer.tsx,
                         CompilerSetup.tsx …
  app/theme.css          Numenor's theme (tokens `--nm-*`); append new styles here, use the tokens
  api/client.ts          every backend call (`request` = throws on HTTP error, `maziarRequest` = JSON errors)
  latex/                 diagnostics (log parser, reads the LAST pass only), spell, language
templates/               conference templates
docs/                    Install-Numenor-on-Mac.tex/.pdf (XeLaTeX)
scripts/bump-version.mjs
```

## Build, run, check

- Dependencies: `npm install` (root, workspaces). Build UI: `npm run build`. Run: `npm start` (port 8787).
- The real `maziar/Numenor/` has **no `node_modules`** — don't install there. Test in a scratch copy:
  `rsync -a --exclude node_modules --exclude apps/frontend/dist --exclude data Numenor/ <scratch>/numenor-view/`,
  `npm install` once, then run with `PORT=8796 NUMENOR_HOST=127.0.0.1 NUMENOR_DATA_DIR=… NUMENOR_STATE_DIR=…
  node apps/backend/src/index.js` (start it with the preview/background tools, never block on it).
- **After every frontend rebuild, restart the server**: it caches the built asset names at startup and
  otherwise serves a blank page.
- Type-check from the scratch copy: `cd apps/frontend && ../../node_modules/.bin/tsc --noEmit -p .`.
  **EditorPage.tsx has 10 old type errors** (lines nobody touched) — only new errors matter.
- Backend: `node --check <file>` on every touched file (no build step catches typos).
- Verify UI changes in the browser pane against the scratch server, and API changes with `curl`.
- **Testing as an invited person:** any request from localhost counts as the *owner*. To be a guest you need a
  non-local request: run the scratch server with `NUMENOR_HOST=0.0.0.0` and open it via the Mac's LAN IP, or
  via a tunnel. Get a session pass with `POST /api/collab/unlock {token, code}` and open
  `/collab?session=<pass>` — don't type access codes into pages served from a tunnel host.
- Don't leave a scratch tunnel running: free ngrok allows one session per account and the user's Maziar
  shares on the same account.

## Inside Maziar (things that break silently)

- `maziar/Sources/Maziar/NumenorServer.swift` copies this folder into the app bundle (`build_app.sh`), then
  into Application Support when its digest changes, runs `npm install` only if `package-lock.json` changed,
  `npm run build`, and starts `node apps/backend/src/index.js` on a free port from 8787 with env:
  `NUMENOR_HOST=127.0.0.1`, `NUMENOR_LLM_LOCKED=1` + `NUMENOR_LLM_*`, `NUMENOR_DATA_DIR`, `NUMENOR_STATE_DIR`,
  `NUMENOR_OWNER_NAME`, `NUMENOR_COLLAB_TOKEN_SECRET`, `MAZIAR_SPELL_HELPER`, `NUMENOR_SUPERVISED=1`.
- Self-update under Maziar exits with **code 75**; Maziar restarts it. Standalone, the server re-spawns itself.
- `Views/NumenorView.swift` (`NumenorTheme.pageScript`) injects JS that keys off Numenor's **CSS class names**
  (dark mode, greeting, hiding AI fields whose `<label>` matches `/LLM|VLM/`, opening projects in windows).
  Renaming classes or those labels breaks Maziar without any error.
- Maziar's web view (`ScholarBrowserView.swift`) implements `alert`/`confirm`/`prompt`; without that, every
  `window.confirm` silently returned false (e.g. "remove person" did nothing).
- Stored names still say `openPrism` (`maziar.openPrism.*`, Drive `op-<id>.zip`) on purpose — don't rename.

## Data and per-computer state

- A project = a folder `<projects folder>/<id>/` with `project.json` (name, fileOrder, `mainFile`, tags…),
  its files, `.numenor-history/` (index.json + one JSON per edit; travels with the project) and `.compile/`
  (build output, `last/` kept for SyncTeX; never synced or copied).
- Projects folders: `DATA_DIR` plus extra folders listed in `DATA_DIR/.numenor-folders.json` (e.g. inside
  Google Drive). **The same project id can exist in several folders** (an old copy from Maziar's own Drive
  sync + the live Google Drive copy): `getProjectCopies`/`getProjectRoot` pick the most recently changed
  copy. Always resolve projects through `getProjectRoot`, never `path.join(DATA_DIR, id)`.
- `STATE_DIR` (per computer, never in the synced projects folder): `invites.json`, `shared-with-me.json`,
  `share-settings.json` (fixed ngrok domain, `resume` = restart sharing after a restart/update),
  `mail-settings.json` (mode 0600, app password — never returned by the API), `spell-vocabulary.json`,
  `sync-targets.json` + `sync-manifests/` (Copies).
- Change events: `historyService.recordEdit/recordEvent` and a finished compile call
  `projectEvents.projectChanged` → `syncService` updates the project's Copies a few seconds later.

## Security model (read before adding any route)

- `isLocalRequest(req)` = loopback socket, no proxy headers, localhost Host. Everything else is remote and needs
  a token. Invite links carry `op2.` tokens (identify the invite only); the 8-character access code turns one
  into a 12-hour `ops.` session pass (`/api/collab/unlock`; 10 wrong codes → 15-minute lock).
- `remoteRequestAllowed` lets an invited person reach **anything under `/api/projects/<their id>/…`**
  (view-only: GET only), plus a few listed routes. So a new project-scoped route is guest-reachable by
  default: if it touches this computer (folders, Finder, settings, mail, updates, copies) put it outside
  `/api/projects/:id/` or check `isLocalRequest` explicitly, like `location`, `reveal`, `sync`, `update`.
- Never return secrets (mail password, tokens of other people, the collab secret) from an API.

## Compile pipeline (`services/compileService.js`)

- pdflatex/xelatex/lualatex: pass 1 → BibTeX (or Biber) → 2 more passes; latexmk/tectonic run once.
  Output goes to `.compile/<run id>/` with `-output-directory`.
- **BibTeX runs with the project as its working folder** (`openout_any=a`, reading the `.aux` from the build
  folder) so `\bibliography{./references}` works like on Overleaf.
- A compile is limited to 3 minutes (`NUMENOR_COMPILE_TIMEOUT_SEC`), and a new compile of the same project
  stops the running one (`replaced`) — documents with an unclosed environment can make TeX loop forever.
- The main file can be any `.tex`, or a `.txt`/`.ltx` starting with `\documentclass` (Overleaf imports);
  the choice is saved in `project.json` `mainFile` (`PUT /api/projects/:id/main-file`).
- `services/missingFiles.js` names files LaTeX/BibTeX couldn't open and, from the history, whether they were
  moved (where) or deleted — shown above the PDF with "Move it back". `rename` refuses to overwrite.

## Frontend conventions

- Text goes through `t('…')` (react-i18next). Older keys are Chinese strings from OpenPrism; new text uses
  plain English keys.
- Live editing is Yjs (`collab/provider.ts`, backend `collab/docStore.js`). In collab mode the server's
  Yjs doc owns the text — don't write files around it. Presence (`routes/presence.js`) and cursor colours
  are keyed by identity (`'owner'` / `'invite:<id>'`) via `colorForKey`, so the top-bar ring matches the cursor.
- The editor polls `/api/projects/:id/stat` every 4 s to pick up files changed outside Numenor (Google Drive
  from another computer); with unsaved edits it asks instead of overwriting, and autosave pauses.
- Cmd/Ctrl+F searches the pane clicked last: CodeMirror's panel (themed in theme.css) or the PDF
  (`PdfViewer.find`, highlights as page-relative percentages so they survive zoom).

## Keep in step

- Update `README.md` (feature list, env vars) whenever a feature changes.
- `maziar/README.md` has a Numenor section; `docs/Install-Numenor-on-Mac.tex` explains install, sharing and
  access codes — rebuild the PDF with XeLaTeX if you change it.
