import { promises as fs, createWriteStream } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { STATE_DIR } from '../../config/constants.js';

export const researchDir = path.join(STATE_DIR, 'Research2');
const stateFile = path.join(researchDir, 'state.json');
const imports = path.join(researchDir, 'imports');
let writes = Promise.resolve();
let inventory;
let inventoryTime = 0;

async function json(file, fallback) {
  try { return JSON.parse(await fs.readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return fallback; throw error; }
}

export function state() {
  return json(stateFile, { papers: {}, imported: [], library: {}, reader: {} });
}

export function updateState(edit) {
  const write = writes.then(async () => {
    const next = await state();
    const result = edit(next);
    await fs.mkdir(researchDir, { recursive: true, mode: 0o700 });
    const temporary = path.join(researchDir, randomUUID() + '.tmp');
    try {
      await fs.writeFile(temporary, JSON.stringify(next), { mode: 0o600 });
      await fs.rename(temporary, stateFile);
    } finally { await fs.rm(temporary, { force: true }); }
    return result;
  });
  writes = write.catch(() => {});
  return write;
}

const validName = (name) => typeof name === 'string' && !!name && !['.', '..'].includes(name)
  && name === path.basename(name) && !name.includes('\\') && !name.includes('\0');
const pdfName = (name) => validName(name) && /\.pdf$/i.test(name);
const idForPath = (root, relative) => createHash('sha256').update(root + '\0' + relative).digest('hex').slice(0, 32);
const validID = (id) => typeof id === 'string' && /^[a-f0-9-]{32,36}$/i.test(id);

async function scan(root, relative = '') {
  const result = [];
  for (const entry of await fs.readdir(path.join(root, relative), { withFileTypes: true })) {
    if (entry.name.startsWith('.') || !validName(entry.name)) continue;
    const item = path.join(relative, entry.name);
    if (entry.isDirectory()) result.push(...await scan(root, item).catch(() => []));
    else if (entry.isFile() && pdfName(entry.name)) result.push(item);
  }
  return result;
}

async function within(root, relative) {
  if (!root || !relative) return;
  try {
    const file = await fs.realpath(path.join(root, relative));
    if (file.startsWith(root + path.sep) && (await fs.stat(file)).isFile()) return file;
  } catch { /* The file may be offline or moved. */ }
}

async function readInventory() {
  const source = await json(path.join(researchDir, 'library-source.json'), {});
  const local = await state();
  const entries = Array.isArray(source.entries) ? source.entries : [];
  const groups = (source.groups ?? []).filter((group) => validName(group.folderName));
  const groupsById = new Map(groups.map((group) => [group.id.toLowerCase(), group]));
  let available = false;
  let root;
  let paths = [];
  if (source.folder) {
    try {
      root = await fs.realpath(source.folder);
      paths = await scan(root);
      available = true;
    } catch { /* Managed imports remain available if the connected folder goes offline. */ }
  }
  const claimed = new Set();
  const papers = [];
  for (const entry of entries) {
    if (!validID(entry.id)) continue;
    const copies = pdfName(entry.rootFileName) ? [entry.rootFileName] : [];
    const collections = [];
    const filenames = entry.groupFileNames ?? {};
    for (const [id, filename] of Array.isArray(filenames) ? Array.from({ length: Math.floor(filenames.length / 2) }, (_, index) => filenames.slice(index * 2, index * 2 + 2)) : Object.entries(filenames)) {
      const group = groupsById.get(String(id).toLowerCase());
      if (!group || !pdfName(filename)) continue;
      collections.push(group.id);
      copies.push(path.join(group.folderName, filename));
    }
    copies.forEach((copy) => claimed.add(copy));
    let file;
    for (const copy of copies) {
      file = await within(root, copy);
      if (file) break;
    }
    const { id, title, authors, year, venue, doi, abstract, notes, tags, subgroupIDs } = entry;
    papers.push({
      id: id.toLowerCase(), title, authors, year, venue, doi, abstract, notes, tags, subgroupIDs, collections,
      archived: !!entry.archived || (collections.length > 0 && !entry.rootFileName && collections.every((id) => groupsById.get(id.toLowerCase())?.archived)),
      file: file ?? null, root
    });
  }

  for (const relative of paths) {
    if (claimed.has(relative)) continue;
    const folder = path.dirname(relative);
    const group = groups.find((item) => item.folderName === folder);
    if (folder !== '.' && !group && !groups.some((item) => item.id === 'folder:' + folder)) {
      groups.push({ id: 'folder:' + folder, name: folder, subgroups: [] });
    }
    papers.push({ id: idForPath(root, relative), title: path.basename(relative, path.extname(relative)),
      collections: folder === '.' ? [] : [group?.id || 'folder:' + folder], file: path.join(root, relative), root });
  }
  for (const entry of local.imported) {
    const root = await fs.realpath(imports).catch(() => null);
    papers.push({ ...entry, collections: [], file: await within(root, entry.id + '.pdf'), root });
  }
  return { papers, groups, available, folder: source.folder ? path.basename(source.folder) : '' };
}

export async function catalog(refresh = false) {
  if (refresh || !inventory || Date.now() - inventoryTime > 2500) {
    inventoryTime = Date.now();
    inventory = readInventory();
  }
  const [records, local] = await Promise.all([inventory, state()]);
  return { ...records, local };
}

export async function paperFor(id) {
  if (!validID(id)) return;
  return (await catalog()).papers.find((paper) => paper.id === id.toLowerCase());
}

export function publicPaper(paper) {
  const { file, root, notes, ...metadata } = paper;
  return { ...metadata, hasPDF: Boolean(file) };
}

export async function pdfFor(paper) {
  return within(paper?.root, paper?.file ? path.relative(paper.root, paper.file) : '');
}

export async function originalNotes(paper) {
  const pdf = await pdfFor(paper);
  if (!pdf) return (paper.notes ?? '').slice(0, 100_000);
  const companion = pdf.slice(0, -4) + '.txt';
  const file = await within(paper.root, path.relative(paper.root, companion));
  if (!file) return originalNotebookText(paper, pdf);
  const handle = await fs.open(file, 'r');
  try {
    const bytes = Buffer.alloc(100_000);
    const { bytesRead } = await handle.read(bytes);
    return bytes.toString('utf8', 0, bytesRead);
  } finally { await handle.close(); }
}

async function originalNotebookText(paper, pdf) {
  const stem = pdf.slice(0, -4);
  const directory = await fs.realpath(stem).catch(() => null);
  const entries = directory?.startsWith(paper.root + path.sep)
    ? await fs.readdir(directory, { withFileTypes: true }).catch(() => []) : [];
  const files = [stem + '.ipynb', ...entries.filter((entry) => entry.isFile() && /\.ipynb$/i.test(entry.name))
    .slice(0, 30).map((entry) => path.join(directory, entry.name))];
  const notes = [];
  for (const filename of files) {
    const file = await within(paper.root, path.relative(paper.root, filename));
    if (!file) continue;
    try {
      if ((await fs.stat(file)).size > 8 * 1024 * 1024) continue;
      const notebook = await json(file, {});
      const paragraphs = (notebook.cells ?? []).filter((cell) => cell.cell_type === 'markdown')
        .map((cell) => [].concat(cell.source ?? '').join(''));
      if (paragraphs.some((text) => text.trim())) notes.push(path.basename(file) + '\n\n' + paragraphs.join('\n\n'));
      if (notes.join('').length > 100_000) break;
    } catch { /* Unavailable original notes should not prevent PDF reading. */ }
  }
  return (notes.join('\n\n') || paper.notes || '').slice(0, 100_000);
}

export async function importPDF(part) {
  if (!part || !pdfName(part.filename)) throw new Error('Choose a PDF file.');
  await fs.mkdir(imports, { recursive: true, mode: 0o700 });
  const id = randomUUID();
  const file = path.join(imports, id + '.pdf');
  let header = Buffer.alloc(0);
  const check = new Transform({
    transform(chunk, encoding, next) {
      if (header.length < 1024) header = Buffer.concat([header, chunk.subarray(0, 1024 - header.length)]);
      next(null, chunk);
    }
  });
  try {
    await pipeline(part.file, check, createWriteStream(file, { flags: 'wx', mode: 0o600 }));
    if (part.file.truncated) throw new Error('The PDF exceeds the 200 MB import limit.');
    if (!header.includes('%PDF-')) throw new Error('This file does not contain a PDF header.');
    const entry = { id, title: path.basename(part.filename, path.extname(part.filename)), added: new Date().toISOString() };
    await updateState((data) => data.imported.push(entry));
    inventory = undefined;
    return publicPaper({ ...entry, file });
  } catch (error) {
    await fs.rm(file, { force: true });
    throw error;
  }
}
