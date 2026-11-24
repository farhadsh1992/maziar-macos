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
let collaborationProjects = new Set();

// The 8-character access code each person types (once in their Numenor, each visit in a browser) on top of
// their link. No I, L, O, 0 or 1, so it can be read out or copied by hand without mix-ups.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
export function newAccessCode() {
  let code = '';
  for (let n = 0; n < 8; n += 1) code += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
  return code;
}
/** "abcd-efgh", " ABCD EFGH " → "ABCDEFGH" */
export function normalizeCode(value) {
  return String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function load() {
  try {
    const mtime = fs.statSync(FILE).mtimeMs;
    if (cache && mtime === cacheMtime) return cache;
    const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    cache = Array.isArray(raw.invites) ? raw.invites : [];
    collaborationProjects = new Set(Array.isArray(raw.collaborationProjects) ? raw.collaborationProjects : []);
    cacheMtime = mtime;
    // Invites made before access codes existed get one now (their links then need it too).
    if (cache.some((i) => !i.code && !i.revokedAt)) save(cache.map((i) => (i.code || i.revokedAt ? i : { ...i, code: newAccessCode() })));
  } catch {
    if (!cache) cache = [];
  }
  return cache;
}

function save(list, projects = collaborationProjects) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = `${FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify({ invites: list, collaborationProjects: [...projects] }, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, FILE);
  cache = list;
  collaborationProjects = projects;
  try { cacheMtime = fs.statSync(FILE).mtimeMs; } catch { /* ignore */ }
}

const publicView = ({ id, projectId, name, email, role, code, createdAt, lastSeenAt, emailedAt }) => ({ id, projectId, name, email, role, code: code || '', createdAt, lastSeenAt: lastSeenAt || null, emailedAt: emailedAt || null });

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
    code: newAccessCode(),
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
    if (changes.newCode) next.code = newAccessCode(); // old code (and passes made with it) stop working
    return next;
  });
  save(list);
  const found = list.find((i) => i.id === id && i.projectId === projectId && !i.revokedAt);
  return found ? publicView(found) : null;
}

/** Remembers when the invite email was last sent, so the Share dialog can show it. */
export function markInviteEmailed(projectId, id) {
  const list = load().map((i) => (i.id === id && i.projectId === projectId && !i.revokedAt ? { ...i, emailedAt: new Date().toISOString() } : i));
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

export function collaborationEnabled(projectId) {
  load();
  return collaborationProjects.has(projectId);
}

export function setCollaborationEnabled(projectId, enabled) {
  const invites = load();
  const projects = new Set(collaborationProjects);
  if (enabled) projects.add(projectId);
  else projects.delete(projectId);
  save(invites, projects);
}

export function effectiveInviteRole(invite) {
  return collaborationEnabled(invite.projectId) ? invite.role : 'view';
}
