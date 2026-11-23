// The people a project is shared with. Each invite is one person (name + optional email) with a role —
// 'edit' or 'view' — and its own link. Removing an invite revokes that link at once, including any editor
// the person has open. Stored per computer in STATE_DIR/invites.json, never next to the projects.
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { STATE_DIR } from '../config/constants.js';

const FILE = path.join(STATE_DIR, 'invites.json');
let cache = null;
let cacheMtime = 0;

function load() {
  try {
    const mtime = fs.statSync(FILE).mtimeMs;
    if (cache && mtime === cacheMtime) return cache;
    const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    cache = Array.isArray(raw.invites) ? raw.invites : [];
    cacheMtime = mtime;
  } catch {
    if (!cache) cache = [];
  }
  return cache;
}

function save(list) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = `${FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify({ invites: list }, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, FILE);
  cache = list;
  try { cacheMtime = fs.statSync(FILE).mtimeMs; } catch { /* ignore */ }
}

const publicView = ({ id, projectId, name, email, role, createdAt, lastSeenAt }) => ({ id, projectId, name, email, role, createdAt, lastSeenAt: lastSeenAt || null });

export function listInvites(projectId) {
  return load().filter((i) => i.projectId === projectId && !i.revokedAt).map(publicView);
}

export function createInvite({ projectId, name, email, role }) {
  const invite = {
    id: crypto.randomBytes(9).toString('base64url'),
    projectId,
    name: String(name || '').trim().slice(0, 80) || String(email || '').split('@')[0] || 'Guest',
    email: String(email || '').trim().slice(0, 200),
    role: role === 'view' ? 'view' : 'edit',
    createdAt: new Date().toISOString(),
    lastSeenAt: null,
    revokedAt: null
  };
  save([...load(), invite]);
  return publicView(invite);
}

export function updateInvite(projectId, id, changes) {
  const list = load().map((i) => {
    if (i.id !== id || i.projectId !== projectId || i.revokedAt) return i;
    const next = { ...i };
    if (changes.role) next.role = changes.role === 'view' ? 'view' : 'edit';
    if (typeof changes.name === 'string' && changes.name.trim()) next.name = changes.name.trim().slice(0, 80);
    return next;
  });
  save(list);
  const found = list.find((i) => i.id === id && i.projectId === projectId && !i.revokedAt);
  return found ? publicView(found) : null;
}

/** Revoked invites stay on file (marked) so an old link can say "access removed" rather than "invalid". */
export function revokeInvite(projectId, id) {
  let hit = false;
  save(load().map((i) => {
    if (i.id !== id || i.projectId !== projectId || i.revokedAt) return i;
    hit = true;
    return { ...i, revokedAt: new Date().toISOString() };
  }));
  return hit;
}

/** The live (not revoked) invite, or null. Synchronous: token checks run on every request. */
export function getActiveInvite(id) {
  const invite = load().find((i) => i.id === id);
  return invite && !invite.revokedAt ? invite : null;
}

export function isRevoked(id) {
  return Boolean(load().find((i) => i.id === id)?.revokedAt);
}

const touchPending = new Map();
let touchTimer = null;
/** Remembers when the person last used their link (written at most every 30 s). */
export function touchInvite(id) {
  touchPending.set(id, new Date().toISOString());
  if (touchTimer) return;
  touchTimer = setTimeout(() => {
    touchTimer = null;
    const seen = new Map(touchPending);
    touchPending.clear();
    try {
      save(load().map((i) => (seen.has(i.id) ? { ...i, lastSeenAt: seen.get(i.id) } : i)));
    } catch { /* ignore */ }
  }, 30_000);
}
