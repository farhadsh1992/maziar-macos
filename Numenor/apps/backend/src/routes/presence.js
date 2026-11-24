// Who has a project open right now. Every open editor calls this every few seconds with the file it shows;
// the answer lists everyone seen in the last ~25 s (the owner and invited people), so each editor can show
// the others in its top bar — in the same colour as their cursor in the text.
import { collaborationEnabled } from '../services/inviteService.js';
import { OWNER_NAME } from '../config/constants.js';

const STALE_MS = 25 * 1000;
const seen = new Map(); // projectId → Map(key → { key, name, kind, role, file, lastSeen })

function prune(list) {
  const now = Date.now();
  for (const [key, p] of list) if (now - p.lastSeen > STALE_MS) list.delete(key);
}

export function registerPresenceRoutes(fastify) {
  fastify.get('/api/projects/:id/presence', async (req) => {
    const projectId = String(req.params.id);
    const auth = req.collabAuth;
    const me = auth
      ? { key: `invite:${auth.inviteId}`, name: auth.name || 'Guest', kind: 'guest', role: auth.role }
      : { key: 'owner', name: OWNER_NAME, kind: 'owner', role: 'owner' };
    if (!collaborationEnabled(projectId)) {
      seen.delete(projectId);
      return { ok: true, you: me.key, people: [], collaborationEnabled: false, role: me.role };
    }
    let list = seen.get(projectId);
    if (!list) seen.set(projectId, (list = new Map()));
    const file = typeof req.query?.file === 'string' ? req.query.file.slice(0, 500) : '';
    if (req.query?.leave === '1') list.delete(me.key);
    else list.set(me.key, { ...me, file, lastSeen: Date.now() });
    prune(list);
    const people = [...list.values()]
      .sort((a, b) => (a.kind === 'owner' ? -1 : b.kind === 'owner' ? 1 : a.name.localeCompare(b.name)))
      .map(({ key, name, kind, role, file: f, lastSeen }) => ({ key, name, kind, role, file: f, lastSeen: new Date(lastSeen).toISOString() }));
    return { ok: true, you: me.key, people, collaborationEnabled: true, role: me.role };
  });
}
