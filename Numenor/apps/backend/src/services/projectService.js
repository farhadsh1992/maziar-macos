import { promises as fs } from 'fs';
import path from 'path';
import { DATA_DIR } from '../config/constants.js';

export async function getProjectRoot(id) {
  const projectRoot = path.join(DATA_DIR, id);
  const metaPath = path.join(projectRoot, 'project.json');
  await fs.access(metaPath);
  return projectRoot;
}
