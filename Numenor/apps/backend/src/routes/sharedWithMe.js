// Projects other people shared with this computer's user. Paste an invite link once; the project then shows
// on the Projects page under "Shared with me", with whether it's reachable right now. The project itself
// stays on the owner's computer — opening it opens the owner's Numenor through their share link.
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { STATE_DIR } from '../config/constants.js';

const FILE = path.join(STATE_DIR, 'shared-with-me.json');

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    return Array.isArray(raw.items) ? raw.items : [];
  } catch {
    return [];
  }
}
function save(items) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(FILE, JSON.stringify({ items }, null, 2), { mode: 0o600 });
}

/** "https://x.ngrok-free.app/collab?token=…" → { origin, token } */
function parseLink(link) {
  try {
    const url = new URL(String(link).trim());
    if (!/^https?:$/.test(url.protocol)) return null;
    const token = url.searchParams.get('token');
    if (!token || !/^op2\.[\w-]+\.[\w-]+$/.test(token)) return null;
    return { origin: url.origin, token };
  } catch {
    return null;
  }
}

/** Asks the owner's Numenor about the invite: { state: 'ok'|'revoked'|'invalid'|'offline', info? } */
async function probe(origin, token) {
  try {
    const res = await fetch(`${origin}/api/collab/resolve?token=${encodeURIComponent(token)}`, {
      signal: AbortSignal.timeout(6000),
      headers: HEADERS
    });
    const data = await res.json().catch(() => null);
    if (!data) return { state: 'offline' };
    if (res.ok && data.ok) return { state: 'ok', info: data };
    if (data.revoked) return { state: 'revoked' };
    if (res.status === 401) return { state: 'invalid' };
    return { state: 'offline' };
  } catch {
    return { state: 'offline' };
  }
}

const HEADERS = { 'ngrok-skip-browser-warning': '1', 'bypass-tunnel-reminder': '1', accept: 'application/json' };
const cleanCode = (value) => String(value || '').toUpperCase().replace(/[^A-Z0-9]/g, '');

/** Trades the saved link + code for a pass on the owner's Numenor: { session } or { error, wrongCode?, offline? } */
async function unlock(origin, token, code) {
  try {
    const res = await fetch(`${origin}/api/collab/unlock`, {
      method: 'POST',
      signal: AbortSignal.timeout(8000),
      headers: { ...HEADERS, 'content-type': 'application/json' },
      body: JSON.stringify({ token, code })
    });
    const data = await res.json().catch(() => null);
    if (!data) return { offline: true, error: 'The owner’s computer isn’t reachable right now.' };
    if (res.ok && data.ok && data.session) return { session: data.session };
    return { error: data.error || 'Couldn’t open the project.', wrongCode: Boolean(data.wrongCode), revoked: Boolean(data.revoked) };
  } catch {
    return { offline: true, error: 'The owner’s computer isn’t reachable right now.' };
  }
}

export function registerSharedWithMeRoutes(fastify) {
  fastify.get('/api/shared-with-me', async () => {
    const items = load();
    const states = await Promise.all(items.map((i) => probe(i.origin, i.token)));
    let changed = false;
    const out = items.map((item, n) => {
      const { state, info } = states[n];
      if (state === 'ok') {
        const next = { ...item, projectName: info.projectName || item.projectName, role: info.role || item.role, owner: info.owner || item.owner, lastOnlineAt: new Date().toISOString() };
        if (next.projectName !== item.projectName || next.role !== item.role || next.owner !== item.owner) changed = true;
        items[n] = next;
      }
      const { token, code, ...rest } = items[n];
      return { ...rest, hasCode: Boolean(code), state, link: `${item.origin}/collab?token=${encodeURIComponent(token)}` };
    });
    if (changed) save(items);
    return { ok: true, items: out };
  });

  fastify.post('/api/shared-with-me', async (req, reply) => {
    const parsed = parseLink(req.body?.link || '');
    if (!parsed) return reply.code(400).send({ ok: false, error: 'Paste the whole invite link (it contains “/collab?token=”).' });
    const code = cleanCode(req.body?.code);
    if (code.length !== 8) return reply.code(400).send({ ok: false, error: 'Enter the 8-character access code that came with the link.' });
    const { state, info } = await probe(parsed.origin, parsed.token);
    if (state === 'revoked') return reply.code(400).send({ ok: false, error: 'This invite was cancelled by the project’s owner.' });
    if (state === 'invalid') return reply.code(400).send({ ok: false, error: 'This invite link isn’t valid.' });
    if (state === 'ok') {
      // Check the code now, so a typo shows up here rather than later.
      const check = await unlock(parsed.origin, parsed.token, code);
      if (!check.session && !check.offline) return reply.code(400).send({ ok: false, error: check.error });
    }
    const items = load();
    const existing = items.find((i) => i.token === parsed.token);
    const item = {
      id: existing?.id || crypto.randomBytes(6).toString('hex'),
      origin: parsed.origin,
      token: parsed.token,
      code,
      projectId: info?.projectId || existing?.projectId || '',
      projectName: info?.projectName || existing?.projectName || 'Shared project',
      role: info?.role || existing?.role || 'edit',
      owner: info?.owner || existing?.owner || '',
      addedAt: existing?.addedAt || new Date().toISOString(),
      lastOnlineAt: state === 'ok' ? new Date().toISOString() : existing?.lastOnlineAt || null
    };
    // A newer link for the same project (e.g. the owner's share address changed) replaces the old one.
    const rest = items.filter((i) => i.token !== parsed.token && !(item.projectId && i.projectId === item.projectId && i.owner === item.owner && i.origin !== parsed.origin && state === 'ok'));
    save([...rest, item]);
    return { ok: true, item: { ...item, token: undefined, code: undefined, hasCode: true, state, link: `${item.origin}/collab?token=${encodeURIComponent(item.token)}` } };
  });

  // Opening a saved project: gets a pass with the saved code, so the person never types it again here.
  fastify.post('/api/shared-with-me/:id/open', async (req, reply) => {
    const item = load().find((i) => i.id === req.params.id);
    if (!item) return reply.code(404).send({ ok: false, error: 'Not found' });
    if (!item.code) return reply.code(400).send({ ok: false, needsCode: true, error: 'Enter the access code for this project once.' });
    const result = await unlock(item.origin, item.token, item.code);
    if (!result.session) {
      return reply.code(result.offline ? 502 : 400).send({ ok: false, needsCode: result.wrongCode, error: result.wrongCode ? 'The saved access code no longer works — the owner may have changed it. Enter the new one.' : result.error });
    }
    return { ok: true, url: `${item.origin}/collab?session=${encodeURIComponent(result.session)}` };
  });

  // Saves a new access code for an item (e.g. the owner changed it).
  fastify.put('/api/shared-with-me/:id/code', async (req, reply) => {
    const items = load();
    const item = items.find((i) => i.id === req.params.id);
    if (!item) return reply.code(404).send({ ok: false, error: 'Not found' });
    const code = cleanCode(req.body?.code);
    if (code.length !== 8) return reply.code(400).send({ ok: false, error: 'The access code has 8 characters.' });
    const check = await unlock(item.origin, item.token, code);
    if (!check.session && !check.offline) return reply.code(400).send({ ok: false, error: check.error });
    save(items.map((i) => (i.id === item.id ? { ...i, code } : i)));
    return { ok: true };
  });

  fastify.delete('/api/shared-with-me/:id', async (req) => {
    save(load().filter((i) => i.id !== req.params.id));
    return { ok: true };
  });
}
