import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { catalog } from './catalog.js';
import { aiDirectory, atomicJSON } from './storage.js';
import { installedModel, localEndpoint, localStatus, scheduleUnload, stopRuntime } from './localModels.js';
import { nativeAI } from './native.js';

const settingsFile = path.join(aiDirectory, 'providers.json');
const remoteProviders = ['ollama', 'openai', 'gemini'];
const providers = ['off', 'local', 'apple', ...remoteProviders];
const gemini = 'https://generativelanguage.googleapis.com/v1beta/openai';
let loaded;
let activeRequest;
let changing = false;
let apple = process.platform === 'darwin' ? 'Check availability on this Mac.' : 'Apple Foundation Models requires macOS.';
let lastError = '';

async function readSettings() {
  try {
    const stored = JSON.parse(await fs.readFile(settingsFile, 'utf8'));
    if (providers.includes(stored.active)) {
      const remote = {};
      for (const provider of remoteProviders) {
        const entry = stored.remote?.[provider];
        if (typeof entry?.endpoint === 'string' && typeof entry?.model === 'string') {
          remote[provider] = { endpoint: entry.endpoint, model: entry.model, hasKey: entry.hasKey === true };
        }
      }
      return { active: stored.active, local: typeof stored.local === 'string' ? stored.local : '', remote };
    }
  } catch {}
  return { active: 'off', local: '', remote: {} };
}
const settings = () => loaded ??= readSettings();

async function save(next) {
  await fs.mkdir(aiDirectory, { recursive: true, mode: 0o700 });
  await atomicJSON(settingsFile, next);
  loaded = Promise.resolve(next);
}

export async function getAIStatus() {
  const config = await settings();
  return {
    ...config, apple, localStatus: await localStatus(), generating: Boolean(activeRequest), lastError,
    catalog: await Promise.all(catalog.map(async ({ id, name, bytes, license, role, quantization, ...entry }) => ({
      id, name, bytes, license, role, quantization, installed: await installedModel({ id, bytes, ...entry })
    })))
  };
}

async function stopCurrent() {
  if (activeRequest) {
    const request = activeRequest;
    request.controller.abort();
    await request.done;
  }
  await stopRuntime();
}

async function update(action) {
  if (changing) throw new Error('A provider change is already in progress.');
  changing = true;
  try { await action(await settings()); }
  finally { changing = false; }
}

export async function checkApple() {
  apple = await nativeAI({ action: 'apple-status' }).catch((error) => error.message);
  return apple;
}

export async function selectProvider(provider, id) {
  if (!providers.includes(provider)) throw new Error('Unknown AI provider.');
  await update(async (current) => {
    if (provider === 'local') {
      const entry = catalog.find((item) => item.id === id);
      if (!entry || !await installedModel(entry)) throw new Error('Install this model first.');
    }
    if (provider === 'apple' && await checkApple() !== 'available') throw new Error(apple);
    if (remoteProviders.includes(provider) && !current.remote[provider]?.model) {
      throw new Error('Save this provider’s model first.');
    }
    await stopCurrent();
    await save({ ...current, active: provider, local: provider === 'local' ? id : current.local });
    lastError = '';
  });
}

export async function uninstall(entry, remove) {
  await update(async (current) => {
    if (current.active === 'local' && current.local === entry.id) {
      await stopCurrent();
      await save({ ...current, active: 'off', local: '' });
    }
    await remove(entry);
  });
}

function remoteBase(provider, endpoint) {
  if (provider === 'gemini') return gemini;
  const url = new URL(endpoint);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('Enter an HTTP(S) base URL without credentials, query parameters, or fragments.');
  }
  const clean = url.href.replace(/\/+$/, '').replace(/\/chat\/completions$/i, '');
  if (provider === 'ollama') return clean.replace(/\/v1$/i, '');
  return /\/v\d+(?:beta\d*)?$/i.test(clean) ? clean : `${clean}/v1`;
}

const credentialScope = (endpoint) => createHash('sha256').update(endpoint).digest('hex');

export async function configureRemote(provider, input) {
  if (!remoteProviders.includes(provider)) throw new Error('Unknown remote provider.');
  const endpoint = remoteBase(provider, String(input.endpoint || '').trim());
  const model = String(input.model || '').trim();
  const suppliedKey = typeof input.key === 'string' ? input.key.trim() : undefined;
  if (!model || model.length > 240) throw new Error('Enter a model ID.');
  await update(async (current) => {
    if (current.active === provider) await stopCurrent();
    const saved = current.remote[provider];
    const hasKey = suppliedKey === undefined ? saved?.endpoint === endpoint && Boolean(saved.hasKey) : Boolean(suppliedKey);
    if (suppliedKey !== undefined) {
      await nativeAI({ action: 'key-write', provider, scope: credentialScope(endpoint), value: suppliedKey });
    }
    await save({
      ...current,
      remote: { ...current.remote, [provider]: { endpoint, model, hasKey } }
    });
    lastError = '';
  });
}

async function getKey(provider, endpoint, explicit, signal) {
  if (typeof explicit === 'string') return explicit.trim();
  if (process.platform !== 'darwin') return '';
  return nativeAI({ action: 'key-read', provider, scope: credentialScope(endpoint) }, signal);
}

async function upstream(url, key, options = {}) {
  try {
    const response = await fetch(url, {
      ...options, redirect: 'error',
      headers: { 'Content-Type': 'application/json', ...(key ? { Authorization: `Bearer ${key}` } : {}) }
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`AI endpoint returned HTTP ${response.status}.`);
    }
    return await response.json();
  } catch (error) {
    if (options.signal?.aborted) throw new Error('AI request cancelled or timed out.');
    if (/^AI endpoint returned/.test(error.message)) throw error;
    throw new Error('Unable to reach the AI endpoint or read its response.');
  }
}

export async function testRemote(provider, input) {
  if (!remoteProviders.includes(provider)) throw new Error('Unknown remote provider.');
  const endpoint = remoteBase(provider, String(input.endpoint || '').trim());
  const signal = AbortSignal.timeout(12000);
  const saved = (await settings()).remote[provider];
  const key = await getKey(provider, endpoint, input.key ?? (saved?.endpoint === endpoint && saved.hasKey ? undefined : ''), signal);
  if (provider === 'gemini' && !key) throw new Error('Enter a Gemini API key.');
  const suffix = provider === 'ollama' ? '/api/tags' : '/models';
  const data = await upstream(endpoint + suffix, key, { signal });
  const models = provider === 'ollama' ? data.models?.map((item) => item.name) : data.data?.map((item) => item.id);
  if (!Array.isArray(models)) throw new Error('The endpoint did not return a model list.');
  return models.filter((item) => typeof item === 'string');
}

export function cancelGeneration() {
  activeRequest?.controller.abort();
}

export async function providerCompletion(payload, externalSignal) {
  if (changing || activeRequest) throw new Error('An AI request or provider change is already in progress.');
  const controller = new AbortController();
  let finish;
  activeRequest = { controller, done: new Promise((resolve) => { finish = resolve; }) };
  const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(180000), ...(externalSignal ? [externalSignal] : [])]);
  let provider;
  try {
    const config = await settings();
    provider = config.active;
    const messages = payload.messages;
    if (!Array.isArray(messages) || !messages.length) throw new Error('Provide messages for the AI request.');
    if (provider === 'off') throw new Error('AI is Off. Choose a provider in Settings → AI & Models.');
    const hasImage = messages.some((message) => Array.isArray(message.content) &&
      message.content.some((part) => part.type === 'image_url'));
    if (provider === 'apple') {
      if (payload.tools?.length || hasImage) throw new Error('Choose an endpoint supporting tools or images for this action.');
      const prompt = messages.map((message) => `${message.role}: ${message.content}`).join('\n\n');
      const content = await nativeAI({ action: 'apple-generate', value: prompt }, signal);
      return { choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }] };
    }

    let endpoint;
    let key;
    let model;
    if (provider === 'local') {
      if (hasImage) throw new Error('This local model accepts text. Choose an image-capable endpoint for image input.');
      model = config.local;
      const local = await localEndpoint(model, signal);
      endpoint = `${local.base}/v1`;
      key = local.key;
    } else {
      const remote = config.remote[provider];
      if (!remote?.model) throw new Error('Configure the active provider first.');
      model = remote.model;
      endpoint = provider === 'ollama' ? `${remote.endpoint}/v1` : remote.endpoint;
      key = remote.hasKey ? await getKey(provider, remote.endpoint, undefined, signal) : '';
      if (provider === 'gemini' && !key) throw new Error('Enter a Gemini API key in AI & Models.');
    }
    lastError = '';
    const request = { ...payload, model, stream: false };
    if (provider === 'local') {
      request.max_tokens = Math.min(Number(request.max_tokens) || 512, 512);
      if (model !== 'qwen3-4b-instruct') request.chat_template_kwargs = { enable_thinking: false };
    }
    return await upstream(`${endpoint}/chat/completions`, key, {
      method: 'POST', body: JSON.stringify(request), signal
    });
  } catch (error) {
    lastError = controller.signal.aborted ? '' : error.message;
    throw error;
  } finally {
    if (provider === 'local') {
      if (signal.aborted) await stopRuntime();
      else scheduleUnload();
    }
    activeRequest = undefined;
    finish();
  }
}
