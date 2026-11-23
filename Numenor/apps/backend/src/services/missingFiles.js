// "Why did the compile break?" — finds the project files LaTeX / BibTeX couldn't open (an \input, an image, a
// .bib) and, from the project's history, what happened to each: moved (dragged into another folder by
// mistake, renamed) or deleted, by whom and when. The editor shows this above the PDF with a way to fix it.
import { promises as fs, existsSync } from 'fs';
import path from 'path';
import { listHistory } from './historyService.js';
import { listFilesRecursive } from '../utils/fsUtils.js';

const PATTERNS = [
  /LaTeX Error: File `([^']+)' not found/g,
  /! I can't find file `([^']+)'/g,
  /File `([^']+)' not found: using draft setting/g,
  /Package pdftex\.def Error: File `([^']+)' not found/g,
  /I couldn't open database file ([^\s]+)/g,
  /Package biblatex Warning: File '([^']+)' not found/g
];
// Installed-by-TeX files: a missing package isn't a project file that went missing.
const SYSTEM_EXT = /\.(sty|cls|bst|cfg|def|fd|clo|ldf|tfm|map|enc|pfb)$/i;
const TRY_EXT = ['', '.tex', '.bib', '.png', '.pdf', '.jpg', '.jpeg', '.eps', '.svg'];

const norm = (p) => p.replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/{2,}/g, '/');

export async function findMissingFiles(projectRoot, log) {
  if (!log) return [];
  const names = new Set();
  for (const re of PATTERNS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(log))) {
      const name = norm(m[1].trim());
      if (name && !SYSTEM_EXT.test(name) && !path.isAbsolute(name)) names.add(name.replace(/^(\.\/)+/, ''));
    }
  }
  if (!names.size) return [];

  let files = [];
  try {
    files = (await listFilesRecursive(projectRoot)).filter((i) => i.type === 'file').map((i) => norm(i.path));
  } catch {
    /* ignore */
  }
  let history = [];
  try {
    history = await listHistory(projectRoot, { limit: 2000 }); // newest first
  } catch {
    /* no history */
  }

  // Images are looked up through \graphicspath (e.g. {figures/}), so "../figures/x.png" means figures/x.png:
  // also try each name from every folder of the project, the way LaTeX would.
  const dirs = new Set(['']);
  for (const f of files) {
    const parts = f.split('/');
    for (let i = 1; i < parts.length; i += 1) dirs.add(parts.slice(0, i).join('/'));
  }
  const inProject = (p) => !p.startsWith('../') && p !== '..' && !path.posix.isAbsolute(p);
  const resolveName = (name) => {
    const tries = [];
    for (const d of dirs) {
      const n = path.posix.normalize(d ? `${d}/${name}` : name);
      if (inProject(n) && !tries.includes(n)) tries.push(n);
    }
    return tries;
  };

  const out = [];
  for (const raw of names) {
    const bases = resolveName(raw);
    if (!bases.length) continue;
    const variants = bases.flatMap((b) => TRY_EXT.map((ext) => (ext && b.toLowerCase().endsWith(ext) ? null : b + ext)).filter(Boolean));
    // The name to show: the first form that the history knows about, else the name as written.
    const known = history.find((e) => variants.some((v) => e.path === v || v.startsWith(`${e.path}/`)));
    const name = known ? (variants.find((v) => known.path === v || v.startsWith(`${known.path}/`)) || raw) : (inProject(path.posix.normalize(raw)) ? path.posix.normalize(raw) : raw);
    // Still there (e.g. created or found on a later pass)? Only the name as written counts here: LaTeX did
    // fail to find it, so a same-named file in another folder is a suggestion, not a reason to stay quiet.
    const asWritten = path.posix.normalize(raw);
    if (inProject(asWritten) && TRY_EXT.some((ext) => existsSync(path.join(projectRoot, asWritten + ext)))) continue;
    const item = { file: name };
    // What happened to it, according to the history (a moved folder moves the files inside it too).
    for (const e of history) {
      const hit = variants.find((v) => e.path === v || v.startsWith(`${e.path}/`));
      if (!hit) continue;
      if (e.action === 'rename' && e.to) {
        const dest = hit === e.path ? e.to : `${e.to}${hit.slice(e.path.length)}`;
        Object.assign(item, { file: hit, movedTo: norm(dest), by: e.author, at: e.time, folderMove: hit !== e.path ? { from: e.path, to: e.to } : undefined });
        // Follow later moves of the same file.
        if (!existsSync(path.join(projectRoot, item.movedTo))) item.movedTo = undefined;
        break;
      }
      if (e.action === 'delete') {
        Object.assign(item, { file: hit, deleted: true, by: e.author, at: e.time });
        break;
      }
    }
    // A file with the same name somewhere else in the project?
    if (!item.movedTo) {
      const base = path.posix.basename(name).toLowerCase();
      const same = files.filter((f) => {
        const b = path.posix.basename(f).toLowerCase();
        return b === base || TRY_EXT.some((ext) => ext && b === base + ext);
      });
      if (same.length === 1) item.foundAt = same[0];
    }
    out.push(item);
  }
  return out;
}

export async function fileExists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}
