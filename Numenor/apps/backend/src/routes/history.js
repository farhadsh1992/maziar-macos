// A project's change history (see historyService.js). Invited people can read it too; restoring needs
// edit rights (view-only people can't call non-GET routes at all — see remoteRequestAllowed).
import { promises as fs } from 'fs';
import { getProjectRoot } from '../services/projectService.js';
import { listHistory, getHistoryEntry, getEntryText, recordEdit, authorOf } from '../services/historyService.js';
import { safeJoin } from '../utils/pathUtils.js';
import { OWNER_NAME } from '../config/constants.js';
import { reloadDocFromDisk } from '../services/collab/docStore.js';

export function registerHistoryRoutes(fastify) {
  fastify.get('/api/projects/:id/history', async (req) => {
    const root = await getProjectRoot(req.params.id);
    const limit = Math.min(Number(req.query?.limit) || 500, 2000);
    return { ok: true, entries: await listHistory(root, { limit, file: String(req.query?.file || '') }) };
  });

  fastify.get('/api/projects/:id/history/:hid', async (req, reply) => {
    const root = await getProjectRoot(req.params.id);
    const found = await getHistoryEntry(root, req.params.hid);
    if (!found) return reply.code(404).send({ ok: false, error: 'Not found' });
    return { ok: true, ...found };
  });

  /** Puts a file back the way it was after (or before) a change. The restore is itself recorded. */
  fastify.post('/api/projects/:id/history/:hid/restore', async (req, reply) => {
    const { id, hid } = req.params;
    const root = await getProjectRoot(id);
    const found = await getHistoryEntry(root, hid);
    const which = req.body?.which === 'before' ? 'before' : 'after';
    const text = found ? await getEntryText(root, hid, which) : null;
    if (!found || text == null) return reply.code(404).send({ ok: false, error: 'Nothing to restore' });
    const abs = safeJoin(root, found.entry.path);
    let current = null;
    try { current = await fs.readFile(abs, 'utf8'); } catch { /* gone */ }
    await fs.writeFile(abs, text, 'utf8');
    await recordEdit(root, found.entry.path, current, text, authorOf(req, OWNER_NAME));
    await reloadDocFromDisk(`${id}:${found.entry.path}`);
    return { ok: true, path: found.entry.path };
  });
}
