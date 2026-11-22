// Sharing: one public link (a tunnel) for this Numenor server, started and stopped on demand. Visitors
// still need a per-project invite link — the public URL alone opens nothing (see authUtils).
import { startTunnel } from './tunnel.js';

let state = { active: false, starting: false, url: '', provider: '', note: '', error: '', startedAt: null };
let current = null;
let port = 0;

export function setSharePort(value) {
  port = value;
}

export function shareStatus() {
  const { active, starting, url, provider, note, error, startedAt } = state;
  return { active, starting, url, provider, note, error, startedAt };
}

export async function startSharing(mode = 'auto') {
  if (state.active) return shareStatus();
  if (state.starting) return shareStatus();
  state = { ...state, starting: true, error: '' };
  const result = await startTunnel(port, mode);
  if (result?.url) {
    current = result;
    state = { active: true, starting: false, url: result.url.replace(/\/$/, ''), provider: result.provider, note: result.note || '', error: '', startedAt: new Date().toISOString() };
    console.log(`  Sharing on (${result.provider}): ${state.url}`);
  } else {
    state = { active: false, starting: false, url: '', provider: '', note: '', error: result?.error || 'Couldn’t start sharing.', startedAt: null };
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
  state = { active: false, starting: false, url: '', provider: '', note: '', error: '', startedAt: null };
  console.log('  Sharing off');
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
