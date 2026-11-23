// Sharing: one public link (a tunnel) for this Numenor server, started and stopped on demand. Visitors
// still need a per-project invite link — the public URL alone opens nothing (see authUtils).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { STATE_DIR } from '../config/constants.js';
import { checkNgrokDomain, startTunnel } from './tunnel.js';

// Per-computer sharing settings. `ngrokDomain` is the fixed address a free ngrok account includes, so
// share links stay the same after Numenor or the computer restarts.
const SETTINGS_FILE = path.join(STATE_DIR, 'share-settings.json');

export function getShareSettings() {
  try {
    const data = JSON.parse(readFileSync(SETTINGS_FILE, 'utf8'));
    return { ngrokDomain: typeof data.ngrokDomain === 'string' ? data.ngrokDomain : '' };
  } catch {
    return { ngrokDomain: '' };
  }
}

/** Accepts "x.ngrok-free.app", "https://x.ngrok-free.app/", etc. Returns '' for empty, null for invalid. */
export function normalizeDomain(value) {
  const text = String(value || '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  if (!text) return '';
  return /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(text) ? text : null;
}

export function saveShareSettings(next) {
  const merged = { ...getShareSettings(), ...next };
  if (!existsSync(STATE_DIR)) mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(SETTINGS_FILE, JSON.stringify(merged, null, 2));
  return merged;
}

let state = { active: false, starting: false, url: '', provider: '', note: '', error: '', startedAt: null, fixed: false };
let current = null;
let port = 0;

export function setSharePort(value) {
  port = value;
}

export function shareStatus() {
  const { active, starting, url, provider, note, error, startedAt, fixed } = state;
  return { active, starting, url, provider, note, error, startedAt, fixed, fixedDomain: getShareSettings().ngrokDomain };
}

export async function startSharing(mode = 'auto') {
  if (state.active) return shareStatus();
  if (state.starting) return shareStatus();
  state = { ...state, starting: true, error: '' };
  const result = await startTunnel(port, mode, { ngrokDomain: getShareSettings().ngrokDomain });
  if (result?.url) {
    current = result;
    state = { active: true, starting: false, url: result.url.replace(/\/$/, ''), provider: result.provider, note: result.note || '', error: '', startedAt: new Date().toISOString(), fixed: Boolean(result.fixed) };
    console.log(`  Sharing on (${result.provider}): ${state.url}`);
  } else {
    state = { active: false, starting: false, url: '', provider: '', note: '', error: result?.error || 'Couldn’t start sharing.', startedAt: null, fixed: false };
  }
  return shareStatus();
}

export async function stopSharing() {
  try {
    await current?.close?.();
  } catch {
    /* already closed */
  }
  current = null;
  state = { active: false, starting: false, url: '', provider: '', note: '', error: '', startedAt: null, fixed: false };
  console.log('  Sharing off');
  return shareStatus();
}

/**
 * Check, then save a new fixed address ('' turns it off); if sharing is on, restart it so the new address
 * takes effect now. Resolves to { error } (nothing saved) when ngrok won't let this account use it.
 */
export async function setFixedDomain(domain, mode = 'auto') {
  const alreadyLive = state.active && state.fixed && getShareSettings().ngrokDomain === domain;
  if (domain && !alreadyLive) {
    const problem = await checkNgrokDomain(port, domain);
    if (problem) return { error: `Couldn’t use ${domain}: ${problem}.` };
  }
  saveShareSettings({ ngrokDomain: domain });
  if (alreadyLive) return shareStatus();
  if (state.active) {
    await stopSharing();
    return startSharing(mode);
  }
  return shareStatus();
}

// Don't leave a tunnel process behind when the server stops.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, () => {
    try { current?.close?.(); } catch { /* ignore */ }
    process.exit(0);
  });
}
process.once('exit', () => {
  try { current?.close?.(); } catch { /* ignore */ }
});
