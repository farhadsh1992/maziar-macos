// Maziar: SyncTeX navigation between LaTeX source and the compiled PDF.
//
// Every successful compile keeps the PDF and its `.synctex.gz` in `<project>/.compile/last/`
// (see `keepLastBuild` in compileService.js). These routes ask the `synctex` command-line tool that
// ships with every TeX distribution to translate between the two:
//   forward  source file + line  -> PDF page + box (points, origin top-left of the page)
//   reverse  PDF page + point    -> source file + line
import path from 'path';
import zlib from 'zlib';
import { promises as fs } from 'fs';
import { spawn } from 'child_process';
import { getProjectRoot } from '../services/projectService.js';
import { lastBuildDir } from '../services/compileService.js';

function run(cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString(); });
    child.stderr.on('data', (d) => { err += d.toString(); });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, out, err }));
  });
}

async function loadBuild(projectId) {
  const projectRoot = await getProjectRoot(projectId);
  const dir = lastBuildDir(projectRoot);
  let meta;
  try {
    meta = JSON.parse(await fs.readFile(path.join(dir, 'build.json'), 'utf8'));
  } catch {
    throw new Error('Compile the project first.');
  }
  if (!meta.synctex) throw new Error('The last compile produced no SyncTeX data.');
  return { projectRoot, dir, meta, pdf: path.join(dir, `${meta.base}.pdf`) };
}

/** Source paths as SyncTeX recorded them (absolute, or relative to the project with `./`). */
async function recordedInputs(build) {
  const raw = zlib.gunzipSync(await fs.readFile(path.join(build.dir, `${build.meta.base}.synctex.gz`))).toString('utf8');
  // Files \input later in the document are declared where TeX opens them, i.e. anywhere in the body.
  const inputs = [];
  const re = /^Input:\d+:(.*)$/gm;
  let match;
  while ((match = re.exec(raw))) inputs.push(match[1]);
  return inputs;
}

/** A recorded/reported source path as a project-relative path, or '' when it's outside the project. */
function toProjectPath(projectRoot, recorded, outDir) {
  if (!recorded) return '';
  const candidates = [path.resolve(projectRoot, recorded)];
  if (outDir) candidates.push(path.resolve(outDir, recorded));
  for (const abs of candidates) {
    const rel = path.relative(projectRoot, abs);
    if (rel && !rel.startsWith('..') && !path.isAbsolute(rel)) return rel.split(path.sep).join('/');
  }
  return '';
}

function parseRecords(text) {
  const records = [];
  let current = null;
  for (const line of text.split('\n')) {
    const match = line.match(/^(\w+):(.*)$/);
    if (!match) continue;
    const [, key, value] = match;
    if (key === 'Page' || key === 'Input') {
      current = {};
      records.push(current);
    }
    if (current) current[key] = value;
  }
  return records;
}

export function registerSynctexRoutes(fastify) {
  fastify.get('/api/projects/:id/synctex/forward', async (req, reply) => {
    const { id } = req.params;
    const file = String(req.query.file || '');
    const line = Math.max(1, Number(req.query.line) || 1);
    const column = Math.max(0, Number(req.query.column) || 0);
    try {
      const build = await loadBuild(id);
      const inputs = await recordedInputs(build);
      const recorded = inputs.find((input) => toProjectPath(build.projectRoot, input, build.meta.outDir) === file);
      if (!recorded) {
        return reply.code(404).send({ ok: false, error: `${file} is not part of the last compiled PDF.` });
      }
      const { code, out, err } = await run('synctex', ['view', '-i', `${line}:${column}:${recorded}`, '-o', build.pdf], build.projectRoot);
      if (code !== 0) return reply.code(500).send({ ok: false, error: err.trim() || 'synctex failed' });
      const boxes = parseRecords(out)
        .filter((r) => r.Page)
        .map((r) => ({ page: Number(r.Page), h: Number(r.h), v: Number(r.v), width: Number(r.W), height: Number(r.H) }))
        .filter((b) => Number.isFinite(b.page) && Number.isFinite(b.h) && Number.isFinite(b.v));
      if (!boxes.length) return reply.code(404).send({ ok: false, error: 'No matching position in the PDF.' });
      return { ok: true, boxes };
    } catch (err) {
      return reply.code(400).send({ ok: false, error: err.message || String(err) });
    }
  });

  fastify.get('/api/projects/:id/synctex/reverse', async (req, reply) => {
    const { id } = req.params;
    const page = Math.max(1, Number(req.query.page) || 1);
    const x = Number(req.query.x) || 0;
    const y = Number(req.query.y) || 0;
    try {
      const build = await loadBuild(id);
      const { code, out, err } = await run('synctex', ['edit', '-o', `${page}:${x}:${y}:${build.pdf}`], build.projectRoot);
      if (code !== 0) return reply.code(500).send({ ok: false, error: err.trim() || 'synctex failed' });
      const hit = parseRecords(out).find((r) => r.Input);
      const file = hit ? toProjectPath(build.projectRoot, hit.Input.trim(), build.meta.outDir) : '';
      if (!file) return reply.code(404).send({ ok: false, error: 'No source position for that spot.' });
      return { ok: true, file, line: Math.max(1, Number(hit.Line) || 1), column: Math.max(0, Number(hit.Column) || 0) };
    } catch (err) {
      return reply.code(400).send({ ok: false, error: err.message || String(err) });
    }
  });
}
