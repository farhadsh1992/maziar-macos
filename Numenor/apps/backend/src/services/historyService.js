// A project's change history: who changed which file, when, and how (line diff). Lives inside the project
// (`.numenor-history/`), so it travels with it — e.g. through Google Drive.
//   index.json  — newest last: { id, time, author, kind, action, path, to?, added, removed }
//   <id>.json   — for edits: { before, after }
// Saves come every second or so while someone types, so consecutive edits of one file by one person within
// a few minutes are folded into one entry (its `before` stays, its `after` moves on).
import { promises as fs } from 'fs';
import path from 'path';
import crypto from 'crypto';
import { diffLines } from 'diff';
import { projectChanged } from './projectEvents.js';

export const HISTORY_DIR = '.numenor-history';
const MERGE_WINDOW_MS = 5 * 60 * 1000;
const MAX_ENTRIES = 2000;
const MAX_TEXT = 2 * 1024 * 1024;

const queues = new Map();
/** Runs history writes for one project one at a time. */
function serial(projectRoot, task) {
  const prev = queues.get(projectRoot) || Promise.resolve();
  const next = prev.then(task, task).catch((err) => console.warn('history:', err?.message || err));
  queues.set(projectRoot, next);
  return next;
}

const dirOf = (root) => path.join(root, HISTORY_DIR);

async function readIndex(root) {
  try {
    const raw = JSON.parse(await fs.readFile(path.join(dirOf(root), 'index.json'), 'utf8'));
    return Array.isArray(raw.entries) ? raw.entries : [];
  } catch {
    return [];
  }
}

async function writeIndex(root, entries) {
  await fs.mkdir(dirOf(root), { recursive: true });
  const file = path.join(dirOf(root), 'index.json');
  await fs.writeFile(`${file}.tmp`, JSON.stringify({ entries }), 'utf8');
  await fs.rename(`${file}.tmp`, file);
}

function countLines(before, after) {
  let added = 0;
  let removed = 0;
  for (const part of diffLines(before, after)) {
    if (part.added) added += part.count || 0;
    else if (part.removed) removed += part.count || 0;
  }
  return { added, removed };
}

async function prune(root, entries) {
  if (entries.length <= MAX_ENTRIES) return entries;
  const drop = entries.slice(0, entries.length - MAX_ENTRIES);
  for (const e of drop) await fs.rm(path.join(dirOf(root), `${e.id}.json`), { force: true }).catch(() => {});
  return entries.slice(-MAX_ENTRIES);
}

const newId = () => `${Date.now().toString(36)}-${crypto.randomBytes(4).toString('hex')}`;

/** author: { name, kind: 'owner' | 'guest', id? } */
export function recordEdit(projectRoot, filePath, before, after, author) {
  if (before === after || typeof after !== 'string') return Promise.resolve();
  projectChanged(projectRoot);
  if ((before?.length || 0) > MAX_TEXT || after.length > MAX_TEXT) return Promise.resolve();
  return serial(projectRoot, async () => {
    let entries = await readIndex(projectRoot);
    const last = entries[entries.length - 1];
    const now = Date.now();
    if (last && last.action === 'edit' && last.path === filePath && last.author === author.name && last.kind === author.kind
      && now - Date.parse(last.time) < MERGE_WINDOW_MS) {
      const blobPath = path.join(dirOf(projectRoot), `${last.id}.json`);
      let start = before ?? '';
      try { start = JSON.parse(await fs.readFile(blobPath, 'utf8')).before ?? start; } catch { /* keep */ }
      if (start === after) {
        // Typed and then undone: nothing left to show.
        entries.pop();
        await fs.rm(blobPath, { force: true });
      } else {
        await fs.writeFile(blobPath, JSON.stringify({ before: start, after }), 'utf8');
        Object.assign(last, { time: new Date(now).toISOString(), ...countLines(start, after) });
      }
      await writeIndex(projectRoot, entries);
      return;
    }
    const id = newId();
    await fs.mkdir(dirOf(projectRoot), { recursive: true });
    await fs.writeFile(path.join(dirOf(projectRoot), `${id}.json`), JSON.stringify({ before: before ?? '', after }), 'utf8');
    entries.push({ id, time: new Date(now).toISOString(), author: author.name, kind: author.kind, action: before == null ? 'create' : 'edit', path: filePath, ...countLines(before ?? '', after) });
    entries = await prune(projectRoot, entries);
    await writeIndex(projectRoot, entries);
  });
}

/** Non-text events: 'upload' | 'delete' | 'rename' | 'folder'. */
export function recordEvent(projectRoot, action, filePath, author, extra = {}) {
  projectChanged(projectRoot);
  return serial(projectRoot, async () => {
    let entries = await readIndex(projectRoot);
    entries.push({ id: newId(), time: new Date().toISOString(), author: author.name, kind: author.kind, action, path: filePath, added: 0, removed: 0, ...extra });
    entries = await prune(projectRoot, entries);
    await writeIndex(projectRoot, entries);
  });
}

export async function listHistory(projectRoot, { limit = 500, file = '' } = {}) {
  let entries = await readIndex(projectRoot);
  if (file) entries = entries.filter((e) => e.path === file || e.to === file);
  return entries.slice(-limit).reverse();
}

export async function getHistoryEntry(projectRoot, id) {
  if (!/^[a-z0-9]+-[0-9a-f]{8}$/.test(id)) return null;
  const entry = (await readIndex(projectRoot)).find((e) => e.id === id);
  if (!entry) return null;
  let parts = [];
  try {
    const { before, after } = JSON.parse(await fs.readFile(path.join(dirOf(projectRoot), `${id}.json`), 'utf8'));
    parts = diffLines(before ?? '', after ?? '').map((p) => ({ value: p.value, added: Boolean(p.added), removed: Boolean(p.removed) }));
  } catch { /* events have no diff */ }
  return { entry, parts };
}

/** The file's text after an entry (for "Restore this version"). */
export async function getEntryText(projectRoot, id, which = 'after') {
  if (!/^[a-z0-9]+-[0-9a-f]{8}$/.test(id)) return null;
  try {
    const blob = JSON.parse(await fs.readFile(path.join(dirOf(projectRoot), `${id}.json`), 'utf8'));
    return which === 'before' ? blob.before : blob.after;
  } catch {
    return null;
  }
}

/** Who made a request: an invited person (by their invite's name) or the owner of this computer. */
export function authorOf(req, ownerName) {
  if (req?.collabAuth?.inviteId) return { name: req.collabAuth.name || 'Guest', kind: 'guest', id: req.collabAuth.inviteId };
  return { name: ownerName, kind: 'owner' };
}
