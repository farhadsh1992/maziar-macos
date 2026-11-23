// Maziar: spelling and grammar checking through macOS's own checker (NSSpellChecker).
//
// Maziar ships a tiny helper executable (`MaziarSpell`) and passes its path in MAZIAR_SPELL_HELPER.
// The helper stays running and answers one JSON request per line, so checks are fast and the text never
// leaves the Mac. Without Maziar (plain Numenor) the routes answer 503 and the editor hides the feature.
import { spawn } from 'child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import path from 'path';
import readline from 'readline';
import { STATE_DIR } from '../config/constants.js';
import { isLocalRequest } from '../utils/authUtils.js';

// Spelling vocabulary: words you've told Numenor are correct. Kept on this computer (not in the browser,
// whose storage changes with the server's port), and taken out of every check's results.
const VOCAB_FILE = path.join(STATE_DIR, 'spell-vocabulary.json');

function readVocabulary() {
  try {
    const words = JSON.parse(readFileSync(VOCAB_FILE, 'utf8'));
    return Array.isArray(words) ? words.filter((w) => typeof w === 'string') : [];
  } catch {
    return [];
  }
}

function writeVocabulary(words) {
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  const unique = [...new Set(words.map((w) => w.trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
  writeFileSync(VOCAB_FILE, JSON.stringify(unique, null, 2));
  return unique;
}

const cleanWord = (value) => String(value || '').trim().slice(0, 80);

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
    const result = await answer(reply, { op: 'check', text, language, grammar: Boolean(grammar) });
    if (result && result.ok && Array.isArray(result.issues)) {
      const known = new Set(readVocabulary().map((w) => w.toLowerCase()));
      if (known.size) result.issues = result.issues.filter((issue) => !(issue.kind === 'spelling' && known.has(String(issue.word || '').toLowerCase())));
    }
    return result;
  });

  fastify.get('/api/spell/vocabulary', async () => ({ ok: true, words: readVocabulary() }));

  // Only the computer running Numenor changes the vocabulary (invited people keep theirs in their browser).
  fastify.post('/api/spell/vocabulary', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    const word = cleanWord(req.body?.word);
    if (!word) return reply.code(400).send({ ok: false, error: 'Missing word.' });
    const words = writeVocabulary([...readVocabulary(), word]);
    ask({ op: 'learn', word }).catch(() => {});
    return { ok: true, words };
  });

  fastify.delete('/api/spell/vocabulary', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    const word = cleanWord(req.body?.word ?? req.query?.word).toLowerCase();
    const removed = readVocabulary().filter((w) => w.toLowerCase() === word);
    const words = writeVocabulary(readVocabulary().filter((w) => w.toLowerCase() !== word));
    for (const w of removed) ask({ op: 'unlearn', word: w }).catch(() => {});
    return { ok: true, words };
  });

  fastify.post('/api/spell/learn', async (req, reply) => {
    const { word = '' } = req.body || {};
    if (!word) return reply.code(400).send({ ok: false, error: 'Missing word.' });
    return answer(reply, { op: 'learn', word: String(word) });
  });
}
