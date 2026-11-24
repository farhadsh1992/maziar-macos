import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { readJson } from '../utils/fsUtils.js';

const pending = new Map();

export function updateProjectMetadata(root, update, rollback) {
  const filename = path.join(root, 'project.json');
  const job = (pending.get(root) ?? Promise.resolve()).catch(() => {}).then(async () => {
    const current = await readJson(filename);
    const next = await update(current);
    if (next === current) return current;
    const staged = path.join(root, `.numenor-project-${randomUUID()}.tmp`);
    try {
      await fs.writeFile(staged, JSON.stringify(next, null, 2), 'utf8');
      await fs.rename(staged, filename);
    } catch (error) {
      await rollback?.();
      throw error;
    } finally {
      await fs.rm(staged, { force: true }).catch(() => {});
    }
    return next;
  });
  pending.set(root, job);
  return job.finally(() => { if (pending.get(root) === job) pending.delete(root); });
}

export function writingStatus(value) {
  if (!value || !['todo', 'in-progress', 'done'].includes(value.status)) return null;
  const date = value.date ?? '';
  if (typeof date !== 'string') return null;
  const parsed = /^\d{4}-\d{2}-\d{2}$/.test(date) ? new Date(date) : null;
  if (date && (!parsed || !Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date)) return null;
  const note = value.note ?? '';
  if (typeof note !== 'string' || note.length > 2000) return null;
  return { status: value.status, date, note };
}

export function remapWritingStatuses(meta, from, to) {
  const entries = Object.entries(meta.writingStatuses ?? {});
  const matches = (file) => file === from || file.startsWith(from + '/');
  if (!entries.some(([file]) => matches(file))) return meta;
  return {
    ...meta,
    writingStatuses: Object.fromEntries(entries.flatMap(([file, status]) =>
      !matches(file) ? [[file, status]] : to ? [[to + file.slice(from.length), status]] : []
    ))
  };
}

export function validSourceComment(comment) {
  return comment && typeof comment.id === 'string' && typeof comment.file === 'string'
    && Number.isSafeInteger(comment.from) && comment.from >= 0
    && Number.isSafeInteger(comment.line) && comment.line >= 1
    && typeof comment.quote === 'string' && comment.quote.length > 0
    && typeof comment.note === 'string';
}

export function remapSourceComments(meta, from, to) {
  if (!Array.isArray(meta.sourceComments)) return meta;
  const matches = (file) => file === from || file.startsWith(from + '/');
  const comments = meta.sourceComments.filter(validSourceComment);
  if (!comments.some((comment) => matches(comment.file))) return meta;
  return {
    ...meta,
    sourceComments: comments.flatMap((comment) => !matches(comment.file) ? [comment]
      : to ? [{ ...comment, file: to + comment.file.slice(from.length) }] : [])
  };
}
