// "Keep a copy in…": a project can be mirrored into any number of other folders on this computer — a
// Google Drive folder, a SharePoint / OneDrive library synced by the OneDrive app, Dropbox, iCloud, a USB
// drive… Each save (by the owner or by an invited person) and each new PDF updates every copy a few seconds
// later; the cloud apps then upload the changes with the account they are signed in with, so Numenor never
// needs (or stores) a cloud password.
//
// Per computer (folder paths differ between Macs): STATE_DIR/sync-targets.json
//   { projects: { [projectId]: { targets: [{ id, dest, includePdf, enabled, createdAt, lastSyncAt, lastError, fileCount }] } } }
// A copy only ever deletes files it wrote itself (remembered in STATE_DIR/sync-manifests/<targetId>.json),
// so other people's files in a shared folder are never touched.
import { promises as fs, existsSync } from 'fs';
import path from 'path';
import crypto from 'crypto';
import { STATE_DIR } from '../config/constants.js';
import { getProjectFolders, getProjectRoot } from './projectService.js';
import { projectEvents } from './projectEvents.js';

const FILE = () => path.join(STATE_DIR, 'sync-targets.json');
const MANIFEST_DIR = () => path.join(STATE_DIR, 'sync-manifests');
const DEBOUNCE_MS = Number(process.env.NUMENOR_SYNC_DEBOUNCE_MS || 4000);
// Numenor's own bookkeeping stays out of the copies.
const SKIP = new Set(['.compile', '.numenor-history', 'project.json', '.DS_Store', '.git', 'node_modules']);

let cache = null;
async function load() {
  if (cache) return cache;
  try {
    const raw = JSON.parse(await fs.readFile(FILE(), 'utf8'));
    cache = raw && typeof raw.projects === 'object' ? raw : { projects: {} };
  } catch {
    cache = { projects: {} };
  }
  return cache;
}

async function save() {
  await fs.mkdir(STATE_DIR, { recursive: true });
  await fs.writeFile(`${FILE()}.tmp`, JSON.stringify(cache, null, 2));
  await fs.rename(`${FILE()}.tmp`, FILE());
}

const targetsOf = (data, projectId) => (data.projects[projectId] ||= { targets: [] }).targets;

export function safeFolderName(name) {
  const clean = String(name || 'Project').replace(/[/\\:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim();
  return (clean || 'Project').slice(0, 120);
}

async function projectName(projectRoot) {
  try {
    return JSON.parse(await fs.readFile(path.join(projectRoot, 'project.json'), 'utf8')).name || path.basename(projectRoot);
  } catch {
    return path.basename(projectRoot);
  }
}

const inside = (child, parent) => child === parent || child.startsWith(parent + path.sep);

/** Refuses destinations that would copy a project into itself or into the projects folders. */
async function checkDestination(projectRoot, dest) {
  if (!path.isAbsolute(dest)) throw new Error('Choose a folder on this computer.');
  if (inside(dest, projectRoot) || inside(projectRoot, dest)) throw new Error('That folder is the project itself — choose another one.');
  for (const folder of await getProjectFolders()) {
    if (inside(path.resolve(dest), path.resolve(folder))) {
      throw new Error('That folder is inside a Numenor projects folder — choose a folder outside it.');
    }
  }
}

export async function listTargets(projectId) {
  const data = await load();
  return (data.projects[projectId]?.targets || []).map((t) => ({ ...t, running: running.has(t.id), exists: existsSync(path.dirname(t.dest)) }));
}

/** parent: the folder chosen; the copy goes in "<parent>/<project name>" unless useFolderAsIs. */
export async function addTarget(projectId, { parent, includePdf = true, useFolderAsIs = false }) {
  const projectRoot = await getProjectRoot(projectId);
  const base = path.resolve(String(parent || ''));
  let stat;
  try {
    stat = await fs.stat(base);
  } catch {
    throw new Error(`${base} doesn't exist.`);
  }
  if (!stat.isDirectory()) throw new Error(`${base} isn't a folder.`);
  const dest = useFolderAsIs ? base : path.join(base, safeFolderName(await projectName(projectRoot)));
  await checkDestination(projectRoot, dest);
  const data = await load();
  const targets = targetsOf(data, projectId);
  if (targets.some((t) => path.resolve(t.dest) === dest)) throw new Error('This project is already copied to that folder.');
  const target = {
    id: crypto.randomBytes(6).toString('base64url'),
    dest,
    includePdf: Boolean(includePdf),
    enabled: true,
    createdAt: new Date().toISOString(),
    lastSyncAt: null,
    lastError: null,
    fileCount: 0
  };
  targets.push(target);
  await save();
  await syncTarget(projectId, target.id).catch(() => {});
  return (await listTargets(projectId)).find((t) => t.id === target.id);
}

export async function updateTarget(projectId, targetId, changes) {
  const data = await load();
  const target = targetsOf(data, projectId).find((t) => t.id === targetId);
  if (!target) throw new Error('That copy no longer exists.');
  if (typeof changes.enabled === 'boolean') target.enabled = changes.enabled;
  if (typeof changes.includePdf === 'boolean') target.includePdf = changes.includePdf;
  await save();
  if (target.enabled) await syncTarget(projectId, targetId).catch(() => {});
  return (await listTargets(projectId)).find((t) => t.id === targetId);
}

/** Stops copying. The files already copied stay where they are. */
export async function removeTarget(projectId, targetId) {
  const data = await load();
  const targets = targetsOf(data, projectId);
  const i = targets.findIndex((t) => t.id === targetId);
  if (i < 0) return;
  targets.splice(i, 1);
  await save();
  await fs.rm(path.join(MANIFEST_DIR(), `${targetId}.json`), { force: true });
}

async function readManifest(targetId) {
  try {
    const raw = JSON.parse(await fs.readFile(path.join(MANIFEST_DIR(), `${targetId}.json`), 'utf8'));
    return raw && typeof raw.files === 'object' ? raw.files : {};
  } catch {
    return {};
  }
}

async function writeManifest(targetId, files) {
  await fs.mkdir(MANIFEST_DIR(), { recursive: true });
  await fs.writeFile(path.join(MANIFEST_DIR(), `${targetId}.json`), JSON.stringify({ files }));
}

/** Every file of the project that belongs in a copy: relative path → absolute source path. */
async function collectFiles(projectRoot, includePdf) {
  const out = new Map();
  const walk = async (dir, rel) => {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (SKIP.has(entry.name) || entry.name.endsWith('.tmp')) continue;
      const abs = path.join(dir, entry.name);
      const relPath = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(abs, relPath);
      else if (entry.isFile()) out.set(relPath, abs);
    }
  };
  await walk(projectRoot, '');
  if (includePdf) {
    // The last good build, next to the sources under its usual name (e.g. main.pdf).
    try {
      const build = JSON.parse(await fs.readFile(path.join(projectRoot, '.compile', 'last', 'build.json'), 'utf8'));
      const pdf = path.join(projectRoot, '.compile', 'last', `${build.base}.pdf`);
      const mainDir = path.posix.dirname(String(build.mainFile || '').replace(/\\/g, '/'));
      const rel = mainDir && mainDir !== '.' ? `${mainDir}/${build.base}.pdf` : `${build.base}.pdf`;
      if (existsSync(pdf) && !out.has(rel)) out.set(rel, pdf);
    } catch {
      /* not compiled yet */
    }
  }
  return out;
}

const running = new Map(); // targetId → Promise
const timers = new Map(); // projectId → timeout

/** Brings one copy up to date: copies new and changed files, removes files it copied earlier that are gone. */
export function syncTarget(projectId, targetId) {
  const prev = running.get(targetId) || Promise.resolve();
  const next = prev.catch(() => {}).then(() => doSync(projectId, targetId));
  running.set(targetId, next);
  next.finally(() => {
    if (running.get(targetId) === next) running.delete(targetId);
  }).catch(() => {});
  return next;
}

async function doSync(projectId, targetId) {
  const data = await load();
  const target = targetsOf(data, projectId).find((t) => t.id === targetId);
  if (!target || !target.enabled) return null;
  let copied = 0;
  let removed = 0;
  try {
    const projectRoot = await getProjectRoot(projectId);
    await checkDestination(projectRoot, target.dest);
    const parent = path.dirname(target.dest);
    if (!existsSync(parent)) throw new Error(`${parent} isn't available (is the drive or cloud app running?)`);
    await fs.mkdir(target.dest, { recursive: true });
    const files = await collectFiles(projectRoot, target.includePdf);
    const before = await readManifest(targetId);
    const after = {};
    for (const [rel, src] of files) {
      const st = await fs.stat(src);
      const destFile = path.join(target.dest, ...rel.split('/'));
      const known = before[rel];
      let destSize = -1;
      try {
        destSize = (await fs.stat(destFile)).size;
      } catch {
        /* not there yet */
      }
      if (!known || known.mtimeMs !== st.mtimeMs || known.size !== st.size || destSize !== st.size) {
        await fs.mkdir(path.dirname(destFile), { recursive: true });
        await fs.copyFile(src, destFile);
        copied += 1;
      }
      after[rel] = { size: st.size, mtimeMs: st.mtimeMs };
    }
    for (const rel of Object.keys(before)) {
      if (after[rel]) continue;
      await fs.rm(path.join(target.dest, ...rel.split('/')), { force: true }).catch(() => {});
      removed += 1;
      // Tidy up folders left empty by the removal (never the copy's own folder).
      let dir = path.dirname(path.join(target.dest, ...rel.split('/')));
      while (dir !== target.dest && inside(dir, target.dest)) {
        try {
          await fs.rmdir(dir);
        } catch {
          break;
        }
        dir = path.dirname(dir);
      }
    }
    await writeManifest(targetId, after);
    Object.assign(target, { lastSyncAt: new Date().toISOString(), lastError: null, fileCount: Object.keys(after).length });
  } catch (err) {
    target.lastError = String(err?.message || err);
  }
  await save();
  return { copied, removed, error: target.lastError };
}

export async function syncProject(projectId) {
  const data = await load();
  const targets = (data.projects[projectId]?.targets || []).filter((t) => t.enabled);
  return Promise.all(targets.map((t) => syncTarget(projectId, t.id)));
}

projectEvents.on('changed', ({ projectId }) => {
  load()
    .then((data) => {
      if (!(data.projects[projectId]?.targets || []).some((t) => t.enabled)) return;
      clearTimeout(timers.get(projectId));
      timers.set(projectId, setTimeout(() => {
        timers.delete(projectId);
        syncProject(projectId).catch((err) => console.warn('sync:', err?.message || err));
      }, DEBOUNCE_MS));
    })
    .catch(() => {});
});
