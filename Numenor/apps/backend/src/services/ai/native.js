import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { REPO_ROOT } from '../../config/constants.js';
import { aiDirectory } from './storage.js';

let preparation;

function run(binary, args, input, signal) {
  return new Promise((resolve, reject) => {
    const process = spawn(binary, args, { signal, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    let error = '';
    process.stdout.setEncoding('utf8').on('data', (chunk) => { output += chunk; });
    process.stderr.setEncoding('utf8').on('data', (chunk) => { error += chunk; });
    process.stdin.on('error', () => {});
    process.on('error', reject);
    process.on('close', (code) => code === 0 ? resolve(output) : reject(new Error(error || 'The macOS AI helper stopped.')));
    process.stdin.end(input);
  });
}

async function standaloneHelper() {
  const binary = path.join(aiDirectory, 'NumenorAI-v2');
  try {
    await fs.access(binary);
  } catch {
    await fs.mkdir(aiDirectory, { recursive: true, mode: 0o700 });
    const pending = `${binary}.${process.pid}.tmp`;
    try {
      await run('/usr/bin/xcrun', ['swiftc', path.join(REPO_ROOT, 'scripts/native-ai/main.swift'), '-o', pending], '');
      await fs.rename(pending, binary);
    } catch {
      throw new Error('The native AI helper requires the Maziar app or the macOS Swift command-line tools.');
    } finally {
      await fs.rm(pending, { force: true });
    }
  }
  return binary;
}

export async function nativeAI(input, signal) {
  if (process.platform !== 'darwin') throw new Error('This provider requires macOS.');
  const binary = process.env.NUMENOR_AI_HELPER ?? await (preparation ??= standaloneHelper().catch((error) => {
    preparation = undefined;
    throw error;
  }));
  return JSON.parse(await run(binary, [], JSON.stringify(input), signal));
}
