import path from 'path';
import { promises as fs } from 'fs';

export function safeJoin(root, targetPath) {
  const resolved = path.resolve(root, targetPath);
  if (!resolved.startsWith(root + path.sep) && resolved !== root) {
    throw new Error('Invalid path');
  }
  return resolved;
}

export function sanitizeUploadPath(filename) {
  if (!filename) return '';
  const normalized = filename.replace(/\\/g, '/').replace(/^\/+/, '');
  const parts = normalized.split('/').filter((part) => part && part !== '.' && part !== '..');
  return parts.join('/');
}

export function isProjectRelativePath(value) {
  return typeof value === 'string' && Boolean(value) && !/[\\:\x00-\x1f]/.test(value)
    && value.split('/').every((part) => part && !part.startsWith('.') && part.toLowerCase() !== 'project.json');
}

export async function projectAgentPath(root, relative) {
  if (!isProjectRelativePath(relative)) throw new Error('Invalid project path');
  let current = root;
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    const stat = await fs.lstat(current).catch((error) => {
      if (error.code !== 'ENOENT') throw error;
    });
    if (stat?.isSymbolicLink()) throw new Error('Agent cannot follow symbolic links');
  }
  return current;
}
