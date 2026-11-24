import { catalog } from '../services/ai/catalog.js';
import { cancelInstall, discardInterruptedInstall, installModel, removeModel, stopRuntime } from '../services/ai/localModels.js';
import {
  cancelGeneration, checkApple, configureRemote, getAIStatus, selectProvider, testRemote, uninstall
} from '../services/ai/providers.js';
import { isLocalRequest } from '../utils/authUtils.js';

export function registerAIModelRoutes(fastify) {
  fastify.addHook('preHandler', async (request, reply) => {
    const route = request.routeOptions.url ?? request.url;
    if (!/^\/api\/(?:ai|agent|llm|vision|plot|transfer)(?:[/?]|$)/.test(route)) return;
    const origin = request.headers.origin;
    const sameOrigin = !origin || origin === `http://${request.headers.host}` || origin === `https://${request.headers.host}`;
    if (!isLocalRequest(request) || !sameOrigin || request.headers['sec-fetch-site'] === 'cross-site') {
      return reply.code(403).send({ ok: false, error: 'AI settings and inference are available in the local editor.' });
    }
  });
  fastify.get('/api/ai', () => getAIStatus());
  fastify.post('/api/ai/action', async (req, reply) => {
    const { action, id, provider, ...input } = req.body || {};
    const entry = catalog.find((model) => model.id === id);
    try {
      switch (action) {
        case 'install':
          if (!entry) throw new Error('Unknown model.');
          installModel(entry);
          break;
        case 'remove':
          if (!entry) throw new Error('Unknown model.');
          await uninstall(entry, removeModel);
          break;
        case 'cancel-install': cancelInstall(); break;
        case 'discard-install': await discardInterruptedInstall(); break;
        case 'cancel-generation': cancelGeneration(); break;
        case 'select': await selectProvider(provider, id); break;
        case 'configure': await configureRemote(provider, input); break;
        case 'apple-status': await checkApple(); break;
        case 'test': return { models: await testRemote(provider, input) };
        default: throw new Error('Unknown AI action.');
      }
      return getAIStatus();
    } catch (error) {
      return reply.code(400).send({ error: error.message });
    }
  });
  fastify.addHook('onClose', async () => {
    const pendingInstall = cancelInstall();
    cancelGeneration();
    await Promise.all([pendingInstall, stopRuntime()]);
  });
}
