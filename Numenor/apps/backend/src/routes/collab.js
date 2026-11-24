import path from 'path';
import { readJson } from '../utils/fsUtils.js';
import { getProjectRoot } from '../services/projectService.js';
import { safeJoin } from '../utils/pathUtils.js';
import { isTextFile } from '../utils/texUtils.js';
import crypto from 'crypto';
import { verifyToken, decodeToken, verifyInviteToken, issueSessionToken, SESSION_HOURS } from '../services/collab/tokenService.js';
import { isRevoked, getActiveInvite, normalizeCode, collaborationEnabled, setCollaborationEnabled, listInvites } from '../services/inviteService.js';
import { OWNER_NAME } from '../config/constants.js';
import { getOrCreateDoc, setupConnection, flushDocNow, getDocDiagnostics, disconnectInvite } from '../services/collab/docStore.js';
import { isLocalRequest } from '../utils/authUtils.js';

const failures = new Map(); // inviteId → times of recent wrong codes
const MAX_TRIES = 10;
const LOCK_MS = 15 * 60 * 1000;

async function projectNameOf(projectId) {
  try {
    const meta = await readJson(path.join(await getProjectRoot(projectId), 'project.json'));
    return meta?.name || projectId;
  } catch {
    return projectId;
  }
}

export function registerCollabRoutes(fastify) {
  fastify.get('/api/projects/:id/collaboration', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false });
    await getProjectRoot(req.params.id);
    return { ok: true, enabled: collaborationEnabled(req.params.id) };
  });

  fastify.put('/api/projects/:id/collaboration', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false });
    const { id } = req.params;
    if (typeof req.body?.enabled !== 'boolean') {
      return reply.code(400).send({ ok: false, error: 'Expected an enabled flag.' });
    }
    await getProjectRoot(id);
    const { enabled } = req.body;
    setCollaborationEnabled(id, enabled);
    if (!enabled) {
      for (const invite of listInvites(id)) disconnectInvite(invite.id);
    }
    return { ok: true, enabled };
  });

  // What a link or pass is for. A pass (after the access code) gets everything; a bare invite link only
  // gets the project's name and owner, so the page can ask for the code.
  fastify.get('/api/collab/resolve', async (req, reply) => {
    const { token } = req.query || {};
    const tokenValue = Array.isArray(token) ? token[0] : token;
    const session = verifyToken(tokenValue);
    const payload = session || verifyInviteToken(tokenValue);
    if (!payload) {
      reply.code(401);
      const decoded = decodeToken(tokenValue);
      if (decoded && isRevoked(decoded.inviteId)) return { ok: false, revoked: true, error: 'Your access to this project was removed.' };
      if (String(tokenValue || '').startsWith('ops.')) return { ok: false, expired: true, error: 'This sign-in has ended — open your invite link again and enter your access code.' };
      return { ok: false, error: 'Invalid token' };
    }
    const projectName = await projectNameOf(payload.projectId);
    if (!session) return { ok: true, needsCode: true, projectId: payload.projectId, projectName, role: payload.role, name: payload.name, owner: OWNER_NAME };
    return { ok: true, projectId: payload.projectId, projectName, role: payload.role, name: payload.name, owner: OWNER_NAME };
  });

  // Link + access code → a pass for SESSION_HOURS. Too many wrong codes lock that link for a while.
  fastify.post('/api/collab/unlock', async (req, reply) => {
    const { token, code } = req.body || {};
    const invite = verifyInviteToken(String(token || ''));
    if (!invite) {
      const decoded = decodeToken(String(token || ''));
      if (decoded && isRevoked(decoded.inviteId)) return reply.code(401).send({ ok: false, revoked: true, error: 'Your access to this project was removed.' });
      return reply.code(401).send({ ok: false, error: 'This invite link isn’t valid.' });
    }
    const now = Date.now();
    const tries = (failures.get(invite.inviteId) || []).filter((t) => now - t < LOCK_MS);
    if (tries.length >= MAX_TRIES) {
      return reply.code(429).send({ ok: false, locked: true, error: 'Too many wrong codes — try again in 15 minutes, or ask the owner for your code.' });
    }
    const stored = getActiveInvite(invite.inviteId)?.code || '';
    const given = Buffer.from(normalizeCode(code));
    const want = Buffer.from(stored);
    if (!stored || given.length !== want.length || !crypto.timingSafeEqual(given, want)) {
      tries.push(now);
      failures.set(invite.inviteId, tries);
      return reply.code(401).send({ ok: false, wrongCode: true, error: 'That access code isn’t right.' });
    }
    failures.delete(invite.inviteId);
    return {
      ok: true,
      session: issueSessionToken({ projectId: invite.projectId, inviteId: invite.inviteId, code: stored }),
      hours: SESSION_HOURS,
      projectId: invite.projectId,
      projectName: await projectNameOf(invite.projectId),
      role: invite.role,
      name: invite.name,
      owner: OWNER_NAME
    };
  });

  fastify.post('/api/projects/:id/collab/flush', async (req) => {
    const { id } = req.params;
    const { path: filePath } = req.body || {};
    if (!filePath) return { ok: false, error: 'Missing path' };
    await getProjectRoot(id);
    const key = `${id}:${filePath}`;
    await flushDocNow(key);
    return { ok: true };
  });

  fastify.get('/api/projects/:id/collab/status', async (req) => {
    const { id } = req.params;
    const { path: filePath } = req.query || {};
    if (!filePath) return { ok: false, error: 'Missing path' };
    await getProjectRoot(id);
    const key = `${id}:${filePath}`;
    const diagnostics = getDocDiagnostics(key);
    return { ok: true, diagnostics };
  });

  fastify.get('/api/collab', { websocket: true }, async (conn, req) => {
    const { token, projectId, file } = req.query || {};
    const tokenValue = Array.isArray(token) ? token[0] : token;
    const filePath = Array.isArray(file) ? file[0] : file;
    const projectParam = Array.isArray(projectId) ? projectId[0] : projectId;
    const isLocal = isLocalRequest(req);
    let payload = null;
    if (tokenValue) {
      payload = verifyToken(tokenValue);
    } else if (!isLocal) {
      conn.socket.close(1008, 'Unauthorized');
      return;
    }
    const effectiveProjectId = payload?.projectId || projectParam;
    if (!effectiveProjectId || !filePath) {
      conn.socket.close(1008, 'Missing project or file');
      return;
    }
    if (payload && projectParam && payload.projectId !== projectParam) {
      conn.socket.close(1008, 'Project mismatch');
      return;
    }
    if (!payload && !isLocal) {
      conn.socket.close(1008, 'Unauthorized');
      return;
    }
    let projectRoot = '';
    try {
      projectRoot = await getProjectRoot(effectiveProjectId);
    } catch {
      conn.socket.close(1008, 'Project not found');
      return;
    }
    if (!isTextFile(filePath)) {
      conn.socket.close(1003, 'Binary file');
      return;
    }
    let absPath = '';
    try {
      absPath = safeJoin(projectRoot, filePath);
    } catch {
      conn.socket.close(1008, 'Invalid path');
      return;
    }
    const metaPath = path.join(projectRoot, 'project.json');
    const key = `${effectiveProjectId}:${filePath}`;
    if (!collaborationEnabled(effectiveProjectId)) {
      conn.socket.close(1008, 'Collaboration is off');
      return;
    }
    const doc = await getOrCreateDoc({ key, absPath, metaPath, filePath });
    if (!collaborationEnabled(effectiveProjectId)) {
      conn.socket.close(1008, 'Collaboration is off');
      return;
    }
    setupConnection(doc, conn.socket, payload
      ? { author: { name: payload.name || 'Guest', kind: 'guest' }, inviteId: payload.inviteId, readOnly: payload.role === 'view', canWrite: () => verifyToken(tokenValue)?.role === 'edit' }
      : { author: { name: OWNER_NAME, kind: 'owner' } });
  });
}
