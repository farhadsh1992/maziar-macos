// Version and self-update (see updateService.js). Anyone may read the version; checking GitHub and
// updating only work on the computer running Numenor.
import { isLocalRequest } from '../utils/authUtils.js';
import { applyUpdate, checkForUpdate, currentVersion, restartServer, updateProgress } from '../services/updateService.js';

export function registerUpdateRoutes(fastify) {
  fastify.get('/api/version', async () => ({ ok: true, ...currentVersion(), supervised: process.env.NUMENOR_SUPERVISED === '1' }));

  fastify.get('/api/update/check', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    try {
      return await checkForUpdate({ force: req.query?.force === '1' });
    } catch (err) {
      return reply.code(502).send({ ok: false, error: `Couldn’t reach GitHub: ${err?.message || err}`, current: currentVersion() });
    }
  });

  fastify.get('/api/update/status', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false });
    return { ok: true, ...updateProgress(), current: currentVersion() };
  });

  fastify.post('/api/update/apply', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    return { ok: true, ...applyUpdate({ onRestart: restartServer }) };
  });
}
