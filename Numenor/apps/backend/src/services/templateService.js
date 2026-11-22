import { promises as fs } from 'fs';
import path from 'path';
import { TEMPLATE_DIR, TEMPLATE_MANIFEST } from '../config/constants.js';
import { ensureDir, readJson, writeJson } from '../utils/fsUtils.js';

export async function readTemplateManifest() {
  // Read manifest
  let manifestTemplates = [];
  let categories = [];
  try {
    const data = await readJson(TEMPLATE_MANIFEST);
    manifestTemplates = Array.isArray(data?.templates) ? data.templates : [];
    categories = Array.isArray(data?.categories) ? data.categories : [];
  } catch { /* ignore */ }

  // Scan templates directory for dirs not in manifest
  const knownIds = new Set(manifestTemplates.map(t => t.id));
  try {
    await ensureDir(TEMPLATE_DIR);
    const entries = await fs.readdir(TEMPLATE_DIR, { withFileTypes: true });
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (entry.name === 'node_modules') continue;
      if (knownIds.has(entry.name)) continue;
      // Check if dir contains a .tex file
      const dirPath = path.join(TEMPLATE_DIR, entry.name);
      const files = await fs.readdir(dirPath);
      const hasTex = files.some(f => f.endsWith('.tex'));
      if (!hasTex) continue;
      // Auto-generate entry
      manifestTemplates.push({
        id: entry.name,
        label: entry.name,
        mainFile: 'main.tex',
        category: 'academic',
        description: entry.name,
        descriptionEn: entry.name,
        tags: [],
        author: '',
        featured: false,
      });
    }
  } catch { /* ignore */ }

  return { templates: manifestTemplates, categories };
}

export async function addTemplateToManifest(entry) {
  let data = { templates: [], categories: [] };
  try {
    data = await readJson(TEMPLATE_MANIFEST);
  } catch { /* ignore */ }
  const templates = Array.isArray(data.templates) ? data.templates : [];
  const exists = templates.findIndex(t => t.id === entry.id);
  if (exists >= 0) {
    templates[exists] = { ...templates[exists], ...entry };
  } else {
    templates.push(entry);
  }
  data.templates = templates;
  await writeJson(TEMPLATE_MANIFEST, data);
}

export async function copyTemplateIntoProject(templateRoot, projectRoot) {
  const changed = [];
  const walk = async (rel = '') => {
    const dirPath = path.join(templateRoot, rel);
    const entries = await fs.readdir(dirPath, { withFileTypes: true });
    for (const entry of entries) {
      const nextRel = path.join(rel, entry.name);
      if (entry.name === 'main.tex') continue;
      const srcPath = path.join(templateRoot, nextRel);
      const destPath = path.join(projectRoot, nextRel);
      if (entry.isDirectory()) {
        await ensureDir(destPath);
        await walk(nextRel);
      } else {
        const ext = path.extname(entry.name).toLowerCase();
        const shouldOverwrite = ext && ext !== '.tex';
        try {
          await fs.access(destPath);
          if (!shouldOverwrite) continue;
        } catch {
          // file missing; proceed to copy
        }
        await ensureDir(path.dirname(destPath));
        await fs.copyFile(srcPath, destPath);
        changed.push(nextRel);
      }
    }
  };
  await walk('');
  return changed;
}
