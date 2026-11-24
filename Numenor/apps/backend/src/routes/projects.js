import { updateProjectMetadata, writingStatus, remapWritingStatuses } from '../services/projectMetadata.js';
import { projectChanged } from '../services/projectEvents.js';
import path from 'path';
import { promises as fs, createWriteStream } from 'fs';
import { pipeline } from 'stream/promises';
import tar from 'tar';
import unzipper from 'unzipper';
import crypto from 'crypto';
import { DATA_DIR, TEMPLATE_DIR, OWNER_NAME } from '../config/constants.js';
import { recordEdit, recordEvent, authorOf } from '../services/historyService.js';
import { ensureDir, readJson, writeJson, copyDir, listFilesRecursive } from '../utils/fsUtils.js';
import { safeJoin, sanitizeUploadPath } from '../utils/pathUtils.js';
import { isTextFile, extractDocumentBody, mergeTemplateBody } from '../utils/texUtils.js';
import { readTemplateManifest, copyTemplateIntoProject } from '../services/templateService.js';
import { getProjectRoot, getProjectCopies, getProjectFolders, resolveTargetFolder, expandHome } from '../services/projectService.js';
import { buildZip } from '../utils/zipWriter.js';
import { isLocalRequest } from '../utils/authUtils.js';
import { downloadArxivSource, extractArxivId } from '../services/arxivService.js';
import { getLang, t } from '../i18n/index.js';

/**
 * Files that can be compiled: every .tex file, plus .ltx / .txt files that start a document
 * (\\documentclass near the top) — Overleaf projects sometimes keep the real document in main.txt.
 */
async function mainFileCandidates(projectRoot, items) {
  const out = [];
  for (const item of items) {
    if (item.type !== 'file') continue;
    const rel = item.path.split(path.sep).join('/');
    if (/\.tex$/i.test(rel)) {
      out.push(rel);
      continue;
    }
    if (!/\.(ltx|txt)$/i.test(rel)) continue;
    try {
      const handle = await fs.open(path.join(projectRoot, item.path), 'r');
      try {
        const { buffer, bytesRead } = await handle.read(Buffer.alloc(8192), 0, 8192, 0);
        if (/^[^%\n]*\\documentclass/m.test(buffer.toString('utf8', 0, bytesRead))) out.push(rel);
      } finally {
        await handle.close();
      }
    } catch {
      /* unreadable: skip */
    }
  }
  return out;
}

export function registerProjectRoutes(fastify) {
  fastify.get('/api/projects', async (req) => {
    await ensureDir(DATA_DIR);
    const projects = [];
    const where = new Map(); // id → folders that hold it
    // Every project folder (the main one plus any added on the Projects page); `folder` says which.
    for (const folder of await getProjectFolders()) {
      let entries = [];
      try {
        entries = await fs.readdir(folder, { withFileTypes: true });
      } catch {
        continue; // e.g. a Google Drive folder that isn't available right now
      }
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        try {
          await fs.access(path.join(folder, entry.name, 'project.json'));
        } catch {
          continue;
        }
        if (!where.has(entry.name)) where.set(entry.name, []);
        where.get(entry.name).push(folder);
      }
    }
    for (const [id, folders] of where) {
      // In more than one folder: show the most recently changed copy (see getProjectCopies).
      let folder = folders[0];
      let otherCopies = [];
      if (folders.length > 1) {
        try {
          const copies = await getProjectCopies(id);
          folder = path.dirname(copies[0].root);
          otherCopies = copies.slice(1).map((c) => path.dirname(c.root));
        } catch {
          /* keep the first */
        }
      }
      try {
        const meta = await readJson(path.join(folder, id, 'project.json'));
        projects.push({
          ...meta,
          id,
          folder,
          otherCopies,
          updatedAt: meta.updatedAt || meta.createdAt,
          tags: meta.tags || [],
          archived: meta.archived || false,
          trashed: meta.trashed || false,
          trashedAt: meta.trashedAt || null
        });
      } catch {
        // ignore
      }
    }
    // An invited visitor sees only the project they were invited to.
    if (req.collabAuth?.projectId) return { projects: projects.filter((p) => p.id === req.collabAuth.projectId) };
    return { projects };
  });

  fastify.post('/api/projects', async (req, reply) => {
    await ensureDir(DATA_DIR);
    const { name = 'Untitled', template, folder } = req.body || {};
    const id = crypto.randomUUID();
    const projectRoot = path.join(await resolveTargetFolder(folder), id);
    await ensureDir(projectRoot);
    const meta = { id, name, createdAt: new Date().toISOString() };
    await writeJson(path.join(projectRoot, 'project.json'), meta);
    if (template) {
      const templateRoot = path.join(TEMPLATE_DIR, template);
      await copyDir(templateRoot, projectRoot);
    }
    reply.send(meta);
  });

  fastify.post('/api/projects/import-zip', async (req) => {
    const lang = getLang(req);
    await ensureDir(DATA_DIR);
    const id = crypto.randomUUID();
    const projectRoot = path.join(await resolveTargetFolder(req.query?.folder), id);
    await ensureDir(projectRoot);
    let projectName = 'Imported Project';
    let hasZip = false;

    try {
      const parts = req.parts();
      for await (const part of parts) {
        if (part.type === 'field' && part.fieldname === 'projectName') {
          projectName = String(part.value || '').trim() || projectName;
          continue;
        }
        if (part.type !== 'file') continue;
        hasZip = true;
        const zipStream = part.file.pipe(unzipper.Parse({ forceStream: true }));
        for await (const entry of zipStream) {
          const relPath = sanitizeUploadPath(entry.path);
          if (!relPath || relPath.endsWith('project.json')) {
            entry.autodrain();
            continue;
          }
          const abs = safeJoin(projectRoot, relPath);
          if (entry.type === 'Directory') {
            await ensureDir(abs);
            entry.autodrain();
            continue;
          }
          await ensureDir(path.dirname(abs));
          await pipeline(entry, createWriteStream(abs));
        }
      }
    } catch (err) {
      await fs.rm(projectRoot, { recursive: true, force: true });
      return { ok: false, error: t(lang, 'zip_extract_failed', { error: String(err) }) };
    }

    if (!hasZip) {
      return { ok: false, error: 'Missing zip file.' };
    }

    const meta = { id, name: projectName, createdAt: new Date().toISOString() };
    await writeJson(path.join(projectRoot, 'project.json'), meta);
    return { ok: true, project: meta };
  });

  fastify.get('/api/projects/import-arxiv-sse', async (req, reply) => {
    const lang = getLang(req);
    await ensureDir(DATA_DIR);
    const { arxivIdOrUrl, projectName, folder } = req.query;
    const arxivId = extractArxivId(arxivIdOrUrl);
    req.log.info({ arxivId, arxivIdOrUrl }, 'import-arxiv-sse: parsed id');

    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive'
    });
    const send = (event, data) => {
      reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    };

    if (!arxivId) {
      send('error', { error: 'Invalid arXiv ID.' });
      reply.raw.end();
      return reply;
    }

    const id = crypto.randomUUID();
    const projectRoot = path.join(await resolveTargetFolder(folder), id);
    await ensureDir(projectRoot);
    const meta = {
      id,
      name: projectName || `arxiv-${arxivId}`,
      createdAt: new Date().toISOString()
    };

    const tmpTar = path.join(projectRoot, '__arxiv_source.tar.gz');
    try {
      send('progress', { phase: 'download', percent: 0 });
      await downloadArxivSource(arxivId, tmpTar, ({ received, total }) => {
        const percent = total > 0 ? Math.round((received / total) * 100) : -1;
        send('progress', { phase: 'download', percent, received, total });
      });

      send('progress', { phase: 'extract', percent: -1 });
      await tar.x({
        file: tmpTar,
        cwd: projectRoot,
        filter: (entryPath) => {
          if (!entryPath) return false;
          if (path.isAbsolute(entryPath)) return false;
          return !entryPath.split('/').some((part) => part === '..');
        }
      });
    } catch (err) {
      await fs.rm(projectRoot, { recursive: true, force: true });
      send('error', { error: t(lang, 'arxiv_download_failed', { error: String(err) }) });
      reply.raw.end();
      return reply;
    } finally {
      await fs.rm(tmpTar, { force: true });
    }

    await writeJson(path.join(projectRoot, 'project.json'), meta);
    send('done', { ok: true, project: meta });
    reply.raw.end();
    return reply;
  });

  fastify.post('/api/projects/:id/rename-project', async (req) => {
    const { id } = req.params;
    const { name } = req.body || {};
    if (!name) return { ok: false, error: 'Missing name' };
    const projectRoot = await getProjectRoot(id);
    const next = await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, name }));
    return { ok: true, project: next };
  });

  fastify.post('/api/projects/:id/copy', async (req) => {
    const { id } = req.params;
    const { name } = req.body || {};
    const srcRoot = await getProjectRoot(id);
    const srcMeta = await readJson(path.join(srcRoot, 'project.json'));
    const newId = crypto.randomUUID();
    // A copy stays in the same folder as the original.
    const destRoot = path.join(path.dirname(srcRoot), newId);
    await copyDir(srcRoot, destRoot);
    const newMeta = {
      ...srcMeta,
      id: newId,
      name: name || `${srcMeta.name} (Copy)`,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      trashed: false,
      trashedAt: null,
    };
    await writeJson(path.join(destRoot, 'project.json'), newMeta);
    return { ok: true, project: newMeta };
  });

  fastify.delete('/api/projects/:id', async (req) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, trashed: true, trashedAt: new Date().toISOString() }));
    return { ok: true };
  });

  // Download a project as a .zip (its files, without build output) — importable again with "Import project".
  fastify.get('/api/projects/:id/download', async (req, reply) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    let name = 'project';
    try {
      name = (await readJson(path.join(projectRoot, 'project.json'))).name || name;
    } catch { /* keep default */ }
    const items = await listFilesRecursive(projectRoot); // skips project.json and .compile/
    const entries = [];
    for (const item of items) {
      if (item.type !== 'file' || path.basename(item.path) === '.DS_Store') continue;
      const abs = path.join(projectRoot, item.path);
      const [data, stat] = await Promise.all([fs.readFile(abs), fs.stat(abs)]);
      entries.push({ name: item.path.split(path.sep).join('/'), data, mtime: stat.mtime });
    }
    const zip = buildZip(entries);
    const safe = name.replace(/[^\p{L}\p{N}._ -]+/gu, '').trim().replace(/\s+/g, '-') || 'project';
    reply
      .header('Content-Type', 'application/zip')
      .header('Content-Disposition', `attachment; filename="${safe.replace(/[^\x20-\x7e]/g, '_')}.zip"; filename*=UTF-8''${encodeURIComponent(safe)}.zip`)
      .header('Content-Length', zip.length);
    return reply.send(zip);
  });

  // Move a project to another project folder (e.g. into or out of a Google Drive folder). Only on this computer.
  fastify.post('/api/projects/:id/move', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Projects can only be moved on the computer running Numenor.' });
    const { id } = req.params;
    const srcRoot = await getProjectRoot(id);
    const wanted = path.resolve(expandHome(String(req.body?.folder || '')));
    const folders = await getProjectFolders();
    const target = folders.find((f) => path.resolve(f) === wanted);
    if (!target) return reply.code(400).send({ ok: false, error: 'Choose one of the project folders.' });
    if (path.resolve(path.dirname(srcRoot)) === path.resolve(target)) return { ok: true, folder: target, unchanged: true };
    const destRoot = path.join(target, id);
    try {
      await fs.access(destRoot);
      return reply.code(409).send({ ok: false, error: 'A project with the same id already exists there.' });
    } catch { /* free */ }
    try {
      await fs.rename(srcRoot, destRoot);
    } catch (err) {
      if (err.code !== 'EXDEV' && err.code !== 'EPERM') throw err;
      // Different volumes (e.g. into Google Drive): copy, check, then remove the original.
      await copyDir(srcRoot, destRoot);
      await fs.access(path.join(destRoot, 'project.json'));
      await fs.rm(srcRoot, { recursive: true, force: true });
    }
    return { ok: true, folder: target };
  });

  fastify.delete('/api/projects/:id/permanent', async (req) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    await fs.rm(projectRoot, { recursive: true, force: true });
    return { ok: true };
  });

  fastify.patch('/api/projects/:id/tags', async (req) => {
    const { id } = req.params;
    const { tags } = req.body || {};
    if (!Array.isArray(tags)) return { ok: false, error: 'tags must be an array' };
    const projectRoot = await getProjectRoot(id);
    const next = await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, tags, updatedAt: new Date().toISOString() }));
    return { ok: true, project: next };
  });

  fastify.patch('/api/projects/:id/archive', async (req) => {
    const { id } = req.params;
    const { archived } = req.body || {};
    const projectRoot = await getProjectRoot(id);
    const next = await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, archived: !!archived, updatedAt: new Date().toISOString() }));
    return { ok: true, project: next };
  });

  fastify.patch('/api/projects/:id/trash', async (req) => {
    const { id } = req.params;
    const { trashed } = req.body || {};
    const projectRoot = await getProjectRoot(id);
    const next = await updateProjectMetadata(projectRoot, (meta) => ({
      ...meta,
      trashed: !!trashed,
      trashedAt: trashed ? new Date().toISOString() : null,
      updatedAt: new Date().toISOString()
    }));
    return { ok: true, project: next };
  });

  fastify.get('/api/projects/:id/tree', async (req) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    const items = await listFilesRecursive(projectRoot);
    let fileOrder = {};
    let statuses = {};
    let mainFile = '';
    try {
      const meta = await readJson(path.join(projectRoot, 'project.json'));
      fileOrder = meta?.fileOrder || {};
      statuses = meta?.writingStatuses || {};
      mainFile = typeof meta?.mainFile === 'string' ? meta.mainFile : '';
    } catch {
      fileOrder = {};
    }
    for (const item of items) {
      if (item.type !== 'file' || !/\.txt$/i.test(item.path)) continue;
      const saved = writingStatus(statuses[item.path]);
      if (saved) item.writingStatus = saved;
    }
    return { items, fileOrder, mainFile, mainFiles: await mainFileCandidates(projectRoot, items) };
  });

  // A cheap fingerprint of every file (modified time + size), polled by the open editor so changes made
  // outside Numenor show up: Google Drive / iCloud bringing in edits from another computer, a text editor…
  fastify.get('/api/projects/:id/stat', async (req) => {
    const projectRoot = await getProjectRoot(req.params.id);
    const items = await listFilesRecursive(projectRoot);
    const files = [];
    for (const item of items) {
      if (item.type !== 'file') continue;
      try {
        const st = await fs.stat(path.join(projectRoot, item.path));
        files.push([item.path.split(path.sep).join('/'), Math.round(st.mtimeMs), st.size]);
      } catch {
        /* vanished meanwhile */
      }
    }
    return { ok: true, files };
  });

  // Where a project is kept on this computer (shown in the editor's settings). Only for the computer running
  // Numenor — invited people never see the owner's folders.
  fastify.get('/api/projects/:id/location', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    const projectRoot = await getProjectRoot(req.params.id);
    const p = projectRoot.split(path.sep).join('/');
    let place = 'This computer';
    let m;
    if ((m = p.match(/\/Library\/CloudStorage\/GoogleDrive-([^/]+)\//))) place = `Google Drive (${m[1]})`;
    else if (/\/Library\/CloudStorage\/OneDrive-SharedLibraries/.test(p)) place = 'SharePoint (via OneDrive)';
    else if ((m = p.match(/\/Library\/CloudStorage\/OneDrive-?([^/]*)\//))) place = m[1] ? `OneDrive (${m[1]})` : 'OneDrive';
    else if (/\/Library\/CloudStorage\/Dropbox/.test(p)) place = 'Dropbox';
    else if (/\/Library\/Mobile Documents\/com~apple~CloudDocs\//.test(p)) place = 'iCloud Drive';
    const otherCopies = (await getProjectCopies(req.params.id)).slice(1).map((c) => c.root);
    return { ok: true, path: projectRoot, projectsFolder: path.dirname(projectRoot), place, inDataFolder: path.resolve(path.dirname(projectRoot)) === path.resolve(DATA_DIR), otherCopies };
  });

  // "Show in Finder" (Explorer / file manager): the server runs on this computer, so it can open it.
  fastify.post('/api/projects/:id/reveal', async (req, reply) => {
    if (!isLocalRequest(req)) return reply.code(403).send({ ok: false, error: 'Only on the computer running Numenor.' });
    const projectRoot = await getProjectRoot(req.params.id);
    const { spawn } = await import('child_process');
    const [cmd, args] = process.platform === 'darwin' ? ['open', [projectRoot]]
      : process.platform === 'win32' ? ['explorer', [projectRoot]]
        : ['xdg-open', [projectRoot]];
    try {
      const child = spawn(cmd, args, { detached: true, stdio: 'ignore' });
      child.on('error', () => {});
      child.unref();
      return { ok: true };
    } catch (err) {
      return reply.code(500).send({ ok: false, error: String(err?.message || err) });
    }
  });

  // The file to compile, saved in project.json so everyone working on the project (and every computer)
  // compiles the same one — e.g. main.txt in a project brought over from Overleaf.
  fastify.put('/api/projects/:id/writing-status', async (req, reply) => {
    const { path: file, tag } = req.body || {};
    const saved = tag === null ? null : writingStatus(tag);
    if (typeof file !== 'string' || !/\.txt$/i.test(file) || (tag !== null && !saved)) {
      return reply.code(400).send({ ok: false, error: 'Choose a TXT file and a valid writing status.' });
    }
    const root = await getProjectRoot(req.params.id);
    const abs = safeJoin(root, file);
    const key = path.relative(root, abs).split(path.sep).join('/');
    let exists = false;
    await updateProjectMetadata(root, async (meta) => {
      exists = Boolean((await fs.lstat(abs).catch(() => null))?.isFile());
      if (!exists) return meta;
      const statuses = { ...meta.writingStatuses };
      if (saved) statuses[key] = saved;
      else delete statuses[key];
      return { ...meta, writingStatuses: statuses };
    });
    if (!exists) return reply.code(404).send({ ok: false, error: 'The file no longer exists.' });
    projectChanged(root);
    return { ok: true, tag: saved };
  });

  fastify.put('/api/projects/:id/main-file', async (req, reply) => {
    const projectRoot = await getProjectRoot(req.params.id);
    const wanted = String(req.body?.path || '').replace(/\\/g, '/');
    let abs;
    try {
      abs = safeJoin(projectRoot, wanted);
      await fs.access(abs);
    } catch {
      return reply.code(400).send({ ok: false, error: 'That file doesn’t exist in this project.' });
    }
    if (!/\.(tex|ltx|txt)$/i.test(wanted)) return reply.code(400).send({ ok: false, error: 'Choose a .tex, .ltx or .txt file.' });
    await updateProjectMetadata(projectRoot, (meta) => meta.mainFile === wanted ? meta : { ...meta, mainFile: wanted });
    return { ok: true, mainFile: wanted };
  });

  fastify.post('/api/projects/:id/file-order', async (req) => {
    const { id } = req.params;
    const { folder = '', order } = req.body || {};
    if (!Array.isArray(order)) {
      return { ok: false, error: 'Missing order.' };
    }
    const projectRoot = await getProjectRoot(id);
    await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, fileOrder: { ...(meta.fileOrder || {}), [folder]: order } }));
    return { ok: true };
  });

  fastify.get('/api/projects/:id/file', async (req) => {
    const { id } = req.params;
    const { path: filePath } = req.query;
    if (!filePath) return { content: '' };
    const projectRoot = await getProjectRoot(id);
    const abs = safeJoin(projectRoot, filePath);
    const content = await fs.readFile(abs, 'utf8');
    return { content };
  });

  fastify.get('/api/projects/:id/blob', async (req, reply) => {
    const { id } = req.params;
    const { path: filePath } = req.query;
    if (!filePath) return reply.code(400).send('Missing path');
    const projectRoot = await getProjectRoot(id);
    const abs = safeJoin(projectRoot, filePath);
    const buffer = await fs.readFile(abs);
    const ext = path.extname(filePath).toLowerCase();
    const contentTypes = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.svg': 'image/svg+xml',
      '.pdf': 'application/pdf',
      '.eps': 'application/postscript'
    };
    const contentType = contentTypes[ext] || 'application/octet-stream';
    reply.header('Content-Type', contentType);
    return reply.send(buffer);
  });

  fastify.post('/api/projects/:id/upload', async (req, reply) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    const saved = [];
    // Maziar: the multipart parser reduces a part's filename to its base name, so a file meant for
    // `figures/plots/a.png` used to land in the project root. The client now sends the intended
    // relative path in a `relpath` field right before each file; plain uploads still fall back to
    // the filename.
    let pendingRelPath = '';
    let current = '';
    try {
      for await (const part of req.parts()) {
        if (part.type !== 'file') {
          if (part.fieldname === 'relpath') pendingRelPath = String(part.value || '');
          continue;
        }
        const relPath = sanitizeUploadPath(pendingRelPath || part.filename);
        pendingRelPath = '';
        current = relPath || part.filename || '';
        if (!relPath) {
          part.file.resume();
          continue;
        }
        const abs = safeJoin(projectRoot, relPath);
        await ensureDir(path.dirname(abs));
        await pipeline(part.file, createWriteStream(abs));
        if (part.file.truncated) {
          await fs.rm(abs, { force: true });
          throw new Error('file is larger than the 200 MB upload limit');
        }
        saved.push(relPath);
        recordEvent(projectRoot, 'upload', relPath, authorOf(req, OWNER_NAME));
      }
    } catch (err) {
      const reason = err?.message || String(err);
      return reply.code(400).send({ ok: false, files: saved, error: current ? `${current}: ${reason}` : reason });
    }
    return { ok: true, files: saved };
  });

  fastify.put('/api/projects/:id/file', async (req) => {
    const { id } = req.params;
    const { path: filePath, content } = req.body || {};
    if (!filePath) return { ok: false };
    const projectRoot = await getProjectRoot(id);
    const abs = safeJoin(projectRoot, filePath);
    await ensureDir(path.dirname(abs));
    let before = null;
    try { before = await fs.readFile(abs, 'utf8'); } catch { /* new file */ }
    await fs.writeFile(abs, content ?? '', 'utf8');
    if (isTextFile(filePath)) recordEdit(projectRoot, filePath, before, content ?? '', authorOf(req, OWNER_NAME));
    try {
      await updateProjectMetadata(projectRoot, (meta) => ({ ...meta, updatedAt: new Date().toISOString() }));
    } catch { /* ignore */ }
    return { ok: true };
  });

  fastify.get('/api/projects/:id/files', async (req) => {
    const { id } = req.params;
    const projectRoot = await getProjectRoot(id);
    const items = await listFilesRecursive(projectRoot);
    const files = [];
    for (const item of items) {
      if (item.type !== 'file') continue;
      const abs = path.join(projectRoot, item.path);
      const buffer = await fs.readFile(abs);
      if (isTextFile(item.path)) {
        files.push({ path: item.path, content: buffer.toString('utf8'), encoding: 'utf8' });
      } else {
        files.push({ path: item.path, content: buffer.toString('base64'), encoding: 'base64' });
      }
    }
    return { files };
  });

  fastify.post('/api/projects/:id/convert-template', async (req) => {
    const { id } = req.params;
    const { targetTemplate, mainFile = 'main.tex' } = req.body || {};
    if (!targetTemplate) return { ok: false, error: 'Missing targetTemplate' };
    const { templates } = await readTemplateManifest();
    const template = templates.find((item) => item.id === targetTemplate);
    if (!template) return { ok: false, error: 'Unknown template' };

    try {
      const projectRoot = await getProjectRoot(id);
      const currentMainPath = safeJoin(projectRoot, mainFile);
      const templateRoot = path.join(TEMPLATE_DIR, template.id);
      const templateMain = template.mainFile || 'main.tex';
      const templateMainPath = path.join(templateRoot, templateMain);

      let currentTex = '';
      try {
        currentTex = await fs.readFile(currentMainPath, 'utf8');
      } catch {
        currentTex = '';
      }

      const templateTex = await fs.readFile(templateMainPath, 'utf8');
      const body = extractDocumentBody(currentTex);
      const merged = mergeTemplateBody(templateTex, body);
      const changedFiles = await copyTemplateIntoProject(templateRoot, projectRoot);
      await fs.writeFile(safeJoin(projectRoot, templateMain), merged, 'utf8');
      changedFiles.push(templateMain);
      return { ok: true, mainFile: templateMain, changedFiles };
    } catch (err) {
      return { ok: false, error: `Template convert failed: ${String(err)}` };
    }
  });

  fastify.post('/api/projects/:id/template', async (req) => {
    const { id } = req.params;
    const { template } = req.body || {};
    const projectRoot = await getProjectRoot(id);
    if (!template) return { ok: false };
    const templateRoot = path.join(TEMPLATE_DIR, template);
    await copyDir(templateRoot, projectRoot);
    return { ok: true };
  });

  fastify.post('/api/projects/:id/folder', async (req) => {
    const { id } = req.params;
    const { path: folderPath } = req.body || {};
    if (!folderPath) return { ok: false };
    const projectRoot = await getProjectRoot(id);
    const abs = safeJoin(projectRoot, folderPath);
    await ensureDir(abs);
    recordEvent(projectRoot, 'folder', folderPath, authorOf(req, OWNER_NAME));
    return { ok: true };
  });

  fastify.post('/api/projects/:id/rename', async (req) => {
    const { id } = req.params;
    const { from, to } = req.body || {};
    if (!from || !to) return { ok: false };
    const projectRoot = await getProjectRoot(id);
    const absFrom = safeJoin(projectRoot, from);
    const absTo = safeJoin(projectRoot, to);
    const keyFrom = path.relative(projectRoot, absFrom).split(path.sep).join('/');
    const keyTo = path.relative(projectRoot, absTo).split(path.sep).join('/');
    let conflict = false;
    await updateProjectMetadata(projectRoot, async (meta) => {
      const existing = await fs.lstat(absTo).catch((error) => {
        if (error.code !== 'ENOENT') throw error;
        return null;
      });
      if (existing && keyFrom !== keyTo) {
        const original = await fs.lstat(absFrom);
        const sameFile = original.dev === existing.dev && original.ino === existing.ino;
        if (!sameFile || keyFrom.toLowerCase() !== keyTo.toLowerCase()) {
          conflict = true;
          return meta;
        }
      }
      const next = remapWritingStatuses(meta, keyFrom, keyTo);
      await ensureDir(path.dirname(absTo));
      await fs.rename(absFrom, absTo);
      return next;
    }, () => fs.rename(absTo, absFrom));
    if (conflict) return { ok: false, error: `${to} already exists.` };
    recordEvent(projectRoot, 'rename', from, authorOf(req, OWNER_NAME), { to });
    return { ok: true };
  });

  fastify.delete('/api/projects/:id/file', async (req) => {
    const { id } = req.params;
    const { path: filePath } = req.query || {};
    if (!filePath) return { ok: false, error: 'Missing file path' };
    const projectRoot = await getProjectRoot(id);
    const abs = safeJoin(projectRoot, filePath);
    const key = path.relative(projectRoot, abs).split(path.sep).join('/');
    try {
      await updateProjectMetadata(projectRoot, async (meta) => {
        const stat = await fs.stat(abs);
        await fs.rm(abs, { recursive: stat.isDirectory() });
        return remapWritingStatuses(meta, key);
      });
    } catch (err) {
      if (err.code === 'ENOENT') {
        return { ok: false, error: 'File not found' };
      }
      throw err;
    }
    recordEvent(projectRoot, 'delete', filePath, authorOf(req, OWNER_NAME));
    return { ok: true };
  });
}
