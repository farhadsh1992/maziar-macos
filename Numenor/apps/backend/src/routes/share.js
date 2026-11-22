// Turn the public share link on/off. Only the computer running Numenor may do this.
import { isLocalRequest } from '../utils/authUtils.js';
import { shareStatus, startSharing, stopSharing } from '../services/shareService.js';

function localOnly(req, reply) {
  if (isLocalRequest(req)) return true;
  reply.code(403).send({ ok: false, error: 'Sharing can only be changed on the computer running Numenor.' });
  return false;
}

export function registerShareRoutes(fastify) {
  fastify.get('/api/share/status', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    return { ok: true, ...shareStatus() };
  });

  fastify.post('/api/share/start', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const status = await startSharing(req.body?.provider || process.env.NUMENOR_TUNNEL_PROVIDER || 'auto');
    if (!status.active) return reply.code(502).send({ ok: false, ...status });
    return { ok: true, ...status };
  });

  fastify.post('/api/share/stop', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    return { ok: true, ...(await stopSharing()) };
  });
}
