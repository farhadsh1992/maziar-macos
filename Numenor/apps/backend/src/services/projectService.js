import { promises as fs } from 'fs';
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

export async function getProjectRoot(id) {
  if (!isPlainId(id)) throw new Error('Invalid project id');
  for (const folder of await getProjectFolders()) {
    const projectRoot = path.join(folder, id);
    try {
      await fs.access(path.join(projectRoot, 'project.json'));
      return projectRoot;
    } catch {
      /* not in this folder */
    }
  }
  const err = new Error(`Project not found: ${id}`);
  err.code = 'ENOENT';
  throw err;
}
