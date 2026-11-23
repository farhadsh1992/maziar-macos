import crypto from 'crypto';
import path from 'path';
import { promises as fs } from 'fs';
import { spawn } from 'child_process';
import { ensureDir } from '../utils/fsUtils.js';
import { safeJoin } from '../utils/pathUtils.js';
import { getProjectRoot } from './projectService.js';
import { projectChanged } from './projectEvents.js';

const SUPPORTED_ENGINES = ['pdflatex', 'xelatex', 'lualatex', 'latexmk', 'tectonic'];

function buildCommand(engine, outDir, mainFile) {
  switch (engine) {
    // Maziar: -synctex=1 for source <-> PDF navigation, -file-line-error so every error names its file.
    case 'pdflatex':
    case 'xelatex':
    case 'lualatex':
      return { cmd: engine, args: ['-interaction=nonstopmode', '-synctex=1', '-file-line-error', `-output-directory=${outDir}`, mainFile] };
    case 'latexmk':
      return { cmd: 'latexmk', args: ['-pdf', '-interaction=nonstopmode', '-synctex=1', '-file-line-error', `-outdir=${outDir}`, mainFile] };
    case 'tectonic':
      return { cmd: 'tectonic', args: ['--synctex', '--outdir', outDir, mainFile] };
    default:
      return null;
  }
}

export { SUPPORTED_ENGINES };

// Engines that need multiple passes + bibtex for citations
const MULTI_PASS_ENGINES = ['pdflatex', 'xelatex', 'lualatex'];

// Maziar: TeX wraps log lines at 79 characters by default, which splits file names and messages and
// breaks error parsing. A wide limit keeps every message on one line.
const TEX_LOG_ENV = { max_print_line: '10000', error_line: '254', half_error_line: '238' };

// A document can send TeX into an endless loop (e.g. a longtable or other environment left open). Without a
// limit each Compile click left another pdflatex running at full CPU forever. Now a whole compile gets
// COMPILE_TIMEOUT_MS, and a new compile of the same project stops the one still running.
const COMPILE_TIMEOUT_MS = Number(process.env.NUMENOR_COMPILE_TIMEOUT_SEC || 180) * 1000;
const activeRuns = new Map(); // projectId → run { children:Set, stopped:'' | 'timeout' | 'replaced' }

class CompileStopped extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

function stopRun(run, reason) {
  if (run.stopped) return;
  run.stopped = reason;
  for (const child of run.children) {
    try { child.kill('SIGKILL'); } catch { /* already gone */ }
  }
}

function runSpawn(cmd, args, cwd, pushLog, env, run) {
  return new Promise((resolve, reject) => {
    if (run?.stopped) return reject(new CompileStopped(run.stopped));
    const child = spawn(cmd, args, { cwd, env: { ...(env || process.env), ...TEX_LOG_ENV } });
    run?.children.add(child);
    child.stdout.on('data', pushLog);
    child.stderr.on('data', pushLog);
    child.on('error', (err) => { run?.children.delete(child); reject(err); });
    child.on('close', (code) => {
      run?.children.delete(child);
      if (run?.stopped) reject(new CompileStopped(run.stopped));
      else resolve(code);
    });
  });
}

export async function runCompile({ projectId, mainFile, engine = 'pdflatex' }) {
  if (!SUPPORTED_ENGINES.includes(engine)) {
    return { ok: false, error: `Unsupported engine: ${engine}` };
  }

  const projectRoot = await getProjectRoot(projectId);
  const absMain = safeJoin(projectRoot, mainFile);
  await fs.access(absMain);

  const buildRoot = path.join(projectRoot, '.compile');
  await ensureDir(buildRoot);
  const runId = crypto.randomUUID();
  const outDir = path.join(buildRoot, runId);
  await ensureDir(outDir);

  const logChunks = [];
  const MAX_LOG_BYTES = 200_000;
  const pushLog = (chunk) => {
    if (!chunk) return;
    const next = chunk.toString();
    const currentSize = logChunks.reduce((sum, item) => sum + item.length, 0);
    if (currentSize >= MAX_LOG_BYTES) return;
    const remaining = MAX_LOG_BYTES - currentSize;
    logChunks.push(next.slice(0, remaining));
  };

  const { cmd, args } = buildCommand(engine, outDir, mainFile);
  const needsBibPass = MULTI_PASS_ENGINES.includes(engine);

  const previous = activeRuns.get(projectId);
  if (previous) stopRun(previous, 'replaced');
  const run = { children: new Set(), stopped: '' };
  activeRuns.set(projectId, run);
  const timer = setTimeout(() => stopRun(run, 'timeout'), COMPILE_TIMEOUT_MS);
  const finish = () => {
    clearTimeout(timer);
    if (activeRuns.get(projectId) === run) activeRuns.delete(projectId);
  };

  let code;
  try {
    // Pass 1: generate .aux with \citation{} entries
    code = await runSpawn(cmd, args, projectRoot, pushLog, undefined, run);

    if (needsBibPass) {
      const base = path.basename(mainFile, path.extname(mainFile));
      const auxPath = path.join(outDir, `${base}.aux`);

      // Detect whether to use biber or bibtex by checking .aux / source for biblatex
      let useBiber = false;
      try {
        const auxContent = await fs.readFile(auxPath, 'utf8');
        // biblatex writes \abx@aux@... commands in .aux; traditional bibtex does not
        useBiber = auxContent.includes('\\abx@aux@');
      } catch { /* .aux missing — skip bib pass */ }

      // Also check the source .tex for \usepackage{biblatex} as a fallback
      if (!useBiber) {
        try {
          const texContent = await fs.readFile(safeJoin(projectRoot, mainFile), 'utf8');
          useBiber = /\\usepackage(\[.*?\])?\{biblatex\}/.test(texContent);
        } catch { /* ignore */ }
      }

      const bibCmd = useBiber ? 'biber' : 'bibtex';
      const bibEnv = {
        ...process.env,
        BIBINPUTS: `${projectRoot}:`,
        BSTINPUTS: `${projectRoot}:`,
      };
      // Run bibtex/biber with cwd=outDir and relative base name to avoid
      // openout_any=p blocking writes to absolute paths.
      const bibArgs = useBiber
        ? [`--input-directory=${projectRoot}`, base]
        : [base];

      try {
        await runSpawn(bibCmd, bibArgs, outDir, pushLog, bibEnv, run);
      } catch (err) {
        if (err instanceof CompileStopped) throw err;
        // bibtex/biber not installed or failed — continue without it
        pushLog(Buffer.from(`[warn] ${bibCmd} not available, skipping bibliography pass.\n`));
      }

      // Pass 2 + 3: resolve citations and cross-references
      code = await runSpawn(cmd, args, projectRoot, pushLog, undefined, run);
      code = await runSpawn(cmd, args, projectRoot, pushLog, undefined, run);
    }
  } catch (err) {
    finish();
    await fs.rm(outDir, { recursive: true, force: true }).catch(() => {});
    const log = logChunks.join('');
    if (err instanceof CompileStopped && err.reason === 'replaced') {
      return { ok: false, replaced: true, error: 'Stopped — a newer compile of this project started.', log };
    }
    if (err instanceof CompileStopped) {
      const secs = Math.round(COMPILE_TIMEOUT_MS / 1000);
      return {
        ok: false,
        timedOut: true,
        status: -1,
        error: `LaTeX was still running after ${secs} seconds and was stopped — the document probably sends it into an endless loop (often an environment that is never closed, e.g. \\begin{longtable} without \\end{longtable}). Fix the first error in the log and compile again.`,
        log
      };
    }
    return { ok: false, error: `${engine} not available: ${err.message}` };
  }
  finish();

  const base = path.basename(mainFile, path.extname(mainFile));
  const pdfPath = path.join(outDir, `${base}.pdf`);
  let pdfBase64 = '';
  try {
    const buffer = await fs.readFile(pdfPath);
    pdfBase64 = buffer.toString('base64');
  } catch {
    pdfBase64 = '';
  }
  const log = logChunks.join('');
  if (pdfBase64) {
    // Maziar: keep the latest PDF and its SyncTeX data for source <-> PDF navigation (see routes/synctex.js).
    await keepLastBuild({ buildRoot, outDir, base, mainFile }).then(() => projectChanged(projectRoot, 'compile')).catch(() => {});
  }
  await fs.rm(outDir, { recursive: true, force: true });
  if (!pdfBase64) {
    return { ok: false, error: 'No PDF generated.', log, status: code ?? -1 };
  }
  return { ok: true, pdf: pdfBase64, log, status: code ?? 0 };
}

export function lastBuildDir(projectRoot) {
  return path.join(projectRoot, '.compile', 'last');
}

async function keepLastBuild({ buildRoot, outDir, base, mainFile }) {
  const lastDir = path.join(buildRoot, 'last');
  await fs.rm(lastDir, { recursive: true, force: true });
  await ensureDir(lastDir);
  await fs.copyFile(path.join(outDir, `${base}.pdf`), path.join(lastDir, `${base}.pdf`));
  let synctex = false;
  try {
    await fs.copyFile(path.join(outDir, `${base}.synctex.gz`), path.join(lastDir, `${base}.synctex.gz`));
    synctex = true;
  } catch { /* engine without SyncTeX output */ }
  await fs.writeFile(
    path.join(lastDir, 'build.json'),
    JSON.stringify({ base, mainFile, outDir, synctex, builtAt: new Date().toISOString() })
  );
}
