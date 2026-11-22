// Project folders: which folders Numenor keeps projects in (the main one plus any added ones, e.g. inside
// Google Drive), and a small folder browser for choosing one.
//
// These routes touch the computer's file system outside the projects, so they only answer requests
// made on this computer — never collaborators joining through an invite link or a tunnel.
import { promises as fs, existsSync } from 'fs';
import os from 'os';
import path from 'path';
import { DATA_DIR, TUNNEL_MODE } from '../config/constants.js';
import { getClientIp, isLocalAddress } from '../utils/authUtils.js';
import { expandHome, getExtraFolders, setExtraFolders, getProjectFolders } from '../services/projectService.js';

function isThisComputer(req) {
  const tunnelActive = !['false', '0', 'no'].includes(String(TUNNEL_MODE).toLowerCase().trim());
  if (tunnelActive) return false; // behind a tunnel every request looks local
  if (req.headers?.['x-forwarded-for']) return false;
  return isLocalAddress(getClientIp(req));
}

function localOnly(req, reply) {
  if (isThisComputer(req)) return true;
  reply.code(403).send({ ok: false, error: 'Project folders can only be changed on the computer running Numenor.' });
  return false;
}

async function countProjects(folder) {
  try {
    const entries = await fs.readdir(folder, { withFileTypes: true });
    let n = 0;
    for (const entry of entries) {
      if (entry.isDirectory() && existsSync(path.join(folder, entry.name, 'project.json'))) n += 1;
    }
    return n;
  } catch {
    return 0;
  }
}

/** Cloud and common folders on this computer, offered as shortcuts in the folder browser. */
async function suggestions() {
  const home = os.homedir();
  const found = [];
  const add = (label, p, kind) => {
    if (p && existsSync(p)) found.push({ label, path: p, kind });
  };
  const cloud = path.join(home, 'Library', 'CloudStorage');
  try {
    for (const name of await fs.readdir(cloud)) {
      const base = path.join(cloud, name);
      if (name.startsWith('GoogleDrive-')) {
        const account = name.slice('GoogleDrive-'.length);
        const myDrive = ['My Drive', 'Min disk', 'Mon Drive', 'Mi unidad', 'Meine Ablage'].map((d) => path.join(base, d)).find(existsSync);
        add(`Google Drive (${account})`, myDrive || base, 'google');
      } else if (name.startsWith('Dropbox')) {
        add('Dropbox', base, 'dropbox');
      } else if (name.startsWith('OneDrive')) {
        add(name.replace(/^OneDrive-?/, 'OneDrive ').trim(), base, 'onedrive');
      }
    }
  } catch {
    /* no CloudStorage folder (not macOS, or nothing installed) */
  }
  add('iCloud Drive', path.join(home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs'), 'icloud');
  add('Google Drive', path.join(home, 'Google Drive'), 'google'); // older Drive for desktop / Linux setups
  add('Documents', path.join(home, 'Documents'), 'folder');
  add('Home', home, 'folder');
  // De-duplicate by path, keeping the first (most specific) label.
  return found.filter((item, i) => found.findIndex((o) => o.path === item.path) === i);
}

async function describe() {
  const folders = [];
  for (const folder of await getProjectFolders()) {
    folders.push({
      path: folder,
      primary: path.resolve(folder) === path.resolve(DATA_DIR),
      exists: existsSync(folder),
      projectCount: await countProjects(folder),
      cloud: /CloudStorage\/GoogleDrive-|\/Google Drive\//.test(folder) ? 'google' : null
    });
  }
  return { ok: true, primary: DATA_DIR, folders };
}

export function registerFolderRoutes(fastify) {
  fastify.get('/api/folders', async () => describe());

  fastify.get('/api/folders/suggestions', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    return { ok: true, suggestions: await suggestions(), home: os.homedir() };
  });

  fastify.post('/api/folders', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const raw = String(req.body?.path || '').trim();
    if (!raw) return reply.code(400).send({ ok: false, error: 'Choose a folder.' });
    const folder = path.resolve(expandHome(raw));
    let stat;
    try {
      stat = await fs.stat(folder);
    } catch {
      return reply.code(400).send({ ok: false, error: `${folder} doesn't exist.` });
    }
    if (!stat.isDirectory()) return reply.code(400).send({ ok: false, error: `${folder} isn't a folder.` });
    if (path.resolve(folder) === path.resolve(DATA_DIR)) {
      return reply.code(400).send({ ok: false, error: 'That is already the main projects folder.' });
    }
    // A folder that is itself a project (or sits inside the main folder) would show projects twice.
    if (existsSync(path.join(folder, 'project.json')) || folder.startsWith(path.resolve(DATA_DIR) + path.sep)) {
      return reply.code(400).send({ ok: false, error: 'Pick the folder that contains projects, not a project or a folder inside the main projects folder.' });
    }
    try {
      await fs.access(folder, fs.constants?.W_OK ?? 2);
    } catch {
      return reply.code(400).send({ ok: false, error: `Numenor can't write to ${folder}.` });
    }
    const extra = await getExtraFolders();
    if (!extra.some((f) => path.resolve(f) === folder)) await setExtraFolders([...extra, folder]);
    return describe();
  });

  fastify.delete('/api/folders', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const folder = path.resolve(expandHome(String(req.query?.path || '')));
    if (folder === path.resolve(DATA_DIR)) return reply.code(400).send({ ok: false, error: 'The main projects folder can’t be removed.' });
    // Only forgets the folder — the projects in it stay on disk untouched.
    await setExtraFolders((await getExtraFolders()).filter((f) => path.resolve(f) !== folder));
    return describe();
  });

  fastify.get('/api/folders/browse', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const target = path.resolve(expandHome(String(req.query?.path || os.homedir())));
    let entries;
    try {
      entries = await fs.readdir(target, { withFileTypes: true });
    } catch (err) {
      return reply.code(400).send({ ok: false, error: `Can't open ${target}: ${err.code || err.message}` });
    }
    const dirs = [];
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const full = path.join(target, entry.name);
      let isDir = entry.isDirectory();
      if (!isDir && entry.isSymbolicLink()) {
        try { isDir = (await fs.stat(full)).isDirectory(); } catch { isDir = false; }
      }
      if (!isDir) continue;
      dirs.push({ name: entry.name, path: full, isProject: existsSync(path.join(full, 'project.json')) });
    }
    dirs.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
    const parent = path.dirname(target);
    return {
      ok: true,
      path: target,
      parent: parent !== target ? parent : null,
      entries: dirs,
      projectCount: dirs.filter((d) => d.isProject).length
    };
  });

  fastify.post('/api/folders/mkdir', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const parent = path.resolve(expandHome(String(req.body?.parent || '')));
    const name = String(req.body?.name || '').trim();
    if (!name || name.includes('/') || name.includes('\\') || name === '.' || name === '..') {
      return reply.code(400).send({ ok: false, error: 'Give the new folder a plain name.' });
    }
    const full = path.join(parent, name);
    try {
      await fs.mkdir(full);
    } catch (err) {
      return reply.code(400).send({ ok: false, error: err.code === 'EEXIST' ? `${name} already exists.` : String(err.message || err) });
    }
    return { ok: true, path: full };
  });
}
