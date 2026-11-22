// Must run before anything reads process.env.
import './config/envCompat.js';
import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import websocket from '@fastify/websocket';
import { ensureDir } from './utils/fsUtils.js';
import { DATA_DIR, PORT, TUNNEL_MODE } from './config/constants.js';
import { registerHealthRoutes } from './routes/health.js';
import { registerArxivRoutes } from './routes/arxiv.js';
import { registerProjectRoutes } from './routes/projects.js';
import { registerCompileRoutes } from './routes/compile.js';
import { registerLLMRoutes } from './routes/llm.js';
import { registerVisionRoutes } from './routes/vision.js';
import { registerPlotRoutes } from './routes/plot.js';
import { registerAgentRoutes } from './routes/agent.js';
import { registerCollabRoutes } from './routes/collab.js';
import { registerTransferRoutes } from './routes/transfer.js';
import { registerSynctexRoutes } from './routes/synctex.js';
import { registerSpellRoutes } from './routes/spell.js';
import { registerFolderRoutes } from './routes/folders.js';
import { registerShareRoutes } from './routes/share.js';
import { setSharePort, startSharing } from './services/shareService.js';
import { requireAuthIfRemote, remoteRequestAllowed } from './utils/authUtils.js';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';

const fastify = Fastify({ logger: true });

await fastify.register(cors, { origin: true });
await fastify.register(multipart, {
  limits: {
    fileSize: 200 * 1024 * 1024
  }
});
await fastify.register(websocket);
fastify.decorateRequest('collabAuth', null);

fastify.addHook('preHandler', async (req, reply) => {
  if (!req.url.startsWith('/api')) return;
  if (req.method === 'OPTIONS') return;
  if (req.url.startsWith('/api/health')) return;
  if (req.url.startsWith('/api/collab')) return; // token-checked in the collab routes themselves
  const auth = requireAuthIfRemote(req);
  if (!auth.ok) {
    return reply.code(401).send({ ok: false, error: 'This needs a valid invite link.' });
  }
  // An invited visitor only gets the invited project (see remoteRequestAllowed).
  if (auth.payload && !remoteRequestAllowed(req, auth.payload)) {
    return reply.code(403).send({ ok: false, error: 'Not available through an invite link.' });
  }
  req.collabAuth = auth.payload || null;
});

registerHealthRoutes(fastify);
registerArxivRoutes(fastify);
registerProjectRoutes(fastify);
registerCompileRoutes(fastify);
registerLLMRoutes(fastify);
registerVisionRoutes(fastify);
registerPlotRoutes(fastify);
registerAgentRoutes(fastify);
registerCollabRoutes(fastify);
registerTransferRoutes(fastify);
registerSynctexRoutes(fastify);
registerSpellRoutes(fastify);
registerFolderRoutes(fastify);
registerShareRoutes(fastify);

// Serve frontend static files in tunnel/production mode
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const frontendDist = join(__dirname, '../../frontend/dist');

if (existsSync(frontendDist)) {
  const fastifyStatic = await import('@fastify/static');
  await fastify.register(fastifyStatic.default, {
    root: frontendDist,
    prefix: '/',
    wildcard: false,
  });

  // SPA fallback: serve index.html for non-API routes
  fastify.setNotFoundHandler((req, reply) => {
    if (req.url.startsWith('/api')) {
      reply.code(404).send({ error: 'Not Found' });
    } else {
      reply.sendFile('index.html');
    }
  });
}

await ensureDir(DATA_DIR);

// NUMENOR_HOST=127.0.0.1 keeps the editor reachable from this computer only (Maziar does that);
// the default listens on every interface so collaborators on the network can join.
await fastify.listen({ port: PORT, host: process.env.NUMENOR_HOST || '0.0.0.0' });

console.log('');
console.log(`  Numenor started at http://localhost:${PORT}`);
console.log('');

setSharePort(PORT);
const tunnelMode = TUNNEL_MODE.toLowerCase().trim();
if (tunnelMode !== 'false' && tunnelMode !== '0' && tunnelMode !== 'no') {
  console.log('  Starting a share link...');
  const status = await startSharing(tunnelMode);
  if (status.active) {
    console.log(`  Public URL (${status.provider}): ${status.url}`);
    console.log('  Invite people from a project\'s Collab tab — the URL alone opens nothing.');
  } else {
    console.log(`  ${status.error}`);
  }
  console.log('');
} else {
  console.log('  Share a project from its Collab tab ("Share this project"), or start with');
  console.log('  NUMENOR_TUNNEL=auto npm start (Cloudflare, ngrok or localtunnel).');
  console.log('');
}
