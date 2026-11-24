import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { STATE_DIR } from '../../config/constants.js';

export const aiDirectory = path.join(
  process.env.NUMENOR_STATE_DIR ? STATE_DIR : path.join(homedir(), 'Library', 'Application Support', 'Numenor'),
  'ai-models'
);

export async function atomicJSON(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
    await fs.rename(temporary, file);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}
