// Turn the public share link on/off. Only the computer running Numenor may do this.
import { isLocalRequest } from '../utils/authUtils.js';
import { normalizeDomain, setFixedDomain, shareStatus, startSharing, stopSharing } from '../services/shareService.js';

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

  // The fixed ngrok address ('' turns it off). Restarts sharing if it's on.
  fastify.put('/api/share/settings', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    const domain = normalizeDomain(req.body?.ngrokDomain);
    if (domain === null) return reply.code(400).send({ ok: false, error: 'That doesn’t look like an address — it should look like something.ngrok-free.app' });
    const status = await setFixedDomain(domain, process.env.NUMENOR_TUNNEL_PROVIDER || 'auto');
    if (status.error && !('active' in status)) return reply.code(400).send({ ok: false, error: status.error });
    return { ok: true, ...status };
  });

  fastify.post('/api/share/stop', async (req, reply) => {
    if (!localOnly(req, reply)) return reply;
    return { ok: true, ...(await stopSharing()) };
  });
}
