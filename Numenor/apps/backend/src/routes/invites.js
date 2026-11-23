// People a project is shared with (owner only — on the computer running Numenor).
import { isLocalRequest } from '../utils/authUtils.js';
import { getProjectRoot } from '../services/projectService.js';
import { listInvites, createInvite, revokeInvite, updateInvite } from '../services/inviteService.js';
import { issueToken } from '../services/collab/tokenService.js';
import { disconnectInvite } from '../services/collab/docStore.js';
import { OWNER_NAME } from '../config/constants.js';

const withToken = (invite) => ({ ...invite, token: issueToken({ projectId: invite.projectId, inviteId: invite.id }) });
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function registerInviteRoutes(fastify) {
  fastify.addHook('preHandler', async (req, reply) => {
    if (!/^\/api\/projects\/[^/]+\/invites/.test(req.url) && !req.url.startsWith('/api/shared-with-me')) return;
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
  });

  fastify.get('/api/projects/:id/invites', async (req) => {
    await getProjectRoot(req.params.id);
    return { ok: true, invites: listInvites(req.params.id).map(withToken) };
  });

  fastify.post('/api/projects/:id/invites', async (req, reply) => {
    await getProjectRoot(req.params.id);
    const { name = '', email = '', role = 'edit' } = req.body || {};
    if (email && !EMAIL.test(String(email).trim())) return reply.code(400).send({ ok: false, error: 'That email address doesn’t look right.' });
    if (!String(name).trim() && !String(email).trim()) return reply.code(400).send({ ok: false, error: 'Enter a name or an email.' });
    return { ok: true, invite: withToken(createInvite({ projectId: req.params.id, name, email, role })) };
  });

  fastify.patch('/api/projects/:id/invites/:iid', async (req, reply) => {
    const invite = updateInvite(req.params.id, req.params.iid, req.body || {});
    if (!invite) return reply.code(404).send({ ok: false, error: 'Not found' });
    if (req.body?.role) disconnectInvite(invite.id); // reconnects with the new rights
    return { ok: true, invite: withToken(invite) };
  });

  fastify.delete('/api/projects/:id/invites/:iid', async (req, reply) => {
    if (!revokeInvite(req.params.id, req.params.iid)) return reply.code(404).send({ ok: false, error: 'Not found' });
    disconnectInvite(req.params.iid);
    return { ok: true };
  });

  // Who's asking: the owner here, or an invited person (name + role).
  fastify.get('/api/me', async (req) => {
    if (req.collabAuth) return { ok: true, kind: 'guest', name: req.collabAuth.name, role: req.collabAuth.role, projectId: req.collabAuth.projectId };
    return { ok: true, kind: 'owner', name: OWNER_NAME, role: 'owner' };
  });
}
