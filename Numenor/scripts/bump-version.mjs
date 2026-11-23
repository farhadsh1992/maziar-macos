#!/usr/bin/env node
// Sets Numenor's version in package.json and package-lock.json (kept identical so npm doesn't rewrite the
// lockfile). `node scripts/bump-version.mjs` raises the last number (1.0.5 → 1.0.6);
// `node scripts/bump-version.mjs 1.1.0` sets it. The release label ("Beta") stays as it is.
import { readFileSync, writeFileSync } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkgFile = path.join(root, 'package.json');
const lockFile = path.join(root, 'package-lock.json');
const pkg = JSON.parse(readFileSync(pkgFile, 'utf8'));
let next = process.argv[2];
if (!next) {
  const parts = String(pkg.version || '0.0.0').split('.').map((n) => parseInt(n, 10) || 0);
  while (parts.length < 3) parts.push(0);
  parts[parts.length - 1] += 1;
  next = parts.join('.');
}
if (!/^\d+\.\d+\.\d+$/.test(next)) {
  console.error(`Not a version: ${next}`);
  process.exit(1);
}

// Put "version" right after "name" (npm's usual order).
const withVersion = (obj) => {
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (k === 'version') continue;
    out[k] = v;
    if (k === 'name') out.version = next;
  }
  if (!('version' in out)) out.version = next;
  return out;
};
writeFileSync(pkgFile, JSON.stringify(withVersion(pkg), null, 2) + '\n');
try {
  const lock = withVersion(JSON.parse(readFileSync(lockFile, 'utf8')));
  if (lock.packages?.['']) lock.packages[''] = withVersion(lock.packages['']);
  writeFileSync(lockFile, JSON.stringify(lock, null, 2) + '\n');
} catch {
  /* no lockfile */
}
console.log(`${pkg.releaseLabel ? `${pkg.releaseLabel} ` : ''}${next}`);
