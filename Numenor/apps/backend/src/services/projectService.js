import { promises as fs, existsSync } from 'fs';
import os from 'os';
import path from 'path';
import { DATA_DIR } from '../config/constants.js';

// Projects can live in more than one folder: the main one (DATA_DIR) plus any folders the user adds on
// the Projects page — e.g. one inside Google Drive. The list is per computer and stored next to the
// projects, in DATA_DIR/.numenor-folders.json. A project is any sub-folder holding a project.json.
const FOLDERS_FILE = () => path.join(DATA_DIR, '.numenor-folders.json');

export function expandHome(p) {
  if (!p) return p;
  if (p === '~') return os.homedir();
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

export async function getExtraFolders() {
  try {
    const raw = JSON.parse(await fs.readFile(FOLDERS_FILE(), 'utf8'));
    return Array.isArray(raw.folders) ? raw.folders.filter((f) => typeof f === 'string' && path.isAbsolute(f)) : [];
  } catch {
    return [];
  }
}

export async function setExtraFolders(folders) {
  await fs.mkdir(DATA_DIR, { recursive: true });
  const unique = [...new Set(folders.map((f) => path.resolve(f)))];
  await fs.writeFile(FOLDERS_FILE(), JSON.stringify({ folders: unique }, null, 2));
  return unique;
}

/** The main folder first, then the added ones. */
export async function getProjectFolders() {
  return [DATA_DIR, ...(await getExtraFolders()).filter((f) => path.resolve(f) !== path.resolve(DATA_DIR))];
}

/** Where a new project goes: the requested folder if it's one of the project folders, else the main one. */
export async function resolveTargetFolder(folder) {
  if (!folder) return DATA_DIR;
  const wanted = path.resolve(expandHome(String(folder)));
  const folders = await getProjectFolders();
  return folders.find((f) => path.resolve(f) === wanted) || DATA_DIR;
}

function isPlainId(id) {
  return typeof id === 'string' && id.length > 0 && !id.includes('/') && !id.includes('\\') && id !== '.' && id !== '..';
}

/** The newest modification time inside a project (its files and history; not the build folder). */
async function latestChange(projectRoot) {
  let latest = 0;
  let seen = 0;
  const walk = async (dir) => {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (seen > 3000) return;
      if (entry.name === '.compile' || entry.name === 'node_modules' || entry.name === '.git') continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else {
        seen += 1;
        try {
          latest = Math.max(latest, (await fs.stat(full)).mtimeMs);
        } catch {
          /* vanished */
        }
      }
    }
  };
  await walk(projectRoot);
  return latest;
}

const rootCache = new Map(); // id → { at, root, copies }
/** Forget which copy of each project is newest (the ↻ button on the Projects page). */
export function clearProjectCache() {
  rootCache.clear();
}
const ROOT_CACHE_MS = 15000;

/**
 * Every folder holding this project, newest first. The same project can be in two project folders — e.g. an
 * old copy in this computer's own folder (put there by an earlier sync) and the live one in a Google Drive
 * folder that another computer keeps editing. The most recently changed copy is the one to use.
 */
export async function getProjectCopies(id) {
  if (!isPlainId(id)) throw new Error('Invalid project id');
  const cached = rootCache.get(id);
  if (cached && Date.now() - cached.at < ROOT_CACHE_MS
    && cached.copies.every((c) => existsSync(path.join(c.root, 'project.json')))) return cached.copies;
  const found = [];
  for (const folder of await getProjectFolders()) {
    const projectRoot = path.join(folder, id);
    try {
      await fs.access(path.join(projectRoot, 'project.json'));
      found.push(projectRoot);
    } catch {
      /* not in this folder */
    }
  }
  let copies = found.map((root) => ({ root, latest: 0 }));
  if (found.length > 1) {
    copies = await Promise.all(found.map(async (root) => ({ root, latest: await latestChange(root) })));
    copies.sort((a, b) => b.latest - a.latest);
  }
  // Only copies in several folders are worth remembering (comparing them reads every file's date).
  if (copies.length > 1) rootCache.set(id, { at: Date.now(), copies });
  else rootCache.delete(id);
  return copies;
}

export async function getProjectRoot(id) {
  const copies = await getProjectCopies(id);
  if (copies.length) return copies[0].root;
  const err = new Error(`Project not found: ${id}`);
  err.code = 'ENOENT';
  throw err;
}
