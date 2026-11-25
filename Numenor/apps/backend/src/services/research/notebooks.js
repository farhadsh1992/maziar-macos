import path from 'node:path';
import { promises as fs } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { researchDir, state } from './library.js';
import { jupyterGateway, requestJupyter } from './jupyterGateway.js';

const bridgeDirectory = path.dirname(fileURLToPath(import.meta.url));
const workspace = path.join(researchDir, 'notebooks');
let owned;
let starting;

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const connected = () => new Promise((resolve) => {
  const socket = net.createConnection({ host: '127.0.0.1', port: 6666 });
  const done = (value) => { socket.destroy(); resolve(value); };
  socket.setTimeout(800, () => done(false));
  socket.once('connect', () => done(true));
  socket.once('error', () => done(false));
});

async function verify(token, external = false) {
  const response = await requestJupyter('/api', '');
  const info = await response.json().catch(() => null);
  if (!response.ok || typeof info?.version !== 'string') throw new Error('Port 6666 is occupied by another service. It was left running.');
  if (external) {
    const unauthenticated = await requestJupyter('/api/status', '');
    if (unauthenticated.ok) throw new Error('Enable authentication on the existing JupyterLab server before connecting Reader2.');
  }
  const status = await requestJupyter('/api/status', token);
  if (!status.ok) throw new Error('JupyterLab is running on port 6666. Enter its access token in Reader2 settings.');
  const server = await status.json().catch(() => null);
  if (!server || typeof server.started !== 'string') throw new Error('Port 6666 is occupied by another service. It was left running.');
}

export async function notebookStatus() {
  if (starting) return { label: 'Starting JupyterLab…', owned: !!owned };
  if (owned) return { label: 'JupyterLab started by Maziar', owned: true };
  return { label: await connected() ? 'Port 6666 is in use' : 'JupyterLab is stopped', owned: false };
}

export async function stopOwnedNotebookServer() {
  const child = owned?.child;
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const ended = new Promise((resolve) => child.once('exit', resolve));
  child.kill('SIGTERM');
  await Promise.race([ended, pause(2600)]);
}

async function connect(ownerOrigin) {
  const { reader } = await state();
  if (await connected()) {
    const token = owned?.token ?? reader.jupyterToken ?? '';
    try { await verify(token, !owned); }
    catch (error) {
      if (error.code || error.name === 'TimeoutError' || error.name === 'AbortError') throw new Error('Port 6666 is occupied or unresponsive. The process was left running.');
      throw error;
    }
    return { token, owned: !!owned };
  }
  const executable = reader.jupyterCommand || process.env.MAZIAR_JUPYTER || 'jupyter';
  const token = randomBytes(32).toString('hex');
  await fs.mkdir(workspace, { recursive: true, mode: 0o700 });
  const config = path.join(researchDir, 'jupyter.json');
  await fs.writeFile(config, JSON.stringify({
    ServerApp: {
      ip: '127.0.0.1', port: 6666, port_retries: 0, open_browser: false, root_dir: workspace,
      jpserver_extensions: { reader2_bridge: true, jupyter_server_mcp: false },
      tornado_settings: { headers: { 'Content-Security-Policy': `frame-ancestors 'self' ${ownerOrigin}` } }
    },
    IdentityProvider: { token },
    LabApp: { expose_app_in_browser: true }
  }), { mode: 0o600 });
  const child = spawn(executable, ['lab', '--config=' + config], {
    cwd: workspace,
    env: { ...process.env, MAZIAR_READER_ORIGIN: ownerOrigin, PYTHONDONTWRITEBYTECODE: '1',
      JUPYTER_RUNTIME_DIR: path.join(researchDir, 'jupyter-runtime'),
      PYTHONPATH: [bridgeDirectory, process.env.PYTHONPATH].filter(Boolean).join(path.delimiter) },
    stdio: ['ignore', 'ignore', 'pipe']
  });
  owned = { child, token };
  let failure = '';
  let output = '';
  child.stderr.on('data', (data) => { output = (output + data).slice(-3000); });
  child.once('error', (error) => {
    failure = error.code === 'ENOENT' ? `JupyterLab was not found at ${executable}. Install it with python -m pip install jupyterlab, then set the full jupyter executable path in Reader2 settings.` : error.message;
    if (owned?.child === child) owned = undefined;
  });
  child.once('exit', () => { if (owned?.child === child) owned = undefined; });
  try {
    for (let attempt = 0; attempt < 80; attempt += 1) {
      if (failure) throw new Error(failure);
      if (child.exitCode !== null || child.signalCode !== null) {
        const detail = /already in use|address already in use/i.test(output)
          ? 'Port 6666 is occupied. The other process was left running.'
          : `JupyterLab could not start using ${executable}. Check that this environment has JupyterLab installed.`;
        throw new Error(detail);
      }
      try {
        await verify(token);
        return { token, owned: true };
      } catch { await pause(250); }
    }
    throw new Error('JupyterLab did not become ready on port 6666.');
  } catch (error) {
    await stopOwnedNotebookServer();
    throw error;
  }
}

const notebookTasks = new Map();
export async function openNotebook(id, ownerOrigin) {
  if (notebookTasks.has(id)) return notebookTasks.get(id);
  const operation = (async () => {
    starting ??= connect(ownerOrigin).finally(() => { starting = undefined; });
    const connection = await starting;
    const filename = id + '.ipynb';
    const folder = connection.owned ? '' : 'Reader2/';
    if (folder) await ensureContent('Reader2', { type: 'directory' }, connection.token);
    await ensureContent(folder + filename, { type: 'notebook', format: 'json',
      content: { cells: [], metadata: {}, nbformat: 4, nbformat_minor: 5 } }, connection.token);
    const browserOrigin = await jupyterGateway();
    const query = connection.token ? '?token=' + encodeURIComponent(connection.token) : '';
    return {
      label: connection.owned ? 'Connected to Maziar’s JupyterLab' : 'Connected to existing JupyterLab',
      owned: connection.owned,
      browserURL: browserOrigin + '/lab/tree/' + folder + filename + query,
      embedURL: connection.owned ? browserOrigin + '/reader2/bridge/' + filename + query : null,
      sourceLink: connection.owned ? browserOrigin + '/reader2/paper/' + id : ownerOrigin + '/reader2/' + id
    };
  })().finally(() => notebookTasks.delete(id));
  notebookTasks.set(id, operation);
  return operation;
}

async function ensureContent(name, content, token) {
  const route = '/api/contents/' + name;
  const existing = await requestJupyter(route + '?content=0', token);
  if (existing.ok) return;
  if (existing.status !== 404) throw new Error('JupyterLab could not read the Reader2 workspace.');
  const result = await requestJupyter(route, token, { method: 'PUT', body: JSON.stringify(content) });
  if (!result.ok) throw new Error('JupyterLab could not create ' + name + '.');
}
