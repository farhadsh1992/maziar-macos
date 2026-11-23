import { verifyToken } from '../services/collab/tokenService.js';
import { touchInvite } from '../services/inviteService.js';
import { COLLAB_REQUIRE_TOKEN } from '../config/constants.js';

export function isLocalAddress(ip) {
  if (!ip) return false;
  if (ip === '127.0.0.1' || ip === '::1') return true;
  if (ip.startsWith('::ffff:127.0.0.1')) return true;
  return false;
}

// Headers a tunnel or reverse proxy adds. A request carrying any of them came from outside, even though
// the tunnel client itself connects from 127.0.0.1.
const PROXY_HEADERS = ['x-forwarded-for', 'x-forwarded-host', 'x-real-ip', 'cf-connecting-ip', 'forwarded', 'true-client-ip'];
const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);

/** The visitor's address: the real one behind a tunnel/proxy, else the socket's. */
export function getClientIp(req) {
  const forwarded = req.headers?.['cf-connecting-ip'] || req.headers?.['x-forwarded-for'];
  if (forwarded) return String(forwarded).split(',')[0].trim();
  return req.ip;
}

/**
 * True only for requests made on this computer: from a loopback address, addressed to localhost, and not
 * relayed by a tunnel or proxy. Everything else — LAN visitors and anyone coming through a share link —
 * is remote and needs an invite token.
 */
export function isLocalRequest(req) {
  const socketIp = req.socket?.remoteAddress || req.raw?.socket?.remoteAddress || req.ip;
  if (!isLocalAddress(socketIp)) return false;
  for (const header of PROXY_HEADERS) {
    if (req.headers?.[header]) return false;
  }
  const host = String(req.headers?.host || '').toLowerCase();
  const hostname = host.startsWith('[') ? host.slice(0, host.indexOf(']') + 1) : host.split(':')[0];
  return !hostname || LOCAL_HOSTS.has(hostname);
}

export function getBearerToken(req) {
  const header = req.headers?.authorization || '';
  if (!header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

export function getQueryToken(req) {
  const token = req.query?.token;
  if (!token) return null;
  if (Array.isArray(token)) return token[0];
  return String(token);
}

/**
 * What an invited (remote) visitor may call: the invited project and the few routes its editor needs.
 * Anything touching other projects, the computer's folders, templates, imports or the owner's AI key is
 * refused.
 */
export function remoteRequestAllowed(req, payload) {
  const url = String(req.url || '').split('?')[0];
  const method = req.method;
  const projectMatch = url.match(/^\/api\/projects\/([^/]+)(\/.*)?$/);
  if (projectMatch) {
    const [, id, rest = ''] = projectMatch;
    if (decodeURIComponent(id) !== payload.projectId) return false;
    if (rest === '' && method !== 'GET') return false; // no trashing/deleting the project itself
    if (/^\/(permanent|copy|move|trash|archive|unarchive|restore|tags|rename-project|collab\/invite)$/.test(rest)) return false;
    if (rest.startsWith('/invites')) return false; // who has access is the owner's business
    // View-only people can read everything (and compile, which only writes the build folder) but change nothing.
    if (payload.role === 'view' && method !== 'GET') return false;
    return true;
  }
  if (url === '/api/projects' && method === 'GET') return true; // filtered to the invited project
  if (url === '/api/compile' && method === 'POST') return req.body?.projectId === payload.projectId;
  if (url === '/api/spell/learn') return payload.role !== 'view';
  if (url.startsWith('/api/spell/')) return true;
  if (url === '/api/me') return true;
  if (url === '/api/collab/resolve') return true;
  return false;
}

export function requireAuthIfRemote(req) {
  if (isLocalRequest(req)) return { ok: true, payload: null, local: true };
  const token = getBearerToken(req) || getQueryToken(req);
  const payload = verifyToken(token);
  if (!payload) {
    // NUMENOR_COLLAB_REQUIRE_TOKEN=0 restores open access on a trusted network (never through a share link).
    if (!COLLAB_REQUIRE_TOKEN && !req.headers?.['x-forwarded-for'] && !req.headers?.['cf-connecting-ip']) {
      return { ok: true, payload: null, local: false };
    }
    return { ok: false, payload: null, local: false };
  }
  touchInvite(payload.inviteId);
  return { ok: true, payload, local: false };
}
