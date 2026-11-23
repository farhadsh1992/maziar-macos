import crypto from 'crypto';
import { COLLAB_TOKEN_SECRET } from '../../config/constants.js';
import { getActiveInvite } from '../inviteService.js';

// v2 tokens name one invite (one person). They don't expire on their own; removing the person's access
// (revoking the invite) is what ends them. v1 tokens (one anonymous link per project) are no longer accepted.
const TOKEN_VERSION = 2;

function base64UrlEncode(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64UrlDecode(input) {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/');
  const pad = padded.length % 4 === 0 ? '' : '='.repeat(4 - (padded.length % 4));
  return Buffer.from(padded + pad, 'base64');
}

function sign(data) {
  return crypto.createHmac('sha256', COLLAB_TOKEN_SECRET).update(data).digest();
}

export function issueToken({ projectId, inviteId }) {
  const payload = { v: TOKEN_VERSION, pid: projectId, iid: inviteId };
  const body = base64UrlEncode(JSON.stringify(payload));
  const sig = base64UrlEncode(sign(body));
  return `op2.${body}.${sig}`;
}

/** Checks the signature only: { projectId, inviteId } or null. */
export function decodeToken(token) {
  if (!token || typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [prefix, body, sig] = parts;
  if (prefix !== 'op2') return null;
  const expectedBuf = Buffer.from(base64UrlEncode(sign(body)));
  const sigBuf = Buffer.from(sig);
  if (expectedBuf.length !== sigBuf.length) return null;
  if (!crypto.timingSafeEqual(expectedBuf, sigBuf)) return null;
  try {
    const payload = JSON.parse(base64UrlDecode(body).toString('utf8'));
    if (payload.v !== TOKEN_VERSION || !payload.pid || !payload.iid) return null;
    return { projectId: payload.pid, inviteId: payload.iid };
  } catch {
    return null;
  }
}

/** A valid token whose invite is still active: { projectId, inviteId, role, name } or null. */
export function verifyToken(token) {
  const decoded = decodeToken(token);
  if (!decoded) return null;
  const invite = getActiveInvite(decoded.inviteId);
  if (!invite || invite.projectId !== decoded.projectId) return null;
  return { projectId: decoded.projectId, inviteId: invite.id, role: invite.role, name: invite.name };
}
