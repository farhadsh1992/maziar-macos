import { createHash, randomBytes } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { createWriteStream, promises as fs } from 'node:fs';
import { createServer } from 'node:net';
import { release } from 'node:os';
import path from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { catalog, runtimeArtifact } from './catalog.js';
import { aiDirectory, atomicJSON } from './storage.js';

const exec = promisify(execFile);
const modelDir = path.join(aiDirectory, 'models');
const runtimeDir = path.join(aiDirectory, 'llama-b6500');
const runtimeBin = path.join(runtimeDir, 'llama-server');
const stagingDir = path.join(aiDirectory, '.installing');
const installMarker = path.join(stagingDir, 'job.json');
let recovery;
let install;
let clearing = false;
let runtime;
let idle;
let phase = 'idle';
let runtimeError = '';

export const localCompatibility = process.platform === 'darwin' && process.arch === 'arm64' && Number(release().split('.')[0]) >= 23;
const modelPath = (id) => path.join(modelDir, id, 'model.gguf');

export async function installedModel(entry) {
  try {
    const file = modelPath(entry.id);
    const [stat, manifest] = await Promise.all([
      fs.stat(file), fs.readFile(path.join(path.dirname(file), 'verified.json'), 'utf8')
    ]);
    return stat.isFile() && stat.size === entry.bytes && JSON.parse(manifest).sha256 === entry.sha256;
  } catch {
    return false;
  }
}

export async function localStatus() {
  let progress = install && {
    id: install.id, phase: install.phase, bytes: install.bytes, total: install.total, error: install.error
  };
  if (!progress) {
    const entry = await fs.readFile(installMarker, 'utf8').then(JSON.parse).catch(() => null);
    if (entry?.id && catalog.some((model) => model.id === entry.id)) {
      progress = { id: entry.id, phase: 'failed', bytes: 0, total: 0, error: 'The previous download was interrupted. Retry to start again.' };
    }
  }
  return { compatible: localCompatibility, progress, runtime: phase, error: runtimeError };
}

async function download(artifact, destination, job) {
  job.bytes = 0;
  job.total = artifact.bytes;
  const hash = createHash('sha256');
  const response = await fetch(artifact.url, { signal: job.controller.signal });
  if (!response.ok || !response.body) throw new Error(`Download failed (HTTP ${response.status}).`);
  const meter = new Transform({
    transform(chunk, _encoding, callback) {
      job.bytes += chunk.length;
      if (job.bytes > artifact.bytes) return callback(new Error('Artifact exceeds its pinned size.'));
      hash.update(chunk);
      callback(null, chunk);
    }
  });
  await pipeline(Readable.fromWeb(response.body), meter, createWriteStream(destination, { flags: 'wx', mode: 0o600 }),
    { signal: job.controller.signal });
  if (job.bytes !== artifact.bytes || hash.digest('hex') !== artifact.sha256) {
    throw new Error('Artifact checksum or size did not match. Retry the download.');
  }
}

async function runtimeInstalled() {
  try {
    return (await fs.readFile(path.join(runtimeDir, 'verified'), 'utf8')) === runtimeArtifact.sha256
      && (await fs.stat(runtimeBin)).isFile();
  } catch { return false; }
}

async function performInstall(entry, job) {
  try {
    recovery ??= fs.rm(stagingDir, { recursive: true, force: true });
    await recovery;
    const alreadyInstalled = await installedModel(entry);
    const needsRuntime = !await runtimeInstalled();
    if (alreadyInstalled && !needsRuntime) {
      job.phase = 'installed';
      if (phase === 'unavailable') {
        phase = 'idle';
        runtimeError = '';
      }
      return;
    }
    await fs.mkdir(stagingDir, { recursive: true, mode: 0o700 });
    await atomicJSON(installMarker, { id: entry.id });
    const disk = await fs.statfs(stagingDir, { bigint: true });
    const required = BigInt((alreadyInstalled ? 0 : entry.bytes) + (needsRuntime ? 100 * 1024 ** 2 : 32 * 1024 ** 2));
    if (disk.bavail * disk.bsize < required) throw new Error('Insufficient disk space for this install.');
    if (needsRuntime) {
      job.phase = 'runtime';
      const archive = path.join(stagingDir, 'runtime.zip');
      await download(runtimeArtifact, archive, job);
      job.phase = 'verifying';
      const expanded = path.join(stagingDir, 'runtime');
      await fs.mkdir(expanded);
      await exec('/usr/bin/ditto', ['-x', '-k', archive, expanded], { signal: job.controller.signal });
      const source = path.join(expanded, 'build', 'bin');
      await exec(path.join(source, 'llama-server'), ['--version'], { timeout: 15000, signal: job.controller.signal });
      await fs.writeFile(path.join(source, 'verified'), runtimeArtifact.sha256);
      await fs.rm(runtimeDir, { recursive: true, force: true });
      await fs.rename(source, runtimeDir);
    }
    if (alreadyInstalled) {
      job.phase = 'installed';
      runtimeError = '';
      phase = 'idle';
      return;
    }
    job.phase = 'model';
    const staged = path.join(stagingDir, 'model');
    await fs.mkdir(staged);
    await download(entry, path.join(staged, 'model.gguf'), job);
    job.phase = 'verifying';
    job.controller.signal.throwIfAborted();
    await atomicJSON(path.join(staged, 'verified.json'), { sha256: entry.sha256 });
    job.controller.signal.throwIfAborted();
    await fs.mkdir(modelDir, { recursive: true, mode: 0o700 });
    const target = path.dirname(modelPath(entry.id));
    await fs.rm(target, { recursive: true, force: true });
    job.controller.signal.throwIfAborted();
    await fs.rename(staged, target);
    job.phase = 'installed';
  } catch (error) {
    job.phase = job.controller.signal.aborted ? 'cancelled' : 'failed';
    job.error = job.phase === 'failed' ? error.message : '';
  } finally {
    await fs.rm(stagingDir, { recursive: true, force: true }).catch(() => {});
    job.pending = false;
  }
}

export function installModel(entry) {
  if (!localCompatibility) throw new Error('Managed models require Apple Silicon and macOS 14 or later.');
  if (install?.pending || clearing) throw new Error('An install or cleanup is already running.');
  const job = { id: entry.id, phase: 'checking', bytes: 0, total: entry.bytes, pending: true, controller: new AbortController() };
  install = job;
  job.done = performInstall(entry, job);
}

export function cancelInstall() {
  if (!install?.pending) return;
  install.controller.abort();
  return install.done;
}

export async function discardInterruptedInstall() {
  if (install?.pending || clearing) throw new Error('Cancel the current download or wait for cleanup.');
  clearing = true;
  try {
    await fs.rm(stagingDir, { recursive: true, force: true });
    install = undefined;
  } finally { clearing = false; }
}

export async function removeModel(entry) {
  if (install?.pending) throw new Error('Wait for the current install to finish.');
  await fs.rm(path.dirname(modelPath(entry.id)), { recursive: true, force: true });
  if (install?.id === entry.id) install = undefined;
}

async function freePort() {
  const server = createServer();
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function signalRuntime(current, signal = 'SIGTERM') {
  if (!current.child.pid || current.child.exitCode !== null || current.child.signalCode !== null) return;
  try { process.kill(-current.child.pid, signal); } catch (error) {
    if (error.code !== 'ESRCH') throw error;
  }
}

export async function stopRuntime() {
  clearTimeout(idle);
  const current = runtime;
  runtime = undefined;
  phase = 'idle';
  runtimeError = '';
  if (!current) return;
  signalRuntime(current);
  const timeout = setTimeout(() => { signalRuntime(current, 'SIGKILL'); }, 3000).unref();
  try { await current.closed; }
  finally { clearTimeout(timeout); }
}

export async function localEndpoint(id, signal) {
  clearTimeout(idle);
  if (!localCompatibility) {
    phase = 'unavailable';
    runtimeError = 'Managed models require Apple Silicon and macOS 14 or later.';
    throw new Error(runtimeError);
  }
  const entry = catalog.find((item) => item.id === id);
  if (!entry || !await installedModel(entry) || !await runtimeInstalled()) {
    phase = 'unavailable';
    runtimeError = 'Install or reinstall the selected model in AI & Models.';
    throw new Error(runtimeError);
  }
  if (runtime?.id === id && phase === 'ready') return runtime;
  try {
    phase = 'loading';
    const port = await freePort();
    const key = randomBytes(32).toString('hex');
    signal.throwIfAborted();
    const watchParent = `
      parent="$1"; shift
      "$@" &
      model=$!
      trap 'kill "$model" 2>/dev/null; wait "$model"; exit 0' TERM INT HUP
      while kill -0 "$model" 2>/dev/null; do
        if ! kill -0 "$parent" 2>/dev/null; then
          kill "$model" 2>/dev/null
          break
        fi
        sleep 1
      done
      wait "$model"
    `;
    const child = spawn('/bin/sh', ['-c', watchParent, 'numenor-llama', String(process.pid), runtimeBin,
      '--model', modelPath(id), '--host', '127.0.0.1', '--port', String(port),
      '--ctx-size', '2048', '--parallel', '1', '--alias', id, '--jinja', '--reasoning-format', 'deepseek'
    ], {
      env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, LLAMA_API_KEY: key },
      cwd: runtimeDir, detached: true, stdio: 'ignore'
    });
    const current = { id, child, key, base: `http://127.0.0.1:${port}` };
    current.closed = new Promise((resolve) => {
      child.on('error', () => {});
      child.once('close', () => {
        if (runtime === current) {
          runtime = undefined;
          phase = 'unavailable';
          runtimeError = 'The local runtime stopped. Retry generation or reinstall the model.';
        }
        resolve();
      });
    });
    runtime = current;
    for (let i = 0; i < 180; i++) {
      signal.throwIfAborted();
      if (runtime !== current) throw new Error(runtimeError || 'The local runtime stopped.');
      const health = await fetch(`${current.base}/health`, {
        signal: AbortSignal.any([signal, AbortSignal.timeout(1000)]),
        headers: { Authorization: `Bearer ${key}` }
      }).catch(() => null);
      if (health?.ok) {
        phase = 'ready';
        return current;
      }
      await delay(500, undefined, { signal });
    }
    throw new Error('The local runtime timed out while loading.');
  } catch (error) {
    await stopRuntime();
    if (!signal.aborted) {
      phase = 'unavailable';
      runtimeError = error.message;
    }
    throw error;
  }
}

export function scheduleUnload() {
  if (!runtime) return;
  clearTimeout(idle);
  idle = setTimeout(() => { void stopRuntime(); }, 120_000);
  idle.unref();
}

process.once('exit', () => { if (runtime) signalRuntime(runtime); });
