// Maziar: spelling and grammar checking through macOS's own checker (NSSpellChecker).
//
// Maziar ships a tiny helper executable (`MaziarSpell`) and passes its path in MAZIAR_SPELL_HELPER.
// The helper stays running and answers one JSON request per line, so checks are fast and the text never
// leaves the Mac. Without Maziar (plain Numenor) the routes answer 503 and the editor hides the feature.
import { spawn } from 'child_process';
import { existsSync } from 'fs';
import readline from 'readline';

let helper = null;
let nextId = 1;
const pending = new Map();

function helperPath() {
  const p = process.env.MAZIAR_SPELL_HELPER;
  return p && existsSync(p) ? p : '';
}

function ensureHelper() {
  if (helper) return helper;
  const bin = helperPath();
  if (!bin) return null;
  const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'ignore'] });
  const rl = readline.createInterface({ input: child.stdout });
  rl.on('line', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    const entry = pending.get(msg.id);
    if (!entry) return;
    pending.delete(msg.id);
    clearTimeout(entry.timer);
    entry.resolve(msg);
  });
  const fail = (reason) => {
    if (helper === child) helper = null;
    for (const [key, entry] of pending) {
      clearTimeout(entry.timer);
      entry.reject(new Error(reason));
      pending.delete(key);
    }
  };
  child.on('exit', () => fail('spell helper exited'));
  child.on('error', (err) => fail(err.message));
  helper = child;
  return child;
}

function ask(payload, timeoutMs = 15000) {
  const child = ensureHelper();
  if (!child) return Promise.reject(Object.assign(new Error('Spell checking is available when Numenor runs inside Maziar.'), { statusCode: 503 }));
  const id = nextId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('spell helper timed out'));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(`${JSON.stringify({ ...payload, id })}\n`);
  });
}

async function answer(reply, payload) {
  try {
    const res = await ask(payload);
    if (res.error) return reply.code(400).send({ ok: false, error: res.error });
    return { ok: true, ...res, id: undefined };
  } catch (err) {
    return reply.code(err.statusCode || 500).send({ ok: false, error: err.message || String(err) });
  }
}

export function registerSpellRoutes(fastify) {
  fastify.get('/api/spell/status', async () => ({ ok: true, available: Boolean(helperPath()) }));

  fastify.get('/api/spell/languages', async (req, reply) => answer(reply, { op: 'languages' }));

  fastify.post('/api/spell/check', async (req, reply) => {
    const { text = '', language = 'en', grammar = true } = req.body || {};
    if (typeof text !== 'string' || text.length > 2_000_000) {
      return reply.code(400).send({ ok: false, error: 'Text missing or too long.' });
    }
    return answer(reply, { op: 'check', text, language, grammar: Boolean(grammar) });
  });

  fastify.post('/api/spell/learn', async (req, reply) => {
    const { word = '' } = req.body || {};
    if (!word) return reply.code(400).send({ ok: false, error: 'Missing word.' });
    return answer(reply, { op: 'learn', word: String(word) });
  });
}
