// Email setup for sending invites (owner only — on the computer running Numenor).
import { isLocalRequest } from '../utils/authUtils.js';
import { clearMailSettings, mailStatus, saveMailSettings, sendMail } from '../services/mailService.js';

export function registerMailRoutes(fastify) {
  fastify.addHook('preHandler', async (req, reply) => {
    if (!req.url.startsWith('/api/mail')) return;
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
  });

  fastify.get('/api/mail/settings', async () => ({ ok: true, ...mailStatus() }));

  fastify.put('/api/mail/settings', async (req, reply) => {
    const result = await saveMailSettings(req.body || {});
    if (result.error) return reply.code(400).send({ ok: false, error: result.error });
    return { ok: true, ...result };
  });

  fastify.delete('/api/mail/settings', async () => ({ ok: true, ...clearMailSettings() }));

  // Sends a short test message to your own address.
  fastify.post('/api/mail/test', async (req, reply) => {
    const status = mailStatus();
    if (!status.configured) return reply.code(400).send({ ok: false, error: 'Set up email first.' });
    const result = await sendMail({
      to: status.user,
      subject: 'Numenor test email',
      text: 'Numenor can send invite emails from this account.'
    });
    if (result.error) return reply.code(502).send({ ok: false, error: result.error });
    return { ok: true };
  });
}
