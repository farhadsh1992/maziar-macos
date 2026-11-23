// Numenor's version and updates from GitHub. The version lives in the root package.json ("version" plus
// "releaseLabel", shown as e.g. "Beta 1.0.5"); every published update raises it. The app compares it with
// the package.json on GitHub and, when asked, updates itself in place:
//   - a git checkout (the usual `git clone` install): `git pull --ff-only`
//   - anything else (e.g. the copy Maziar sets up): the latest source archive, unpacked over the code
// then `npm install` (only if package-lock.json changed) and `npm run build`, and restarts. Projects and
// settings live outside the code (data folder, state folder) and are never touched.
import { promises as fs, existsSync, readFileSync, createWriteStream } from 'fs';
import path from 'path';
import os from 'os';
import { spawn } from 'child_process';
import { Readable } from 'stream';
import { pipeline } from 'stream/promises';
import tar from 'tar';
import { REPO_ROOT } from '../config/constants.js';

const REPO = process.env.NUMENOR_UPDATE_REPO || 'farhadsh1992/numenor';
const BRANCH = process.env.NUMENOR_UPDATE_BRANCH || 'main';
const CHECK_TTL_MS = 30 * 60 * 1000;
// Maziar (or another supervisor) restarts Numenor when it exits with this code.
export const RESTART_EXIT_CODE = 75;

function readPackage(root = REPO_ROOT) {
  try {
    return JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
  } catch {
    return {};
  }
}

export function currentVersion() {
  const pkg = readPackage();
  const version = String(pkg.version || '0.0.0');
  const label = String(pkg.releaseLabel || '').trim();
  return { version, label, display: label ? `${label} ${version}` : version };
}

/** -1 / 0 / 1 for plain x.y.z versions. */
export function compareVersions(a, b) {
  const pa = String(a).split(/[.+-]/).map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split(/[.+-]/).map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length, 3); i += 1) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0 ? 1 : -1;
  }
  return 0;
}

let lastCheck = null; // { at, result }

export async function checkForUpdate({ force = false } = {}) {
  if (!force && lastCheck && Date.now() - lastCheck.at < CHECK_TTL_MS) return lastCheck.result;
  const current = currentVersion();
  const res = await fetch(`https://raw.githubusercontent.com/${REPO}/${BRANCH}/package.json?t=${Date.now()}`, {
    headers: { 'Cache-Control': 'no-cache', 'User-Agent': 'numenor-updater' },
    signal: AbortSignal.timeout(15000)
  });
  if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
  const remote = await res.json();
  const latestVersion = String(remote.version || '0.0.0');
  const latestLabel = String(remote.releaseLabel || '').trim();
  let notes = '';
  try {
    // The latest commit's message says what changed (best effort; GitHub limits anonymous API calls).
    const commit = await fetch(`https://api.github.com/repos/${REPO}/commits/${BRANCH}`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'numenor-updater' },
      signal: AbortSignal.timeout(10000)
    });
    if (commit.ok) {
      const lines = String((await commit.json())?.commit?.message || '').split('\nSynced from maziar@')[0].trim().split('\n');
      // The sync commit repeats its subject as the first "- " line of the list below it.
      notes = lines.filter((line, i) => i === 0 || line.trim() !== `- ${lines[0].trim()}`).join('\n').replace(/\n{3,}/g, '\n\n').trim();
    }
  } catch {
    /* no notes */
  }
  const result = {
    ok: true,
    current,
    latest: { version: latestVersion, label: latestLabel, display: latestLabel ? `${latestLabel} ${latestVersion}` : latestVersion },
    available: compareVersions(latestVersion, current.version) > 0,
    notes: notes.slice(0, 2000),
    method: existsSync(path.join(REPO_ROOT, '.git')) ? 'git' : 'archive',
    checkedAt: new Date().toISOString()
  };
  lastCheck = { at: Date.now(), result };
  return result;
}

// ---- Applying an update -------------------------------------------------------------------------------

const progress = { state: 'idle', step: '', error: '', log: '', startedAt: null };

export function updateProgress() {
  return { ...progress, log: progress.log.slice(-6000) };
}

function step(state, text) {
  progress.state = state;
  progress.step = text;
  progress.log += `\n▸ ${text}\n`;
}

/** Node's own folder first, then the usual Homebrew places — a GUI-launched app has a bare PATH. */
function toolEnv() {
  const extra = [path.dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin'];
  return { ...process.env, PATH: [...extra, process.env.PATH || '/usr/bin:/bin'].join(':') };
}

function run(cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd, env: toolEnv() });
    const add = (d) => {
      progress.log += d.toString();
      if (progress.log.length > 60000) progress.log = progress.log.slice(-40000);
    };
    child.stdout.on('data', add);
    child.stderr.on('data', add);
    child.on('error', reject);
    child.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} ${args.join(' ')} failed (exit ${code})`))));
  });
}

async function fileText(p) {
  try {
    return await fs.readFile(p, 'utf8');
  } catch {
    return '';
  }
}

/** Files the update must never overwrite: projects, dependencies, build output, local markers. */
const KEEP = new Set(['data', 'node_modules', '.git', '.DS_Store']);
const keep = (rel) => {
  const first = rel.split('/')[0];
  return KEEP.has(first) || first.startsWith('.maziar-') || first.startsWith('.numenor-') || rel === 'apps/frontend/dist' || rel.startsWith('apps/frontend/dist/');
};

async function copyOver(from, to, rel = '') {
  for (const entry of await fs.readdir(path.join(from, rel), { withFileTypes: true })) {
    const childRel = rel ? `${rel}/${entry.name}` : entry.name;
    if (keep(childRel)) continue;
    const src = path.join(from, childRel);
    const dest = path.join(to, childRel);
    if (entry.isDirectory()) {
      await fs.mkdir(dest, { recursive: true });
      await copyOver(from, to, childRel);
    } else if (entry.isFile()) {
      await fs.copyFile(src, dest);
    }
  }
}

async function updateFromArchive() {
  const work = await fs.mkdtemp(path.join(os.tmpdir(), 'numenor-update-'));
  try {
    step('downloading', 'Downloading the latest Numenor from GitHub…');
    const res = await fetch(`https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}`, {
      headers: { 'User-Agent': 'numenor-updater' },
      signal: AbortSignal.timeout(5 * 60 * 1000)
    });
    if (!res.ok || !res.body) throw new Error(`Download failed (GitHub answered ${res.status}).`);
    const archive = path.join(work, 'numenor.tar.gz');
    await pipeline(Readable.fromWeb(res.body), createWriteStream(archive));
    const unpacked = path.join(work, 'src');
    await fs.mkdir(unpacked);
    await tar.x({ file: archive, cwd: unpacked, strip: 1 });
    if (!existsSync(path.join(unpacked, 'package.json'))) throw new Error('The download doesn’t look like Numenor.');
    step('installing', 'Copying the new files…');
    await copyOver(unpacked, REPO_ROOT);
  } finally {
    await fs.rm(work, { recursive: true, force: true }).catch(() => {});
  }
}

export function applyUpdate({ onRestart }) {
  if (['downloading', 'installing', 'building', 'restarting'].includes(progress.state)) return updateProgress();
  Object.assign(progress, { state: 'downloading', step: '', error: '', log: '', startedAt: new Date().toISOString() });
  (async () => {
    const lockBefore = await fileText(path.join(REPO_ROOT, 'package-lock.json'));
    if (existsSync(path.join(REPO_ROOT, '.git'))) {
      step('downloading', 'Getting the latest Numenor from GitHub (git pull)…');
      await run('git', ['pull', '--ff-only'], REPO_ROOT);
    } else {
      await updateFromArchive();
    }
    const lockAfter = await fileText(path.join(REPO_ROOT, 'package-lock.json'));
    if (lockBefore !== lockAfter || !existsSync(path.join(REPO_ROOT, 'node_modules'))) {
      step('installing', 'Installing dependencies…');
      await run('npm', ['install', '--no-audit', '--no-fund'], REPO_ROOT);
    }
    step('building', 'Building the interface…');
    await run('npm', ['run', 'build'], REPO_ROOT);
    lastCheck = null;
    step('restarting', `Restarting Numenor ${currentVersion().display}…`);
    setTimeout(() => onRestart(), 800);
  })().catch((err) => {
    progress.state = 'error';
    progress.error = String(err?.message || err);
    progress.log += `\n✗ ${progress.error}\n`;
  });
  return updateProgress();
}

/**
 * Restarts the server so the new code runs. Under Maziar (NUMENOR_SUPERVISED=1) exiting with
 * RESTART_EXIT_CODE is enough — Maziar starts it again. On its own, Numenor starts a fresh copy of itself
 * (same command, folder and settings) that waits for this one to free the port, then exits.
 */
export function restartServer() {
  if (process.env.NUMENOR_SUPERVISED === '1') process.exit(RESTART_EXIT_CODE);
  const child = spawn(process.execPath, process.argv.slice(1), {
    cwd: process.cwd(),
    env: { ...process.env, NUMENOR_RESTARTED: '1' },
    detached: true,
    stdio: 'ignore'
  });
  child.unref();
  process.exit(0);
}
