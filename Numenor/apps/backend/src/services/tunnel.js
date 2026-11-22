// Public links to this Numenor server, through a tunnel provider. Each start function resolves to
// { url, provider, close } or null (provider missing or failed) — never throws.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PROVIDERS = ['cloudflared', 'ngrok', 'localtunnel'];

/** `mode` is a provider name, or 'auto' to try them in order (Cloudflare, ngrok, localtunnel). */
export async function startTunnel(port, mode = 'auto') {
  const wanted = String(mode || 'auto').toLowerCase().trim();
  const order = wanted === 'auto' || wanted === 'true' || wanted === '1' ? PROVIDERS : [wanted];
  const tried = [];
  for (const provider of order) {
    let result = null;
    if (provider === 'cloudflared') result = await tryCloudflared(port);
    else if (provider === 'ngrok') result = await tryNgrok(port);
    else if (provider === 'localtunnel') result = await tryLocaltunnel(port);
    else continue;
    if (result) return result;
    tried.push(provider);
  }
  return { error: `No tunnel could be started (tried ${tried.join(', ') || mode}).` };
}

/** Kept for startup via NUMENOR_TUNNEL. */
export async function tryStartTunnel(port, mode) {
  const result = await startTunnel(port, mode);
  return result && result.url ? result : null;
}

function cloudflaredPath() {
  for (const p of ['/opt/homebrew/bin/cloudflared', '/usr/local/bin/cloudflared', '/usr/bin/cloudflared']) {
    if (existsSync(p)) return p;
  }
  return 'cloudflared';
}

async function tryCloudflared(port) {
  return new Promise((resolve) => {
    let proc;
    try {
      proc = spawn(cloudflaredPath(), ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${port}`], { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch {
      resolve(null);
      return;
    }
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (!value) {
        try { proc.kill(); } catch { /* already gone */ }
      }
      resolve(value);
    };
    const timer = setTimeout(() => finish(null), 30000);
    const onData = (data) => {
      const match = data.toString().match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
      if (match) finish({ url: match[0], provider: 'cloudflared', close: () => { try { proc.kill(); } catch { /* gone */ } } });
    };
    proc.stdout.on('data', onData);
    proc.stderr.on('data', onData);
    proc.on('error', () => finish(null));
    proc.on('exit', () => finish(null));
  });
}

/** ngrok needs an account token: NGROK_AUTHTOKEN, or the one the ngrok app saved in its config file. */
function ngrokAuthtoken() {
  if (process.env.NGROK_AUTHTOKEN) return process.env.NGROK_AUTHTOKEN;
  const home = os.homedir();
  const files = [
    path.join(home, 'Library', 'Application Support', 'ngrok', 'ngrok.yml'),
    path.join(home, '.config', 'ngrok', 'ngrok.yml'),
    path.join(home, '.ngrok2', 'ngrok.yml')
  ];
  for (const file of files) {
    try {
      const match = readFileSync(file, 'utf8').match(/^\s*authtoken:\s*["']?([^"'\s]+)/m);
      if (match) return match[1];
    } catch {
      /* not there */
    }
  }
  return '';
}

async function tryNgrok(port) {
  const authtoken = ngrokAuthtoken();
  if (!authtoken) return null;
  try {
    const ngrok = await import('@ngrok/ngrok');
    const listener = await ngrok.default.forward({ addr: `127.0.0.1:${port}`, authtoken });
    return { url: listener.url(), provider: 'ngrok', close: () => listener.close().catch(() => {}) };
  } catch {
    return null;
  }
}

async function tryLocaltunnel(port) {
  try {
    const { default: localtunnel } = await import('localtunnel');
    const tunnel = await localtunnel({ port, local_host: '127.0.0.1' });
    let closedOnPurpose = false;
    tunnel.on('error', (err) => console.warn(`[tunnel] localtunnel error: ${err.message}`));
    // loca.lt asks first-time visitors for a "tunnel password": this computer's public IP address.
    let password = '';
    try {
      const res = await fetch('https://loca.lt/mytunnelpassword', { signal: AbortSignal.timeout(5000) });
      if (res.ok) password = (await res.text()).trim();
    } catch {
      /* shown as unknown */
    }
    return {
      url: tunnel.url,
      provider: 'localtunnel',
      note: password ? `Visitors may be asked for a tunnel password: ${password}` : 'Visitors may be asked for a tunnel password (your public IP address).',
      close: () => {
        closedOnPurpose = true;
        try { tunnel.close(); } catch { /* gone */ }
      },
      isClosedOnPurpose: () => closedOnPurpose
    };
  } catch {
    return null;
  }
}
