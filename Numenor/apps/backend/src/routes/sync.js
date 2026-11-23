// "Keep a copy in…" (see syncService.js). Only the computer running Numenor may change where its projects
// are copied — never someone who joined through an invite link.
import { isLocalRequest } from '../utils/authUtils.js';
import { addTarget, listTargets, removeTarget, syncProject, updateTarget } from '../services/syncService.js';

function localOnly(req, reply) {
  if (isLocalRequest(req)) return true;
  reply.code(403).send({ ok: false, error: 'Copies can only be set up on the computer running Numenor.' });
  return false;
}

const fail = (reply, err) => reply.code(400).send({ ok: false, error: String(err?.message || err) });

export function registerSyncRoutes(fastify) {
  fastify.get('/api/sync/:projectId', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    return { ok: true, targets: await listTargets(req.params.projectId) };
  });

  fastify.post('/api/sync/:projectId', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    try {
      const target = await addTarget(req.params.projectId, {
        parent: req.body?.parent,
        includePdf: req.body?.includePdf !== false,
        useFolderAsIs: Boolean(req.body?.useFolderAsIs)
      });
      return { ok: true, target, targets: await listTargets(req.params.projectId) };
    } catch (err) {
      return fail(reply, err);
    }
  });

  fastify.patch('/api/sync/:projectId/:targetId', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    try {
      await updateTarget(req.params.projectId, req.params.targetId, req.body || {});
      return { ok: true, targets: await listTargets(req.params.projectId) };
    } catch (err) {
      return fail(reply, err);
    }
  });

  fastify.delete('/api/sync/:projectId/:targetId', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    await removeTarget(req.params.projectId, req.params.targetId);
    return { ok: true, targets: await listTargets(req.params.projectId) };
  });

  fastify.post('/api/sync/:projectId/now', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    await syncProject(req.params.projectId);
    return { ok: true, targets: await listTargets(req.params.projectId) };
  });
}
