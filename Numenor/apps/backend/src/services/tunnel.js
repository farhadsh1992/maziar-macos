// Public links to this Numenor server, through a tunnel provider. Each start function resolves to
// { url, provider, close } or null (provider missing or failed) — never throws.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const PROVIDERS = ['cloudflared', 'ngrok', 'localtunnel'];

/**
 * `mode` is a provider name, or 'auto' to try them in order (Cloudflare, ngrok, localtunnel).
 * With `ngrokDomain` (the fixed address a free ngrok account includes), ngrok goes first so the link
 * stays the same every time; if that address can't be used, the others are tried and `note` says why.
 */
export async function startTunnel(port, mode = 'auto', { ngrokDomain = '' } = {}) {
  const wanted = String(mode || 'auto').toLowerCase().trim();
  let order = wanted === 'auto' || wanted === 'true' || wanted === '1' ? PROVIDERS : [wanted];
  if (ngrokDomain && order.includes('ngrok')) order = ['ngrok', ...order.filter((p) => p !== 'ngrok')];
  const tried = [];
  let fixedProblem = '';
  for (const provider of order) {
    let result = null;
    if (provider === 'cloudflared') result = await tryCloudflared(port);
    else if (provider === 'ngrok' && ngrokDomain) {
      result = await tryNgrok(port, ngrokDomain);
      if (result?.error) {
        fixedProblem = result.error;
        result = null;
      }
      if (!result) {
        const random = await tryNgrok(port);
        if (random) result = random;
      }
    } else if (provider === 'ngrok') result = await tryNgrok(port);
    else if (provider === 'localtunnel') result = await tryLocaltunnel(port);
    else continue;
    if (result) {
      if (fixedProblem) {
        result.note = [`Your fixed address ${ngrokDomain} couldn’t be used (${fixedProblem}), so this link is temporary.`, result.note].filter(Boolean).join(' ');
        result.fixedFailed = true;
      }
      return result;
    }
    tried.push(provider);
  }
  const why = fixedProblem ? ` Fixed address ${ngrokDomain}: ${fixedProblem}` : '';
  return { error: `No tunnel could be started (tried ${tried.join(', ') || mode}).${why}` };
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

/** Briefly opens `domain` on ngrok to see if this account can use it. Resolves to '' (fine) or a reason. */
export async function checkNgrokDomain(port, domain) {
  const result = await tryNgrok(port, domain);
  if (result?.error) return result.error;
  try { await result?.close?.(); } catch { /* closed */ }
  return '';
}

/** With `domain`, failures come back as { error } so the caller can say why the fixed address didn't work. */
async function tryNgrok(port, domain = '') {
  const authtoken = ngrokAuthtoken();
  if (!authtoken) return domain ? { error: 'no ngrok account is set up on this computer' } : null;
  try {
    const ngrok = await import('@ngrok/ngrok');
    const options = { addr: `127.0.0.1:${port}`, authtoken };
    if (domain) options.domain = domain;
    const listener = await ngrok.default.forward(options);
    return { url: listener.url(), provider: 'ngrok', fixed: Boolean(domain), close: () => listener.close().catch(() => {}) };
  } catch (err) {
    if (!domain) return null;
    return { error: ngrokReason(err) };
  }
}

function ngrokReason(err) {
  const text = String(err?.message || err || '');
  if (/ERR_NGROK_31[39]|ERR_NGROK_320|custom subdomain|not (?:reserved|found)|doesn.t exist|is not bound/i.test(text)) return 'this isn’t the fixed address on your ngrok account — copy it exactly from dashboard.ngrok.com/domains';
  if (/ERR_NGROK_334|already online|already bound/i.test(text)) return 'it is already in use by another ngrok session';
  if (/ERR_NGROK_10[0-9]|authtoken|authentication/i.test(text)) return 'ngrok didn’t accept this computer’s account token';
  const code = text.match(/ERR_NGROK_\d+/);
  return code ? `ngrok said ${code[0]}` : text.split('\n')[0].slice(0, 160) || 'ngrok refused it';
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
