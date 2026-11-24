import path from 'path';
import fs from 'fs';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..', '..');
export const DATA_DIR = process.env.NUMENOR_DATA_DIR || path.join(REPO_ROOT, 'data');
// Per-computer state that shouldn't travel with the projects (they may sit in Google Drive): the people a
// project is shared with, and the projects others shared with this computer.
export const STATE_DIR = process.env.NUMENOR_STATE_DIR || DATA_DIR;
// The name edits made on this computer are recorded under in a project's history.
export const OWNER_NAME = process.env.NUMENOR_OWNER_NAME || 'Owner';
export const TEMPLATE_DIR = path.join(REPO_ROOT, 'templates');
export const TEMPLATE_MANIFEST = path.join(TEMPLATE_DIR, 'manifest.json');
export const PORT = Number(process.env.PORT || 8787);
// Invite links are signed with this secret. Without NUMENOR_COLLAB_TOKEN_SECRET a random one is created
// once per install (kept next to the projects, readable only by this user) — a fixed default would let
// anyone who knows it forge an invite.
function loadCollabSecret() {
  if (process.env.NUMENOR_COLLAB_TOKEN_SECRET) return process.env.NUMENOR_COLLAB_TOKEN_SECRET;
  const file = path.join(DATA_DIR, '.numenor-collab-secret');
  try {
    const existing = fs.readFileSync(file, 'utf8').trim();
    if (existing.length >= 32) return existing;
  } catch {
    /* create below */
  }
  const secret = crypto.randomBytes(32).toString('hex');
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(file, secret, { mode: 0o600 });
  } catch {
    /* keep it in memory for this run */
  }
  return secret;
}
export const COLLAB_TOKEN_SECRET = loadCollabSecret();
export const COLLAB_TOKEN_TTL = Number(process.env.NUMENOR_COLLAB_TOKEN_TTL || 24 * 60 * 60);
export const COLLAB_FLUSH_DEBOUNCE_MS = Number(process.env.NUMENOR_COLLAB_FLUSH_DEBOUNCE_MS || 800);
export const TUNNEL_MODE = process.env.NUMENOR_TUNNEL || 'false';

// MinerU API
export const MINERU_API_BASE = 'https://mineru.net/api/v4';
export const MINERU_POLL_INTERVAL_MS = 3000;
export const MINERU_MAX_POLL_ATTEMPTS = 200;
