import crypto from 'crypto';
import { COLLAB_TOKEN_SECRET } from '../../config/constants.js';
import { getActiveInvite, effectiveInviteRole } from '../inviteService.js';

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

/** An invite link's token whose invite is still active: { projectId, inviteId, role, name } or null.
 *  On its own it only says who the link is for — opening the project also needs the access code. */
export function verifyInviteToken(token) {
  const decoded = decodeToken(token);
  if (!decoded) return null;
  const invite = getActiveInvite(decoded.inviteId);
  if (!invite || invite.projectId !== decoded.projectId) return null;
  return { projectId: decoded.projectId, inviteId: invite.id, role: effectiveInviteRole(invite), name: invite.name };
}

// A pass: what the link + the right access code are exchanged for (POST /api/collab/unlock). It is what
// the editor sends with every request. It ends after SESSION_HOURS, when the person is removed, or when
// their code is changed (it carries a fingerprint of the code it was made with).
export const SESSION_HOURS = 12;
const codePrint = (code) => crypto.createHmac('sha256', COLLAB_TOKEN_SECRET).update(`code:${code}`).digest('hex').slice(0, 12);

export function issueSessionToken({ projectId, inviteId, code }) {
  const payload = { v: 1, pid: projectId, iid: inviteId, cp: codePrint(code), exp: Date.now() + SESSION_HOURS * 3600 * 1000 };
  const body = base64UrlEncode(JSON.stringify(payload));
  return `ops.${body}.${base64UrlEncode(sign(`ops.${body}`))}`;
}

/** A valid, unexpired pass for a still-active invite: { projectId, inviteId, role, name } or null. */
export function verifyToken(token) {
  if (!token || typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3 || parts[0] !== 'ops') return null;
  const expected = Buffer.from(base64UrlEncode(sign(`ops.${parts[1]}`)));
  const given = Buffer.from(parts[2]);
  if (expected.length !== given.length || !crypto.timingSafeEqual(expected, given)) return null;
  let payload;
  try {
    payload = JSON.parse(base64UrlDecode(parts[1]).toString('utf8'));
  } catch {
    return null;
  }
  if (payload.v !== 1 || !payload.pid || !payload.iid || !(payload.exp > Date.now())) return null;
  const invite = getActiveInvite(payload.iid);
  if (!invite || invite.projectId !== payload.pid || !invite.code || codePrint(invite.code) !== payload.cp) return null;
  return { projectId: payload.pid, inviteId: invite.id, role: effectiveInviteRole(invite), name: invite.name };
}
