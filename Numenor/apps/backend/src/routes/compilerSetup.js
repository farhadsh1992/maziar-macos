import { execFile } from 'node:child_process';
import { accessSync, constants, statSync } from 'node:fs';
import path from 'node:path';
import { promisify } from 'node:util';
import { SUPPORTED_ENGINES } from '../services/compileService.js';
import { isLocalRequest } from '../utils/authUtils.js';

const run = promisify(execFile);
const macTeXEngines = SUPPORTED_ENGINES.filter((engine) => engine !== 'tectonic');
const macTeXPackage = ['--cask', 'mactex-no-gui'];

export function addMacCompilerPaths() {
  if (process.platform !== 'darwin') return;
  process.env.PATH = [process.env.PATH, '/Library/TeX/texbin', '/opt/homebrew/bin', '/usr/local/bin']
    .filter(Boolean).join(path.delimiter);
}

function executable(name) {
  for (const directory of (process.env.PATH || '').split(path.delimiter).filter(path.isAbsolute)) {
    const candidate = path.join(directory, name);
    try {
      accessSync(candidate, constants.X_OK);
      if (statSync(candidate).isFile()) return candidate;
    } catch {
      // Keep looking through PATH.
    }
  }
  return null;
}

async function install(brew, distribution) {
  const options = { cwd: path.dirname(brew), timeout: 45 * 60 * 1000, maxBuffer: 2 * 1024 * 1024 };
  if (distribution === 'tectonic') {
    await run(brew, ['install', 'tectonic'], options);
    return;
  }

  await run(brew, ['fetch', ...macTeXPackage], options);
  const { stdout } = await run(brew, ['--cache', ...macTeXPackage], options);
  const pkg = stdout.trim();
  if (!path.isAbsolute(pkg) || path.extname(pkg) !== '.pkg' || !statSync(pkg).isFile()) {
    throw new Error('Homebrew did not return a MacTeX installer package.');
  }
  await run('/usr/bin/osascript', [
    '-e', 'on run argv',
    '-e', 'do shell script ("/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /") with administrator privileges',
    '-e', 'end run',
    pkg
  ], options);
}

export function registerCompilerSetupRoutes(fastify) {
  let job = { distribution: null, running: false, error: null };
  const platform = process.platform;
  const status = () => ({
    ok: true,
    platform,
    managedByMaziar: process.env.NUMENOR_SUPERVISED === '1',
    homebrew: platform === 'darwin' && Boolean(executable('brew')),
    engines: Object.fromEntries(SUPPORTED_ENGINES.map((engine) => [engine, Boolean(executable(engine))])),
    job
  });

  fastify.get('/api/compiler-setup', async (req, reply) => {
    reply.header('Cache-Control', 'no-store');
    if (!isLocalRequest(req)) {
      return reply.code(403).send({ ok: false, error: 'Compiler setup is available from the local Numenor address.' });
    }
    return status();
  });

  fastify.post('/api/compiler-setup', async (req, reply) => {
    const origin = `http://${req.headers.host}`;
    if (!isLocalRequest(req) || req.headers.origin !== origin || req.collabAuth) {
      return reply.code(403).send({ ok: false, error: 'Open Numenor directly on this Mac to install compilers.' });
    }
    const { distribution } = req.body || {};
    if (distribution !== 'mactex' && distribution !== 'tectonic') {
      return reply.code(400).send({ ok: false, error: 'Unknown compiler distribution.' });
    }
    const brew = executable('brew');
    if (platform !== 'darwin' || process.env.NUMENOR_SUPERVISED === '1' || !brew) {
      return reply.code(409).send({ ok: false, error: 'Installing here requires standalone Numenor on macOS with Homebrew.' });
    }
    if (job.running) return status();
    const engines = distribution === 'mactex' ? macTeXEngines : ['tectonic'];
    if (engines.every(executable)) return status();

    job = { distribution, running: true, error: null };
    install(brew, distribution)
      .then(() => {
        if (!engines.every(executable)) throw new Error('The installer finished, but some compilers are still missing from PATH.');
        job = { distribution, running: false, error: null };
      })
      .catch((error) => {
        req.log.error({ err: error }, 'Compiler installation failed');
        const message = error.stderr?.trim() || error.message;
        job = { distribution, running: false, error: message.slice(-1000) };
      });
    return reply.code(202).send(status());
  });
}
