import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { CSSProperties, Dispatch, MouseEvent, SetStateAction, RefObject, DragEvent } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { basicSetup } from 'codemirror';
import { latex, strongComments } from '../latex/lang';
import { Compartment, EditorState, Prec, StateEffect, StateField } from '@codemirror/state';
import { Decoration, EditorView, DecorationSet, WidgetType, keymap, gutter, GutterMarker } from '@codemirror/view';
import { search, searchKeymap, openSearchPanel } from '@codemirror/search';
import { autocompletion, CompletionContext } from '@codemirror/autocomplete';
import { toggleComment, undo as cmUndo, redo as cmRedo } from '@codemirror/commands';
import { foldKeymap, foldService, indentOnInput, HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as hlTags } from '@lezer/highlight';
import { GlobalWorkerOptions, getDocument, renderTextLayer } from 'pdfjs-dist';
import pdfWorker from 'pdfjs-dist/build/pdf.worker.min?url';
import 'pdfjs-dist/web/pdf_viewer.css';
// Maziar: PDF viewer, SyncTeX, compile diagnostics, spelling/grammar.
import PdfViewer, { type PdfViewerHandle, type PdfZoomMode } from './PdfViewer';
import { parseLatexLog, diagnosticsExtension, showDiagnostics, revealLine, type LatexDiagnostic } from '../latex/diagnostics';
import { spellExtension, listVocabulary, onVocabularyChange, removeFromVocabulary, type SpellStatus } from '../latex/spell';
import {
  NumenorMark, IconSidebar, IconArrowLeft, IconChevronRight, IconChevronLeft, IconChevronDown, IconUpload,
  IconSearch, IconSection, IconList, IconSigma, IconInsert, IconUndo, IconRedo, IconPlus, IconMinus, IconSync,
  IconDownload, IconDots, IconCheckCircle, IconAlert, IconLayers, IconLog, IconSpinner, IconClose,
  IconShare, IconHistory, IconPopOut, IconPopIn, IconCopy, IconCloud
} from './icons';
import ShareDialog from './ShareDialog';
import SyncDialog from './SyncDialog';
import type { PdfWindowMessage } from './PdfWindowPage';
import { synctexForward, synctexReverse, spellStatus, spellLanguages, shareStatus, startShare, stopShare, blobUrl, whoAmI, presence, setProjectMainFile, getProjectLocation, revealProject, projectStat, type ProjectLocation, type MissingFile, type ShareState, type Me, type PresencePerson } from '../api/client';
import {
  arxivBibtex,
  arxivSearch,
  createFolder as createFolderApi,
  createCollabInvite,
  compileProject,
  getAllFiles,
  getCollabServer,
  getFile,
  getProjectTree,
  getCollabToken,
  getCollabInviteToken,
  listProjects,
  renamePath,
  deleteFile,
  updateFileOrder,
  runAgent,
  plotFromTable,
  callLLM,
  uploadFiles,
  visionToLatex,
  writeFile,
  flushCollabFile,
  setCollabServer
} from '../api/client';
import type { ArxivPaper } from '../api/client';
import { createTwoFilesPatch, diffLines } from 'diff';
import type { CompileOutcome } from '../latex/engine';
import * as Y from 'yjs';
import { Awareness } from 'y-protocols/awareness';
import { yCollab } from 'y-codemirror.next';
import { CollabProvider } from '../collab/provider';

GlobalWorkerOptions.workerSrc = pdfWorker;

interface Message {
  role: 'user' | 'assistant' | 'system';
  content: string;
}

interface WebsearchItem {
  id: string;
  title: string;
  summary: string;
  url: string;
  bibtex: string;
  citeKey: string;
}

interface PendingChange {
  filePath: string;
  original: string;
  proposed: string;
  diff: string;
}

type InlineEdit =
  | { kind: 'new-file' | 'new-folder'; parent: string; value: string }
  | { kind: 'rename'; path: string; value: string };

type CompileEngine = 'pdflatex' | 'xelatex' | 'lualatex' | 'latexmk' | 'tectonic';

type AppSettings = {
  llmEndpoint: string;
  llmApiKey: string;
  llmModel: string;
  searchEndpoint: string;
  searchApiKey: string;
  searchModel: string;
  visionEndpoint: string;
  visionApiKey: string;
  visionModel: string;
  compileEngine: CompileEngine;
};

const DEFAULT_TASKS = (t: (key: string) => string) => [
  { value: 'polish', label: t('润色') },
  { value: 'rewrite', label: t('改写') },
  { value: 'structure', label: t('结构调整') },
  { value: 'translate', label: t('翻译') },
  { value: 'websearch', label: t('检索 (arXiv)') },
  { value: 'custom', label: t('自定义') }
];

const RIGHT_VIEW_OPTIONS = (t: (key: string) => string) => [
  { value: 'pdf', label: 'PDF' },
  { value: 'toc', label: t('目录') },
  { value: 'figures', label: 'FIG' },
  { value: 'diff', label: 'DIFF' },
  { value: 'log', label: 'LOG' },
  { value: 'review', label: t('评审报告') }
];

const SETTINGS_KEY = 'numenor-settings-v1';
const DEFAULT_SETTINGS: AppSettings = {
  llmEndpoint: 'https://api.openai.com/v1/chat/completions',
  llmApiKey: '',
  llmModel: 'gpt-4o-mini',
  searchEndpoint: '',
  searchApiKey: '',
  searchModel: '',
  visionEndpoint: '',
  visionApiKey: '',
  visionModel: '',
  compileEngine: 'pdflatex'
};

const COLLAB_NAME_KEY = 'numenor-collab-name';
const COLLAB_COLORS = ['#b44a2f', '#2f6fb4', '#2f9b74', '#b48a2f', '#6b2fb4', '#b42f6d', '#2f8fb4'];

function loadSettings(): AppSettings {
  if (typeof window === 'undefined') return DEFAULT_SETTINGS;
  try {
    const raw = window.localStorage.getItem(SETTINGS_KEY);
    if (!raw) return DEFAULT_SETTINGS;
    const parsed = JSON.parse(raw) as Partial<AppSettings>;
    const engine = parsed.compileEngine;
    const VALID_ENGINES: CompileEngine[] = ['pdflatex', 'xelatex', 'lualatex', 'latexmk', 'tectonic'];
    const compileEngine: CompileEngine =
      VALID_ENGINES.includes(engine as CompileEngine)
        ? (engine as CompileEngine)
        : DEFAULT_SETTINGS.compileEngine;
    return {
      ...DEFAULT_SETTINGS,
      ...parsed,
      compileEngine
    };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

function persistSettings(settings: AppSettings) {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch {
    // ignore
  }
}

function loadCollabName() {
  if (typeof window === 'undefined') return '';
  try {
    return window.localStorage.getItem(COLLAB_NAME_KEY) || '';
  } catch {
    return '';
  }
}

function persistCollabName(name: string) {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(COLLAB_NAME_KEY, name);
  } catch {
    // ignore
  }
}

// Each person's colour — the same in the top bar (who's here) and on their cursor in the text. Keyed by who
// they are ('owner' or 'invite:<id>'), so it stays the same in every file and on every computer.
const PRESENCE_COLORS = ['#1c7ed6', '#e8590c', '#2f9e44', '#c2255c', '#7048e8', '#0c8599', '#d9480f', '#5c940d', '#ae3ec9', '#1864ab'];
const OWNER_COLOR = '#d4a017';
function colorForKey(key: string) {
  if (key === 'owner') return OWNER_COLOR;
  let hash = 0;
  for (let i = 0; i < key.length; i += 1) hash = (hash * 31 + key.charCodeAt(i)) >>> 0;
  return PRESENCE_COLORS[hash % PRESENCE_COLORS.length];
}

function presenceInitials(name: string) {
  return name.split(/[\s@._-]+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('') || '?';
}

/** Loads the project's folder when the settings window opens (renders nothing). */
function SettingsLocationLoader({ projectId, onLoad }: { projectId: string; onLoad: (loc: ProjectLocation | null) => void }) {
  useEffect(() => {
    if (!projectId) { onLoad(null); return; }
    getProjectLocation(projectId).then(onLoad).catch(() => onLoad(null));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);
  return null;
}

function pickCollabColor(seed?: string) {
  if (!seed) {
    return COLLAB_COLORS[Math.floor(Math.random() * COLLAB_COLORS.length)];
  }
  let hash = 0;
  for (let i = 0; i < seed.length; i += 1) {
    hash = (hash * 31 + seed.charCodeAt(i)) % 997;
  }
  return COLLAB_COLORS[hash % COLLAB_COLORS.length];
}

function normalizeServerUrl(value: string) {
  const trimmed = value.trim();
  if (!trimmed) return '';
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return `http://${trimmed}`;
}

const FIGURE_EXTS = ['.png', '.jpg', '.jpeg', '.pdf', '.svg', '.eps'];
const TEXT_EXTS = ['.sty', '.cls', '.bst', '.txt', '.md', '.json', '.yaml', '.yml', '.csv', '.tsv'];

function isTextPath(filePath: string) {
  const lower = filePath.toLowerCase();
  return lower.endsWith('.tex') || lower.endsWith('.bib') || TEXT_EXTS.some((ext) => lower.endsWith(ext));
}

const SECTION_LEVELS: Record<string, number> = {
  section: 1,
  subsection: 2,
  subsubsection: 3,
  paragraph: 4,
  subparagraph: 5
};

const SECTION_RE = /\\(section|subsection|subsubsection|paragraph|subparagraph)\*?\b/;
const ENV_RE = /\\(begin|end)\{([^}]+)\}/g;
const IF_START_RE = /\\if[a-zA-Z@]*\b/g;
const IF_END_RE = /\\fi\b/g;
const IF_START_TEST = /\\if[a-zA-Z@]*\b/;
const GROUP_START_RE = /\\begingroup\b/g;
const GROUP_END_RE = /\\endgroup\b/g;
const GROUP_START_TEST = /\\begingroup\b/;

function stripLatexComment(text: string) {
  let result = '';
  let escaped = false;
  for (const ch of text) {
    if (ch === '%' && !escaped) break;
    result += ch;
    if (ch === '\\' && !escaped) {
      escaped = true;
    } else {
      escaped = false;
    }
  }
  return result;
}

function findEnvFold(state: EditorState, startLineNumber: number, lineEnd: number, env: string) {
  let depth = 1;
  for (let lineNo = startLineNumber + 1; lineNo <= state.doc.lines; lineNo += 1) {
    const line = state.doc.line(lineNo);
    const clean = stripLatexComment(line.text);
    let match: RegExpExecArray | null;
    ENV_RE.lastIndex = 0;
    while ((match = ENV_RE.exec(clean)) !== null) {
      const kind = match[1];
      const name = match[2];
      if (name !== env) continue;
      if (kind === 'begin') depth += 1;
      if (kind === 'end') depth -= 1;
      if (depth === 0) {
        if (line.from > lineEnd) {
          return { from: lineEnd, to: line.from };
        }
        return null;
      }
    }
  }
  return null;
}

function findSectionFold(state: EditorState, startLineNumber: number, lineEnd: number, level: number) {
  for (let lineNo = startLineNumber + 1; lineNo <= state.doc.lines; lineNo += 1) {
    const line = state.doc.line(lineNo);
    const clean = stripLatexComment(line.text);
    const match = clean.match(SECTION_RE);
    if (!match) continue;
    const nextLevel = SECTION_LEVELS[match[1]] ?? 99;
    if (nextLevel <= level) {
      if (line.from > lineEnd) {
        return { from: lineEnd, to: line.from };
      }
      return null;
    }
  }
  if (state.doc.length > lineEnd) {
    return { from: lineEnd, to: state.doc.length };
  }
  return null;
}

function countRegex(text: string, re: RegExp) {
  let count = 0;
  let match: RegExpExecArray | null;
  re.lastIndex = 0;
  while ((match = re.exec(text)) !== null) {
    count += 1;
  }
  return count;
}

function countUnescapedToken(text: string, token: string) {
  let count = 0;
  for (let i = 0; i <= text.length - token.length; i += 1) {
    if (text.slice(i, i + token.length) !== token) continue;
    if (i > 0 && text[i - 1] === '\\') continue;
    count += 1;
    i += token.length - 1;
  }
  return count;
}

function findTokenFold(
  state: EditorState,
  startLineNumber: number,
  lineEnd: number,
  startRe: RegExp,
  endRe: RegExp
) {
  let depth = 1;
  for (let lineNo = startLineNumber + 1; lineNo <= state.doc.lines; lineNo += 1) {
    const line = state.doc.line(lineNo);
    const clean = stripLatexComment(line.text);
    depth += countRegex(clean, startRe);
    depth -= countRegex(clean, endRe);
    if (depth <= 0) {
      if (line.from > lineEnd) {
        return { from: lineEnd, to: line.from };
      }
      return null;
    }
  }
  return null;
}

function findDisplayMathFold(
  state: EditorState,
  startLineNumber: number,
  lineEnd: number,
  startToken: string,
  endToken: string
) {
  for (let lineNo = startLineNumber + 1; lineNo <= state.doc.lines; lineNo += 1) {
    const line = state.doc.line(lineNo);
    const clean = stripLatexComment(line.text);
    if (countUnescapedToken(clean, endToken) > 0) {
      if (line.from > lineEnd) {
        return { from: lineEnd, to: line.from };
      }
      return null;
    }
  }
  return null;
}

function latexFoldService(state: EditorState, lineStart: number, lineEnd: number) {
  const line = state.doc.lineAt(lineStart);
  const clean = stripLatexComment(line.text);
  if (!clean.trim()) return null;
  const envMatch = clean.match(/\\begin\{([^}]+)\}/);
  if (envMatch) {
    return findEnvFold(state, line.number, lineEnd, envMatch[1]);
  }
  const sectionMatch = clean.match(SECTION_RE);
  if (sectionMatch) {
    const level = SECTION_LEVELS[sectionMatch[1]] ?? 99;
    return findSectionFold(state, line.number, lineEnd, level);
  }
  if (GROUP_START_TEST.test(clean)) {
    return findTokenFold(state, line.number, lineEnd, GROUP_START_RE, GROUP_END_RE);
  }
  if (IF_START_TEST.test(clean)) {
    return findTokenFold(state, line.number, lineEnd, IF_START_RE, IF_END_RE);
  }
  const hasDisplayDollar = countUnescapedToken(clean, '$$') % 2 === 1;
  if (hasDisplayDollar) {
    return findDisplayMathFold(state, line.number, lineEnd, '$$', '$$');
  }
  const hasDisplayBracket = clean.includes('\\[');
  if (hasDisplayBracket && !clean.includes('\\]')) {
    return findDisplayMathFold(state, line.number, lineEnd, '\\[', '\\]');
  }
  return null;
}

function isFigureFile(path: string) {
  const lower = path.toLowerCase();
  return FIGURE_EXTS.some((ext) => lower.endsWith(ext));
}

function isTextFile(path: string) {
  const lower = path.toLowerCase();
  return lower.endsWith('.tex') || lower.endsWith('.bib') || TEXT_EXTS.some((ext) => lower.endsWith(ext));
}

function getFileTypeLabel(path: string) {
  const lower = path.toLowerCase();
  if (lower.endsWith('.tex')) return 'TEX';
  if (lower.endsWith('.bib')) return 'BIB';
  if (lower.endsWith('.cls')) return 'CLS';
  if (lower.endsWith('.sty')) return 'STY';
  if (lower.endsWith('.png')) return 'PNG';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'JPG';
  if (lower.endsWith('.svg')) return 'SVG';
  if (lower.endsWith('.pdf')) return 'PDF';
  if (lower.endsWith('.txt')) return 'TXT';
  return 'FILE';
}

function getParentPath(target: string) {
  if (!target) return '';
  const idx = target.lastIndexOf('/');
  return idx === -1 ? '' : target.slice(0, idx);
}

type TreeNode = {
  name: string;
  path: string;
  type: 'file' | 'dir';
  children: TreeNode[];
};

type OutlineItem = {
  title: string;
  level: number;
  pos: number;
  line: number;
};

function buildTree(items: { path: string; type: string }[], orderMap: Record<string, string[]> = {}) {
  const root: TreeNode = { name: '', path: '', type: 'dir', children: [] };
  const nodeMap = new Map<string, TreeNode>([['', root]]);

  const sorted = [...items].sort((a, b) => a.path.localeCompare(b.path));

  sorted.forEach((item) => {
    const parts = item.path.split('/').filter(Boolean);
    let currentPath = '';
    parts.forEach((part, index) => {
      const nextPath = currentPath ? `${currentPath}/${part}` : part;
      if (!nodeMap.has(nextPath)) {
        const isLeaf = index === parts.length - 1;
        const node: TreeNode = {
          name: part,
          path: nextPath,
          type: isLeaf ? (item.type === 'dir' ? 'dir' : 'file') : 'dir',
          children: []
        };
        const parent = nodeMap.get(currentPath);
        if (parent) {
          parent.children.push(node);
        }
        nodeMap.set(nextPath, node);
      }
      currentPath = nextPath;
    });
  });

  const sortNodes = (node: TreeNode) => {
    const order = orderMap[node.path] || [];
    node.children.sort((a, b) => {
      const aKey = a.name;
      const bKey = b.name;
      const aIndex = order.indexOf(aKey);
      const bIndex = order.indexOf(bKey);
      if (aIndex !== -1 || bIndex !== -1) {
        if (aIndex === -1) return 1;
        if (bIndex === -1) return -1;
        if (aIndex !== bIndex) return aIndex - bIndex;
      }
      if (a.type !== b.type) return a.type === 'dir' ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    node.children.forEach(sortNodes);
  };

  sortNodes(root);
  return root;
}

function findTreeNode(root: TreeNode, targetPath: string) {
  if (root.path === targetPath) return root;
  const parts = targetPath.split('/').filter(Boolean);
  let current: TreeNode | null = root;
  let pathSoFar = '';
  for (const part of parts) {
    if (!current) return null;
    pathSoFar = pathSoFar ? `${pathSoFar}/${part}` : part;
    current = current.children.find((child) => child.path === pathSoFar) || null;
  }
  return current;
}

function stripLineComment(line: string) {
  let escaped = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '%' && !escaped) {
      return line.slice(0, i);
    }
    escaped = ch === '\\';
  }
  return line;
}

function parseOutline(text: string): OutlineItem[] {
  const items: OutlineItem[] = [];
  const lines = text.split(/\r?\n/);
  let offset = 0;
  lines.forEach((line, index) => {
    const clean = stripLineComment(line);
    const regex = /\\+(section|subsection|subsubsection)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/g;
    let match: RegExpExecArray | null;
    while ((match = regex.exec(clean))) {
      const name = match[1];
      const title = (match[2] || '').trim() || '(untitled)';
      const level = name === 'section' ? 1 : name === 'subsection' ? 2 : 3;
      items.push({
        title,
        level,
        pos: offset + (match.index ?? 0),
        line: index + 1
      });
    }
    offset += line.length + 1;
  });
  return items;
}

function extractIncludeTargets(text: string) {
  const targets: string[] = [];
  const lines = text.split(/\r?\n/);
  const regex = /\\(?:input|include)\s*\{([^}]+)\}/g;
  lines.forEach((line) => {
    const clean = stripLineComment(line);
    let match: RegExpExecArray | null;
    while ((match = regex.exec(clean))) {
      const raw = (match[1] || '').trim();
      if (raw) targets.push(raw);
    }
  });
  return targets;
}

function findNearestHeading(text: string, cursorPos: number) {
  const before = text.slice(0, cursorPos);
  const lines = before.split(/\r?\n/).reverse();
  for (const line of lines) {
    const clean = stripLineComment(line);
    const match = clean.match(/\\+(section|subsection|subsubsection)\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}/);
    if (match) {
      return {
        title: (match[2] || '').trim() || '(untitled)',
        level: match[1]
      };
    }
  }
  return null;
}

function findCurrentEnvironment(text: string) {
  const stack: string[] = [];
  const clean = text
    .split('\n')
    .map((line) => stripLineComment(line))
    .join('\n');
  const regex = /\\\\(begin|end)\\s*\\{([^}]+)\\}/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(clean))) {
    const type = match[1];
    const name = match[2].trim();
    if (!name) continue;
    if (type === 'begin') {
      stack.push(name);
    } else if (type === 'end') {
      const idx = stack.lastIndexOf(name);
      if (idx !== -1) {
        stack.splice(idx, 1);
      }
    }
  }
  return stack.length > 0 ? stack[stack.length - 1] : '';
}

function extractJsonBlock(text: string) {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return '';
  return text.slice(start, end + 1);
}

function sanitizeJsonString(raw: string) {
  let inString = false;
  let escaped = false;
  let out = '';
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    if (inString) {
      if (escaped) {
        out += ch;
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        out += ch;
        escaped = true;
        continue;
      }
      if (ch === '"') {
        out += ch;
        inString = false;
        continue;
      }
      if (ch === '\n') {
        out += '\\n';
        continue;
      }
      if (ch === '\r') {
        out += '\\r';
        continue;
      }
      if (ch === '\t') {
        out += '\\t';
        continue;
      }
      const code = ch.charCodeAt(0);
      if (code >= 0 && code < 0x20) {
        out += `\\u${code.toString(16).padStart(4, '0')}`;
        continue;
      }
      out += ch;
    } else {
      if (ch === '"') {
        inString = true;
      }
      out += ch;
    }
  }
  return out;
}

function safeJsonParse<T>(raw: string): T | null {
  try {
    return JSON.parse(raw) as T;
  } catch (err) {
    try {
      return JSON.parse(sanitizeJsonString(raw)) as T;
    } catch (err2) {
      return null;
    }
  }
}

function appendLog(setter: (val: string[] | ((prev: string[]) => string[])) => void, line: string) {
  setter((prev) => [...prev, line]);
}

function latexCompletionSource(context: CompletionContext) {
  const before = context.matchBefore(/[\\/][A-Za-z]*$/);
  if (!before) return null;
  const prev = before.from > 0 ? context.state.doc.sliceString(before.from - 1, before.from) : ' ';
  if (prev && !/[\s({\n]/.test(prev)) return null;
  if (before.text.startsWith('/') && prev === ':') return null;
  const options = [
    { label: '\\section{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\section{}' },
        selection: { anchor: from + '\\section{'.length }
      });
    }},
    { label: '\\subsection{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\subsection{}' },
        selection: { anchor: from + '\\subsection{'.length }
      });
    }},
    { label: '\\subsubsection{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\subsubsection{}' },
        selection: { anchor: from + '\\subsubsection{'.length }
      });
    }},
    { label: '\\paragraph{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\paragraph{}' },
        selection: { anchor: from + '\\paragraph{'.length }
      });
    }},
    { label: '\\cite{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\cite{}' },
        selection: { anchor: from + '\\cite{'.length }
      });
    }},
    { label: '\\ref{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\ref{}' },
        selection: { anchor: from + '\\ref{'.length }
      });
    }},
    { label: '\\label{}', type: 'keyword', apply: (view: any, _completion: any, from: number, to: number) => {
      view.dispatch({
        changes: { from, to, insert: '\\label{}' },
        selection: { anchor: from + '\\label{'.length }
      });
    }},
    { label: '\\begin{itemize}', type: 'keyword', apply: '\\begin{itemize}\n\\item \n\\end{itemize}' },
    { label: '\\begin{enumerate}', type: 'keyword', apply: '\\begin{enumerate}\n\\item \n\\end{enumerate}' },
    { label: '\\begin{figure}', type: 'keyword', apply: '\\begin{figure}[t]\n\\centering\n\\includegraphics[width=0.9\\linewidth]{}\n\\caption{}\n\\label{}\n\\end{figure}' },
    { label: '\\begin{table}', type: 'keyword', apply: '\\begin{table}[t]\n\\centering\n\\begin{tabular}{}\n\\end{tabular}\n\\caption{}\n\\label{}\n\\end{table}' }
  ];
  return {
    from: before.from,
    options,
    validFor: /^[\\/][A-Za-z]*$/
  };
}

const setGhostEffect = StateEffect.define<{ pos: number | null; text: string }>();

class GhostWidget extends WidgetType {
  constructor(private text: string) {
    super();
  }

  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-ghost';
    span.textContent = this.text;
    return span;
  }

  ignoreEvent() {
    return true;
  }
}

const ghostField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none;
  },
  update(deco, tr) {
    let next = deco.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(setGhostEffect)) {
        const { pos, text } = effect.value;
        if (pos == null || !text) {
          return Decoration.none;
        }
        const widget = Decoration.widget({
          widget: new GhostWidget(text),
          side: 1
        });
        return Decoration.set([widget.range(pos)]);
      }
    }
    if (tr.docChanged || tr.selectionSet) {
      return Decoration.none;
    }
    return next;
  },
  provide: (field) => EditorView.decorations.from(field)
});

/* ── LaTeX environment scope colorization ── */
const SCOPE_COLORS = [
  'rgba(180, 74, 47, 0.5)',
  'rgba(59, 130, 186, 0.5)',
  'rgba(76, 159, 88, 0.5)',
  'rgba(180, 137, 47, 0.5)',
  'rgba(142, 68, 173, 0.5)',
  'rgba(211, 84, 0, 0.5)',
];

function computeEnvDepths(doc: { lines: number; line: (n: number) => { text: string } }): number[] {
  const depths: number[] = [];
  let depth = 0;
  for (let i = 1; i <= doc.lines; i++) {
    const clean = stripLatexComment(doc.line(i).text);
    ENV_RE.lastIndex = 0;
    let match: RegExpExecArray | null;
    const events: { pos: number; delta: number }[] = [];
    while ((match = ENV_RE.exec(clean)) !== null) {
      events.push({ pos: match.index, delta: match[1] === 'begin' ? 1 : -1 });
    }
    events.sort((a, b) => a.pos - b.pos);
    let lineDepth = depth;
    for (const ev of events) {
      if (ev.delta < 0) { depth--; lineDepth = Math.min(lineDepth, depth); }
      else { depth++; }
    }
    depths.push(Math.max(0, lineDepth));
  }
  return depths;
}

const envDepthField = StateField.define<number[]>({
  create(state) { return computeEnvDepths(state.doc); },
  update(value, tr) {
    if (tr.docChanged) return computeEnvDepths(tr.state.doc);
    return value;
  },
});

class ScopeMarker extends GutterMarker {
  constructor(readonly depth: number) { super(); }
  toDOM() {
    const wrap = document.createElement('div');
    wrap.className = 'cm-scope-marker';
    for (let i = 0; i < this.depth; i++) {
      const bar = document.createElement('span');
      bar.className = 'cm-scope-bar';
      bar.style.backgroundColor = SCOPE_COLORS[i % SCOPE_COLORS.length];
      wrap.appendChild(bar);
    }
    return wrap;
  }
}

const scopeGutter = gutter({
  class: 'cm-scope-gutter',
  lineMarker(view, line) {
    const depths = view.state.field(envDepthField);
    const lineNo = view.state.doc.lineAt(line.from).number;
    const d = depths[lineNo - 1] || 0;
    return d > 0 ? new ScopeMarker(d) : null;
  },
});

// Numenor theme for the source editor: colours come from theme.css variables, so it follows light/dark.
const editorTheme = EditorView.theme(
  {
    '&': {
      height: '100%',
      background: 'var(--nm-pane)',
      color: 'var(--nm-text)'
    },
    '.cm-scroller': {
      fontFamily: 'var(--nm-mono)',
      fontSize: 'var(--editor-font-size, 11px)',
      lineHeight: '1.65'
    },
    '.cm-content': {
      padding: '14px 16px 40px 8px',
      caretColor: 'var(--nm-gold)'
    },
    '.cm-cursor, .cm-dropCursor': {
      borderLeftColor: 'var(--nm-gold)',
      borderLeftWidth: '2px'
    },
    '.cm-gutters': {
      background: 'var(--nm-pane)',
      border: 'none',
      color: 'var(--nm-gutter)'
    },
    '.cm-lineNumbers .cm-gutterElement': {
      padding: '0 10px 0 14px'
    },
    '.cm-activeLine': {
      background: 'var(--nm-hover)'
    },
    '.cm-activeLineGutter': {
      background: 'transparent',
      color: 'var(--nm-text-2)'
    },
    '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': {
      background: 'var(--nm-gold-soft) !important'
    },
    '.cm-matchingBracket': {
      background: 'var(--nm-gold-soft)',
      outline: '1px solid var(--nm-gold-line)'
    },
    '.cm-foldPlaceholder': {
      background: 'var(--nm-chip)',
      border: 'none',
      color: 'var(--nm-text-2)'
    }
  }
);

// LaTeX token colours: commands and their arguments' braces in gold, comments in a muted gold.
const numenorHighlight = HighlightStyle.define([
  { tag: hlTags.keyword, color: 'var(--nm-syn-command)' },
  { tag: hlTags.comment, color: 'var(--nm-syn-comment)', fontStyle: 'normal' },
  { tag: hlTags.bracket, color: 'var(--nm-syn-bracket)' },
  { tag: hlTags.number, color: 'var(--nm-syn-math)' },
  { tag: hlTags.string, color: 'var(--nm-syn-math)' }
]);

function buildSplitDiff(original: string, proposed: string) {
  const parts = diffLines(original, proposed);
  let leftLine = 1;
  let rightLine = 1;
  const rows: {
    left?: string;
    right?: string;
    leftNo?: number;
    rightNo?: number;
    type: 'context' | 'added' | 'removed';
  }[] = [];

  parts.forEach((part) => {
    const lines = part.value.split('\n');
    if (lines[lines.length - 1] === '') {
      lines.pop();
    }
    lines.forEach((line) => {
      if (part.added) {
        rows.push({ right: line, rightNo: rightLine++, type: 'added' });
      } else if (part.removed) {
        rows.push({ left: line, leftNo: leftLine++, type: 'removed' });
      } else {
        rows.push({
          left: line,
          right: line,
          leftNo: leftLine++,
          rightNo: rightLine++,
          type: 'context'
        });
      }
    });
  });

  return rows;
}

type CompileError = {
  message: string;
  line?: number;
  file?: string;
  raw?: string;
};

function parseCompileErrors(log: string): CompileError[] {
  if (!log) return [];
  const lines = log.split('\n');
  const errors: CompileError[] = [];
  const seen = new Set<string>();

  const pushError = (error: CompileError) => {
    const key = `${error.file || ''}:${error.line || ''}:${error.message}`;
    if (seen.has(key)) return;
    seen.add(key);
    errors.push(error);
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const fileLineMatch = line.match(/([A-Za-z0-9_./-]+\.tex):(\d+)/);
    if (fileLineMatch) {
      pushError({
        message: line.trim(),
        file: fileLineMatch[1],
        line: Number(fileLineMatch[2]),
        raw: line
      });
    }
    if (line.startsWith('!')) {
      const message = line.replace(/^!+\s*/, '').trim();
      let lineNo: number | undefined;
      for (let j = i + 1; j < Math.min(i + 4, lines.length); j += 1) {
        const match = lines[j].match(/l\.(\d+)/);
        if (match) {
          lineNo = Number(match[1]);
          break;
        }
      }
      pushError({ message, line: lineNo, raw: line });
    }
  }

  return errors;
}

function findLineOffset(text: string, line: number) {
  if (line <= 1) return 0;
  let offset = 0;
  let current = 1;
  while (current < line && offset < text.length) {
    const next = text.indexOf('\n', offset);
    if (next === -1) break;
    offset = next + 1;
    current += 1;
  }
  return offset;
}

function replaceSelection(source: string, start: number, end: number, replacement: string) {
  return source.slice(0, start) + replacement + source.slice(end);
}

function SplitDiffView({ rows }: { rows: ReturnType<typeof buildSplitDiff> }) {
  const { t } = useTranslation();
  const leftRef = useRef<HTMLDivElement | null>(null);
  const rightRef = useRef<HTMLDivElement | null>(null);
  const lockRef = useRef(false);

  const syncScroll = (source: HTMLDivElement | null, target: HTMLDivElement | null) => {
    if (!source || !target || lockRef.current) return;
    lockRef.current = true;
    target.scrollTop = source.scrollTop;
    target.scrollLeft = source.scrollLeft;
    requestAnimationFrame(() => {
      lockRef.current = false;
    });
  };

  return (
    <div className="split-diff">
      <div
        className="split-column"
        ref={leftRef}
        onScroll={() => syncScroll(leftRef.current, rightRef.current)}
      >
        <div className="split-header">{t('Before')}</div>
        {rows.map((row, idx) => (
          <div key={`l-${idx}`} className={`split-row ${row.type}`}>
            <div className="line-no">{row.leftNo ?? ''}</div>
            <div className="line-text">{row.left ?? ''}</div>
          </div>
        ))}
      </div>
      <div
        className="split-column"
        ref={rightRef}
        onScroll={() => syncScroll(rightRef.current, leftRef.current)}
      >
        <div className="split-header">{t('After')}</div>
        {rows.map((row, idx) => (
          <div key={`r-${idx}`} className={`split-row ${row.type}`}>
            <div className="line-no">{row.rightNo ?? ''}</div>
            <div className="line-text">{row.right ?? ''}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

// Maziar: spelling/grammar language. American English by default; Maziar's Settings (US or UK) is passed in
// as window.__maziarSpellLanguage. A change there wins once; after that the editor's own language menu
// can still pick something else until the Maziar setting changes again.
const SPELL_DEFAULT = 'en_US';
function resolveSpellLanguage(fromMaziar?: string) {
  try {
    let stored = localStorage.getItem('maziar.spell.language') || '';
    if (stored === 'en') stored = 'en_US'; // older default — macOS's "en" is American English
    if (fromMaziar && localStorage.getItem('maziar.spell.maziarDefault') !== fromMaziar) {
      localStorage.setItem('maziar.spell.maziarDefault', fromMaziar);
      localStorage.setItem('maziar.spell.language', fromMaziar);
      return fromMaziar;
    }
    return stored || fromMaziar || SPELL_DEFAULT;
  } catch {
    return fromMaziar || SPELL_DEFAULT;
  }
}

export default function EditorPage() {
  const navigate = useNavigate();
  const { t, i18n } = useTranslation();
  const { projectId: routeProjectId } = useParams();
  const projectId = routeProjectId || '';
  const [settings, setSettings] = useState<AppSettings>(() => loadSettings());
  const [settingsOpen, setSettingsOpen] = useState(false);
  // A file changed on disk by something else (Google Drive from another computer…) while it had unsaved edits here.
  const [externalChange, setExternalChange] = useState<{ path: string; content: string } | null>(null);
  // Settings → "Where this project is saved" (owner's computer only).
  const [projectLocation, setProjectLocation] = useState<ProjectLocation | null>(null);
  const [locationNote, setLocationNote] = useState('');
  const [projectName, setProjectName] = useState('');
  const [tree, setTree] = useState<{ path: string; type: string }[]>([]);
  const [fileOrder, setFileOrder] = useState<Record<string, string[]>>({});
  const [activePath, setActivePath] = useState<string>('');
  const [files, setFiles] = useState<Record<string, string>>({});
  const filesRef = useRef(files);
  filesRef.current = files;
  const [editorValue, setEditorValue] = useState<string>('');
  const [selectionRange, setSelectionRange] = useState<[number, number]>([0, 0]);
  const [isSuggesting, setIsSuggesting] = useState(false);
  const [inlineSuggestionText, setInlineSuggestionText] = useState('');
  const [suggestionPos, setSuggestionPos] = useState<{ left: number; top: number } | null>(null);
  const [assistantMode, setAssistantMode] = useState<'chat' | 'agent'>('agent');
  const [chatMessages, setChatMessages] = useState<Message[]>([]);
  const [agentMessages, setAgentMessages] = useState<Message[]>([]);
  const [prompt, setPrompt] = useState('');
  const [task, setTask] = useState(DEFAULT_TASKS(t)[0].value);
  const [mode, setMode] = useState<'direct' | 'tools'>('direct');
  const [translateScope, setTranslateScope] = useState<'selection' | 'file' | 'project'>('selection');
  const [translateTarget, setTranslateTarget] = useState('English');
  const [taskDropdownOpen, setTaskDropdownOpen] = useState(false);
  const [modeDropdownOpen, setModeDropdownOpen] = useState(false);
  const [translateScopeDropdownOpen, setTranslateScopeDropdownOpen] = useState(false);
  const [translateTargetDropdownOpen, setTranslateTargetDropdownOpen] = useState(false);
  const [rightViewDropdownOpen, setRightViewDropdownOpen] = useState(false);
  const [mainFileDropdownOpen, setMainFileDropdownOpen] = useState(false);
  const [engineDropdownOpen, setEngineDropdownOpen] = useState(false);
  const [langDropdownOpen, setLangDropdownOpen] = useState(false);
  const [topBarDropdownRect, setTopBarDropdownRect] = useState<{ top: number; left: number; width: number } | null>(null);
  const [visionModeDropdownOpen, setVisionModeDropdownOpen] = useState(false);
  const [bibTargetDropdownOpen, setBibTargetDropdownOpen] = useState(false);
  const [citeTargetDropdownOpen, setCiteTargetDropdownOpen] = useState(false);
  const [wsBibDropdownOpen, setWsBibDropdownOpen] = useState(false);
  const [wsTexDropdownOpen, setWsTexDropdownOpen] = useState(false);
  const [plotTypeDropdownOpen, setPlotTypeDropdownOpen] = useState(false);
  const [figureDropdownOpen, setFigureDropdownOpen] = useState(false);
  const [pendingChanges, setPendingChanges] = useState<PendingChange[]>([]);
  const [compileLog, setCompileLog] = useState('');
  const [pdfUrl, setPdfUrl] = useState('');
  const [pdfScale, setPdfScale] = useState(1);
  const [pdfFitWidth, setPdfFitWidth] = useState(true);
  const [pdfFitScale, setPdfFitScale] = useState<number | null>(null);
  const [pdfSpread, setPdfSpread] = useState(false);
  const [pdfOutline, setPdfOutline] = useState<{ title: string; page?: number; level: number }[]>([]);
  const [pdfAnnotations, setPdfAnnotations] = useState<{ id: string; page: number; x: number; y: number; text: string }[]>([]);
  const [pdfAnnotateMode, setPdfAnnotateMode] = useState(false);
  const [pdfZoom, setPdfZoom] = useState<{ scale: number; mode: PdfZoomMode }>({ scale: 1, mode: 'fitWidth' });
  const [diagnosticsOpen, setDiagnosticsOpen] = useState(false);
  // Redesign: result of the last compile (status bar), PDF page indicator, toolbar menus.
  const [compileState, setCompileState] = useState<'idle' | 'ok' | 'failed'>('idle');
  const [pdfPage, setPdfPage] = useState({ page: 0, total: 0 });
  const [nmMenu, setNmMenu] = useState('');
  // Page asked for by the ‹ › buttons while the scroll is still moving there, so quick clicks add up.
  const requestedPageRef = useRef<{ page: number; at: number }>({ page: 0, at: 0 });
  const goToPdfPage = (delta: number) => {
    const recent = Date.now() - requestedPageRef.current.at < 1500 ? requestedPageRef.current.page : 0;
    const from = recent || pdfPage.page || 1;
    const target = Math.min(Math.max(1, from + delta), Math.max(1, pdfPage.total));
    requestedPageRef.current = { page: target, at: Date.now() };
    pdfViewerRef.current?.scrollToPage(target);
  };
  const [uploadError, setUploadError] = useState('');
  const [docTick, setDocTick] = useState(0);
  const [spellAvailable, setSpellAvailable] = useState(false);
  const [spellEnabled, setSpellEnabled] = useState(() => {
    try { return localStorage.getItem('maziar.spell.enabled') !== '0'; } catch { return true; }
  });
  const [spellLanguage, setSpellLanguage] = useState(() => resolveSpellLanguage((window as any).__maziarSpellLanguage));
  const [spellLanguageList, setSpellLanguageList] = useState<string[]>([]);
  const [spellInfo, setSpellInfo] = useState<SpellStatus>({ checking: false, count: 0 });
  const [spellPanelOpen, setSpellPanelOpen] = useState(false);
  const [vocabOpen, setVocabOpen] = useState(false);
  const [vocabWords, setVocabWords] = useState<string[]>([]);
  useEffect(() => {
    setVocabWords(listVocabulary());
    return onVocabularyChange(() => setVocabWords(listVocabulary()));
  }, []);
  const [engineName, setEngineName] = useState<string>('');
  const [isCompiling, setIsCompiling] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [isDirty, setIsDirty] = useState(false);
  const [savePulse, setSavePulse] = useState(false);
  const [status, setStatus] = useState<string>('');
  const [rightView, setRightView] = useState<'pdf' | 'figures' | 'diff' | 'log' | 'toc' | 'review'>('pdf');
  const [selectedFigure, setSelectedFigure] = useState<string>('');
  const [diffFocus, setDiffFocus] = useState<PendingChange | null>(null);
  const [activeSidebar, setActiveSidebar] = useState<'files' | 'agent' | 'vision' | 'search' | 'websearch' | 'plot' | 'review' | 'collab'>('files');
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [columnSizes, setColumnSizes] = useState({ sidebar: 260, editor: 640, right: 420 });
  const [editorSplit, setEditorSplit] = useState(0.7);
  const [selectedPath, setSelectedPath] = useState('');
  const [openFolders, setOpenFolders] = useState<Record<string, boolean>>({});
  const [dragOverPath, setDragOverPath] = useState('');
  const [dragOverKind, setDragOverKind] = useState<'file' | 'folder' | ''>('');
  const [draggingPath, setDraggingPath] = useState('');
  const [dragHint, setDragHint] = useState<{ text: string; x: number; y: number } | null>(null);
  const [mainFile, setMainFile] = useState('');
  // The compile file saved in the project (project.json) and the files that can be compiled.
  const [projectMainFile, setProjectMainFileState] = useState('');
  const [mainFiles, setMainFiles] = useState<string[]>([]);
  const [fileFilter, setFileFilter] = useState('');
  const [inlineEdit, setInlineEdit] = useState<InlineEdit | null>(null);
  const [fileContextMenu, setFileContextMenu] = useState<{ x: number; y: number } | null>(null);
  const [outlineCollapsed, setOutlineCollapsed] = useState(false);
  // Maziar: editor zoom, remembered in this browser.
  const [editorFontSize, setEditorFontSize] = useState(() => {
    try {
      const saved = Number(localStorage.getItem('maziar.editor.fontSize'));
      return saved >= 8 && saved <= 32 ? saved : 11;
    } catch {
      return 11;
    }
  });
  const editorZoomRef = useRef<(delta: number | 'reset') => void>(() => {});
  const [visionMode, setVisionMode] = useState<'equation' | 'table' | 'figure' | 'algorithm' | 'ocr'>('equation');
  const [visionFile, setVisionFile] = useState<File | null>(null);
  const [visionPrompt, setVisionPrompt] = useState('');
  const [visionResult, setVisionResult] = useState('');
  const [visionBusy, setVisionBusy] = useState(false);
  const [visionPreviewUrl, setVisionPreviewUrl] = useState('');
  const [arxivQuery, setArxivQuery] = useState('');
  const [arxivMaxResults, setArxivMaxResults] = useState(5);
  const [arxivResults, setArxivResults] = useState<ArxivPaper[]>([]);
  const [arxivSelected, setArxivSelected] = useState<Record<string, boolean>>({});
  const [arxivBusy, setArxivBusy] = useState(false);
  const [arxivStatus, setArxivStatus] = useState('');
  const [useLlmSearch, setUseLlmSearch] = useState(false);
  const [llmSearchOutput, setLlmSearchOutput] = useState('');
  const [arxivBibtexCache, setArxivBibtexCache] = useState<Record<string, string>>({});
  const [bibTarget, setBibTarget] = useState('');
  const [autoInsertCite, setAutoInsertCite] = useState(true);
  const [autoInsertToMain, setAutoInsertToMain] = useState(false);
  const [citeTargetFile, setCiteTargetFile] = useState('');
  const [outlineText, setOutlineText] = useState('');
  const [currentHeading, setCurrentHeading] = useState<{ title: string; level: string } | null>(null);
  const [plotType, setPlotType] = useState<'bar' | 'line' | 'heatmap'>('bar');
  const [plotTitle, setPlotTitle] = useState('');
  const [plotFilename, setPlotFilename] = useState('');
  const [plotPrompt, setPlotPrompt] = useState('');
  const [plotRetries, setPlotRetries] = useState(2);
  const [plotBusy, setPlotBusy] = useState(false);
  const [plotStatus, setPlotStatus] = useState('');
  const [plotAssetPath, setPlotAssetPath] = useState('');
  const [plotAutoInsert, setPlotAutoInsert] = useState(true);
  const [websearchQuery, setWebsearchQuery] = useState('');
  const [websearchLog, setWebsearchLog] = useState<string[]>([]);
  const [websearchBusy, setWebsearchBusy] = useState(false);
  const [websearchResults, setWebsearchResults] = useState<WebsearchItem[]>([]);
  const [websearchSelected, setWebsearchSelected] = useState<Record<string, boolean>>({});
  const [websearchParagraph, setWebsearchParagraph] = useState('');
  const [websearchItemNotes, setWebsearchItemNotes] = useState<Record<string, string>>({});
  const [websearchTargetFile, setWebsearchTargetFile] = useState('');
  const [websearchTargetBib, setWebsearchTargetBib] = useState('');
  const [reviewNotes, setReviewNotes] = useState<{ title: string; content: string }[]>([]);
  const [reviewReport, setReviewReport] = useState('');
  const [reviewReportBusy, setReviewReportBusy] = useState(false);
  const [diagnoseBusy, setDiagnoseBusy] = useState(false);
  const [websearchSelectedAll, setWebsearchSelectedAll] = useState(false);
  const [collabEnabled, setCollabEnabled] = useState(() => Boolean(getCollabToken()));
  const [collabStatus, setCollabStatus] = useState<'disconnected' | 'connecting' | 'connected'>('disconnected');
  const [collabInviteBusy, setCollabInviteBusy] = useState(false);
  const [collabInviteLink, setCollabInviteLink] = useState('');
  // Maziar/Numenor sharing: the public link invited collaborators come in through (owner only).
  const [share, setShare] = useState<ShareState | null>(null);
  const [shareBusy, setShareBusy] = useState(false);
  const isGuest = Boolean(getCollabToken());
  const [collabServer, setCollabServerState] = useState(() => getCollabServer() || (typeof window === 'undefined' ? '' : window.location.origin));
  const [collabName, setCollabName] = useState(() => loadCollabName() || 'Guest');
  const [collabToken] = useState(() => getCollabToken());
  const [collabPeers, setCollabPeers] = useState<{ id: number; name: string; color: string }[]>([]);
  const editorHostRef = useRef<HTMLDivElement | null>(null);
  const editorAreaRef = useRef<HTMLDivElement | null>(null);
  const cmViewRef = useRef<EditorView | null>(null);
  const activePathRef = useRef<string>('');
  const inlineSuggestionRef = useRef<string>('');
  const inlineAnchorRef = useRef<number | null>(null);
  const applyingSuggestionRef = useRef(false);
  const suppressDirtyRef = useRef(false);
  const typewriterTimerRef = useRef<number | null>(null);
  const requestSuggestionRef = useRef<() => void>(() => {});
  const acceptSuggestionRef = useRef<() => void>(() => {});
  const acceptChunkRef = useRef<() => void>(() => {});
  const clearSuggestionRef = useRef<() => void>(() => {});
  const saveActiveFileRef = useRef<() => void>(() => {});
  const gridRef = useRef<HTMLDivElement | null>(null);
  const editorSplitRef = useRef<HTMLDivElement | null>(null);
  const pdfContainerRef = useRef<HTMLDivElement | null>(null);
  const fileTreeRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const folderInputRef = useRef<HTMLInputElement | null>(null);
  const saveTimerRef = useRef<number | null>(null);
  const collabProviderRef = useRef<CollabProvider | null>(null);
  const collabDocRef = useRef<{ doc: Y.Doc; text: Y.Text; awareness: Awareness } | null>(null);
  const collabActiveRef = useRef(false);
  const collabColorRef = useRef<string>(pickCollabColor(collabName));
  // Who this editor is ('owner' / 'invite:<id>'), sent with the cursor so others can find it by name.
  const meKeyRef = useRef('');
  const collabCompartment = useMemo(() => new Compartment(), []);
  const readOnlyCompartment = useMemo(() => new Compartment(), []);
  // Who's using this editor: the owner (on this computer) or an invited person (and their rights).
  const [me, setMe] = useState<Me | null>(null);
  const [shareOpen, setShareOpen] = useState(false);
  const [syncOpen, setSyncOpen] = useState(false);
  const viewOnly = me?.kind === 'guest' && me.role === 'view';
  // PDF preview in its own window (see PdfWindowPage).
  const [pdfPopped, setPdfPopped] = useState(false);
  const pdfPoppedRef = useRef(false);
  pdfPoppedRef.current = pdfPopped;
  const pdfWinRef = useRef<Window | null>(null);
  const spellCompartment = useMemo(() => new Compartment(), []);
  const pdfViewerRef = useRef<PdfViewerHandle | null>(null);
  // Cmd/Ctrl + F searches where you last clicked: the source (.tex, .txt, .bib…) or the compiled PDF.
  const lastPaneRef = useRef<'editor' | 'pdf'>('editor');
  const [pdfFind, setPdfFind] = useState<{ open: boolean; query: string; index: number; total: number; busy: boolean }>({ open: false, query: '', index: 0, total: 0, busy: false });
  const pdfFindInputRef = useRef<HTMLInputElement | null>(null);
  const pdfFindTimerRef = useRef<number | undefined>(undefined);
  // Files the last compile couldn't find (moved or deleted by mistake), shown above the PDF.
  const [missingFiles, setMissingFiles] = useState<MissingFile[]>([]);
  const [missingBusy, setMissingBusy] = useState('');
  const forwardSyncRef = useRef<() => void>(() => {});

  const {
    llmEndpoint,
    llmApiKey,
    llmModel,
    searchEndpoint,
    searchApiKey,
    searchModel,
    visionEndpoint,
    visionApiKey,
    visionModel,
    compileEngine
  } = settings;

  useEffect(() => {
    persistSettings(settings);
  }, [settings]);

  useEffect(() => {
    if (collabServer) {
      setCollabServer(collabServer);
    }
  }, [collabServer]);

  useEffect(() => {
    persistCollabName(collabName);
    collabColorRef.current = me?.key ? colorForKey(me.key) : pickCollabColor(collabName);
    meKeyRef.current = me?.key || '';
    if (collabDocRef.current) {
      collabDocRef.current.awareness.setLocalStateField('user', {
        name: collabName,
        color: collabColorRef.current,
        colorLight: `${collabColorRef.current}33`,
        key: meKeyRef.current
      });
    }
  }, [collabName, me]);

  // The name others see on this cursor is the one the owner gave the invite (or the owner's own name).
  useEffect(() => {
    if (me?.name) setCollabName(me.name);
  }, [me?.name]);

  useEffect(() => {
    if (!collabEnabled) {
      collabActiveRef.current = false;
    }
  }, [collabEnabled]);

  const llmConfig = useMemo(
    () => ({
      endpoint: llmEndpoint,
      apiKey: llmApiKey || undefined,
      model: llmModel
    }),
    [llmEndpoint, llmApiKey, llmModel]
  );

  const searchLlmConfig = useMemo(() => {
    const hasOverride = Boolean(searchEndpoint || searchApiKey || searchModel);
    return {
      endpoint: (hasOverride ? searchEndpoint : llmEndpoint) || llmEndpoint,
      apiKey: (hasOverride ? searchApiKey : llmApiKey) || undefined,
      model: (hasOverride ? searchModel : llmModel) || llmModel
    };
  }, [llmEndpoint, llmApiKey, llmModel, searchEndpoint, searchApiKey, searchModel]);

  const visionLlmConfig = useMemo(() => {
    const hasOverride = Boolean(visionEndpoint || visionApiKey || visionModel);
    return {
      endpoint: (hasOverride ? visionEndpoint : llmEndpoint) || llmEndpoint,
      apiKey: (hasOverride ? visionApiKey : llmApiKey) || undefined,
      model: (hasOverride ? visionModel : llmModel) || llmModel
    };
  }, [llmEndpoint, llmApiKey, llmModel, visionEndpoint, visionApiKey, visionModel]);

  useEffect(() => {
    if (!projectId) {
      navigate('/projects', { replace: true });
      return;
    }
    setProjectName('');
    listProjects()
      .then((res) => {
        const current = res.projects.find((item) => item.id === projectId);
        if (!current) {
          setStatus(t('项目不存在或已被删除。'));
          return;
        }
        setProjectName(current.name);
      })
      .catch((err) => setStatus(t('加载项目信息失败: {{error}}', { error: String(err) })));
  }, [navigate, projectId, t]);

  useEffect(() => {
    activePathRef.current = activePath;
  }, [activePath]);

  useEffect(() => {
    const view = cmViewRef.current;
    if (!view) return;
    if (!collabEnabled || !projectId || !activePath) {
      collabActiveRef.current = false;
      if (collabProviderRef.current) {
        collabProviderRef.current.disconnect();
        collabProviderRef.current = null;
      }
      collabDocRef.current = null;
      view.dispatch({ effects: collabCompartment.reconfigure([]) });
      setCollabStatus('disconnected');
      setCollabPeers([]);
      return;
    }
    if (!isTextPath(activePath)) {
      collabActiveRef.current = false;
      if (collabProviderRef.current) {
        collabProviderRef.current.disconnect();
        collabProviderRef.current = null;
      }
      collabDocRef.current = null;
      view.dispatch({ effects: collabCompartment.reconfigure([]) });
      setCollabStatus('disconnected');
      setCollabPeers([]);
      setStatus(t('协作暂不支持该文件类型。'));
      return;
    }
    const currentDoc = view.state.doc.toString();
    if (currentDoc.length > 0) {
      suppressDirtyRef.current = true;
      view.dispatch({ changes: { from: 0, to: currentDoc.length, insert: '' } });
    }
    setEditorValue('');
    setIsDirty(false);

    const ydoc = new Y.Doc();
    const ytext = ydoc.getText('content');
    const awareness = new Awareness(ydoc);
    awareness.setLocalStateField('user', {
      name: collabName,
      color: collabColorRef.current,
      colorLight: `${collabColorRef.current}33`,
      key: meKeyRef.current
    });
    const provider = new CollabProvider({
      serverUrl: normalizeServerUrl(collabServer) || (typeof window === 'undefined' ? '' : window.location.origin),
      token: collabToken || undefined,
      projectId,
      filePath: activePath,
      doc: ydoc,
      awareness,
      onStatus: setCollabStatus,
      onError: (error) => setStatus(t('协作连接失败: {{error}}', { error }))
    });
    collabProviderRef.current = provider;
    collabDocRef.current = { doc: ydoc, text: ytext, awareness };
    view.dispatch({ effects: collabCompartment.reconfigure(yCollab(ytext, awareness)) });
    collabActiveRef.current = true;
    provider.connect();

    const updatePeers = () => {
      const peers: { id: number; name: string; color: string }[] = [];
      awareness.getStates().forEach((state, id) => {
        const user = (state as { user?: { name?: string; color?: string } }).user;
        if (!user) return;
        peers.push({
          id,
          name: user.name || `User-${id}`,
          color: user.color || '#b44a2f'
        });
      });
      setCollabPeers(peers);
    };
    awareness.on('update', updatePeers);
    updatePeers();

    return () => {
      collabActiveRef.current = false;
      awareness.off('update', updatePeers);
      provider.disconnect();
      collabProviderRef.current = null;
      collabDocRef.current = null;
      ydoc.destroy();
      view.dispatch({ effects: collabCompartment.reconfigure([]) });
      setCollabPeers([]);
    };
  }, [activePath, collabCompartment, collabEnabled, collabName, collabServer, collabToken, projectId, t]);

  const handleCreateInvite = useCallback(async () => {
    if (!projectId) return;
    setCollabInviteBusy(true);
    try {
      const res = await createCollabInvite(projectId);
      if (!res.ok || !res.token) {
        throw new Error(t('邀请生成失败'));
      }
      // When sharing is on, invites point at the public link; otherwise at the address typed above.
      const baseInput = (share?.active && share.url) || normalizeServerUrl(collabServer) || (typeof window === 'undefined' ? '' : window.location.origin);
      const base = baseInput.replace(/\/$/, '');
      const link = `${base}/collab?token=${encodeURIComponent(res.token)}`;
      setCollabInviteLink(link);
      if (!collabEnabled) {
        setCollabEnabled(true);
      }
      setStatus(t('邀请链接已生成'));
    } catch (err) {
      setStatus(t('生成邀请失败: {{error}}', { error: String(err) }));
    } finally {
      setCollabInviteBusy(false);
    }
  }, [collabServer, projectId, share, t]);

  // ---------- Maziar: one-click sharing ----------
  useEffect(() => {
    if (isGuest || activeSidebar !== 'collab') return;
    let stop = false;
    const poll = () => shareStatus().then((s) => { if (!stop) setShare(s); }).catch(() => { if (!stop) setShare(null); });
    poll();
    const timer = window.setInterval(poll, 5000);
    return () => {
      stop = true;
      window.clearInterval(timer);
    };
  }, [activeSidebar, isGuest]);

  /** Starts the public link if needed, creates an invite for this project and copies it. */
  const shareThisProject = useCallback(async () => {
    if (!projectId) return;
    setShareBusy(true);
    try {
      let current = await shareStatus();
      if (!current.active) {
        setStatus(t('Starting a share link… (can take up to 30 seconds)'));
        current = await startShare();
      }
      setShare(current);
      const res = await createCollabInvite(projectId);
      if (!res.ok || !res.token) throw new Error(t('邀请生成失败'));
      const link = `${current.url.replace(/\/$/, '')}/collab?token=${encodeURIComponent(res.token)}`;
      setCollabInviteLink(link);
      if (!collabEnabled && activePath && isTextPath(activePath)) setCollabEnabled(true);
      try {
        await navigator.clipboard.writeText(link);
        setStatus(t('Invite link copied — send it to the people you want to edit this project.'));
      } catch {
        setStatus(t('Invite link ready — copy it from the Collab tab.'));
      }
    } catch (err) {
      setStatus(t('Couldn’t share: {{error}}', { error: (err as Error).message }));
      shareStatus().then(setShare).catch(() => {});
    } finally {
      setShareBusy(false);
    }
  }, [projectId, collabEnabled, activePath, t]);

  const stopSharingNow = useCallback(async () => {
    setShareBusy(true);
    try {
      setShare(await stopShare());
      setCollabInviteLink('');
      setStatus(t('Sharing stopped — invite links no longer work.'));
    } catch (err) {
      setStatus(String((err as Error).message || err));
    } finally {
      setShareBusy(false);
    }
  }, [t]);

  const copyInviteLink = useCallback(async () => {
    if (!collabInviteLink) return;
    try {
      await navigator.clipboard.writeText(collabInviteLink);
      setStatus(t('邀请链接已复制'));
    } catch (err) {
      setStatus(t('复制失败: {{error}}', { error: String(err) }));
    }
  }, [collabInviteLink, t]);

  const refreshTree = async (keepActive = true) => {
    if (!projectId) return;
    const res = await getProjectTree(projectId);
    setTree(res.items);
    setFileOrder(res.fileOrder || {});
    setMainFiles(res.mainFiles || []);
    setProjectMainFileState(res.mainFile || '');
    if (!keepActive || !activePath || !res.items.find((item) => item.path === activePath)) {
      const main = (res.mainFile && res.items.some((item) => item.path === res.mainFile) ? res.mainFile : '')
        || res.items.find((item) => item.path.endsWith('main.tex'))?.path;
      // Maziar: reopen the file that was open last time in this project.
      const lastFile = rememberRead('lastFile');
      const remembered = typeof lastFile === 'string' && res.items.some((item) => item.type === 'file' && item.path === lastFile) && isTextFile(lastFile) ? lastFile : '';
      const next = remembered || main || res.items.find((item) => item.type === 'file')?.path || '';
      if (next) {
        await openFile(next);
      }
    }
  };

  useEffect(() => {
    if (!projectId) return;
    setFiles({});
    setActivePath('');
    refreshTree(false).catch((err) => setStatus(t('加载文件树失败: {{error}}', { error: String(err) })));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId, t]);


  useEffect(() => {
    if (!editorHostRef.current || cmViewRef.current) return;

    const updateListener = EditorView.updateListener.of((update) => {
      const skipClear = applyingSuggestionRef.current;
      if (update.docChanged) {
        const value = update.state.doc.toString();
        const programmatic = suppressDirtyRef.current;
        setEditorValue(value);
        if (!programmatic && !collabActiveRef.current) {
          setIsDirty(true);
        } else {
          suppressDirtyRef.current = false;
        }
        const path = activePathRef.current;
        if (path && (!programmatic || collabActiveRef.current)) {
          setFiles((prev) => ({ ...prev, [path]: value }));
        }
      }
      if (update.selectionSet) {
        saveEditorPositionRef.current();
        const sel = update.state.selection.main;
        setSelectionRange([sel.from, sel.to]);
        const heading = findNearestHeading(update.state.doc.toString(), sel.head);
        setCurrentHeading(heading);
      }
      if (!skipClear && inlineSuggestionRef.current && (update.docChanged || update.selectionSet)) {
        inlineSuggestionRef.current = '';
        inlineAnchorRef.current = null;
        setInlineSuggestionText('');
        setTimeout(() => {
          const view = cmViewRef.current;
          if (view) {
            view.dispatch({ effects: setGhostEffect.of({ pos: null, text: '' }) });
          }
        }, 0);
      }
      if (skipClear) {
        applyingSuggestionRef.current = false;
      }
    });

    const keymapExtension = keymap.of([
      {
        key: 'Mod-s',
        run: () => {
          saveActiveFileRef.current();
          return true;
        }
      },
      {
        key: 'Alt-/',
        run: () => {
          requestSuggestionRef.current();
          return true;
        }
      },
      {
        key: 'Mod-/',
        run: toggleComment
      },
      // Maziar: zoom the editor text.
      { key: 'Mod-=', run: () => { editorZoomRef.current(1); return true; } },
      { key: 'Mod-+', run: () => { editorZoomRef.current(1); return true; } },
      { key: 'Mod--', run: () => { editorZoomRef.current(-1); return true; } },
      { key: 'Mod-0', run: () => { editorZoomRef.current('reset'); return true; } },
      {
        // Maziar: SyncTeX forward search — show the cursor's position in the PDF.
        key: 'Mod-Shift-j',
        run: () => {
          forwardSyncRef.current();
          return true;
        }
      },
      {
        key: 'Mod-Space',
        run: () => {
          requestSuggestionRef.current();
          return true;
        }
      },
      {
        key: 'ArrowRight',
        run: (view) => {
          const pos = view.state.selection.main.head;
          if (inlineSuggestionRef.current && inlineAnchorRef.current === pos) {
            acceptChunkRef.current();
            return true;
          }
          return false;
        }
      },
      {
        key: 'Tab',
        run: () => {
          if (!inlineSuggestionRef.current) return false;
          acceptSuggestionRef.current();
          return true;
        }
      },
      {
        key: 'Escape',
        run: () => {
          clearSuggestionRef.current();
          return true;
        }
      },
      ...foldKeymap,
      ...searchKeymap
    ]);

    const state = EditorState.create({
      doc: '',
      extensions: [
        basicSetup,
        latex(),
        envDepthField,
        scopeGutter,
        indentOnInput(),
        foldService.of(latexFoldService),
        EditorView.lineWrapping,
        editorTheme,
        Prec.high(syntaxHighlighting(numenorHighlight)),
        collabCompartment.of([]),
        readOnlyCompartment.of([]),
        ghostField,
        diagnosticsExtension(),
        strongComments(),
        spellCompartment.of([]),
        search(),
        autocompletion({ override: [latexCompletionSource] }),
        updateListener,
        keymapExtension
      ]
    });

    const view = new EditorView({
      state,
      parent: editorHostRef.current
    });
    cmViewRef.current = view;

    const handleAltSlash = (event: KeyboardEvent) => {
      if (!event.altKey) return;
      if (event.key === '/' || event.key === '÷' || event.code === 'Slash') {
        event.preventDefault();
        event.stopPropagation();
        requestSuggestionRef.current();
      }
    };
    view.dom.addEventListener('keydown', handleAltSlash, true);

    return () => {
      view.dom.removeEventListener('keydown', handleAltSlash, true);
      view.destroy();
      cmViewRef.current = null;
    };
  }, []);

  const openFile = async (filePath: string) => {
    setExternalChange((c) => (c && c.path !== filePath ? null : c));
    setActivePath(filePath);
    activePathRef.current = filePath;
    setSelectedPath(filePath);
    if (filePath.includes('/')) {
      const parts = filePath.split('/').slice(0, -1);
      setOpenFolders((prev) => {
        const next = { ...prev };
        let current = '';
        parts.forEach((part) => {
          current = current ? `${current}/${part}` : part;
          next[current] = true;
        });
        return next;
      });
    }
    if (Object.prototype.hasOwnProperty.call(files, filePath)) {
      const cached = files[filePath] ?? '';
      const collabTextFile = collabEnabled && isTextPath(filePath);
      setEditorValue(collabTextFile ? '' : cached);
      setIsDirty(false);
      if (!collabTextFile) {
        setEditorDoc(cached);
        restoreEditorPosition(filePath);
      }
      rememberWrite('lastFile', filePath);
      return cached;
    }
    const data = await getFile(projectId, filePath);
    setFiles((prev) => ({ ...prev, [filePath]: data.content }));
    const collabTextFile = collabEnabled && isTextPath(filePath);
    setEditorValue(collabTextFile ? '' : data.content);
    setIsDirty(false);
    if (!collabTextFile) {
      setEditorDoc(data.content);
      restoreEditorPosition(filePath);
    }
    rememberWrite('lastFile', filePath);
    return data.content;
  };

  const openFileRef = useRef(openFile);
  openFileRef.current = openFile;
  const refreshTreeRef = useRef(refreshTree);
  refreshTreeRef.current = refreshTree;

  // Maziar: per-project memory (this browser) — last open file, cursor/scroll per file, main file.
  const rememberRead = (key: string) => {
    try {
      return JSON.parse(localStorage.getItem(`maziar.numenor.${projectId}.${key}`) || 'null');
    } catch {
      return null;
    }
  };
  const rememberWrite = (key: string, value: unknown) => {
    try {
      localStorage.setItem(`maziar.numenor.${projectId}.${key}`, JSON.stringify(value));
    } catch {
      /* ignore */
    }
  };
  const rememberRef = useRef({ read: rememberRead, write: rememberWrite });
  rememberRef.current = { read: rememberRead, write: rememberWrite };

  /** Puts the cursor and scroll back where they were the last time `filePath` was open. */
  const restoreEditorPosition = (filePath: string) => {
    const view = cmViewRef.current;
    const saved = rememberRead('pos') || {};
    const pos = saved[filePath];
    if (!view || !pos) return;
    const head = Math.min(Math.max(0, Number(pos.head) || 0), view.state.doc.length);
    view.dispatch({ selection: { anchor: head } });
    window.requestAnimationFrame(() => {
      view.scrollDOM.scrollTop = Number(pos.top) || 0;
    });
  };

  const saveEditorPositionTimerRef = useRef<number | null>(null);
  const saveEditorPosition = () => {
    if (saveEditorPositionTimerRef.current) window.clearTimeout(saveEditorPositionTimerRef.current);
    saveEditorPositionTimerRef.current = window.setTimeout(() => {
      const view = cmViewRef.current;
      const file = activePathRef.current;
      if (!view || !file) return;
      const { read, write } = rememberRef.current;
      const saved = read('pos') || {};
      saved[file] = { head: view.state.selection.main.head, top: Math.round(view.scrollDOM.scrollTop) };
      write('pos', saved);
    }, 400);
  };
  const saveEditorPositionRef = useRef(saveEditorPosition);
  saveEditorPositionRef.current = saveEditorPosition;

  useEffect(() => {
    const view = cmViewRef.current;
    if (!view) return;
    const onScroll = () => saveEditorPositionRef.current();
    view.scrollDOM.addEventListener('scroll', onScroll, { passive: true });
    return () => view.scrollDOM.removeEventListener('scroll', onScroll);
  }, []);
  const goToSourceRef = useRef<(file: string | undefined, line?: number, column?: number) => Promise<void>>(async () => {});

  const setEditorDoc = useCallback((value: string) => {
    const view = cmViewRef.current;
    if (!view) return;
    // Maziar: a new document was loaded — lets the compile-error markers be re-applied to it.
    setDocTick((n) => n + 1);
    const current = view.state.doc.toString();
    if (current === value) return;
    suppressDirtyRef.current = true;
    view.dispatch({
      changes: { from: 0, to: current.length, insert: value }
    });
  }, []);

  const clearInlineSuggestion = useCallback(() => {
    inlineSuggestionRef.current = '';
    inlineAnchorRef.current = null;
    setInlineSuggestionText('');
    setSuggestionPos(null);
    const view = cmViewRef.current;
    if (view) {
      view.dispatch({ effects: setGhostEffect.of({ pos: null, text: '' }) });
    }
  }, []);

  const nextSuggestionChunk = (text: string) => {
    const match = text.match(/^(\s*\S+\s*)/);
    return match ? match[1] : text;
  };

  const acceptInlineSuggestion = useCallback(() => {
    const view = cmViewRef.current;
    const text = inlineSuggestionRef.current;
    const pos = inlineAnchorRef.current;
    if (!view || !text || pos == null) return;
    applyingSuggestionRef.current = true;
    view.dispatch({
      changes: { from: pos, to: pos, insert: text },
      selection: { anchor: pos + text.length }
    });
    clearInlineSuggestion();
  }, [clearInlineSuggestion]);

  const acceptSuggestionChunk = useCallback(() => {
    const view = cmViewRef.current;
    const remaining = inlineSuggestionRef.current;
    const pos = inlineAnchorRef.current;
    if (!view || !remaining || pos == null) return;
    const chunk = nextSuggestionChunk(remaining);
    applyingSuggestionRef.current = true;
    view.dispatch({
      changes: { from: pos, to: pos, insert: chunk },
      selection: { anchor: pos + chunk.length }
    });
    const leftover = remaining.slice(chunk.length);
    if (!leftover) {
      clearInlineSuggestion();
      return;
    }
    inlineSuggestionRef.current = leftover;
    inlineAnchorRef.current = pos + chunk.length;
    setInlineSuggestionText(leftover);
    view.dispatch({ effects: setGhostEffect.of({ pos: pos + chunk.length, text: leftover }) });
  }, [clearInlineSuggestion]);

  const updateSuggestionPosition = useCallback((force = false) => {
    const view = cmViewRef.current;
    const anchor = inlineAnchorRef.current;
    const host = editorAreaRef.current;
    if (!view || !host || (!inlineSuggestionRef.current && !force) || anchor == null) {
      setSuggestionPos(null);
      return;
    }
    const coords = view.coordsAtPos(anchor);
    if (!coords) {
      setSuggestionPos(null);
      return;
    }
    const rect = host.getBoundingClientRect();
    const preferredLeft = coords.left - rect.left;
    const preferredTop = coords.bottom - rect.top + 6;
    const popoverWidth = 320;
    const clampedLeft = Math.min(Math.max(12, preferredLeft), Math.max(12, rect.width - popoverWidth));
    let top = preferredTop;
    if (preferredTop + 80 > rect.height) {
      top = Math.max(12, coords.top - rect.top - 62);
    }
    setSuggestionPos({ left: clampedLeft, top });
  }, []);

  const requestInlineSuggestion = useCallback(async () => {
    const view = cmViewRef.current;
    if (!view || isSuggesting) return;
    clearInlineSuggestion();
    const pos = view.state.selection.main.head;
    const docText = view.state.doc.toString();
    const before = docText.slice(Math.max(0, pos - 4000), pos);
    const after = docText.slice(pos, pos + 400);
    const heading = findNearestHeading(docText, pos);
    const env = findCurrentEnvironment(docText.slice(0, pos));
    inlineAnchorRef.current = pos;
    setIsSuggesting(true);
    updateSuggestionPosition(true);
    try {
      const res = await runAgent({
        task: 'autocomplete',
        prompt: [
          t('You are a LaTeX writing assistant.'),
          t('Continue after <CURSOR> with a coherent next block (1-2 paragraphs or a full environment).'),
          heading ? t('Current section: {{title}} ({{level}}).', { title: heading.title, level: heading.level }) : '',
          env ? t('You are inside environment: {{env}}.', { env }) : '',
          t('Preserve style and formatting.'),
          t('Return only the continuation text, no commentary.')
        ].filter(Boolean).join(' '),
        selection: '',
        content: `${before}<CURSOR>${after}`,
        mode: 'direct',
        projectId,
        activePath,
        compileLog,
        llmConfig
      });
      const suggestion = (res.suggestion || res.reply || '').trim();
      if (!suggestion) return;
      inlineSuggestionRef.current = suggestion;
      inlineAnchorRef.current = pos;
      setInlineSuggestionText(suggestion);
      view.dispatch({
        effects: setGhostEffect.of({ pos, text: suggestion })
      });
    } catch (err) {
      setStatus(t('补全失败: {{error}}', { error: String(err) }));
    } finally {
      setIsSuggesting(false);
      if (!inlineSuggestionRef.current) {
        setSuggestionPos(null);
      }
    }
  }, [activePath, clearInlineSuggestion, compileLog, isSuggesting, llmConfig, projectId, updateSuggestionPosition, t]);

  useEffect(() => {
    if (!inlineSuggestionText) {
      setSuggestionPos(null);
      return;
    }
    updateSuggestionPosition();
  }, [inlineSuggestionText, updateSuggestionPosition]);

  useEffect(() => {
    const view = cmViewRef.current;
    if (!view) return;
    const handleScroll = () => {
      if (inlineSuggestionRef.current) {
        updateSuggestionPosition();
      }
    };
    view.scrollDOM.addEventListener('scroll', handleScroll);
    window.addEventListener('resize', handleScroll);
    return () => {
      view.scrollDOM.removeEventListener('scroll', handleScroll);
      window.removeEventListener('resize', handleScroll);
    };
  }, [updateSuggestionPosition]);

  useEffect(() => {
    if (!inlineSuggestionRef.current) return;
    updateSuggestionPosition();
  }, [columnSizes, editorSplit, updateSuggestionPosition]);

  useEffect(() => {
    requestSuggestionRef.current = requestInlineSuggestion;
    acceptSuggestionRef.current = acceptInlineSuggestion;
    acceptChunkRef.current = acceptSuggestionChunk;
    clearSuggestionRef.current = clearInlineSuggestion;
  }, [requestInlineSuggestion, acceptInlineSuggestion, acceptSuggestionChunk, clearInlineSuggestion]);

  const saveActiveFile = useCallback(
    async (opts?: { silent?: boolean }) => {
      if (!activePath) return;
      if (collabActiveRef.current) {
        setIsSaving(true);
        try {
          await flushCollabFile(projectId, activePath);
          setSavePulse(true);
          window.setTimeout(() => setSavePulse(false), 1200);
          if (!opts?.silent) {
            setStatus(t('协作已同步 {{path}}', { path: activePath }));
          }
        } catch (err) {
          setStatus(t('协作同步失败: {{error}}', { error: String(err) }));
        } finally {
          setIsSaving(false);
        }
        return;
      }
      setIsSaving(true);
      try {
        await writeFile(projectId, activePath, editorValue);
        setIsDirty(false);
        setSavePulse(true);
        window.setTimeout(() => setSavePulse(false), 1200);
        if (!opts?.silent) {
          setStatus(t('已保存 {{path}}', { path: activePath }));
        }
      } catch (err) {
        setStatus(t('保存失败: {{error}}', { error: String(err) }));
      } finally {
        setIsSaving(false);
      }
    },
    [activePath, editorValue, projectId, t]
  );

  const writeFileCompat = useCallback(
    async (path: string, content: string) => {
      if (collabActiveRef.current && collabDocRef.current && path === activePath) {
        const { doc, text } = collabDocRef.current;
        doc.transact(() => {
          text.delete(0, text.length);
          text.insert(0, content);
        });
        setIsDirty(false);
        return { ok: true };
      }
      return writeFile(projectId, path, content);
    },
    [activePath, projectId]
  );

  useEffect(() => {
    saveActiveFileRef.current = () => saveActiveFile();
  }, [saveActiveFile]);

  useEffect(() => {
    if (!cmViewRef.current) return;
    if (collabActiveRef.current || collabEnabled) return;
    setEditorDoc(editorValue);
  }, [editorValue, setEditorDoc, collabEnabled]);

  useEffect(() => {
    if (collabActiveRef.current) return;
    if (!isDirty || !activePath) return;
    // Another computer changed this file and you haven't chosen which version to keep: don't overwrite it.
    if (externalChange && externalChange.path === activePath) return;
    if (saveTimerRef.current) {
      window.clearTimeout(saveTimerRef.current);
    }
    saveTimerRef.current = window.setTimeout(() => {
      saveActiveFile({ silent: true });
    }, 1500);
    return () => {
      if (saveTimerRef.current) {
        window.clearTimeout(saveTimerRef.current);
        saveTimerRef.current = null;
      }
    };
  }, [activePath, editorValue, isDirty, saveActiveFile, collabEnabled, externalChange]);

  const createBibFile = async () => {
    if (!projectId) return;
    const parent = selectedPath && tree.find((item) => item.path === selectedPath && item.type === 'dir')
      ? selectedPath
      : getParentPath(selectedPath || activePath || '');
    const path = parent ? `${parent}/references.bib` : 'references.bib';
    const content = '% Add BibTeX entries here\n';
    await writeFileCompat(path, content);
    await refreshTree();
    await openFile(path);
    return path;
  };

  const insertAtCursor = (text: string, opts?: { block?: boolean }) => {
    if (!activePath) return;
    const view = cmViewRef.current;
    if (!view) return;
    const sel = view.state.selection.main;
    let insert = text;
    if (opts?.block) {
      const before = sel.from > 0 ? view.state.doc.sliceString(sel.from - 1, sel.from) : '';
      if (before && before !== '\n') {
        insert = `\n${insert}`;
      }
      if (!insert.endsWith('\n\n')) {
        insert = insert.endsWith('\n') ? `${insert}\n` : `${insert}\n\n`;
      }
    }
    view.dispatch({
      changes: { from: sel.from, to: sel.to, insert },
      selection: { anchor: sel.from + insert.length }
    });
  };

  const insertFigureSnippet = (filePath: string) => {
    const snippet = [
      '\\begin{figure}[t]',
      '\\centering',
      `\\includegraphics[width=0.9\\linewidth]{${filePath}}`,
      '\\caption{Caption.}',
      `\\label{fig:${filePath.replace(/[^a-zA-Z0-9]+/g, '-')}}`,
      '\\end{figure}',
      ''
    ].join('\n');
    insertAtCursor(snippet, { block: true });
  };

  const insertSectionSnippet = () => insertAtCursor('\\section{Section Title}', { block: true });

  const insertSubsectionSnippet = () => insertAtCursor('\\subsection{Subsection Title}', { block: true });

  const insertSubsubsectionSnippet = () => insertAtCursor('\\subsubsection{Subsubsection Title}', { block: true });

  const insertItemizeSnippet = () => insertAtCursor(['\\begin{itemize}', '\\item ', '\\end{itemize}'].join('\n'), { block: true });

  const insertEnumerateSnippet = () => insertAtCursor(['\\begin{enumerate}', '\\item ', '\\end{enumerate}'].join('\n'), { block: true });

  const insertEquationSnippet = () => insertAtCursor(['\\begin{equation}', 'E = mc^2', '\\end{equation}'].join('\n'), { block: true });

  const insertTableSnippet = () =>
    insertAtCursor(['\\begin{table}[t]', '\\centering', '\\begin{tabular}{lcc}', '\\toprule', 'Method & A & B \\\\', '\\midrule', 'Ours & 0.0 & 0.0 \\\\', '\\bottomrule', '\\end{tabular}', '\\caption{Table caption.}', '\\label{tab:main}', '\\end{table}'].join('\n'), { block: true });

  const insertListingSnippet = () =>
    insertAtCursor(['\\begin{lstlisting}[language=Python]', '# code here', '\\end{lstlisting}'].join('\n'), { block: true });

  const insertAlgorithmSnippet = () =>
    insertAtCursor(['\\begin{algorithm}[t]', '\\caption{Algorithm}', '\\label{alg:main}', '\\begin{algorithmic}', '\\State Initialize', '\\end{algorithmic}', '\\end{algorithm}'].join('\n'), { block: true });

  const insertCiteSnippet = () => insertAtCursor('\\cite{citation-key}');

  const insertRefSnippet = () => insertAtCursor('\\ref{label}');

  const insertLabelSnippet = () => insertAtCursor('\\label{label}');

  const insertFigureTemplate = () =>
    insertAtCursor(['\\begin{figure}[t]', '\\centering', '\\includegraphics[width=0.9\\linewidth]{figures/placeholder.png}', '\\caption{Caption.}', '\\label{fig:placeholder}', '\\end{figure}'].join('\n'), { block: true });

  const ensureFileContent = useCallback(
    async (path: string) => {
      if (Object.prototype.hasOwnProperty.call(files, path)) {
        return files[path] ?? '';
      }
      const data = await getFile(projectId, path);
      setFiles((prev) => ({ ...prev, [path]: data.content }));
      return data.content;
    },
    [files, projectId]
  );

  const buildProjectContext = useCallback(async () => {
    const root = mainFile || activePath;
    if (!root) return '';
    const visited = new Set<string>();
    const queue: string[] = [root];
    const summaries: string[] = [];
    while (queue.length > 0) {
      const current = queue.shift();
      if (!current || visited.has(current)) continue;
      visited.add(current);
      if (!current.toLowerCase().endsWith('.tex')) continue;
      let content = '';
      try {
        content = await ensureFileContent(current);
      } catch {
        continue;
      }
      const outline = parseOutline(content).slice(0, 12);
      const headings = outline.map((item) => `${'  '.repeat(item.level - 1)}- ${item.title}`);
      summaries.push(t('File: {{file}}\n{{headings}}', { file: current, headings: headings.join('\n') }));
      const baseDir = getParentPath(current);
      const includes = extractIncludeTargets(content);
      includes.forEach((raw) => {
        let target = raw.replace(/^\//, '');
        if (!target.endsWith('.tex')) {
          target = `${target}.tex`;
        }
        const resolved = baseDir ? `${baseDir}/${target}` : target;
        if (!visited.has(resolved)) {
          queue.push(resolved);
        }
      });
    }
    const filesList = Array.from(visited).join(', ');
    return t('Project files: {{files}}\nOutline:\n{{summaries}}', { files: filesList, summaries: summaries.join('\n') });
  }, [activePath, ensureFileContent, mainFile, t]);

  const extractBibKey = (bibtex: string) => {
    const match = bibtex.match(/@\w+\s*{\s*([^,\s]+)\s*,/);
    return match ? match[1].trim() : '';
  };

  const handleArxivSearch = useCallback(async () => {
    const query = arxivQuery.trim();
    if (!query) {
      setArxivStatus(t('请输入检索关键词。'));
      return;
    }
    setArxivBusy(true);
    setArxivStatus('');
    try {
      if (useLlmSearch) {
        setLlmSearchOutput('');
        const res = await runAgent({
          task: 'websearch',
          prompt: [
            t('Search arXiv for the user query.'),
            t('Return at most {{max}} papers.', { max: arxivMaxResults }),
            t('Use arxiv_search and arxiv_bibtex tools.'),
            t('Return JSON ONLY in this schema:'),
            t('{"papers":[{"title":"","authors":[],"arxivId":"","bibtex":""}]}.')
          ].join(' '),
          selection: '',
          content: query,
          mode: 'tools',
          projectId,
          activePath,
          compileLog,
          llmConfig: searchLlmConfig,
          interaction: 'agent',
          history: []
        });
        const raw = res.reply || '';
        if (raw) {
          setLlmSearchOutput(raw);
        }
        const jsonBlock = extractJsonBlock(raw);
        if (!jsonBlock) {
          throw new Error(t('LLM 输出无法解析为 JSON。'));
        }
        const parsed = safeJsonParse<{ papers?: { title: string; authors?: string[]; arxivId: string; bibtex?: string }[] }>(jsonBlock);
        if (!parsed) {
          throw new Error(t('LLM 输出 JSON 解析失败。'));
        }
        const papers = parsed.papers || [];
        setArxivResults(
          papers.map((paper) => ({
            title: paper.title || t('(untitled)'),
            abstract: '',
            authors: paper.authors || [],
            url: paper.arxivId ? `https://arxiv.org/abs/${paper.arxivId}` : '',
            arxivId: paper.arxivId
          }))
        );
        const cache: Record<string, string> = {};
        papers.forEach((paper) => {
          if (paper.arxivId && paper.bibtex) {
            cache[paper.arxivId] = paper.bibtex;
          }
        });
        setArxivBibtexCache(cache);
        setArxivSelected({});
        if (papers.length === 0) {
          setArxivStatus(t('没有匹配结果。'));
        }
      } else {
        const res = await arxivSearch({ query, maxResults: arxivMaxResults });
        if (!res.ok) {
          throw new Error(res.error || t('检索失败'));
        }
        setArxivResults(res.papers || []);
        setArxivSelected({});
        if ((res.papers || []).length === 0) {
          setArxivStatus(t('没有匹配结果。'));
        }
      }
    } catch (err) {
      setArxivStatus(t('检索失败: {{error}}', { error: String(err) }));
    } finally {
      setArxivBusy(false);
    }
  }, [arxivQuery, arxivMaxResults, useLlmSearch, projectId, activePath, compileLog, searchLlmConfig, t]);

  const handleArxivApply = useCallback(async () => {
    if (!projectId) return;
    const selected = arxivResults.filter((paper) => arxivSelected[paper.arxivId]);
    if (selected.length === 0) {
      setArxivStatus(t('请选择要导入的论文。'));
      return;
    }
    let targetBib = bibTarget;
    if (!targetBib) {
      const created = await createBibFile();
      if (created) {
        targetBib = created;
        setBibTarget(created);
      }
    }
    if (!targetBib) {
      setArxivStatus(t('请先创建 Bib 文件。'));
      return;
    }
    setArxivBusy(true);
    setArxivStatus(t('正在写入 Bib...'));
    try {
      let content = await ensureFileContent(targetBib);
      const keys: string[] = [];
      for (const paper of selected) {
        let bibtexSource = arxivBibtexCache[paper.arxivId] || '';
        if (!bibtexSource) {
          const res = await arxivBibtex({ arxivId: paper.arxivId });
          if (!res.ok || !res.bibtex) {
            throw new Error(res.error || t('生成 BibTeX 失败: {{id}}', { id: paper.arxivId }));
          }
          bibtexSource = res.bibtex;
        }
        const normalizedBibtex = bibtexSource.replace(/\\n/g, '\n');
        const key = extractBibKey(normalizedBibtex);
        if (key) {
          const exists = new RegExp(`@\\w+\\s*{\\s*${key}\\s*,`, 'i').test(content);
          if (exists) {
            keys.push(key);
            continue;
          }
          keys.push(key);
        }
        if (content && !content.endsWith('\n')) content += '\n';
        content += `${normalizedBibtex.trim()}\n`;
      }
      await writeFileCompat(targetBib, content);
      setFiles((prev) => ({ ...prev, [targetBib]: content }));
      if (activePath === targetBib) {
        setEditorValue(content);
        if (!collabActiveRef.current) {
          setEditorDoc(content);
        }
      }
      if (autoInsertCite && keys.length > 0) {
        if (activePath && activePath.toLowerCase().endsWith('.tex')) {
          insertAtCursor(`\\cite{${keys.join(',')}}`);
        } else {
          setArxivStatus(t('Bib 已写入。打开 TeX 文件后可插入引用。'));
          setArxivBusy(false);
          return;
        }
      }
      if (autoInsertToMain && keys.length > 0) {
        const targetFile = citeTargetFile || mainFile;
        if (!targetFile) {
          setArxivStatus(t('未选择引用插入文件。'));
          setArxivBusy(false);
          return;
        }
        const citePayload = arxivResults
          .filter((paper) => keys.includes(extractBibKey(arxivBibtexCache[paper.arxivId] || '') || ''))
          .map((paper) => ({
            title: paper.title,
            arxivId: paper.arxivId
          }));
        const prompt = [
          t('Insert citations into the target TeX file.'),
          t('Target file: {{file}}.', { file: targetFile }),
          t('Use \\\\cite{{{keys}}}.', { keys: keys.join(',') }),
          t('If a Related Work section exists, add the citations there.'),
          t('Otherwise add a Related Work subsection near the end and cite the papers.'),
          t('Keep edits minimal and preserve formatting.'),
          citePayload.length > 0 ? t('Papers: {{payload}}', { payload: JSON.stringify(citePayload) }) : ''
        ].filter(Boolean).join(' ');
        try {
          const targetContent = await ensureFileContent(targetFile);
          const res = await runAgent({
            task: 'insert_citations',
            prompt,
            selection: '',
            content: targetContent || '',
            mode: 'tools',
            projectId,
            activePath: targetFile,
            compileLog,
            llmConfig: searchLlmConfig,
            interaction: 'agent',
            history: []
          });
          if (res.patches && res.patches.length > 0) {
            const nextPending = res.patches.map((patch) => ({
              filePath: patch.path,
              original: files[patch.path] ?? '',
              proposed: patch.content,
              diff: patch.diff
            }));
            setPendingChanges(nextPending);
            setRightView('diff');
            setArxivStatus(t('已生成引用插入建议，请在 Diff 面板应用。'));
          } else {
            setArxivStatus(t('未生成可应用的引用修改。'));
          }
        } catch (err) {
          setArxivStatus(t('引用插入失败: {{error}}', { error: String(err) }));
        }
      } else {
        setArxivStatus(t('已写入 Bib。'));
      }
    } catch (err) {
      setArxivStatus(t('写入失败: {{error}}', { error: String(err) }));
    } finally {
      setArxivBusy(false);
    }
  }, [activePath, arxivResults, arxivSelected, autoInsertCite, autoInsertToMain, bibTarget, projectId, createBibFile, ensureFileContent, setEditorDoc, arxivBibtexCache, compileLog, searchLlmConfig, mainFile, files, citeTargetFile, t]);

  const handlePlotGenerate = async () => {
    if (!projectId) return;
    if (!selectionText || (!selectionText.includes('\\begin{tabular') && !selectionText.includes('\\begin{table'))) {
      setPlotStatus(t('请在编辑器中选择一个 LaTeX 表格 (tabular)。'));
      return;
    }
    setPlotBusy(true);
    setPlotStatus('');
    try {
      const res = await plotFromTable({
        projectId,
        tableLatex: selectionText,
        chartType: plotType,
        title: plotTitle.trim() || undefined,
        prompt: plotPrompt.trim() || undefined,
        filename: plotFilename.trim() || undefined,
        retries: plotRetries,
        llmConfig
      });
      if (!res.ok || !res.assetPath) {
        throw new Error(res.error || t('图表生成失败'));
      }
      setPlotAssetPath(res.assetPath);
      setPlotStatus(t('图表已生成'));
      await refreshTree();
      if (plotAutoInsert) {
        insertFigureSnippet(res.assetPath);
      }
    } catch (err) {
      setPlotStatus(t('生成失败: {{error}}', { error: String(err) }));
    } finally {
      setPlotBusy(false);
    }
  };

  const runWebsearch = async () => {
    const query = websearchQuery.trim();
    if (!query) {
      setWebsearchLog([t('请输入查询关键词。')]);
      return;
    }
    setWebsearchBusy(true);
    setWebsearchLog([]);
    setWebsearchResults([]);
    setWebsearchSelected({});
    setWebsearchSelectedAll(false);
    setWebsearchParagraph('');
    setWebsearchItemNotes({});
    try {
      appendLog(setWebsearchLog, t('拆分查询...'));
      const splitRes = await callLLM({
        llmConfig: searchLlmConfig,
        messages: [
          { role: 'system', content: t('Split the query into 2-4 targeted search queries. Return JSON only: {"queries":["..."]}.') },
          { role: 'user', content: t('用户问题: {{query}}', { query }) }
        ]
      });
      if (!splitRes.ok || !splitRes.content) {
        throw new Error(splitRes.error || t('Query split failed'));
      }
      const jsonBlock = extractJsonBlock(splitRes.content);
      if (!jsonBlock) {
        throw new Error(t('无法解析拆分结果 JSON。'));
      }
      const parsed = safeJsonParse<{ queries?: string[] }>(jsonBlock);
      if (!parsed) {
        throw new Error(t('拆分结果 JSON 解析失败。'));
      }
      const queries = (parsed.queries || []).filter(Boolean).slice(0, 4);
      if (queries.length === 0) {
        throw new Error(t('拆分结果为空。'));
      }
      appendLog(setWebsearchLog, t('并行检索: {{queries}}', { queries: queries.join(' | ') }));
      const aggregated: WebsearchItem[] = [];
      await Promise.all(
        queries.map(async (q, idx) => {
          appendLog(setWebsearchLog, t('检索中: {{query}}', { query: q }));
          const res = await callLLM({
            llmConfig: searchLlmConfig,
            messages: [
              {
                role: 'system',
                content:
                  t('You are a search assistant. Use the provider search. Return JSON only: {"results":[{"title":"","summary":"","url":"","bibtex":""}]}.')
              },
              { role: 'user', content: t('帮我检索: {{query}}', { query: q }) }
            ]
          });
          if (!res.ok || !res.content) {
            appendLog(setWebsearchLog, t('检索失败: {{query}}', { query: q }));
            return;
          }
          const block = extractJsonBlock(res.content);
          if (!block) {
            appendLog(setWebsearchLog, t('结果解析失败: {{query}}', { query: q }));
            return;
          }
          const parsedRes = safeJsonParse<{ results?: { title?: string; summary?: string; url?: string; bibtex?: string }[] }>(block);
          if (!parsedRes) {
            appendLog(setWebsearchLog, t('结果 JSON 解析失败: {{query}}', { query: q }));
            return;
          }
          const results = parsedRes.results || [];
          results.forEach((item, i) => {
            const bibtex = item.bibtex || '';
            const citeKey = bibtex ? extractBibKey(bibtex.replace(/\\n/g, '\n')) : '';
            aggregated.push({
              id: `${idx}-${i}-${item.url || item.title || 'result'}`,
              title: item.title || t('Untitled'),
              summary: item.summary || '',
              url: item.url || '',
              bibtex,
              citeKey
            });
          });
          appendLog(setWebsearchLog, t('完成: {{query}} ({{count}})', { query: q, count: results.length }));
        })
      );
      const deduped: WebsearchItem[] = [];
      aggregated.forEach((item) => {
        if (!deduped.find((d) => d.url && item.url && d.url === item.url) && !deduped.find((d) => d.title === item.title)) {
          deduped.push(item);
        }
      });
      setWebsearchResults(deduped);
      appendLog(setWebsearchLog, t('聚合结果: {{count}} 条', { count: deduped.length }));
      if (deduped.length === 0) {
        setWebsearchBusy(false);
        return;
      }
      appendLog(setWebsearchLog, t('生成逐条总结...'));
      const summariesRes = await callLLM({
        llmConfig: searchLlmConfig,
        messages: [
          {
            role: 'system',
            content:
              t('你是论文检索助手。请为每篇论文写一条简短总结（1-2 句）。返回 JSON：{"summaries":[{"id":"","summary":""}]}.')
          },
          {
            role: 'user',
            content: JSON.stringify({
              papers: deduped.map((p) => ({
                id: p.id,
                title: p.title,
                summary: p.summary,
                url: p.url,
                citeKey: p.citeKey
              }))
            })
          }
        ]
      });
      if (summariesRes.ok && summariesRes.content) {
        const summaryBlock = extractJsonBlock(summariesRes.content);
        const parsedSummaries = summaryBlock
          ? safeJsonParse<{ summaries?: { id: string; summary: string }[] }>(summaryBlock)
          : null;
        if (parsedSummaries?.summaries?.length) {
          const notes: Record<string, string> = {};
          parsedSummaries.summaries.forEach((item) => {
            if (item.id && item.summary) {
              notes[item.id] = item.summary.trim();
            }
          });
          setWebsearchItemNotes(notes);
          appendLog(setWebsearchLog, t('逐条总结已生成。'));
        } else {
          appendLog(setWebsearchLog, t('逐条总结解析失败。'));
        }
      } else {
        appendLog(setWebsearchLog, t('逐条总结生成失败。'));
      }

      appendLog(setWebsearchLog, t('生成综合总结...'));
      const citeKeys = deduped.map((item) => item.citeKey).filter(Boolean);
      const paragraphRes = await callLLM({
        llmConfig: searchLlmConfig,
        messages: [
          {
            role: 'system',
            content:
              t('请根据提供论文生成 3-5 句中文综合总结（不要分条）。可以使用 \\cite{...} 引用。只返回总结文本。')
          },
          {
            role: 'user',
            content: JSON.stringify({ query, papers: deduped.map((p) => ({ title: p.title, summary: p.summary, url: p.url })), citeKeys })
          }
        ]
      });
      if (paragraphRes.ok && paragraphRes.content) {
        setWebsearchParagraph(paragraphRes.content.trim());
        appendLog(setWebsearchLog, t('段落已生成。'));
      } else {
        appendLog(setWebsearchLog, t('段落生成失败。'));
      }
    } catch (err) {
      appendLog(setWebsearchLog, t('错误: {{error}}', { error: String(err) }));
    } finally {
      setWebsearchBusy(false);
    }
  };

  const applyWebsearchInsert = async () => {
    if (!projectId) return;
    let targetBib = websearchTargetBib;
    if (!targetBib) {
      const created = await createBibFile();
      if (created) targetBib = created;
    }
    if (!targetBib) {
      setWebsearchLog((prev) => [...prev, t('缺少 Bib 文件。')]);
      return;
    }
    let content = await ensureFileContent(targetBib);
    const keys: string[] = [];
    const selectedItems = websearchResults.filter((item) => websearchSelected[item.id]);
    if (selectedItems.length === 0) {
      appendLog(setWebsearchLog, t('请选择至少一条结果。'));
      return;
    }
    const perItemLines = selectedItems.map((item) => {
      const note = websearchItemNotes[item.id] || item.summary || item.title;
      const cite = item.citeKey ? ` \\cite{${item.citeKey}}` : '';
      return `  \\item ${note}${cite}`;
    });
    selectedItems.forEach((item) => {
      if (!item.bibtex) return;
      const normalized = item.bibtex.replace(/\\n/g, '\n');
      const key = extractBibKey(normalized);
      if (!key) return;
      if (new RegExp(`@\\w+\\s*{\\s*${key}\\s*,`, 'i').test(content)) {
        keys.push(key);
        return;
      }
      keys.push(key);
      if (content && !content.endsWith('\n')) content += '\n';
      content += `${normalized.trim()}\n`;
    });
    await writeFileCompat(targetBib, content);
    setFiles((prev) => ({ ...prev, [targetBib]: content }));
    appendLog(setWebsearchLog, t('Bib 写入完成: {{path}}', { path: targetBib }));

    const targetFile = websearchTargetFile || mainFile || activePath;
    const perItemBlock = perItemLines.length
      ? `\\paragraph{${t('逐条总结')}}\n\\begin{itemize}\n${perItemLines.join('\n')}\n\\end{itemize}\n\n`
      : '';
    const finalBlock = websearchParagraph ? `\\paragraph{${t('综合总结')}}\n${websearchParagraph}\n` : '';
    const insertBlock = `${perItemBlock}${finalBlock}`.trim();
    if (!insertBlock) {
      appendLog(setWebsearchLog, t('没有可插入的总结内容。'));
      return;
    }
    if (targetFile && targetFile.toLowerCase().endsWith('.tex')) {
      const targetContent = await ensureFileContent(targetFile);
      const insertText = insertBlock ? `\n${insertBlock}\n` : '\n';
      const nextContent = `${targetContent}\n${insertText}`.replace(/\n{3,}/g, '\n\n');
      await writeFileCompat(targetFile, nextContent);
      setFiles((prev) => ({ ...prev, [targetFile]: nextContent }));
      if (activePath === targetFile) {
        setEditorValue(nextContent);
        if (!collabActiveRef.current) {
          setEditorDoc(nextContent);
        }
      }
      appendLog(setWebsearchLog, t('段落已插入 {{path}}', { path: targetFile }));
    } else if (activePath && activePath.toLowerCase().endsWith('.tex')) {
      if (insertBlock) {
        insertAtCursor(insertBlock, { block: true });
      }
      appendLog(setWebsearchLog, t('段落已插入光标位置。'));
    }
  };

  // Maziar: uploads land in the folder they were dropped on (or the selected folder for the picker),
  // the tree opens to show them, and failures are reported in the Files panel instead of failing silently.
  const handleUpload = async (fileList: FileList | File[] | null, basePath = '') => {
    if (!projectId || !fileList || fileList.length === 0) return;
    const files = Array.from(fileList);
    const where = basePath || t('project root');
    setUploadError('');
    setStatus(t('Uploading {{count}} file(s) to {{where}}…', { count: files.length, where }));
    try {
      const res = await uploadFiles(projectId, files, basePath);
      const saved = res.files || [];
      await refreshTree();
      setOpenFolders((prev) => {
        const next = { ...prev };
        saved.forEach((file) => {
          const parts = file.split('/').slice(0, -1);
          let current = '';
          parts.forEach((part) => {
            current = current ? `${current}/${part}` : part;
            next[current] = true;
          });
        });
        return next;
      });
      if (saved[0]) setSelectedPath(saved[0]);
      if (saved.length === 0) {
        setUploadError(t('Nothing was uploaded — the file names were not valid.'));
      } else {
        setStatus(saved.length === 1 ? t('Uploaded {{file}}', { file: saved[0] }) : t('Uploaded {{count}} files to {{where}}', { count: saved.length, where }));
      }
    } catch (err) {
      const message = (err as Error)?.message || String(err);
      setUploadError(t('Upload failed: {{error}}', { error: message }));
      setStatus(t('Upload failed: {{error}}', { error: message }));
      await refreshTree().catch(() => {});
    }
  };

  const handleVisionSubmit = async () => {
    if (!projectId) return;
    if (!visionFile) {
      setStatus(t('请先选择图片。'));
      return;
    }
    setVisionBusy(true);
    setVisionResult('');
    try {
      let extraPrompt = visionPrompt.trim();
      if (!extraPrompt) {
        if (visionMode === 'table') {
          extraPrompt = t('只输出表格的 LaTeX（tabular 或 table），不要包含文档结构。');
        } else if (visionMode === 'algorithm') {
          extraPrompt = t('只输出 algorithm/algorithmic 环境，不要包含文档结构。');
        } else if (visionMode === 'equation') {
          extraPrompt = t('只输出 equation 环境，不要包含文档结构。');
        }
      }
      const res = await visionToLatex({
        projectId,
        file: visionFile,
        mode: visionMode,
        prompt: extraPrompt,
        llmConfig: visionLlmConfig
      });
      if (!res.ok) {
        throw new Error(res.error || t('识别失败'));
      }
      setVisionResult(res.latex || '');
    } catch (err) {
      setStatus(t('识别失败: {{error}}', { error: String(err) }));
    } finally {
      setVisionBusy(false);
    }
  };

  const handleVisionInsert = () => {
    if (!visionResult) return;
    insertAtCursor(visionResult, { block: true });
  };

  const beginInlineCreate = (kind: 'new-file' | 'new-folder') => {
    if (!projectId) return;
    const selectedIsDir = selectedPath && tree.find((item) => item.path === selectedPath && item.type === 'dir');
    const parent = selectedIsDir ? selectedPath : getParentPath(selectedPath || activePath || '');
    setInlineEdit({ kind, parent, value: '' });
    if (parent) {
      setOpenFolders((prev) => ({ ...prev, [parent]: true }));
    }
  };

  const beginInlineRename = () => {
    if (!projectId) return;
    const target = selectedPath || activePath;
    if (!target) return;
    const name = target.split('/').pop() || target;
    setInlineEdit({ kind: 'rename', path: target, value: name });
  };

  const handleDeleteFile = async () => {
    if (!projectId) return;
    const target = selectedPath || activePath;
    if (!target) return;

    const confirmMessage = t('确定要删除 "{name}" 吗？此操作不可恢复。', { name: target.split('/').pop() || target });
    if (!window.confirm(confirmMessage)) return;

    try {
      const result = await deleteFile(projectId, target);
      if (result.ok) {
        // If deleted file was the active file, clear it
        if (target === activePath) {
          setActivePath('');
          setContent('');
        }
        // Refresh the file tree
        refreshTree();
      } else {
        alert(result.error || t('删除失败'));
      }
    } catch (err) {
      console.error('Delete error:', err);
      alert(t('删除失败') + ': ' + String(err));
    }
  };

  const confirmInlineEdit = async () => {
    if (!projectId || !inlineEdit) return;
    const value = inlineEdit.value.trim();
    if (!value) {
      setInlineEdit(null);
      return;
    }
    if (inlineEdit.kind === 'rename') {
      const from = inlineEdit.path;
      const parent = getParentPath(from);
      const to = parent ? `${parent}/${value}` : value;
      const entry = tree.find((item) => item.path === from);
      const fromName = from.split('/').pop() || '';
      await renamePath(projectId, from, to);
      if (activePath === from) {
        setActivePath(to);
        activePathRef.current = to;
      }
      setSelectedPath(to);
      if (parent && fromName && fileOrder[parent]) {
        const nextOrder = fileOrder[parent].map((name) => (name === fromName ? value : name));
        await persistFileOrder(parent, nextOrder);
      }
      if (entry?.type === 'dir' && fileOrder[from]) {
        await persistFileOrder(to, fileOrder[from]);
        await persistFileOrder(from, []);
      }
      await refreshTree();
      setInlineEdit(null);
      return;
    }

    const parent = inlineEdit.parent;
    const target = parent ? `${parent}/${value}` : value;
    if (inlineEdit.kind === 'new-folder') {
      await createFolderApi(projectId, target);
      if (fileOrder[parent]) {
        await persistFileOrder(parent, [...fileOrder[parent], value]);
      }
    } else {
      await writeFileCompat(target, '');
      if (isTextFile(target)) {
        await openFile(target);
      }
      if (fileOrder[parent]) {
        await persistFileOrder(parent, [...fileOrder[parent], value]);
      }
    }
    await refreshTree();
    setInlineEdit(null);
  };

  const cancelInlineEdit = () => setInlineEdit(null);

  const moveFileWithOrder = async (fromPath: string, folderPath: string, beforeName?: string) => {
    if (!projectId || !fromPath) return;
    const fileName = fromPath.split('/').pop();
    if (!fileName) return;
    const target = folderPath ? `${folderPath}/${fileName}` : fileName;
    if (target === fromPath) return;
    await renamePath(projectId, fromPath, target);
    if (activePath === fromPath) {
      setActivePath(target);
      activePathRef.current = target;
    }
    setSelectedPath(target);

    const fromParent = getParentPath(fromPath);
    if (fromParent && fileOrder[fromParent]) {
      await persistFileOrder(fromParent, fileOrder[fromParent].filter((name) => name !== fileName));
    }

    const targetNode = folderPath ? findTreeNode(treeRoot, folderPath) : treeRoot;
    const childNames = targetNode ? targetNode.children.map((child) => child.name) : [];
    const baseOrder = (fileOrder[folderPath] || []).filter((name) => childNames.includes(name) && name !== fileName);
    childNames.forEach((name) => {
      if (!baseOrder.includes(name) && name !== fileName) baseOrder.push(name);
    });
    const insertIndex = beforeName && baseOrder.includes(beforeName) ? baseOrder.indexOf(beforeName) : baseOrder.length;
    const nextOrder = [...baseOrder];
    nextOrder.splice(insertIndex, 0, fileName);
    await persistFileOrder(folderPath, nextOrder);

    await refreshTree();
  };

  const updateDragHint = useCallback((text: string, event: DragEvent) => {
    const host = fileTreeRef.current;
    if (!host) return;
    const rect = host.getBoundingClientRect();
    const x = Math.min(rect.width - 12, Math.max(8, event.clientX - rect.left));
    const y = Math.min(rect.height - 12, Math.max(8, event.clientY - rect.top));
    setDragHint({ text, x, y });
  }, []);

  const persistFileOrder = useCallback(
    async (folder: string, order: string[]) => {
      if (!projectId) return;
      setFileOrder((prev) => ({ ...prev, [folder]: order }));
      try {
        await updateFileOrder(projectId, folder, order);
      } catch (err) {
        setStatus(t('保存排序失败: {{error}}', { error: String(err) }));
      }
    },
    [projectId, t]
  );

  const filteredTreeItems = useMemo(() => {
    const term = fileFilter.trim().toLowerCase();
    if (!term) return tree;
    return tree.filter((item) => item.path.toLowerCase().includes(term));
  }, [tree, fileFilter]);

  const treeRoot = useMemo(() => buildTree(filteredTreeItems, fileOrder), [filteredTreeItems, fileOrder]);

  const reorderWithinFolder = useCallback(
    async (fromPath: string, targetPath: string) => {
      if (fileFilter.trim()) return false;
      const fromParent = getParentPath(fromPath);
      const targetParent = getParentPath(targetPath);
      if (fromParent !== targetParent) return false;
      const fromName = fromPath.split('/').pop();
      const targetName = targetPath.split('/').pop();
      if (!fromName || !targetName || fromName === targetName) return false;
      const node = findTreeNode(treeRoot, fromParent);
      if (!node) return false;
      const currentNames = node.children.map((child) => child.name);
      const baseOrder = (fileOrder[fromParent] || []).filter((name) => currentNames.includes(name));
      currentNames.forEach((name) => {
        if (!baseOrder.includes(name)) baseOrder.push(name);
      });
      const nextOrder = baseOrder.filter((name) => name !== fromName);
      const targetIndex = nextOrder.indexOf(targetName);
      const insertIndex = targetIndex === -1 ? nextOrder.length : targetIndex;
      nextOrder.splice(insertIndex, 0, fromName);
      await persistFileOrder(fromParent, nextOrder);
      return true;
    },
    [fileOrder, persistFileOrder, treeRoot]
  );

  const texFiles = useMemo(
    () => tree.filter((item) => item.type === 'file' && item.path.toLowerCase().endsWith('.tex')).map((item) => item.path),
    [tree]
  );

  // What the main-file menu offers: .tex files plus .txt/.ltx files that start a document (from the server).
  const mainCandidates = useMemo(() => {
    const all = [...texFiles];
    for (const f of mainFiles) if (!all.includes(f)) all.push(f);
    return all;
  }, [texFiles, mainFiles]);

  const bibFiles = useMemo(
    () => tree.filter((item) => item.type === 'file' && item.path.toLowerCase().endsWith('.bib')).map((item) => item.path),
    [tree]
  );

  const translateTargetOptions = useMemo(
    () => [
      { value: 'English', label: t('English') },
      { value: '中文', label: t('中文') },
      { value: '日本語', label: t('日本語') },
      { value: '한국어', label: t('한국어') },
      { value: 'Français', label: t('Français') },
      { value: 'Deutsch', label: t('Deutsch') },
      { value: 'Español', label: t('Español') }
    ],
    [t]
  );

  const outlineItems = useMemo(() => {
    if (!outlineText || !mainFile || !mainFile.toLowerCase().endsWith('.tex')) return [];
    return parseOutline(outlineText);
  }, [outlineText, mainFile]);

  useEffect(() => {
    if (!mainFile) {
      setOutlineText('');
      return;
    }
    if (activePath === mainFile) {
      setOutlineText(editorValue);
      return;
    }
    let cancelled = false;
    const load = async () => {
      try {
        const content = await ensureFileContent(mainFile);
        if (!cancelled) setOutlineText(content);
      } catch {
        if (!cancelled) setOutlineText('');
      }
    };
    load();
    return () => {
      cancelled = true;
    };
  }, [activePath, editorValue, ensureFileContent, mainFile]);

  useEffect(() => {
    if (!visionFile) {
      setVisionPreviewUrl('');
      return;
    }
    const url = URL.createObjectURL(visionFile);
    setVisionPreviewUrl(url);
    return () => {
      URL.revokeObjectURL(url);
    };
  }, [visionFile]);

  useEffect(() => {
    if (mainCandidates.length === 0) return;
    // The project's own choice wins (shared by everyone working on it).
    if (projectMainFile && mainCandidates.includes(projectMainFile)) {
      if (mainFile !== projectMainFile) setMainFile(projectMainFile);
      else rememberRef.current.write('mainFile', mainFile);
      return;
    }
    if (!mainCandidates.includes(mainFile)) {
      const saved = rememberRef.current.read('mainFile');
      const preferred = (typeof saved === 'string' && mainCandidates.includes(saved) ? saved : '')
        || mainCandidates.find((path) => path.endsWith('main.tex')) || mainCandidates[0];
      setMainFile(preferred);
    } else {
      rememberRef.current.write('mainFile', mainFile);
    }
  }, [mainCandidates, mainFile, projectMainFile]);

  useEffect(() => {
    if (citeTargetFile) return;
    if (mainFile) {
      setCiteTargetFile(mainFile);
    } else if (texFiles.length > 0) {
      setCiteTargetFile(texFiles[0]);
    }
  }, [citeTargetFile, mainFile, texFiles]);

  useEffect(() => {
    if (websearchTargetFile) return;
    if (mainFile) {
      setWebsearchTargetFile(mainFile);
    } else if (texFiles.length > 0) {
      setWebsearchTargetFile(texFiles[0]);
    }
  }, [websearchTargetFile, mainFile, texFiles]);

  useEffect(() => {
    if (websearchTargetBib) return;
    if (bibFiles.length > 0) {
      setWebsearchTargetBib(bibFiles[0]);
    }
  }, [bibFiles, websearchTargetBib]);

  useEffect(() => {
    if (!bibTarget && bibFiles.length > 0) {
      setBibTarget(bibFiles[0]);
    }
  }, [bibFiles, bibTarget]);

  const setAllFolders = useCallback(
    (open: boolean) => {
      const next: Record<string, boolean> = {};
      const walk = (nodes: TreeNode[]) => {
        nodes.forEach((node) => {
          if (node.type === 'dir') {
            next[node.path] = open;
            walk(node.children);
          }
        });
      };
      walk(treeRoot.children);
      setOpenFolders(next);
    },
    [treeRoot]
  );

  const toggleFolder = (path: string) => {
    setOpenFolders((prev) => ({ ...prev, [path]: !prev[path] }));
    setSelectedPath(path);
  };

  const handleFileSelect = async (path: string) => {
    setSelectedPath(path);
    if (isFigureFile(path)) {
      setSelectedFigure(path);
      setRightView('figures');
      return;
    }
    if (!isTextFile(path)) {
      setStatus(t('该文件为二进制文件，暂不支持直接编辑。'));
      return;
    }
    await openFile(path);
  };

  const inlineInputRow = (depth: number) => {
    if (!inlineEdit) return null;
    const paddingLeft = 8 + depth * 14;
    const isFolder = inlineEdit.kind === 'new-folder';
    return (
      <div className="tree-node">
        <div className={`tree-row ${isFolder ? 'folder' : 'file'} inline`} style={{ paddingLeft: paddingLeft + 14 }}>
          <input
            className="inline-input"
            autoFocus
            value={inlineEdit.value}
            onChange={(event) => setInlineEdit({ ...inlineEdit, value: event.target.value })}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                confirmInlineEdit().catch((err) => setStatus(t('操作失败: {{error}}', { error: String(err) })));
              }
              if (event.key === 'Escape') {
                event.preventDefault();
                cancelInlineEdit();
              }
            }}
            onBlur={() => cancelInlineEdit()}
            placeholder={isFolder ? t('新建文件夹') : t('新建文件')}
          />
        </div>
      </div>
    );
  };

  const jumpToError = async (error: { file?: string; line?: number }) => {
    await goToSourceRef.current(error.file, error.line);
  };

  const renderTree = (nodes: TreeNode[], depth = 0) =>
    nodes.map((node) => {
      const isDir = node.type === 'dir';
      const isOpen = openFolders[node.path] ?? depth < 1;
      const isActive = activePath === node.path;
      const isSelected = selectedPath === node.path;
      const isDragOver = dragOverPath === node.path;
      const paddingLeft = 8 + depth * 14;

      if (isDir) {
        return (
          <div key={node.path} className="tree-node">
            <button
              className={`tree-row folder ${isOpen ? 'open' : ''} ${isSelected ? 'selected' : ''} ${isDragOver ? 'drag-over' : ''}`}
              style={{ paddingLeft }}
              onClick={() => toggleFolder(node.path)}
              onDragOver={(event) => {
                event.preventDefault();
                setDragOverPath(node.path);
                setDragOverKind('folder');
                if (draggingPath) {
                  updateDragHint(t('移动到 {{name}} 文件夹', { name: node.name }), event);
                }
              }}
              onDragLeave={() => {
                setDragOverPath('');
                setDragOverKind('');
                setDragHint(null);
              }}
              onDrop={(event) => {
                event.preventDefault();
                event.stopPropagation();
                if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
                  handleUpload(event.dataTransfer.files, node.path).catch((err) => setStatus(t('上传失败: {{error}}', { error: String(err) })));
                  setDragOverPath('');
                  setDragOverKind('');
                  setDragHint(null);
                  return;
                }
                const from = event.dataTransfer.getData('text/plain');
                setDragOverPath('');
                setDragOverKind('');
                setDragHint(null);
                if (from) {
                  if (fileFilter.trim()) {
                    setStatus(t('搜索过滤中无法拖拽移动。'));
                    return;
                  }
                  moveFileWithOrder(from, node.path).catch((err) => setStatus(t('移动失败: {{error}}', { error: String(err) })));
                }
              }}
            >
              <span className="tree-caret">{isOpen ? '▾' : '▸'}</span>
              <span className="tree-icon folder" />
              {inlineEdit?.kind === 'rename' && inlineEdit.path === node.path ? (
                <input
                  className="inline-input"
                  autoFocus
                  value={inlineEdit.value}
                  onChange={(event) => setInlineEdit({ ...inlineEdit, value: event.target.value })}
                  onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault();
                    confirmInlineEdit().catch((err) => setStatus(t('操作失败: {{error}}', { error: String(err) })));
                  }
                    if (event.key === 'Escape') {
                      event.preventDefault();
                      cancelInlineEdit();
                    }
                  }}
                  onBlur={() => cancelInlineEdit()}
                />
              ) : (
                <span className="tree-label">{node.name}</span>
              )}
            </button>
            {isOpen && (
              <div className="tree-children">
                {renderTree(node.children, depth + 1)}
                {inlineEdit && inlineEdit.kind !== 'rename' && inlineEdit.parent === node.path && inlineInputRow(depth + 1)}
              </div>
            )}
          </div>
        );
      }

      return (
        <button
          key={node.path}
          className={`tree-row file ${isActive ? 'active' : ''} ${isSelected ? 'selected' : ''} ${isDragOver ? (dragOverKind === 'file' ? 'drag-over-file' : 'drag-over') : ''} ${draggingPath === node.path ? 'dragging' : ''}`}
          style={{ paddingLeft: paddingLeft + 14 }}
          onClick={() => handleFileSelect(node.path)}
          draggable
          onDragStart={(event) => {
            event.dataTransfer.setData('text/plain', node.path);
            setDraggingPath(node.path);
          }}
          onDragEnd={() => {
            setDraggingPath('');
            setDragHint(null);
          }}
          onDragOver={(event) => {
            event.preventDefault();
            setDragOverPath(node.path);
            setDragOverKind('file');
            if (draggingPath) {
              const targetParent = getParentPath(node.path);
              const fromParent = getParentPath(draggingPath);
              const parentLabel = targetParent || t('根目录');
              const hint =
                fromParent === targetParent
                  ? t('插入到 {{name}} 前', { name: node.name })
                  : t('移动到 {{parent}} 并插入到 {{name}} 前', { parent: parentLabel, name: node.name });
              updateDragHint(hint, event);
            }
          }}
          onDragLeave={() => {
            setDragOverPath('');
            setDragOverKind('');
            setDragHint(null);
          }}
          onDrop={(event) => {
            event.preventDefault();
            event.stopPropagation();
            setDragOverPath('');
            setDragOverKind('');
            setDragHint(null);
            if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
              // Files from Finder dropped on a file go into that file's folder.
              handleUpload(event.dataTransfer.files, getParentPath(node.path)).catch(() => {});
              return;
            }
            const from = event.dataTransfer.getData('text/plain');
            if (!from) return;
            if (fileFilter.trim()) {
              setStatus(t('搜索过滤中无法拖拽排序。'));
              return;
            }
            const targetParent = getParentPath(node.path);
            const fromParent = getParentPath(from);
            if (fromParent === targetParent) {
              reorderWithinFolder(from, node.path).catch((err) => setStatus(t('排序失败: {{error}}', { error: String(err) })));
              return;
            }
            moveFileWithOrder(from, targetParent, node.name).catch((err) => setStatus(t('移动失败: {{error}}', { error: String(err) })));
          }}
        >
          <span className={`tree-icon file ext-${getFileTypeLabel(node.path).toLowerCase()}`}>{getFileTypeLabel(node.path)}</span>
          {inlineEdit?.kind === 'rename' && inlineEdit.path === node.path ? (
            <input
              className="inline-input"
              autoFocus
              value={inlineEdit.value}
              onChange={(event) => setInlineEdit({ ...inlineEdit, value: event.target.value })}
              onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault();
                confirmInlineEdit().catch((err) => setStatus(t('操作失败: {{error}}', { error: String(err) })));
              }
                if (event.key === 'Escape') {
                  event.preventDefault();
                  cancelInlineEdit();
                }
              }}
              onBlur={() => cancelInlineEdit()}
            />
          ) : (
            <span className="tree-label">{node.name}</span>
          )}
          {isFigureFile(node.path) && <span className="tree-tag">FIG</span>}
          {node.path.endsWith('.bib') && <span className="tree-tag">BIB</span>}
        </button>
      );
    });

  const compile = async () => {
    if (!projectId) return;
    setIsCompiling(true);
    setStatus(t('编译中...'));
    try {
      const { files: serverFiles } = await getAllFiles(projectId);
      const fileMap: Record<string, string | Uint8Array> = {};
      for (const file of serverFiles) {
        if (file.encoding === 'base64') {
          const binary = Uint8Array.from(atob(file.content), (c) => c.charCodeAt(0));
          fileMap[file.path] = binary;
        } else {
          fileMap[file.path] = files[file.path] ?? file.content;
        }
      }
      if (activePath) {
        fileMap[activePath] = editorValue;
      }
      if (!fileMap[mainFile]) {
        throw new Error(t('主文件不存在: {{file}}', { file: mainFile }));
      }
      const res = await compileProject({ projectId, mainFile, engine: compileEngine });
      // A newer compile of this project took over (e.g. Compile clicked again): that one reports back.
      if (res.replaced) return;
      setMissingFiles(res.missing || []);
      if (!res.ok && res.missing?.length) {
        setCompileLog(`${res.error}\n\n${res.log || ''}`.trim());
        setCompileState('failed');
        setStatus(res.error || t('后端编译失败'));
        return;
      }
      if (res.timedOut) {
        // LaTeX got stuck in a loop and was stopped: keep its log so the Problems panel shows the first errors.
        setCompileLog(`${res.error}\n\n${res.log || ''}`.trim());
        setCompileState('failed');
        setStatus(t('Compile stopped: LaTeX seemed stuck in a loop — see the first errors in Problems.'));
        return;
      }
      if (!res.ok || !res.pdf) {
        const detail = [res.error, res.log].filter(Boolean).join('\n');
        throw new Error(detail || t('后端编译失败'));
      }
      const result: CompileOutcome = {
        pdf: Uint8Array.from(atob(res.pdf), (c) => c.charCodeAt(0)),
        log: res.log || '',
        status: res.status ?? 0,
        engine: compileEngine
      };

      const meta = [
        t('Engine: {{engine}}', { engine: compileEngine }),
        t('Main file: {{file}}', { file: mainFile })
      ].filter(Boolean).join('\n');
      setEngineName(compileEngine);
      setCompileLog(`${meta}\n\n${result.log || t('No log')}`.trim());

      const blob = new Blob([result.pdf], { type: 'application/pdf' });
      const nextUrl = URL.createObjectURL(blob);
      if (pdfUrl) {
        URL.revokeObjectURL(pdfUrl);
      }
      setPdfUrl(nextUrl);
      setRightView('pdf');
      setCompileState('ok');
      setStatus(t('编译完成 ({{engine}})', { engine: result.engine }));
    } catch (err) {
      console.error('Compilation error:', err);
      setCompileLog(`${t('编译错误: {{error}}', { error: String(err) })}\n${(err as Error).stack || ''}`);
      setCompileState('failed');
      setStatus(t('编译失败: {{error}}', { error: String(err) }));
    } finally {
      setIsCompiling(false);
    }
  };

  // Maziar: compile once automatically when a project is opened, so the PDF is there right away
  // (and opens at the remembered page).
  const compileRef = useRef(compile);
  compileRef.current = compile;
  const autoCompiledRef = useRef('');
  // Waits until the open file has loaded: compile() sends the editor's current text for it, and an
  // empty editor at that moment would look like a missing main file.
  const activeFileLoaded = Boolean(activePath) && Object.prototype.hasOwnProperty.call(files, activePath)
    && editorValue === files[activePath];
  useEffect(() => {
    if (!projectId || !mainFile || !mainCandidates.includes(mainFile) || !activeFileLoaded) return;
    if (autoCompiledRef.current === projectId) return;
    autoCompiledRef.current = projectId;
    compileRef.current().catch(() => {});
  }, [projectId, mainFile, mainCandidates, activeFileLoaded]);

  const selectionText = useMemo(() => {
    const [start, end] = selectionRange;
    if (start === end) return '';
    return editorValue.slice(start, end);
  }, [selectionRange, editorValue]);

  const compileErrors = useMemo(() => parseCompileErrors(compileLog), [compileLog]);

  // ---------- Maziar: diagnostics, SyncTeX, spelling, upload target ----------

  const projectFileSet = useMemo(() => new Set(tree.filter((item) => item.type === 'file').map((item) => item.path)), [tree]);
  const diagnostics = useMemo(() => parseLatexLog(compileLog, projectFileSet), [compileLog, projectFileSet]);
  const diagnosticCounts = useMemo(() => ({
    error: diagnostics.filter((d) => d.severity === 'error').length,
    warning: diagnostics.filter((d) => d.severity === 'warning').length,
    badbox: diagnostics.filter((d) => d.severity === 'badbox').length
  }), [diagnostics]);

  useEffect(() => {
    if (diagnosticCounts.error > 0) setDiagnosticsOpen(true);
  }, [diagnosticCounts.error]);

  useEffect(() => {
    const view = cmViewRef.current;
    if (view) showDiagnostics(view, diagnostics, activePath);
  }, [diagnostics, activePath, docTick]);

  const uploadFolder = useMemo(() => {
    if (!selectedPath) return '';
    const isDir = tree.some((item) => item.path === selectedPath && item.type === 'dir');
    return isDir ? selectedPath : getParentPath(selectedPath);
  }, [selectedPath, tree]);

  const goToSource = useCallback(async (file: string | undefined, line?: number, column = 0) => {
    const target = file && projectFileSet.has(file) ? file : file ? '' : activePathRef.current;
    if (!target) {
      setStatus(t('{{file}} is not a file in this project.', { file }));
      return;
    }
    if (!isTextFile(target)) return;
    if (target !== activePathRef.current) {
      try {
        await openFileRef.current(target);
      } catch (err) {
        setStatus(String(err));
        return;
      }
    }
    const view = cmViewRef.current;
    if (view && line) revealLine(view, line, column);
  }, [projectFileSet, t]);

  const forwardSync = useCallback(async () => {
    const view = cmViewRef.current;
    const file = activePathRef.current;
    if (!view || !file || !projectId) return;
    if (!pdfUrl) {
      setStatus(t('Compile the project first to jump to the PDF.'));
      return;
    }
    // The start of the selected text (or the cursor).
    const head = view.state.selection.main.from;
    const line = view.state.doc.lineAt(head);
    try {
      const { boxes } = await synctexForward(projectId, file, line.number, 0);
      if (pdfPoppedRef.current && pdfWinRef.current && !pdfWinRef.current.closed) {
        pdfWinRef.current.postMessage({ type: 'nm-pdf:reveal', box: boxes[0] } satisfies PdfWindowMessage, window.location.origin);
        return;
      }
      setRightView('pdf');
      window.requestAnimationFrame(() => pdfViewerRef.current?.revealBox(boxes[0]));
    } catch (err) {
      setStatus(t('Couldn’t find this line in the PDF: {{error}}', { error: (err as Error).message }));
    }
  }, [pdfUrl, projectId, t]);
  goToSourceRef.current = goToSource;
  forwardSyncRef.current = () => {
    forwardSync().catch(() => {});
  };

  const reverseSync = useCallback(async (page: number, x: number, y: number) => {
    if (!projectId) return;
    try {
      const res = await synctexReverse(projectId, page, x, y);
      await goToSource(res.file, res.line);
    } catch (err) {
      setStatus(t('Couldn’t find the source for that spot: {{error}}', { error: (err as Error).message }));
    }
  }, [goToSource, projectId, t]);

  useEffect(() => {
    let cancelled = false;
    spellStatus()
      .then(async (res) => {
        if (cancelled || !res.available) return;
        setSpellAvailable(true);
        const { languages } = await spellLanguages();
        if (!cancelled) setSpellLanguageList(languages);
      })
      .catch(() => setSpellAvailable(false));
    return () => {
      cancelled = true;
    };
  }, []);

  // Maziar: "←" — find the selected (or last clicked) spot of the PDF in the LaTeX source.
  const reverseSyncFromPdf = useCallback(() => {
    if (!pdfUrl) {
      setStatus(t('Compile the project first to jump between the PDF and the source.'));
      return;
    }
    if (pdfPoppedRef.current && pdfWinRef.current && !pdfWinRef.current.closed) {
      pdfWinRef.current.postMessage({ type: 'nm-pdf:reverse-request' } satisfies PdfWindowMessage, window.location.origin);
      return;
    }
    const point = pdfViewerRef.current?.sourcePoint();
    if (!point) return;
    reverseSync(point.page, point.x, point.y).catch(() => {});
  }, [pdfUrl, reverseSync, t]);

  // ---------- PDF preview in a separate window ----------
  const postToPdfWindow = useCallback((msg: PdfWindowMessage, transfer: Transferable[] = []) => {
    const win = pdfWinRef.current;
    if (!win || win.closed) return false;
    win.postMessage(msg, window.location.origin, transfer);
    return true;
  }, []);
  const sendPdfToWindowRef = useRef<() => Promise<void>>(async () => {});
  sendPdfToWindowRef.current = async () => {
    if (!pdfUrl) {
      postToPdfWindow({ type: 'nm-pdf:pdf', bytes: null, title: projectName });
      return;
    }
    const bytes = await (await fetch(pdfUrl)).arrayBuffer();
    postToPdfWindow({ type: 'nm-pdf:pdf', bytes, title: projectName }, [bytes]);
  };
  const reverseSyncRef = useRef(reverseSync);
  reverseSyncRef.current = reverseSync;

  const popOutPdf = useCallback(() => {
    if (!projectId) return;
    const win = window.open(`/pdf-window/${projectId}`, `numenor-pdf-${projectId}`, 'width=920,height=1100');
    if (!win) {
      setStatus(t('The PDF window was blocked — allow pop-ups for Numenor and try again.'));
      return;
    }
    pdfWinRef.current = win;
    setPdfPopped(true);
  }, [projectId, t]);

  const dockPdf = useCallback(() => {
    const win = pdfWinRef.current;
    pdfWinRef.current = null;
    setPdfPopped(false);
    try { if (win && !win.closed) win.close(); } catch { /* gone */ }
  }, []);

  useEffect(() => {
    if (pdfPopped) sendPdfToWindowRef.current().catch(() => {});
  }, [pdfPopped, pdfUrl]);
  useEffect(() => {
    if (pdfPopped) postToPdfWindow({ type: 'nm-pdf:status', compiling: isCompiling, title: projectName });
  }, [isCompiling, pdfPopped, projectName, postToPdfWindow]);

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.origin !== window.location.origin || !pdfWinRef.current || event.source !== pdfWinRef.current) return;
      const msg = event.data as PdfWindowMessage;
      if (!msg || typeof msg !== 'object') return;
      if (msg.type === 'nm-pdf:hello') {
        sendPdfToWindowRef.current().catch(() => {});
        postToPdfWindow({ type: 'nm-pdf:status', compiling: false, title: projectName });
      } else if (msg.type === 'nm-pdf:reverse') {
        reverseSyncRef.current(msg.page, msg.x, msg.y).catch(() => {});
        window.focus();
      } else if (msg.type === 'nm-pdf:compile') {
        compileRef.current().catch(() => {});
      } else if (msg.type === 'nm-pdf:dock' || msg.type === 'nm-pdf:closed') {
        pdfWinRef.current = null;
        setPdfPopped(false);
      }
    };
    window.addEventListener('message', onMessage);
    const watch = window.setInterval(() => {
      if (pdfPoppedRef.current && (!pdfWinRef.current || pdfWinRef.current.closed)) {
        pdfWinRef.current = null;
        setPdfPopped(false);
      }
    }, 1500);
    const onUnload = () => postToPdfWindow({ type: 'nm-pdf:editor-closed' });
    window.addEventListener('beforeunload', onUnload);
    return () => {
      window.removeEventListener('message', onMessage);
      window.removeEventListener('beforeunload', onUnload);
      window.clearInterval(watch);
      onUnload();
    };
  }, [postToPdfWindow, projectName]);

  // ---------- files changed outside Numenor (Google Drive from another computer, another editor…) ----------
  const statRef = useRef<Map<string, string> | null>(null);
  const isDirtyRef = useRef(false);
  isDirtyRef.current = isDirty;
  /** Puts new text in the editor, changing only the part that differs so the cursor stays where it was. */
  const replaceEditorText = useCallback((next: string) => {
    const view = cmViewRef.current;
    if (!view) return;
    const cur = view.state.doc.toString();
    if (cur === next) return;
    let start = 0;
    while (start < cur.length && start < next.length && cur[start] === next[start]) start += 1;
    let endCur = cur.length;
    let endNext = next.length;
    while (endCur > start && endNext > start && cur[endCur - 1] === next[endNext - 1]) { endCur -= 1; endNext -= 1; }
    suppressDirtyRef.current = true;
    view.dispatch({ changes: { from: start, to: endCur, insert: next.slice(start, endNext) } });
  }, []);
  const loadExternalVersion = useCallback((path: string, content: string) => {
    setFiles((prev) => ({ ...prev, [path]: content }));
    if (path === activePathRef.current) {
      replaceEditorText(content);
      setEditorValue(content);
      setIsDirty(false);
    }
  }, [replaceEditorText]);
  useEffect(() => {
    if (!projectId) return;
    statRef.current = null;
    let stop = false;
    let busy = false;
    const tick = async () => {
      if (busy || stop || document.visibilityState !== 'visible') return;
      busy = true;
      try {
        const res = await projectStat(projectId);
        const next = new Map(res.files.map(([p, m, size]) => [p, `${m}:${size}`]));
        const prev = statRef.current;
        statRef.current = next;
        if (!prev || stop) return;
        const added = [...next.keys()].some((p) => !prev.has(p));
        const removed = [...prev.keys()].some((p) => !next.has(p));
        if (added || removed) refreshTreeRef.current().catch(() => {});
        for (const [p, sig] of next) {
          const before = prev.get(p);
          if (!before || before === sig || !isTextPath(p)) continue;
          const isActive = p === activePathRef.current;
          if (!isActive && !Object.prototype.hasOwnProperty.call(filesRef.current, p)) continue;
          const { content } = await getFile(projectId, p);
          if (stop) return;
          if (isActive) {
            if (collabActiveRef.current) continue; // live editing keeps everyone's text in step itself
            const shown = cmViewRef.current?.state.doc.toString() ?? '';
            if (content === shown) { setFiles((f) => ({ ...f, [p]: content })); continue; } // our own save
            if (isDirtyRef.current) {
              setExternalChange({ path: p, content });
            } else {
              loadExternalVersion(p, content);
              setStatus(t('{{file}} was updated outside Numenor (e.g. from another computer) — showing the new version.', { file: p }));
            }
          } else if (filesRef.current[p] !== content) {
            setFiles((f) => ({ ...f, [p]: content }));
          }
        }
      } catch {
        /* offline / restarting: try again next time */
      } finally {
        busy = false;
      }
    };
    const timer = window.setInterval(() => { tick().catch(() => {}); }, 4000);
    const onVisible = () => { if (document.visibilityState === 'visible') tick().catch(() => {}); };
    document.addEventListener('visibilitychange', onVisible);
    tick().catch(() => {});
    return () => {
      stop = true;
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  // ---------- Cmd/Ctrl + F: search the source or the PDF, whichever was clicked last ----------
  const runPdfFind = useCallback(async (query: string, step: 0 | 1 | -1) => {
    setPdfFind((f) => ({ ...f, query, busy: true }));
    const res = await pdfViewerRef.current?.find(query, step).catch(() => null);
    setPdfFind((f) => (f.query === query ? { ...f, index: res?.index || 0, total: res?.total || 0, busy: false } : f));
  }, []);
  const closePdfFind = useCallback(() => {
    pdfViewerRef.current?.clearFind();
    setPdfFind((f) => ({ ...f, open: false, index: 0, total: 0 }));
  }, []);
  useEffect(() => {
    const onPointer = (e: PointerEvent) => {
      const target = e.target as HTMLElement | null;
      if (!target) return;
      if (target.closest('.pdf-preview, .nm-pdf-find')) lastPaneRef.current = 'pdf';
      else if (editorAreaRef.current?.contains(target)) lastPaneRef.current = 'editor';
    };
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey || e.key.toLowerCase() !== 'f') return;
      if (lastPaneRef.current === 'pdf' && pdfUrl && rightView === 'pdf') {
        e.preventDefault();
        e.stopPropagation();
        const picked = pdfViewerRef.current?.selectedText() || '';
        setPdfFind((f) => ({ ...f, open: true, query: picked || f.query }));
        window.setTimeout(() => {
          pdfFindInputRef.current?.focus();
          pdfFindInputRef.current?.select();
        }, 0);
        if (picked) runPdfFind(picked, 0).catch(() => {});
        return;
      }
      const view = cmViewRef.current;
      if (!view) return;
      e.preventDefault();
      e.stopPropagation();
      view.focus();
      openSearchPanel(view);
    };
    document.addEventListener('pointerdown', onPointer, true);
    window.addEventListener('keydown', onKey, true);
    return () => {
      document.removeEventListener('pointerdown', onPointer, true);
      window.removeEventListener('keydown', onKey, true);
    };
  }, [pdfUrl, rightView, runPdfFind]);
  // A new PDF (after compiling): search it again so the highlights match the new pages.
  useEffect(() => {
    if (!pdfFind.open || !pdfFind.query.trim() || !pdfUrl) return;
    const timer = window.setTimeout(() => runPdfFind(pdfFind.query, 0).catch(() => {}), 400);
    return () => window.clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pdfUrl]);

  // ---------- who else has this project open (top bar), every few seconds ----------
  const [people, setPeople] = useState<PresencePerson[]>([]);
  const [presenceYou, setPresenceYou] = useState('');
  useEffect(() => {
    if (!projectId) return;
    let stop = false;
    const tick = () => presence(projectId, activePathRef.current || '')
      .then((res) => {
        if (stop) return;
        setPresenceYou(res.you);
        setPeople((prev) => (JSON.stringify(prev.map((p) => [p.key, p.file, p.role])) === JSON.stringify(res.people.map((p) => [p.key, p.file, p.role])) ? prev : res.people));
      })
      .catch(() => {});
    tick();
    const timer = window.setInterval(tick, 5000);
    const leave = () => { presence(projectId, '', true).catch(() => {}); };
    window.addEventListener('pagehide', leave);
    return () => {
      stop = true;
      window.clearInterval(timer);
      window.removeEventListener('pagehide', leave);
      leave();
    };
  }, [projectId]);
  // Report a file change right away rather than at the next tick.
  useEffect(() => {
    if (projectId && activePath) presence(projectId, activePath).catch(() => {});
  }, [projectId, activePath]);
  const others = useMemo(() => people.filter((p) => p.key !== presenceYou), [people, presenceYou]);

  /** Scrolls to someone's cursor in the open file and makes it flash. False if it isn't in this file. */
  const jumpToPerson = useCallback((key: string) => {
    const view = cmViewRef.current;
    const cd = collabDocRef.current;
    if (!view || !cd) return false;
    let head: number | null = null;
    cd.awareness.getStates().forEach((st, id) => {
      if (id === cd.awareness.clientID || head !== null) return;
      const state = st as { user?: { key?: string }; cursor?: { head?: unknown } | null };
      if (state.user?.key !== key || !state.cursor?.head) return;
      const abs = Y.createAbsolutePositionFromRelativePosition(Y.createRelativePositionFromJSON(state.cursor.head), cd.doc);
      if (abs && abs.type === cd.text) head = abs.index;
    });
    if (head === null) return false;
    const pos = Math.min(head, view.state.doc.length);
    view.dispatch({ effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
    // Flash their caret (carets are drawn in the person's colour).
    const probe = document.createElement('span');
    probe.style.color = colorForKey(key);
    const want = probe.style.color;
    window.setTimeout(() => {
      view.dom.querySelectorAll<HTMLElement>('.cm-ySelectionCaret').forEach((el) => {
        if (el.style.borderColor !== want && el.style.backgroundColor !== want) return;
        el.style.color = want;
        el.classList.remove('nm-caret-flash');
        void el.offsetWidth;
        el.classList.add('nm-caret-flash');
        window.setTimeout(() => el.classList.remove('nm-caret-flash'), 2600);
      });
    }, 120);
    return true;
  }, []);

  const followTimerRef = useRef<number | null>(null);
  /** Click on someone in the top bar: open the file they're in and show where their cursor is. */
  const followPerson = async (p: PresencePerson) => {
    if (followTimerRef.current) window.clearInterval(followTimerRef.current);
    if (p.file && p.file !== activePathRef.current) {
      if (!isTextPath(p.file)) {
        setStatus(t('{{name}} is looking at {{file}}', { name: p.name, file: p.file }));
        await handleFileSelect(p.file);
        return;
      }
      await handleFileSelect(p.file);
    }
    if (jumpToPerson(p.key)) {
      setStatus(t('{{name}}’s cursor', { name: p.name }));
      return;
    }
    // The file (and their cursor) may still be loading: keep looking for a few seconds.
    const until = Date.now() + 6000;
    followTimerRef.current = window.setInterval(() => {
      if (jumpToPerson(p.key)) {
        window.clearInterval(followTimerRef.current!);
        followTimerRef.current = null;
        setStatus(t('{{name}}’s cursor', { name: p.name }));
      } else if (Date.now() > until) {
        window.clearInterval(followTimerRef.current!);
        followTimerRef.current = null;
        setStatus(p.file
          ? t('{{name}} is in {{file}} but hasn’t put the cursor in the text yet.', { name: p.name, file: p.file })
          : t('{{name}} hasn’t opened a file yet.', { name: p.name }));
      }
    }, 300);
  };
  useEffect(() => () => { if (followTimerRef.current) window.clearInterval(followTimerRef.current); }, []);
  // Someone else is in: join live editing so both see each other's cursor and changes as they type.
  useEffect(() => {
    if (others.length > 0 && !collabEnabled && activePath && isTextPath(activePath)) setCollabEnabled(true);
  }, [others.length, collabEnabled, activePath]);

  // ---------- who am I (owner, or invited with edit/view rights) ----------
  const [accessRemoved, setAccessRemoved] = useState(false);
  useEffect(() => {
    whoAmI().then(setMe).catch(() => setMe(null));
    if (!isGuest) return;
    // An invited person: notice when the owner removes access or changes it (view ↔ edit).
    const timer = window.setInterval(() => {
      whoAmI()
        .then((next) => setMe((prev) => (prev && prev.role === next.role ? prev : next)))
        .catch((err) => {
          if (/invite link/i.test(String((err as Error).message))) setAccessRemoved(true);
        });
    }, 20000);
    return () => window.clearInterval(timer);
  }, [isGuest]);
  useEffect(() => {
    const view = cmViewRef.current;
    if (!view) return;
    view.dispatch({ effects: readOnlyCompartment.reconfigure(viewOnly ? [EditorState.readOnly.of(true), EditorView.editable.of(false)] : []) });
  }, [viewOnly, readOnlyCompartment]);

  // Maziar: editor zoom — Cmd/Ctrl + scroll or pinch over the editor, Cmd/Ctrl + = / - / 0, or the buttons.
  editorZoomRef.current = (delta) => {
    setEditorFontSize((size) => (delta === 'reset' ? 11 : Math.min(32, Math.max(8, size + delta))));
  };
  useEffect(() => {
    try {
      localStorage.setItem('maziar.editor.fontSize', String(editorFontSize));
    } catch {
      /* ignore */
    }
  }, [editorFontSize]);
  useEffect(() => {
    const area = editorAreaRef.current;
    if (!area) return;
    let pending = 0;
    const onWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      // Trackpad pinches arrive as many small deltas, a mouse notch as one big one: step per ~40px.
      pending += event.deltaMode === 1 ? event.deltaY * 33 : event.deltaY;
      while (Math.abs(pending) >= 40) {
        editorZoomRef.current(pending < 0 ? 1 : -1);
        pending -= Math.sign(pending) * 40;
      }
    };
    let gestureBase = 0;
    let gestureSize = 11;
    const onGestureStart = (event: Event) => {
      event.preventDefault();
      gestureBase = 1;
      setEditorFontSize((size) => {
        gestureSize = size;
        return size;
      });
    };
    const onGestureChange = (event: Event) => {
      event.preventDefault();
      if (!gestureBase) return;
      const scale = (event as Event & { scale: number }).scale;
      setEditorFontSize(Math.min(32, Math.max(8, Math.round(gestureSize * scale))));
    };
    area.addEventListener('wheel', onWheel, { passive: false });
    area.addEventListener('gesturestart', onGestureStart as EventListener, { passive: false } as AddEventListenerOptions);
    area.addEventListener('gesturechange', onGestureChange as EventListener, { passive: false } as AddEventListenerOptions);
    return () => {
      area.removeEventListener('wheel', onWheel);
      area.removeEventListener('gesturestart', onGestureStart as EventListener);
      area.removeEventListener('gesturechange', onGestureChange as EventListener);
    };
  }, []);

  useEffect(() => {
    const onMaziarLanguage = (event: Event) => {
      const detail = (event as CustomEvent<string>).detail;
      if (detail) setSpellLanguage(resolveSpellLanguage(detail));
    };
    window.addEventListener('maziar-spell-language', onMaziarLanguage);
    return () => window.removeEventListener('maziar-spell-language', onMaziarLanguage);
  }, []);

  const spellApplies = /\.(tex|ltx|txt|md)$/i.test(activePath);
  useEffect(() => {
    try {
      localStorage.setItem('maziar.spell.enabled', spellEnabled ? '1' : '0');
      localStorage.setItem('maziar.spell.language', spellLanguage);
    } catch {
      /* ignore */
    }
    const view = cmViewRef.current;
    if (!view) return;
    const on = spellAvailable && spellEnabled && spellApplies;
    view.dispatch({
      effects: spellCompartment.reconfigure(on ? spellExtension({ language: spellLanguage, grammar: true, onStatus: setSpellInfo }) : [])
    });
    if (!on) setSpellInfo({ checking: false, count: 0 });
  }, [spellAvailable, spellEnabled, spellLanguage, spellApplies, activePath, spellCompartment]);

  const languageName = useCallback((code: string) => {
    try {
      const names = new Intl.DisplayNames([i18n.language || 'en'], { type: 'language' });
      return names.of(code.replace('_', '-')) || code;
    } catch {
      return code;
    }
  }, [i18n.language]);
  const pendingGrouped = useMemo(() => {
    const map = new Map<string, PendingChange>();
    pendingChanges.forEach((item) => {
      map.set(item.filePath, item);
    });
    return Array.from(map.values());
  }, [pendingChanges]);

  const figureFiles = useMemo(
    () =>
      tree.filter(
        (item) =>
          item.type === 'file' &&
          FIGURE_EXTS.some((ext) => item.path.toLowerCase().endsWith(ext))
      ),
    [tree]
  );

  useEffect(() => {
    if (!selectedFigure && figureFiles.length > 0) {
      setSelectedFigure(figureFiles[0].path);
    }
  }, [figureFiles, selectedFigure]);

  useEffect(() => {
    setPdfAnnotations([]);
    setPdfOutline([]);
  }, [pdfUrl]);

  const pdfScaleLabel = useMemo(() => `${Math.round(pdfZoom.scale * 100)}%`, [pdfZoom.scale]);

  const breadcrumbParts = useMemo(() => (activePath ? activePath.split('/').filter(Boolean) : []), [activePath]);

  const clampPdfScale = useCallback((value: number) => Math.min(2.5, Math.max(0.6, value)), []);

  const zoomPdf = useCallback(
    (delta: number) => {
      const base = pdfFitScale ?? pdfScale;
      setPdfFitWidth(false);
      setPdfScale(clampPdfScale(base + delta));
    },
    [clampPdfScale, pdfFitScale, pdfScale]
  );

  const scrollToPdfPage = useCallback((page: number) => {
    const container = pdfContainerRef.current;
    if (!container || !page) return;
    const target = container.querySelector(`.pdf-page[data-page-number="${page}"]`) as HTMLElement | null;
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }, []);

  const handlePdfOutline = useCallback((items: { title: string; page?: number; level: number }[]) => {
    setPdfOutline(items);
  }, []);

  const addPdfAnnotation = useCallback((page: number, x: number, y: number) => {
    const text = window.prompt(t('输入注释内容'))?.trim();
    if (!text) return;
    const id = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`;
    setPdfAnnotations((prev) => [...prev, { id, page, x, y, text }]);
  }, [t]);

  const downloadPdf = useCallback(() => {
    if (!pdfUrl) return;
    const name = projectName ? projectName.replace(/\s+/g, '-') : projectId || 'numenor';
    const link = document.createElement('a');
    link.href = pdfUrl;
    link.download = `${name}.pdf`;
    document.body.appendChild(link);
    link.click();
    link.remove();
  }, [pdfUrl, projectId, projectName]);

  const handleFitScale = useCallback((value: number | null) => {
    if (value == null) {
      setPdfFitScale(null);
      return;
    }
    setPdfFitScale((prev) => (prev && Math.abs(prev - value) < 0.005 ? prev : value));
  }, []);

  const startTypewriter = useCallback((setHistory: Dispatch<SetStateAction<Message[]>>, text: string) => {
    if (typewriterTimerRef.current) {
      window.clearTimeout(typewriterTimerRef.current);
      typewriterTimerRef.current = null;
    }
    if (!text) {
      setHistory((prev) => {
        if (prev.length === 0) return prev;
        const next = [...prev];
        const last = next[next.length - 1];
        if (last.role === 'assistant') {
          next[next.length - 1] = { ...last, content: '' };
        }
        return next;
      });
      return;
    }
    let idx = 0;
    const step = () => {
      idx = Math.min(text.length, idx + 2);
      const slice = text.slice(0, idx);
      setHistory((prev) => {
        if (prev.length === 0) return prev;
        const next = [...prev];
        const last = next[next.length - 1];
        if (last.role !== 'assistant') return prev;
        next[next.length - 1] = { ...last, content: slice };
        return next;
      });
      if (idx < text.length) {
        typewriterTimerRef.current = window.setTimeout(step, 16);
      }
    };
    step();
  }, []);

  useEffect(() => {
    return () => {
      if (typewriterTimerRef.current) {
        window.clearTimeout(typewriterTimerRef.current);
      }
    };
  }, []);

  const sendPrompt = async () => {
    const isChat = assistantMode === 'chat';
    if (!activePath && !isChat) return;
    if (isChat === false && task === 'translate') {
      if (translateScope === 'selection' && !selectionText) {
        setStatus(t('请选择要翻译的文本。'));
        return;
      }
    }
    const userMsg: Message = { role: 'user', content: prompt || t('(empty)') };
    const setHistory = isChat ? setChatMessages : setAgentMessages;
    const history = isChat ? chatMessages : agentMessages;
    const nextHistory = [...history, userMsg];
    setHistory(nextHistory);
    try {
      let effectivePrompt = prompt;
      let effectiveSelection = selectionText;
      let effectiveContent = editorValue;
      let effectiveMode = mode;
      let effectiveTask = task;

      if (!isChat && task === 'translate') {
        const note = prompt ? `\n${t('User note')}: ${prompt}` : '';
        if (translateScope === 'project') {
          effectiveMode = 'tools';
          effectiveSelection = '';
          effectiveContent = '';
          effectivePrompt = t('Translate all .tex files in the project to {{target}}. Preserve LaTeX commands and structure.{{note}}', { target: translateTarget, note });
        } else if (translateScope === 'file') {
          effectiveSelection = '';
          effectivePrompt = t('Translate the current file to {{target}}. Preserve LaTeX commands and structure.{{note}}', { target: translateTarget, note });
        } else {
          effectivePrompt = t('Translate the selected text to {{target}}. Preserve LaTeX commands and structure.{{note}}', { target: translateTarget, note });
        }
        effectiveTask = 'translate';
      }

      if (!isChat && task === 'websearch') {
        effectiveMode = 'tools';
        effectiveSelection = '';
        effectiveContent = '';
        effectivePrompt = prompt
          ? t('Search arXiv and return 3-5 relevant papers with BibTeX entries. User query: {{query}}', { query: prompt })
          : t('Search arXiv and return 3-5 relevant papers with BibTeX entries.');
        effectiveTask = 'websearch';
      }

      if (!isChat && effectiveTask !== 'websearch') {
        const context = await buildProjectContext();
        if (context) {
          effectivePrompt = `${effectivePrompt}\n\n[Project Context]\n${context}`;
        }
      }

      const effectiveLlmConfig = !isChat && effectiveTask === 'websearch' ? searchLlmConfig : llmConfig;
      const res = await runAgent({
        task: effectiveTask,
        prompt: effectivePrompt,
        selection: effectiveSelection,
        content: effectiveContent,
        mode: isChat ? 'direct' : effectiveMode,
        projectId,
        activePath,
        compileLog,
        llmConfig: effectiveLlmConfig,
        interaction: isChat ? 'chat' : 'agent',
        history: nextHistory.slice(-8)
      });
      const replyText = res.reply || t('已生成建议。');
      setHistory((prev) => [...prev, { role: 'assistant', content: '' }]);
      window.setTimeout(() => startTypewriter(setHistory, replyText), 0);

      if (!isChat && res.patches && res.patches.length > 0) {
        const nextPending = res.patches.map((patch) => ({
          filePath: patch.path,
          original: files[patch.path] ?? '',
          proposed: patch.content,
          diff: patch.diff
        }));
        setPendingChanges(nextPending);
        setRightView('diff');
      } else if (!isChat && res.suggestion) {
        const proposed = selectionText
          ? replaceSelection(editorValue, selectionRange[0], selectionRange[1], res.suggestion)
          : res.suggestion;
        const diff = createTwoFilesPatch(activePath, activePath, editorValue, proposed, 'current', 'suggested');
        setPendingChanges([{ filePath: activePath, original: editorValue, proposed, diff }]);
        setRightView('diff');
      }
    } catch (err) {
      setHistory((prev) => [...prev, { role: 'assistant', content: t('请求失败: {{error}}', { error: String(err) }) }]);
    }
  };

  const diagnoseCompile = async () => {
    if (!compileLog) {
      setStatus(t('暂无编译日志可诊断。'));
      return;
    }
    if (!activePath) return;
    setDiagnoseBusy(true);
    const userMsg: Message = { role: 'user', content: t('诊断并修复编译错误') };
    const nextHistory = [...agentMessages, userMsg];
    setAgentMessages(nextHistory);
    try {
      const res = await runAgent({
        task: 'debug_compile',
        prompt: t('基于编译日志诊断并修复错误，给出可应用的 diff。'),
        selection: compileLog,
        content: editorValue,
        mode: 'tools',
        projectId,
        activePath,
        compileLog,
        llmConfig,
        interaction: 'agent',
        history: nextHistory.slice(-8)
      });
      const assistant: Message = {
        role: 'assistant',
        content: res.reply || t('已生成编译修复建议。')
      };
      setAgentMessages((prev) => [...prev, assistant]);
      if (res.patches && res.patches.length > 0) {
        const nextPending = res.patches.map((patch) => ({
          filePath: patch.path,
          original: files[patch.path] ?? '',
          proposed: patch.content,
          diff: patch.diff
        }));
        setPendingChanges(nextPending);
        setRightView('diff');
      }
    } catch (err) {
      setAgentMessages((prev) => [...prev, { role: 'assistant', content: t('请求失败: {{error}}', { error: String(err) }) }]);
    } finally {
      setDiagnoseBusy(false);
    }
  };

  const applyPending = async (change?: PendingChange) => {
    const list = change ? [change] : pendingChanges;
    for (const item of list) {
      await writeFileCompat(item.filePath, item.proposed);
      setFiles((prev) => ({ ...prev, [item.filePath]: item.proposed }));
      if (activePath === item.filePath && !collabActiveRef.current) {
        setEditorDoc(item.proposed);
      }
    }
    if (change) {
      setPendingChanges((prev) => prev.filter((item) => item.filePath !== change.filePath));
      if (diffFocus?.filePath === change.filePath) {
        setDiffFocus(null);
      }
    } else {
      setPendingChanges([]);
      setDiffFocus(null);
    }
    setStatus(t('已应用修改'));
  };

  const discardPending = (change?: PendingChange) => {
    if (change) {
      setPendingChanges((prev) => prev.filter((item) => item.filePath !== change.filePath));
      if (diffFocus?.filePath === change.filePath) {
        setDiffFocus(null);
      }
    } else {
      setPendingChanges([]);
      setDiffFocus(null);
    }
  };

  const startColumnDrag = useCallback(
    (side: 'left' | 'right', event: MouseEvent) => {
      event.preventDefault();
      const startX = event.clientX;
      const { sidebar, editor, right } = columnSizes;
      const minSidebar = 220;
      const minEditor = 360;
      const minRight = 320;

      const onMove = (moveEvent: MouseEvent) => {
        const dx = moveEvent.clientX - startX;
        if (side === 'left') {
          const nextSidebar = Math.max(minSidebar, sidebar + dx);
          const nextEditor = Math.max(minEditor, editor - dx);
          setColumnSizes({ sidebar: nextSidebar, editor: nextEditor, right });
        } else {
          const nextEditor = Math.max(minEditor, editor + dx);
          const nextRight = Math.max(minRight, right - dx);
          setColumnSizes({ sidebar, editor: nextEditor, right: nextRight });
        }
      };

      const onUp = () => {
        window.removeEventListener('mousemove', onMove);
        window.removeEventListener('mouseup', onUp);
      };

      window.addEventListener('mousemove', onMove);
      window.addEventListener('mouseup', onUp);
    },
    [columnSizes]
  );

  const startEditorSplitDrag = useCallback(
    (event: MouseEvent) => {
      event.preventDefault();
      const container = editorSplitRef.current;
      if (!container) return;

      const onMove = (moveEvent: MouseEvent) => {
        const rect = container.getBoundingClientRect();
        const offsetY = moveEvent.clientY - rect.top;
        const ratio = Math.min(0.85, Math.max(0.35, offsetY / rect.height));
        setEditorSplit(ratio);
      };

      const onUp = () => {
        window.removeEventListener('mousemove', onMove);
        window.removeEventListener('mouseup', onUp);
      };

      window.addEventListener('mousemove', onMove);
      window.addEventListener('mouseup', onUp);
    },
    []
  );

  return (
    <div className="app-shell">
      {accessRemoved && (
        <div className="modal-backdrop">
          <div className="modal nm-access-removed">
            <div className="modal-header"><div>{t('Access removed')}</div></div>
            <div className="modal-body">
              <p>{t('The owner removed your access to this project, or stopped sharing it. Changes you make now can’t be saved.')}</p>
            </div>
          </div>
        </div>
      )}
      {syncOpen && projectId && (
        <SyncDialog projectId={projectId} projectName={projectName || t('Project')} onClose={() => setSyncOpen(false)} />
      )}
      {shareOpen && projectId && (
        <ShareDialog projectId={projectId} projectName={projectName || t('Project')} onClose={() => setShareOpen(false)} onStatus={setStatus} />
      )}
      {pdfPopped && (
        <div className="nm-pdf-popped-bar" role="status">
          <IconPopOut size={14} /> {t('The PDF preview is in its own window.')}
          <button className="nm-icon-btn" onClick={() => forwardSyncRef.current()} disabled={!pdfUrl} title={t('Show the cursor’s line in the PDF (Cmd/Ctrl + Shift + J)')}>
            <IconSync size={14} /> {t('Show in PDF')}
          </button>
          <button className="nm-icon-btn" onClick={() => pdfWinRef.current?.focus()}>{t('Show it')}</button>
          <button className="nm-icon-btn" onClick={dockPdf}><IconPopIn size={14} /> {t('Back to editor')}</button>
        </div>
      )}
      <header className="top-bar nm-topbar">
        <div className="nm-topbar-left">
          <button
            className="nm-icon-btn borderless"
            onClick={() => setSidebarOpen((prev) => !prev)}
            title={sidebarOpen ? t('隐藏侧栏') : t('显示侧栏')}
            aria-label={sidebarOpen ? t('隐藏侧栏') : t('显示侧栏')}
          >
            <IconSidebar size={17} />
          </button>
          <button type="button" className="nm-brand-link nm-brand-btn" onClick={() => setSettingsOpen(true)} title={t('Numenor settings')}>
            <NumenorMark size={30} />
            <span className="nm-star" aria-hidden="true">✦</span>
            <span className="nm-wordmark">Numenor</span>
          </button>
          <span className="nm-topbar-sep" />
          <Link to="/projects" className="nm-crumb-link"><IconArrowLeft size={15} /> {t('Projects')}</Link>
          <IconChevronRight size={14} className="nm-crumb-sep" />
          <span className="nm-project-name" title={projectName}>{projectName || t('Project')}</span>
        </div>
        <div className="nm-topbar-right">
          <div className="ios-select-wrapper nm-select">
            <button className="ios-select-trigger" title={t('Root document')} onClick={(e) => {
              const opening = !mainFileDropdownOpen;
              setMainFileDropdownOpen(opening); setEngineDropdownOpen(false); setLangDropdownOpen(false);
              if (opening) { const r = e.currentTarget.getBoundingClientRect(); setTopBarDropdownRect({ top: r.bottom + 6, left: r.left, width: r.width }); }
            }}>
              <span className="nm-select-text">{mainFile}</span>
              <IconChevronDown size={14} className={mainFileDropdownOpen ? 'rotate' : ''} />
            </button>
          </div>
          <div className="ios-select-wrapper nm-select">
            <button className="ios-select-trigger" title={t('Compiler')} onClick={(e) => {
              const opening = !engineDropdownOpen;
              setEngineDropdownOpen(opening); setMainFileDropdownOpen(false); setLangDropdownOpen(false);
              if (opening) { const r = e.currentTarget.getBoundingClientRect(); setTopBarDropdownRect({ top: r.bottom + 6, left: r.left, width: r.width }); }
            }}>
              <span className="nm-select-text">{({'pdflatex':'pdfLaTeX','xelatex':'XeLaTeX','lualatex':'LuaLaTeX','latexmk':'Latexmk','tectonic':'Tectonic'} as Record<string,string>)[compileEngine] || compileEngine}</span>
              <IconChevronDown size={14} className={engineDropdownOpen ? 'rotate' : ''} />
            </button>
          </div>
          {me?.kind === 'guest' && (
            <span className={`nm-access-chip ${me.role}`} title={t('You were invited to this project')}>
              {me.role === 'view' ? t('View only') : t('Can edit')}
            </span>
          )}
          {others.length > 0 && (
            <div className="nm-presence" aria-label={t('Also here now')}>
              {others.slice(0, 5).map((p) => {
                const color = colorForKey(p.key);
                const where = p.file ? t('in {{file}}', { file: p.file }) : '';
                const what = p.role === 'owner' ? t('Owner') : p.role === 'view' ? t('View only') : t('Can edit');
                return (
                  <button
                    key={p.key}
                    type="button"
                    className="nm-presence-chip"
                    style={{ borderColor: color }}
                    onClick={() => { followPerson(p).catch(() => {}); }}
                    title={`${p.name} — ${what}${where ? ` · ${where}` : ''}\n${t('Click to see where their cursor is')}`}
                  >
                    <span className="nm-presence-avatar" style={{ background: color }}>{presenceInitials(p.name)}</span>
                    <span className="nm-presence-name nm-hide-narrow">{p.name}</span>
                  </button>
                );
              })}
              {others.length > 5 && <span className="nm-presence-more" title={others.slice(5).map((p) => p.name).join(', ')}>+{others.length - 5}</span>}
            </div>
          )}
          <Link to={`/history/${projectId}`} className="nm-icon-btn nm-topbar-btn" title={t('Who changed what, and when')}>
            <IconHistory size={16} /> <span className="nm-hide-narrow">{t('History')}</span>
          </Link>
          {me?.kind !== 'guest' && !isGuest && (
            <button className="nm-icon-btn nm-topbar-btn" onClick={() => setSyncOpen(true)} disabled={!projectId} title={t('Keep copies of this project in Google Drive, SharePoint and other folders, updated on every save')}>
              <IconCloud size={16} /> <span className="nm-hide-narrow">{t('Copies')}</span>
            </button>
          )}
          {me?.kind !== 'guest' && (
            <button className="nm-icon-btn nm-topbar-btn nm-share-btn" onClick={() => setShareOpen(true)} disabled={!projectId} title={t('Share this project with other people')}>
              <IconShare size={16} /> <span className="nm-hide-narrow">{t('Share')}</span>
            </button>
          )}
          {!viewOnly && <button onClick={saveActiveFile} className="btn nm-save" title={t('Save (Cmd/Ctrl + S)')}>{t('保存')}</button>}
          <button onClick={compile} className="btn nm-primary nm-compile" disabled={isCompiling}>
            {isCompiling ? t('编译中...') : t('编译 PDF')}
          </button>
        </div>
      </header>

      <main
        className={`workspace ${pdfPopped ? 'pdf-popped' : ''}`}
        ref={gridRef}
        style={{
          '--col-sidebar': sidebarOpen ? `${columnSizes.sidebar}px` : '0px',
          '--col-sidebar-gap': sidebarOpen ? '10px' : '0px',
          '--col-editor': `${columnSizes.editor}px`,
          '--col-right': `${columnSizes.right}px`
        } as CSSProperties}
      >
        {sidebarOpen && (
          <aside className="panel side-panel">
            <div className="sidebar-tabs">
              <div className="tab-group">
                <button
                  className={`tab-btn ${activeSidebar === 'files' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('files')}
                  title={t('Files')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg></span>
                  <span className="tab-text">{t('Files')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'collab' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('collab')}
                  title={t('协作')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 21v-2a4 4 0 0 0-3-3.87"/><path d="M7 21v-2a4 4 0 0 1 3-3.87"/><circle cx="7" cy="7" r="3"/><circle cx="17" cy="7" r="3"/></svg></span>
                  <span className="tab-text">{t('协作')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'agent' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('agent')}
                  title={t('Agent')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><line x1="9" y1="9" x2="9.01" y2="9"/><line x1="15" y1="9" x2="15.01" y2="9"/><path d="M8 14s1.5 2 4 2 4-2 4-2"/></svg></span>
                  <span className="tab-text">{t('Agent')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'vision' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('vision')}
                  title={t('图像识别')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg></span>
                  <span className="tab-text">{t('图像识别')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'search' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('search')}
                  title={t('论文检索')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg></span>
                  <span className="tab-text">{t('论文检索')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'websearch' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('websearch')}
                  title={t('Websearch')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg></span>
                  <span className="tab-text">{t('Websearch')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'plot' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('plot')}
                  title={t('绘图')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/></svg></span>
                  <span className="tab-text">{t('绘图')}</span>
                </button>
                <button
                  className={`tab-btn ${activeSidebar === 'review' ? 'active' : ''}`}
                  onClick={() => setActiveSidebar('review')}
                  title={t('Review')}
                >
                  <span className="tab-icon"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg></span>
                  <span className="tab-text">{t('Review')}</span>
                </button>
              </div>
              <button className="icon-btn" onClick={() => setSidebarOpen(false)}>✕</button>
            </div>
            {activeSidebar === 'files' ? (
              <>
                <div className="panel-header nm-pane-head">
                  <div className="nm-pane-title">{t('Project Files')}</div>
                  <button
                    className="nm-icon-btn nm-upload"
                    onClick={() => fileInputRef.current?.click()}
                    title={t('Upload into {{folder}} — or drop files onto a folder', { folder: uploadFolder || t('project root') })}
                  >
                    <IconPlus size={14} /> {t('Upload')}
                  </button>
                </div>
                <div className="upload-target muted">
                  {t('Uploads go to')} <b>{uploadFolder || t('project root')}</b> · {t('select a folder or drop files onto one')}
                </div>
                {uploadError && (
                  <div className="upload-error" role="alert">
                    <span>{uploadError}</span>
                    <button className="icon-btn" onClick={() => setUploadError('')}>✕</button>
                  </div>
                )}
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  style={{ display: 'none' }}
                  onChange={(event) => {
                    handleUpload(event.target.files, uploadFolder).catch((err) => setStatus(t('上传失败: {{error}}', { error: String(err) })));
                    if (event.target) {
                      event.target.value = '';
                    }
                  }}
                />
                <input
                  ref={folderInputRef}
                  type="file"
                  multiple
                  style={{ display: 'none' }}
                  {...({ webkitdirectory: 'true', directory: 'true' } as Record<string, string>)}
                  onChange={(event) => {
                    handleUpload(event.target.files, uploadFolder).catch((err) => setStatus(t('上传失败: {{error}}', { error: String(err) })));
                    if (event.target) {
                      event.target.value = '';
                    }
                  }}
                />
                <div className="panel-search nm-search-field">
                  <IconSearch size={15} />
                  <input
                    className="input"
                    value={fileFilter}
                    onChange={(e) => setFileFilter(e.target.value)}
                    placeholder={t('搜索文件...')}
                  />
                </div>
                <div className="drag-hint muted">{t('拖拽文件：同级排序 / 跨文件夹移动')}</div>
                <div
                  className="file-tree-body"
                  ref={fileTreeRef}
                  onContextMenu={(event) => {
                    event.preventDefault();
                    const menuH = 380;
                    const menuW = 180;
                    const y = event.clientY + menuH > window.innerHeight ? Math.max(8, window.innerHeight - menuH - 8) : event.clientY;
                    const x = event.clientX + menuW > window.innerWidth ? Math.max(8, window.innerWidth - menuW - 8) : event.clientX;
                    setFileContextMenu({ x, y });
                  }}
                  onDragOver={(event) => {
                    event.preventDefault();
                    setDragOverPath('');
                    setDragOverKind('');
                    if (draggingPath) {
                      updateDragHint(t('移动到 根目录'), event);
                    }
                  }}
                  onDrop={(event) => {
                    event.preventDefault();
                    if (event.dataTransfer.files && event.dataTransfer.files.length > 0) {
                      handleUpload(event.dataTransfer.files).catch((err) => setStatus(t('上传失败: {{error}}', { error: String(err) })));
                      return;
                    }
                    const from = event.dataTransfer.getData('text/plain');
                    if (from) {
                      if (fileFilter.trim()) {
                        setStatus(t('搜索过滤中无法拖拽移动。'));
                        return;
                      }
                      moveFileWithOrder(from, '').catch((err) => setStatus(t('移动失败: {{error}}', { error: String(err) })));
                    }
                    setDragHint(null);
                  }}
                >
                  {dragHint && draggingPath && (
                    <div className="drag-hint-overlay" style={{ left: dragHint.x, top: dragHint.y }}>
                      {dragHint.text}
                    </div>
                  )}
                  {inlineEdit && inlineEdit.kind !== 'rename' && inlineEdit.parent === '' && inlineInputRow(0)}
                  {renderTree(treeRoot.children)}
                </div>
                <div className="outline-panel">
                  <div className="outline-header" onClick={() => setOutlineCollapsed(!outlineCollapsed)} style={{ cursor: 'pointer' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" style={{ transform: outlineCollapsed ? 'rotate(-90deg)' : 'rotate(0)', transition: 'transform 0.2s ease' }}>
                        <path d="M2 3L5 6L8 3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                      </svg>
                      {t('Outline')}
                    </div>
                    <div className="muted">{mainFile || 'main.tex'}</div>
                  </div>
                  {!outlineCollapsed && (mainFile && mainFile.toLowerCase().endsWith('.tex') ? (
                    outlineItems.length > 0 ? (
                      <div className="outline-list">
                        {outlineItems.map((item, idx) => (
                          <button
                            key={`${item.pos}-${idx}`}
                            className={`outline-item level-${item.level}`}
                            onClick={() => {
                              const go = async () => {
                                if (mainFile && activePath !== mainFile) {
                                  await openFile(mainFile);
                                }
                                const view = cmViewRef.current;
                                if (!view) return;
                                const pos = Math.min(item.pos, view.state.doc.length);
                                view.dispatch({ selection: { anchor: pos, head: pos }, scrollIntoView: true });
                                view.focus();
                              };
                              go();
                            }}
                          >
                            <span className="outline-title">{item.title}</span>
                            <span className="outline-line">L{item.line}</span>
                          </button>
                        ))}
                      </div>
                    ) : (
                      <div className="muted outline-empty">{t('未发现 Section 标题。')}</div>
                    )
                  ) : (
                    <div className="muted outline-empty">{t('打开 .tex 文件以显示 Outline。')}</div>
                  ))}
                </div>
              </>
            ) : activeSidebar === 'collab' ? (
              <>
                <div className="panel-header">
                  <div>{t('协作')}</div>
                  <div className="panel-actions">
                    <div className="collab-status">
                      <span>{collabStatus === 'connected' ? t('已连接') : collabStatus === 'connecting' ? t('连接中...') : t('未连接')}</span>
                    </div>
                  </div>
                </div>
                <div className="collab-panel">
                  {isGuest ? (
                    <div className="share-box guest">
                      <div className="share-title">{t('You were invited to this project')}{me?.kind === 'guest' ? ` — ${me.role === 'view' ? t('view only') : t('can edit')}` : ''}</div>
                      <div className="muted share-text">{me?.role === 'view' ? t('You can read the project and the PDF; changes by others appear live.') : t('Your edits appear for everyone working on it, live. Connect below if you are not connected yet.')}</div>
                      <div className="muted share-text">{t('Using Numenor on your own Mac or PC? Copy this link and add it there under Projects → Add shared link, with your access code — you then only enter the code once.')}</div>
                      <div className="collab-row">
                        <button className="ios-btn secondary" onClick={() => {
                          const link = `${window.location.origin}/collab?token=${encodeURIComponent(getCollabInviteToken() || collabToken)}`;
                          navigator.clipboard.writeText(link).then(() => setStatus(t('Link copied.'))).catch(() => window.prompt(t('Copy this link:'), link));
                        }}><IconCopy size={14} /> {t('Copy link for my Numenor')}</button>
                      </div>
                    </div>
                  ) : (
                    <div className={`share-box ${share?.active ? 'on' : ''}`}>
                      <div className="share-head">
                        <span className={`share-dot ${share?.active ? 'on' : share?.starting || shareBusy ? 'starting' : ''}`} />
                        <span className="share-title">
                          {share?.active
                            ? t('Sharing is on')
                            : share?.starting || shareBusy
                              ? t('Starting…')
                              : t('Share this project with other people')}
                        </span>
                        {share?.active && <span className="share-provider">{share.provider}</span>}
                      </div>
                      <div className="muted share-text">
                        {t('Each person you invite gets their own link to this project — only this one — and can edit or just view it, live, while Numenor is running on this computer. You can remove anyone’s access at any time. AI features stay yours.')}
                      </div>
                      {share?.note && <div className="share-note">{share.note}</div>}
                      {share?.error && !share.active && <div className="share-error">{share.error}</div>}
                      <div className="collab-row">
                        <button className="ios-btn primary" onClick={() => setShareOpen(true)} disabled={!projectId}>
                          {t('Share with people…')}
                        </button>
                        {share?.active && (
                          <button className="ios-btn secondary" onClick={() => stopSharingNow()} disabled={shareBusy}>
                            {t('Stop sharing')}
                          </button>
                        )}
                      </div>
                    </div>
                  )}
                  <div className="collab-row">
                    <input
                      className="input"
                      value={collabServer}
                      onChange={(e) => setCollabServerState(e.target.value)}
                      placeholder={t('协作服务器地址')}
                    />
                  </div>
                  <div className="collab-row">
                    <input
                      className="input"
                      value={collabName}
                      onChange={(e) => setCollabName(e.target.value)}
                      placeholder={t('显示名称')}
                    />
                    <button
                      className="ios-btn secondary"
                      onClick={() => setCollabEnabled((prev) => !prev)}
                      disabled={!activePath || !isTextPath(activePath)}
                    >
                      {collabEnabled ? t('断开') : t('连接')}
                    </button>
                  </div>
                  <div className="collab-row">
                    <button
                      className="ios-btn primary"
                      onClick={() => handleCreateInvite()}
                      disabled={collabInviteBusy || !projectId}
                    >
                      {collabInviteBusy ? t('生成中...') : t('生成邀请链接')}
                    </button>
                    <button
                      className="ios-btn secondary"
                      onClick={() => copyInviteLink()}
                      disabled={!collabInviteLink}
                    >
                      {t('复制')}
                    </button>
                  </div>
                  <div className="collab-row">
                    <input
                      className="input"
                      readOnly
                      value={collabInviteLink || ''}
                      placeholder={t('尚未生成邀请链接')}
                    />
                  </div>
                  <div className="collab-row">
                    <div className="muted">
                      {activePath ? t('当前文件: {{path}}', { path: activePath }) : t('未选择文件')}
                    </div>
                  </div>
                  <div className="collab-users">
                    {collabPeers.length === 0 ? (
                      <div className="muted">{t('暂无协作者在线')}</div>
                    ) : (
                      collabPeers.map((peer) => (
                        <div key={peer.id} className="collab-user">
                          <span className="dot" style={{ background: peer.color }} />
                          <span>{peer.name}</span>
                        </div>
                      ))
                    )}
                  </div>
                </div>
              </>
            ) : activeSidebar === 'agent' ? (
              <>
                <div className="panel-header">
                  <div>{assistantMode === 'chat' ? t('Chat') : t('Agent')}</div>
                  <div className="panel-actions">
                    <div className="mode-toggle">
                      <button
                        className={`mode-btn ${assistantMode === 'chat' ? 'active' : ''}`}
                        onClick={() => setAssistantMode('chat')}
                      >
                        {t('Chat')}
                      </button>
                      <button
                        className={`mode-btn ${assistantMode === 'agent' ? 'active' : ''}`}
                        onClick={() => setAssistantMode('agent')}
                      >
                        {t('Agent')}
                      </button>
                    </div>
                  </div>
                </div>
                {assistantMode === 'chat' && (
                  <div className="context-tags">
                    <span className="context-tag">{t('只读当前文件')}</span>
                    {selectionText && <span className="context-tag">{t('只读选区')}</span>}
                    {compileLog && <span className="context-tag">{t('只读编译日志')}</span>}
                  </div>
                )}
                <div className="chat-messages">
                  {assistantMode === 'chat' && chatMessages.length === 0 && (
                    <div className="muted">{t('输入问题，进行只读对话。')}</div>
                  )}
                  {assistantMode === 'agent' && agentMessages.length === 0 && (
                    <div className="muted">{t('输入任务描述，生成修改建议。')}</div>
                  )}
                  {(assistantMode === 'chat' ? chatMessages : agentMessages).map((msg, idx) => (
                    <div key={idx} className={`chat-msg ${msg.role}`}>
                      <div className="role">{msg.role}</div>
                      <div className={`content ${msg.role === 'assistant' ? 'markdown-body' : ''}`}>
                        {msg.role === 'assistant' ? (
                          <ReactMarkdown remarkPlugins={[remarkGfm]}>{msg.content}</ReactMarkdown>
                        ) : (
                          msg.content
                        )}
                      </div>
                    </div>
                  ))}
                </div>
                <div className="chat-controls">
                  <div className="row chat-control-row">
                    {assistantMode === 'agent' ? (
                      <>
                        <div className="ios-select-wrapper">
                          <button
                            className="ios-select-trigger"
                            onClick={() => {
                              setTaskDropdownOpen(!taskDropdownOpen);
                              setModeDropdownOpen(false);
                            }}
                          >
                            <span>{DEFAULT_TASKS(t).find((item) => item.value === task)?.label || t('选择任务')}</span>
                            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={taskDropdownOpen ? 'rotate' : ''}>
                              <path d="M3 7L6 4L9 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                            </svg>
                          </button>
                          {taskDropdownOpen && (
                            <div className="ios-dropdown">
                              {DEFAULT_TASKS(t).map((item) => (
                                <div
                                  key={item.value}
                                  className={`ios-dropdown-item ${task === item.value ? 'active' : ''}`}
                                  onClick={() => {
                                    setTask(item.value);
                                    setTaskDropdownOpen(false);
                                  }}
                                >
                                  {item.label}
                                  {task === item.value && (
                                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                                      <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                                    </svg>
                                  )}
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                        <div className="agent-mode-wrap">
                          <div className="ios-select-wrapper">
                            <button
                              className="ios-select-trigger"
                              onClick={() => {
                                setModeDropdownOpen(!modeDropdownOpen);
                                setTaskDropdownOpen(false);
                              }}
                            >
                              <span>{mode === 'direct' ? t('Direct') : t('Tools')}</span>
                              <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={modeDropdownOpen ? 'rotate' : ''}>
                                <path d="M3 7L6 4L9 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                              </svg>
                            </button>
                            {modeDropdownOpen && (
                              <div className="ios-dropdown">
                                <div
                                  className={`ios-dropdown-item ${mode === 'direct' ? 'active' : ''}`}
                                  onClick={() => {
                                    setMode('direct');
                                    setModeDropdownOpen(false);
                                  }}
                                >
                                  {t('Direct')}
                                  {mode === 'direct' && (
                                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                                      <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                                    </svg>
                                  )}
                                </div>
                                <div
                                  className={`ios-dropdown-item ${mode === 'tools' ? 'active' : ''}`}
                                  onClick={() => {
                                    setMode('tools');
                                    setModeDropdownOpen(false);
                                  }}
                                >
                                  {t('Tools')}
                                  {mode === 'tools' && (
                                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                                      <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                                    </svg>
                                  )}
                                </div>
                              </div>
                            )}
                          </div>
                          <span className="info-icon">
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg">
                              <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5" fill="none"/>
                              <path d="M8 7V11" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
                              <circle cx="8" cy="5" r="0.5" fill="currentColor"/>
                            </svg>
                            <span className="tooltip">{t('Direct: 单轮生成 · Tools: 多轮工具调用/多文件修改')}</span>
                          </span>
                        </div>
                      </>
                    ) : (
                      <div className="muted">{t('Chat 模式仅对话，不会改动文件。')}</div>
                    )}
                  </div>
                  {assistantMode === 'agent' && task === 'translate' && (
                    <div className="row chat-control-row">
                      <div className="ios-select-wrapper">
                        <button
                          className="ios-select-trigger"
                          onClick={() => {
                            setTranslateScopeDropdownOpen(!translateScopeDropdownOpen);
                            setTranslateTargetDropdownOpen(false);
                          }}
                          >
                          <span>
                            {translateScope === 'selection' ? t('选区') : translateScope === 'file' ? t('当前文件') : t('整个项目')}
                          </span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={translateScopeDropdownOpen ? 'rotate' : ''}>
                            <path d="M3 7L6 4L9 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                          </svg>
                        </button>
                        {translateScopeDropdownOpen && (
                          <div className="ios-dropdown">
                            {[
                              { value: 'selection', label: t('选区') },
                              { value: 'file', label: t('当前文件') },
                              { value: 'project', label: t('整个项目') }
                            ].map((item) => (
                              <div
                                key={item.value}
                                className={`ios-dropdown-item ${translateScope === item.value ? 'active' : ''}`}
                                onClick={() => {
                                  setTranslateScope(item.value as 'selection' | 'file' | 'project');
                                  setTranslateScopeDropdownOpen(false);
                                }}
                              >
                                {item.label}
                                {translateScope === item.value && (
                                  <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                                    <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                                  </svg>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                      <div className="ios-select-wrapper">
                        <button
                          className="ios-select-trigger"
                          onClick={() => {
                            setTranslateTargetDropdownOpen(!translateTargetDropdownOpen);
                            setTranslateScopeDropdownOpen(false);
                          }}
                        >
                          <span>{translateTargetOptions.find((item) => item.value === translateTarget)?.label || translateTarget}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={translateTargetDropdownOpen ? 'rotate' : ''}>
                            <path d="M3 7L6 4L9 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                          </svg>
                        </button>
                        {translateTargetDropdownOpen && (
                          <div className="ios-dropdown">
                            {translateTargetOptions.map((lang) => (
                              <div
                                key={lang.value}
                                className={`ios-dropdown-item ${translateTarget === lang.value ? 'active' : ''}`}
                                onClick={() => {
                                  setTranslateTarget(lang.value);
                                  setTranslateTargetDropdownOpen(false);
                                }}
                              >
                                {lang.label}
                                {translateTarget === lang.value && (
                                  <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                                    <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                                  </svg>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                  )}
                  <textarea
                    className="chat-input"
                    value={prompt}
                    onChange={(e) => setPrompt(e.target.value)}
                    placeholder={assistantMode === 'chat' ? t('例如：帮我解释这一段的实验设计。') : t('例如：润色这个段落，使其更符合 ACL 风格。')}
                  />
                  <button onClick={sendPrompt} className="btn full">
                    {assistantMode === 'chat' ? t('发送') : t('生成建议')}
                  </button>
                  {selectionText && assistantMode === 'agent' && (
                    <div className="muted">{t('已选择 {{count}} 字符，将用于任务输入', { count: selectionText.length })}</div>
                  )}
                  {assistantMode === 'agent' && task === 'translate' && translateScope === 'selection' && !selectionText && (
                    <div className="muted">{t('翻译选区前请先选择文本。')}</div>
                  )}
                </div>
              </>
            ) : activeSidebar === 'vision' ? (
              <>
                <div className="panel-header">
                  <div>{t('图像识别')}</div>
                  <div className="panel-actions">
                    <button className="btn ghost" onClick={() => setVisionResult('')}>{t('清空结果')}</button>
                  </div>
                </div>
                <div className="tools-body">
                  <div className="tool-section">
                    <div className="tool-title">{t('图像转 LaTeX')}</div>
                    <div className="field">
                      <label>{t('识别类型')}</label>
                      <div className="ios-select-wrapper">
                        <button className="ios-select-trigger" onClick={() => setVisionModeDropdownOpen(!visionModeDropdownOpen)}>
                          <span>{({'equation':t('公式'),'table':t('表格'),'figure':t('图像 + 图注'),'algorithm':t('算法'),'ocr':t('仅提取文字')} as Record<string,string>)[visionMode]}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={visionModeDropdownOpen ? 'rotate' : ''}><path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </button>
                        {visionModeDropdownOpen && (
                          <div className="ios-dropdown dropdown-down">
                            {([['equation',t('公式')],['table',t('表格')],['figure',t('图像 + 图注')],['algorithm',t('算法')],['ocr',t('仅提取文字')]] as [string,string][]).map(([val,lbl]) => (
                              <div key={val} className={`ios-dropdown-item ${visionMode === val ? 'active' : ''}`} onClick={() => { setVisionMode(val as 'equation'|'table'|'figure'|'algorithm'|'ocr'); setVisionResult(''); setVisionModeDropdownOpen(false); }}>
                                {lbl}
                                {visionMode === val && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="field">
                      <label>{t('上传图片')}</label>
                      <div
                        className={`image-drop-zone ${visionFile ? 'has-file' : ''}`}
                        onDragOver={(e) => { e.preventDefault(); e.currentTarget.classList.add('drag-over'); }}
                        onDragLeave={(e) => { e.currentTarget.classList.remove('drag-over'); }}
                        onDrop={(e) => {
                          e.preventDefault();
                          e.currentTarget.classList.remove('drag-over');
                          const file = e.dataTransfer.files?.[0];
                          if (file && file.type.startsWith('image/')) {
                            setVisionFile(file);
                            setVisionResult('');
                          }
                        }}
                        onPaste={(e) => {
                          const items = e.clipboardData?.items;
                          if (!items) return;
                          for (const item of items) {
                            if (item.type.startsWith('image/')) {
                              const file = item.getAsFile();
                              if (file) {
                                setVisionFile(file);
                                setVisionResult('');
                              }
                              break;
                            }
                          }
                        }}
                        tabIndex={0}
                      >
                        <input
                          type="file"
                          accept="image/*"
                          onChange={(e) => {
                            const file = e.target.files?.[0] || null;
                            setVisionFile(file);
                            setVisionResult('');
                          }}
                          style={{ display: 'none' }}
                          id="vision-file-input"
                        />
                        {visionFile ? (
                          <div className="drop-zone-preview">
                            <span className="file-name">{visionFile.name}</span>
                            <button className="remove-btn" onClick={(e) => { e.stopPropagation(); setVisionFile(null); setVisionPreviewUrl(''); }}>✕</button>
                          </div>
                        ) : (
                          <label htmlFor="vision-file-input" className="drop-zone-content">
                            <span className="drop-icon"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg></span>
                            <span className="drop-text">{t('点击选择、拖拽或粘贴图片')}</span>
                          </label>
                        )}
                      </div>
                    </div>
                    {visionPreviewUrl && (
                      <div className="vision-preview">
                        <img src={visionPreviewUrl} alt="preview" />
                      </div>
                    )}
                    <div className="field">
                      <label>{t('附加约束 (可选)')}</label>
                      <textarea
                        className="input"
                        value={visionPrompt}
                        onChange={(event) => setVisionPrompt(event.target.value)}
                        placeholder={t('例如：只输出 tabular，不要表格标题')}
                        rows={2}
                      />
                    </div>
                    <div className="vision-actions">
                      <button className="ios-btn secondary" onClick={handleVisionSubmit} disabled={visionBusy}>
                        {visionBusy ? t('识别中...') : t('开始识别')}
                      </button>
                      <button className="ios-btn primary" onClick={handleVisionInsert} disabled={!visionResult}>{t('插入到光标')}</button>
                    </div>
                    {visionResult && (
                      <div className="vision-result">
                        <div className="muted">{t('识别结果 (可编辑)：')}</div>
                        <textarea
                          className="input"
                          value={visionResult}
                          onChange={(event) => setVisionResult(event.target.value)}
                          rows={6}
                        />
                      </div>
                    )}
                  </div>
                </div>
              </>
            ) : activeSidebar === 'search' ? (
              <>
                <div className="panel-header">
                  <div>{t('论文检索')}</div>
                </div>
                <div className="tools-body">
                  <div className="tool-section">
                    <div className="tool-title">{t('arXiv 检索')}</div>
                    <div className="field">
                      <label>{t('关键词')}</label>
                      <input
                        className="input"
                        value={arxivQuery}
                        onChange={(event) => setArxivQuery(event.target.value)}
                        placeholder={t('例如: diffusion transformer compression')}
                      />
                    </div>
                    <div className="row">
                      <input
                        className="input small"
                        type="number"
                        min={1}
                        max={10}
                        value={arxivMaxResults}
                        onChange={(event) => setArxivMaxResults(Number(event.target.value) || 5)}
                      />
                      <button className="btn ghost" onClick={handleArxivSearch} disabled={arxivBusy}>
                        {arxivBusy ? t('检索中...') : useLlmSearch ? t('LLM 检索') : t('检索')}
                      </button>
                    </div>
                    <label className="checkbox-row">
                      <input
                        type="checkbox"
                        checked={useLlmSearch}
                        onChange={(event) => setUseLlmSearch(event.target.checked)}
                      />
                      {t('使用 Websearch 模型')}
                    </label>
                    {arxivStatus && <div className="muted">{arxivStatus}</div>}
                    {llmSearchOutput && (
                      <div className="vision-result">
                        <div className="muted">{t('LLM 原始输出')}</div>
                        <textarea
                          className="input"
                          value={llmSearchOutput}
                          onChange={(event) => setLlmSearchOutput(event.target.value)}
                          rows={5}
                        />
                      </div>
                    )}
                    {arxivResults.length > 0 && (
                      <div className="tool-list">
                        {arxivResults.map((paper) => (
                          <label key={paper.arxivId} className="tool-item">
                            <input
                              type="checkbox"
                              checked={Boolean(arxivSelected[paper.arxivId])}
                              onChange={(event) => {
                                const checked = event.target.checked;
                                setArxivSelected((prev) => ({ ...prev, [paper.arxivId]: checked }));
                              }}
                            />
                            <div>
                              <div className="tool-item-title">{paper.title}</div>
                              <div className="muted">{paper.authors?.join(', ') || t('Unknown authors')}</div>
                              <div className="muted">{paper.arxivId}</div>
                            </div>
                          </label>
                        ))}
                      </div>
                    )}
                    <div className="field">
                      <label>{t('Bib 文件')}</label>
                      <div className="ios-select-wrapper">
                        <button className="ios-select-trigger" onClick={() => setBibTargetDropdownOpen(!bibTargetDropdownOpen)}>
                          <span>{bibTarget || t('(新建/选择 Bib 文件)')}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={bibTargetDropdownOpen ? 'rotate' : ''}><path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </button>
                        {bibTargetDropdownOpen && (
                          <div className="ios-dropdown dropdown-down">
                            <div className={`ios-dropdown-item ${bibTarget === '' ? 'active' : ''}`} onClick={() => { setBibTarget(''); setBibTargetDropdownOpen(false); }}>
                              {t('(新建/选择 Bib 文件)')}
                              {bibTarget === '' && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                            </div>
                            {bibFiles.map((p) => (
                              <div key={p} className={`ios-dropdown-item ${bibTarget === p ? 'active' : ''}`} onClick={() => { setBibTarget(p); setBibTargetDropdownOpen(false); }}>
                                {p}
                                {bibTarget === p && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                      <button className="btn ghost" onClick={async () => {
                        const created = await createBibFile();
                        if (created) setBibTarget(created);
                      }}>{t('新建 Bib')}</button>
                    </div>
                    <label className="checkbox-row">
                      <input
                        type="checkbox"
                        checked={autoInsertCite}
                        onChange={(event) => setAutoInsertCite(event.target.checked)}
                      />
                      {t('自动插入引用到当前 TeX')}
                    </label>
                    <label className="checkbox-row">
                      <input
                        type="checkbox"
                        checked={autoInsertToMain}
                        onChange={(event) => setAutoInsertToMain(event.target.checked)}
                      />
                      {t('AI 插入引用到指定 TeX')}
                    </label>
                    {autoInsertToMain && (
                      <div className="field">
                        <label>{t('引用插入目标')}</label>
                        <div className="ios-select-wrapper">
                          <button className="ios-select-trigger" onClick={() => setCiteTargetDropdownOpen(!citeTargetDropdownOpen)}>
                            <span>{citeTargetFile || texFiles[0] || 'main.tex'}</span>
                            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={citeTargetDropdownOpen ? 'rotate' : ''}><path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                          </button>
                          {citeTargetDropdownOpen && (
                            <div className="ios-dropdown dropdown-down">
                              {texFiles.map((p) => (
                                <div key={p} className={`ios-dropdown-item ${citeTargetFile === p ? 'active' : ''}`} onClick={() => { setCiteTargetFile(p); setCiteTargetDropdownOpen(false); }}>
                                  {p}
                                  {citeTargetFile === p && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      </div>
                    )}
                    <div className="row">
                      <button className="btn" onClick={handleArxivApply} disabled={arxivBusy}>
                        {t('写入 Bib / 插入引用')}
                      </button>
                    </div>
                  </div>
                </div>
              </>
            ) : activeSidebar === 'websearch' ? (
              <>
                <div className="panel-header">
                  <div>{t('Websearch')}</div>
                </div>
                <div className="tools-body">
                  <div className="tool-section">
                    <div className="tool-title">{t('多点检索')}</div>
                    <div className="field">
                      <label>{t('Query')}</label>
                      <input
                        className="input"
                        value={websearchQuery}
                        onChange={(event) => setWebsearchQuery(event.target.value)}
                        placeholder={t('例如: diffusion editing for safety')}
                      />
                    </div>
                    <div className="row">
                      <button className="btn" onClick={runWebsearch} disabled={websearchBusy}>
                        {websearchBusy ? t('检索中...') : t('开始检索')}
                      </button>
                    </div>
                    <div className="websearch-log">
                      {websearchLog.length === 0 ? (
                        <div className="muted">{t('等待查询...')}</div>
                      ) : (
                        websearchLog.map((line, idx) => (
                          <div key={idx} className="websearch-line">{line}</div>
                        ))
                      )}
                    </div>
                    {websearchResults.length > 0 && (
                      <>
                        <div className="row">
                          <label className="checkbox-row">
                            <input
                              type="checkbox"
                              checked={websearchSelectedAll}
                              onChange={(event) => {
                                const checked = event.target.checked;
                                setWebsearchSelectedAll(checked);
                                const next: Record<string, boolean> = {};
                                websearchResults.forEach((item) => {
                                  next[item.id] = checked;
                                });
                                setWebsearchSelected(next);
                              }}
                            />
                            {t('全选')}
                          </label>
                          <button
                            className="btn ghost small"
                            onClick={() => {
                              const keys = websearchResults
                                .filter((item) => websearchSelected[item.id])
                                .map((item) => item.citeKey)
                                .filter(Boolean);
                              if (keys.length > 0) {
                                insertAtCursor(`\\cite{${keys.join(',')}}`);
                                appendLog(setWebsearchLog, t('已插入选中引用到光标。'));
                              }
                            }}
                          >
                            {t('插入选中引用')}
                          </button>
                        </div>
                        <div className="tool-list">
                          {websearchResults.map((paper) => (
                            <label key={paper.id} className="tool-item">
                              <input
                                type="checkbox"
                                checked={Boolean(websearchSelected[paper.id])}
                                onChange={(event) => {
                                  const checked = event.target.checked;
                                  setWebsearchSelected((prev) => ({ ...prev, [paper.id]: checked }));
                                }}
                              />
                              <div>
                                <div className="tool-item-title">{paper.title}</div>
                                {paper.summary && <div className="muted">{paper.summary}</div>}
                                {paper.url && <div className="muted">{paper.url}</div>}
                                {paper.citeKey && <div className="muted">{t('cite')}: {paper.citeKey}</div>}
                              </div>
                              <button
                                className="btn ghost small"
                                onClick={() => {
                                  if (paper.citeKey) {
                                    insertAtCursor(`\\cite{${paper.citeKey}}`);
                                    appendLog(setWebsearchLog, t('已插入: {{cite}}', { cite: paper.citeKey }));
                                  }
                                }}
                              >
                                {t('插入引用')}
                              </button>
                            </label>
                          ))}
                        </div>
                        <div className="vision-result">
                          <div className="muted">{t('逐条总结')}</div>
                          <div className="tool-list">
                            {websearchResults.map((paper) => (
                              <div key={paper.id} className="tool-item summary-item">
                                <div>
                                  <div className="tool-item-title">{paper.title}</div>
                                  {paper.citeKey && <div className="muted">{t('cite')}: {paper.citeKey}</div>}
                                </div>
                                <textarea
                                  className="input"
                                  value={websearchItemNotes[paper.id] ?? paper.summary ?? ''}
                                  onChange={(event) =>
                                    setWebsearchItemNotes((prev) => ({ ...prev, [paper.id]: event.target.value }))
                                  }
                                  rows={3}
                                />
                              </div>
                            ))}
                          </div>
                        </div>
                      </>
                    )}
                    {websearchParagraph && (
                      <div className="vision-result">
                        <div className="muted">{t('综合总结')}</div>
                        <textarea
                          className="input"
                          value={websearchParagraph}
                          onChange={(event) => setWebsearchParagraph(event.target.value)}
                          rows={6}
                        />
                      </div>
                    )}
                    <div className="field">
                      <label>{t('Bib 文件')}</label>
                      <div className="ios-select-wrapper">
                        <button className="ios-select-trigger" onClick={() => setWsBibDropdownOpen(!wsBibDropdownOpen)}>
                          <span>{websearchTargetBib || t('(新建/选择 Bib 文件)')}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={wsBibDropdownOpen ? 'rotate' : ''}><path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </button>
                        {wsBibDropdownOpen && (
                          <div className="ios-dropdown dropdown-down">
                            <div className={`ios-dropdown-item ${!websearchTargetBib ? 'active' : ''}`} onClick={() => { setWebsearchTargetBib(''); setWsBibDropdownOpen(false); }}>
                              {t('(新建/选择 Bib 文件)')}
                              {!websearchTargetBib && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                            </div>
                            {bibFiles.map((p) => (
                              <div key={p} className={`ios-dropdown-item ${websearchTargetBib === p ? 'active' : ''}`} onClick={() => { setWebsearchTargetBib(p); setWsBibDropdownOpen(false); }}>
                                {p}
                                {websearchTargetBib === p && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                      <button className="btn ghost small" onClick={async () => {
                        const created = await createBibFile();
                        if (created) setWebsearchTargetBib(created);
                      }}>{t('新建 Bib')}</button>
                    </div>
                    <div className="field">
                      <label>{t('插入目标 TeX')}</label>
                      <div className="ios-select-wrapper">
                        <button className="ios-select-trigger" onClick={() => { setWsTexDropdownOpen(!wsTexDropdownOpen); setWsBibDropdownOpen(false); }}>
                          <span>{websearchTargetFile || '—'}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={wsTexDropdownOpen ? 'rotate' : ''}>
                            <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                          </svg>
                        </button>
                        {wsTexDropdownOpen && (
                          <div className="ios-dropdown dropdown-down">
                            {texFiles.map((p) => (
                              <div key={p} className={`ios-dropdown-item ${websearchTargetFile === p ? 'active' : ''}`} onClick={() => { setWebsearchTargetFile(p); setWsTexDropdownOpen(false); }}>
                                {p}
                                {websearchTargetFile === p && (
                                  <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="row">
                      <button className="btn" onClick={applyWebsearchInsert} disabled={websearchBusy}>
                        {t('一键写入 Bib + 插入总结')}
                      </button>
                    </div>
                  </div>
                </div>
              </>
            ) : activeSidebar === 'plot' ? (
              <>
                <div className="panel-header">
                  <div>{t('绘图')}</div>
                </div>
                <div className="tools-body">
                  <div className="tool-section">
                    <div className="tool-title">{t('表格 → 图表')}</div>
                    <div className="muted">{t('从选区表格生成图表（seaborn）')}</div>
                    <div className="field">
                      <label>{t('图表类型')}</label>
                      <div className="ios-select-wrapper">
                        <button className="ios-select-trigger" onClick={() => setPlotTypeDropdownOpen(!plotTypeDropdownOpen)}>
                          <span>{{ bar: t('Bar'), line: t('Line'), heatmap: t('Heatmap') }[plotType]}</span>
                          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={plotTypeDropdownOpen ? 'rotate' : ''}>
                            <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                          </svg>
                        </button>
                        {plotTypeDropdownOpen && (
                          <div className="ios-dropdown dropdown-down">
                            {([['bar', t('Bar')], ['line', t('Line')], ['heatmap', t('Heatmap')]] as [string, string][]).map(([val, label]) => (
                              <div key={val} className={`ios-dropdown-item ${plotType === val ? 'active' : ''}`} onClick={() => { setPlotType(val as 'bar' | 'line' | 'heatmap'); setPlotTypeDropdownOpen(false); }}>
                                {label}
                                {plotType === val && (
                                  <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                    <div className="field">
                      <label>{t('标题 (可选)')}</label>
                      <input
                        className="input"
                        value={plotTitle}
                        onChange={(event) => setPlotTitle(event.target.value)}
                        placeholder={t('Chart title')}
                      />
                    </div>
                    <div className="field">
                      <label>{t('文件名 (可选)')}</label>
                      <input
                        className="input"
                        value={plotFilename}
                        onChange={(event) => setPlotFilename(event.target.value)}
                        placeholder="plot.png"
                      />
                    </div>
                    <div className="field">
                      <label>{t('补充提示 (可选)')}</label>
                      <textarea
                        className="input"
                        value={plotPrompt}
                        onChange={(event) => setPlotPrompt(event.target.value)}
                        placeholder={t('例如：使用折线图，突出 Method A；加上 legend；设置 y 轴为 Accuracy')}
                        rows={2}
                      />
                    </div>
                    <div className="field">
                      <label>{t('Debug 重试次数')}</label>
                      <input
                        className="input"
                        type="number"
                        min={0}
                        max={5}
                        value={plotRetries}
                        onChange={(event) => setPlotRetries(Math.max(0, Math.min(5, Number(event.target.value) || 0)))}
                      />
                    </div>
                    <label className="checkbox-row">
                      <input
                        type="checkbox"
                        checked={plotAutoInsert}
                        onChange={(event) => setPlotAutoInsert(event.target.checked)}
                      />
                      {t('生成后插入 Figure')}
                    </label>
                    <div className="row">
                      <button className="btn" onClick={handlePlotGenerate} disabled={plotBusy}>
                        {plotBusy ? t('生成中...') : t('生成图表')}
                      </button>
                    </div>
                    {plotStatus && <div className="muted">{plotStatus}</div>}
                    {plotAssetPath && (
                      <div className="vision-result">
                        <div className="muted">{t('预览')}</div>
                        <img
                          src={blobUrl(projectId, plotAssetPath)}
                          alt={plotAssetPath}
                          style={{ width: '100%', borderRadius: '8px' }}
                        />
                        <div className="row">
                          <button className="btn ghost" onClick={() => insertFigureSnippet(plotAssetPath)}>{t('插入图模板')}</button>
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              </>
            ) : activeSidebar === 'review' ? (
              <>
                <div className="panel-header">
                  <div>{t('Review')}</div>
                </div>
                <div className="tools-body">
                  <div className="tool-section">
                    <div className="tool-title">{t('质量检查')}</div>
                    <div className="tool-desc">{t('AI 辅助检查论文质量，发现潜在问题')}</div>
                    <div className="review-buttons">
                      <button
                        className="review-btn"
                        onClick={async () => {
                          if (reviewReportBusy) return;
                          setReviewReportBusy(true);
                          setReviewReport(t('生成中...'));
                          setRightView('review');
                          try {
                            const res = await runAgent({
                              task: 'peer_review',
                              prompt: t('Read all .tex files in the project (start from the main file and any included sections). Use list_files and read_file tools to inspect content. Write a detailed reviewer-style report. Include: Summary, Strengths, Weaknesses, Questions, Missing Experiments, Writing/Clarity, Suggestions, Score (1-10), and Confidence. Output report text only; do not propose patches or code.'),
                              selection: '',
                              content: '',
                              mode: 'tools',
                              projectId,
                              activePath,
                              compileLog,
                              llmConfig,
                              interaction: 'agent',
                              history: []
                            });
                            setReviewReport(res.reply || t('无结果'));
                          } catch (err) {
                            setReviewReport(t('生成失败: {{error}}', { error: String(err) }));
                          } finally {
                            setReviewReportBusy(false);
                          }
                        }}
                      >
                        <span className="review-btn-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="8" y1="13" x2="16" y2="13"/><line x1="8" y1="17" x2="16" y2="17"/></svg></span>
                        <span className="review-btn-label">{t('详细评审报告')}</span>
                        <span className="review-btn-desc">{t('阅读项目并输出完整审稿意见')}</span>
                      </button>
                      <button
                        className="review-btn"
                        onClick={async () => {
                          const res = await runAgent({
                            task: 'consistency_check',
                            prompt: `Read all .tex files in the project using list_files and read_file tools. Perform a thorough consistency check across the entire paper. Check the following dimensions:

1. **Terminology consistency**: Identify terms that refer to the same concept but use different wording (e.g., "feature extraction" vs "feature engineering", "model" vs "network" vs "architecture" used interchangeably).

2. **Notation consistency**: Check if mathematical symbols and notation are used consistently (e.g., bold for vectors vs non-bold, x vs X for the same variable, inconsistent subscript/superscript conventions).

3. **Data and results consistency**: Verify that numbers, statistics, and experimental results mentioned in the abstract, introduction, method, and conclusion sections are consistent with those in tables and figures.

4. **Logic and claim consistency**: Check if claims made in the introduction/conclusion are actually supported by the experiments. Flag contradictions between sections.

5. **Reference consistency**: Check for undefined abbreviations, references to figures/tables/sections that don't exist, or mislabeled cross-references.

6. **Tense and style consistency**: Flag inconsistent use of tense (e.g., mixing past and present when describing experiments) or perspective (e.g., "we" vs "the authors" vs passive voice).

For each issue found, report in this format:

---
**[Category]** Terminology / Notation / Data / Logic / Reference / Style
**[Location]** file and approximate line or section
**[Issue]** Describe the inconsistency
**[Suggestion]** How to fix it
---

Here are examples of good findings:

Example 1:
**[Terminology]**
**[Location]** sections/method.tex, Section 3.1 vs sections/experiments.tex, Section 4
**[Issue]** The method section calls the module "Spatial Attention Block" but the experiments section refers to it as "Spatial Attention Module".
**[Suggestion]** Unify to one term throughout the paper, e.g., "Spatial Attention Module".

Example 2:
**[Data]**
**[Location]** sections/abstract.tex vs sections/experiments.tex, Table 2
**[Issue]** The abstract claims "93.2% accuracy on CIFAR-10" but Table 2 reports 92.8%.
**[Suggestion]** Update the abstract to match the actual result in Table 2.

Example 3:
**[Logic]**
**[Location]** sections/introduction.tex, paragraph 3 vs sections/conclusion.tex, paragraph 1
**[Issue]** The introduction states the method "does not require pre-training" but the conclusion mentions "after pre-training on ImageNet".
**[Suggestion]** Clarify whether pre-training is used and make both sections consistent.

Example 4:
**[Notation]**
**[Location]** sections/method.tex, Eq. (3) vs Eq. (7)
**[Issue]** Eq. (3) uses bold lowercase h for hidden states, but Eq. (7) uses non-bold italic h for the same variable.
**[Suggestion]** Use bold h consistently for hidden state vectors.

Be thorough. Read ALL .tex files before reporting. Group findings by category. If no issues are found in a category, state that explicitly.`,
                            selection: '',
                            content: '',
                            mode: 'tools',
                            projectId,
                            activePath,
                            compileLog,
                            llmConfig,
                            interaction: 'agent',
                            history: []
                          });
                          setReviewNotes((prev) => [{ title: t('一致性检查'), content: res.reply || t('无结果') }, ...prev]);
                          if (res.patches && res.patches.length > 0) {
                            const nextPending = res.patches.map((patch) => ({
                              filePath: patch.path,
                              original: files[patch.path] ?? '',
                              proposed: patch.content,
                              diff: patch.diff
                            }));
                            setPendingChanges(nextPending);
                            setRightView('diff');
                          }
                        }}
                      >
                        <span className="review-btn-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg></span>
                        <span className="review-btn-label">{t('一致性检查')}</span>
                        <span className="review-btn-desc">{t('检查术语、符号一致性')}</span>
                      </button>
                      <button
                        className="review-btn"
                        onClick={async () => {
                          const res = await runAgent({
                            task: 'missing_citations',
                            prompt: t('Find claims that likely need citations and list them.'),
                            selection: '',
                            content: '',
                            mode: 'tools',
                            projectId,
                            activePath,
                            compileLog,
                            llmConfig,
                            interaction: 'agent',
                            history: []
                          });
                          setReviewNotes((prev) => [{ title: t('引用缺失'), content: res.reply || t('无结果') }, ...prev]);
                        }}
                      >
                        <span className="review-btn-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg></span>
                        <span className="review-btn-label">{t('引用缺失')}</span>
                        <span className="review-btn-desc">{t('查找需要引用的论述')}</span>
                      </button>
                      <button
                        className="review-btn"
                        onClick={async () => {
                          const res = await runAgent({
                            task: 'compile_summary',
                            prompt: t('Summarize compile log errors and suggested fixes.'),
                            selection: compileLog,
                            content: '',
                            mode: 'direct',
                            projectId,
                            activePath,
                            compileLog,
                            llmConfig,
                            interaction: 'agent',
                            history: []
                          });
                          setReviewNotes((prev) => [{ title: t('编译日志总结'), content: res.reply || t('无结果') }, ...prev]);
                        }}
                      >
                        <span className="review-btn-icon"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/></svg></span>
                        <span className="review-btn-label">{t('编译日志总结')}</span>
                        <span className="review-btn-desc">{t('总结错误并给出修复建议')}</span>
                      </button>
                    </div>
                  </div>
                  {reviewNotes.length > 0 && (
                    <div className="tool-section">
                      <div className="tool-title">{t('结果')}</div>
                      {reviewNotes.map((note, idx) => (
                        <div key={`${note.title}-${idx}`} className="review-item">
                          <div className="review-title">{note.title}</div>
                          <div className="review-content markdown-body">
                            <ReactMarkdown remarkPlugins={[remarkGfm]}>{note.content}</ReactMarkdown>
                          </div>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </>
            ) : null}
          </aside>
        )}

        {sidebarOpen && (
          <div
            className="drag-handle vertical sidebar-handle"
            onMouseDown={(e) => startColumnDrag('left', e)}
          />
        )}

        <section className="panel editor-panel">
          <div className="nm-file-tabs">
            <div className="nm-file-tab active" title={activePath}>
              <span className="nm-file-tab-name">{activePath ? activePath.split('/').pop() : t('No file')}</span>
              {currentHeading && <span className="nm-file-tab-heading">· {currentHeading.title}</span>}
            </div>
          </div>
          <div className="editor-toolbar nm-insert-bar">
            <div className="nm-menu">
              <button className="nm-icon-btn" onClick={() => setNmMenu(nmMenu === 'section' ? '' : 'section')} aria-haspopup="menu">
                <IconSection size={15} /> {t('Section')} <IconChevronDown size={13} />
              </button>
              {nmMenu === 'section' && (
                <>
                  <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                  <div className="nm-menu-list left" role="menu" onClick={() => setNmMenu('')}>
                    <button className="nm-menu-item" onClick={insertSectionSnippet}>\section</button>
                    <button className="nm-menu-item" onClick={insertSubsectionSnippet}>\subsection</button>
                    <button className="nm-menu-item" onClick={insertSubsubsectionSnippet}>\subsubsection</button>
                  </div>
                </>
              )}
            </div>
            <div className="nm-menu">
              <button className="nm-icon-btn" onClick={() => setNmMenu(nmMenu === 'list' ? '' : 'list')} aria-haspopup="menu">
                <IconList size={15} /> {t('List')} <IconChevronDown size={13} />
              </button>
              {nmMenu === 'list' && (
                <>
                  <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                  <div className="nm-menu-list left" role="menu" onClick={() => setNmMenu('')}>
                    <button className="nm-menu-item" onClick={insertItemizeSnippet}>{t('Itemize')}</button>
                    <button className="nm-menu-item" onClick={insertEnumerateSnippet}>{t('Enumerate')}</button>
                  </div>
                </>
              )}
            </div>
            <div className="nm-menu">
              <button className="nm-icon-btn" onClick={() => setNmMenu(nmMenu === 'equation' ? '' : 'equation')} aria-haspopup="menu">
                <IconSigma size={15} /> {t('Equation')} <IconChevronDown size={13} />
              </button>
              {nmMenu === 'equation' && (
                <>
                  <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                  <div className="nm-menu-list left" role="menu" onClick={() => setNmMenu('')}>
                    <button className="nm-menu-item" onClick={insertEquationSnippet}>{t('Equation')}</button>
                    <button className="nm-menu-item" onClick={insertAlgorithmSnippet}>{t('Algorithm')}</button>
                  </div>
                </>
              )}
            </div>
            <div className="nm-menu">
              <button className="nm-icon-btn" onClick={() => setNmMenu(nmMenu === 'insert' ? '' : 'insert')} aria-haspopup="menu" title={t('Figure, table, listing, citation, reference, label')}>
                <IconInsert size={15} /> <span className="nm-hide-narrow">{t('Insert')}</span> <IconChevronDown size={13} />
              </button>
              {nmMenu === 'insert' && (
                <>
                  <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                  <div className="nm-menu-list left" role="menu" onClick={() => setNmMenu('')}>
                    <button className="nm-menu-item" onClick={insertFigureTemplate}>{t('Figure')}</button>
                    <button className="nm-menu-item" onClick={insertTableSnippet}>{t('Table')}</button>
                    <button className="nm-menu-item" onClick={insertListingSnippet}>{t('Listing')}</button>
                    <div className="nm-menu-sep" />
                    <button className="nm-menu-item" onClick={insertCiteSnippet}>{t('Cite')}</button>
                    <button className="nm-menu-item" onClick={insertRefSnippet}>{t('Ref')}</button>
                    <button className="nm-menu-item" onClick={insertLabelSnippet}>{t('Label')}</button>
                  </div>
                </>
              )}
            </div>
            <div className="toolbar-spacer" />
            <div className="nm-zoom" title={t('Editor zoom — Cmd/Ctrl + scroll or pinch over the text, Cmd/Ctrl + = / −')}>
              <button className="nm-icon-btn borderless" onClick={() => editorZoomRef.current(-1)} aria-label={t('Zoom out')}><IconMinus size={14} /></button>
              <button className="nm-zoom-label" onClick={() => editorZoomRef.current('reset')}>{Math.round((editorFontSize / 11) * 100)}%</button>
              <button className="nm-icon-btn borderless" onClick={() => editorZoomRef.current(1)} aria-label={t('Zoom in')}><IconPlus size={14} /></button>
            </div>
            <button className="nm-icon-btn borderless" onClick={() => { const v = cmViewRef.current; if (v) { cmUndo(v); v.focus(); } }} title={t('Undo (Cmd/Ctrl + Z)')} aria-label={t('Undo')}><IconUndo size={16} /></button>
            <button className="nm-icon-btn borderless" onClick={() => { const v = cmViewRef.current; if (v) { cmRedo(v); v.focus(); } }} title={t('Redo (Cmd/Ctrl + Shift + Z)')} aria-label={t('Redo')}><IconRedo size={16} /></button>
          </div>
          <div
            className="editor-split"
            ref={editorSplitRef}
          >
            <div className="editor-area" ref={editorAreaRef}>
              {externalChange && externalChange.path === activePath && (
                <div className="nm-external" role="alert">
                  <span>
                    <b>{externalChange.path}</b> {t('was changed outside Numenor (e.g. on another computer through Google Drive) while you had unsaved changes here.')}
                  </span>
                  <button className="btn small nm-primary" onClick={() => { loadExternalVersion(externalChange.path, externalChange.content); setExternalChange(null); setStatus(t('Loaded the new version of {{file}}.', { file: externalChange.path })); }}>
                    {t('Load the new version')}
                  </button>
                  <button className="btn small ghost" onClick={() => { setExternalChange(null); saveActiveFile().catch(() => {}); }}>
                    {t('Keep mine (overwrite it)')}
                  </button>
                </div>
              )}
              <div ref={editorHostRef} className="editor-host" style={{ '--editor-font-size': `${editorFontSize}px` } as React.CSSProperties} />
              <div className="editor-hint muted">{t('快捷键: Option/Alt + / 或 Cmd/Ctrl + Space 补全；Cmd/Ctrl + / 注释；Cmd/Ctrl + F 搜索；Cmd/Ctrl + S 保存')} · {t('Cmd/Ctrl + Shift + J: show in PDF')}</div>
              {(inlineSuggestionText || isSuggesting) && suggestionPos && (
                <div
                  className={`suggestion-popover ${isSuggesting && !inlineSuggestionText ? 'loading' : ''}`}
                  style={{ left: suggestionPos.left, top: suggestionPos.top }}
                >
                  {isSuggesting && !inlineSuggestionText ? (
                    <div className="suggestion-loading">
                      <span className="spinner" />
                      {t('AI 补全中...')}
                    </div>
                  ) : (
                    <>
                      <div className="suggestion-preview">{inlineSuggestionText}</div>
                      <div className="row">
                        <button className="btn" onClick={() => acceptSuggestionRef.current()}>{t('接受')}</button>
                        <button className="btn ghost" onClick={() => clearSuggestionRef.current()}>{t('拒绝')}</button>
                      </div>
                    </>
                  )}
                </div>
              )}
            </div>
          </div>
        </section>

        <div
          className="drag-handle vertical main-handle"
          onMouseDown={(e) => startColumnDrag('right', e)}
        >
          {/* Maziar: jump between the LaTeX and the PDF. */}
          <div
            className="sync-buttons"
            onMouseDown={(e) => {
              // Don't start a divider drag, and keep the current PDF/editor selection for the button to read.
              e.stopPropagation();
              e.preventDefault();
            }}
          >
            <button
              className="sync-btn"
              onClick={() => forwardSyncRef.current()}
              disabled={!pdfUrl}
              title={t('Show the selected text (or the cursor’s line) in the PDF — Cmd/Ctrl + Shift + J')}
            >
              →
            </button>
            <button
              className="sync-btn"
              onClick={reverseSyncFromPdf}
              disabled={!pdfUrl}
              title={t('Show the text selected in the PDF (or where you last clicked) in the LaTeX — or double-click the PDF')}
            >
              ←
            </button>
          </div>
        </div>

        <section className="panel pdf-panel">
          <div className="panel-header">
            <div className="nm-pane-title">{rightView === 'pdf' ? t('PDF Preview') : t('Preview')}</div>
            <div className="header-controls">
              <div className="ios-select-wrapper">
                <button
                  className="ios-select-trigger"
                  onClick={() => setRightViewDropdownOpen(!rightViewDropdownOpen)}
                >
                  <span>{RIGHT_VIEW_OPTIONS(t).find((item) => item.value === rightView)?.label || 'PDF'}</span>
                  <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={rightViewDropdownOpen ? 'rotate' : ''}>
                    <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </button>
                {rightViewDropdownOpen && (
                  <div className="ios-dropdown dropdown-down">
                    {RIGHT_VIEW_OPTIONS(t).map((item) => (
                      <div
                        key={item.value}
                        className={`ios-dropdown-item ${rightView === item.value ? 'active' : ''}`}
                        onClick={() => {
                          setRightView(item.value as 'pdf' | 'figures' | 'diff' | 'log' | 'toc' | 'review');
                          setRightViewDropdownOpen(false);
                        }}
                      >
                        {item.label}
                        {rightView === item.value && (
                          <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                            <path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
                          </svg>
                        )}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </div>
          </div>
          <div className="right-body">
            <div className="view-content">
              {/* Maziar: kept mounted while other views are shown, so the PDF keeps its place and zoom. */}
              <div className="pdf-view-wrap" style={rightView === 'pdf' ? undefined : { display: 'none' }}>
                  <div className="pdf-toolbar nm-pdf-toolbar">
                    <div className="nm-pager">
                      <button className="nm-icon-btn borderless" disabled={!pdfUrl || pdfPage.page <= 1} onClick={() => goToPdfPage(-1)} aria-label={t('Previous page')}><IconChevronLeft size={16} /></button>
                      <span className="nm-page-pill">{pdfPage.total ? `${pdfPage.page} / ${pdfPage.total}` : '– / –'}</span>
                      <button className="nm-icon-btn borderless" disabled={!pdfUrl || pdfPage.page >= pdfPage.total} onClick={() => goToPdfPage(1)} aria-label={t('Next page')}><IconChevronRight size={16} /></button>
                    </div>
                    <div className="nm-seg">
                      <button className="nm-icon-btn borderless" onClick={() => pdfViewerRef.current?.zoomOut()} disabled={!pdfUrl} title={t('Zoom out — or Cmd/Ctrl + scroll, or pinch')} aria-label={t('Zoom out')}><IconMinus size={15} /></button>
                      <button className="nm-icon-btn borderless" onClick={() => pdfViewerRef.current?.zoomIn()} disabled={!pdfUrl} title={t('Zoom in — or Cmd/Ctrl + scroll, or pinch')} aria-label={t('Zoom in')}><IconPlus size={15} /></button>
                    </div>
                    <div className="nm-menu">
                      <button className="nm-icon-btn" disabled={!pdfUrl} onClick={() => setNmMenu(nmMenu === 'fit' ? '' : 'fit')} aria-haspopup="menu" title={pdfScaleLabel}>
                        {pdfZoom.mode === 'fitWidth' ? t('适合宽度') : pdfZoom.mode === 'fitPage' ? t('Fit page') : pdfScaleLabel} <IconChevronDown size={13} />
                      </button>
                      {nmMenu === 'fit' && (
                        <>
                          <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                          <div className="nm-menu-list left" role="menu" onClick={() => setNmMenu('')}>
                            <button className={`nm-menu-item ${pdfZoom.mode === 'fitWidth' ? 'on' : ''}`} onClick={() => pdfViewerRef.current?.fitWidth()}>{t('适合宽度')}</button>
                            <button className={`nm-menu-item ${pdfZoom.mode === 'fitPage' ? 'on' : ''}`} onClick={() => pdfViewerRef.current?.fitPage()}>{t('Fit page')}</button>
                            <button className={`nm-menu-item ${pdfZoom.mode === 'custom' && Math.abs(pdfZoom.scale - 1) < 0.01 ? 'on' : ''}`} onClick={() => pdfViewerRef.current?.actualSize()}>100%</button>
                            <div className="nm-menu-sep" />
                            <div className="nm-menu-label">{t('Zoom')}: {pdfScaleLabel}</div>
                          </div>
                        </>
                      )}
                    </div>
                    <button
                      className="nm-icon-btn"
                      onClick={() => forwardSyncRef.current()}
                      disabled={!pdfUrl}
                      title={t('Show the cursor’s line in the PDF (Cmd/Ctrl + Shift + J). Double-click the PDF to jump back to the source.')}
                    >
                      <IconSync size={15} /> {t('Sync')}
                    </button>
                    <div className="nm-spacer" />
                    <button className="nm-icon-btn" onClick={popOutPdf} title={t('Open the PDF in a separate window — the editor gets the full width')} aria-label={t('Open PDF in a separate window')}><IconPopOut size={16} /></button>
                    <button className="nm-icon-btn" onClick={downloadPdf} disabled={!pdfUrl} title={t('下载 PDF')} aria-label={t('下载 PDF')}><IconDownload size={16} /></button>
                    <div className="nm-menu">
                      <button className="nm-icon-btn borderless" onClick={() => setNmMenu(nmMenu === 'pdfmore' ? '' : 'pdfmore')} aria-haspopup="menu" aria-label={t('More PDF tools')}><IconDots size={18} /></button>
                      {nmMenu === 'pdfmore' && (
                        <>
                          <div className="nm-menu-backdrop" onClick={() => setNmMenu('')} />
                          <div className="nm-menu-list" role="menu" onClick={() => setNmMenu('')}>
                            <button className={`nm-menu-item ${pdfSpread ? 'on' : ''}`} disabled={!pdfUrl} onClick={() => setPdfSpread((prev) => !prev)}>{pdfSpread ? '✓ ' : ''}{t('双页')}</button>
                            <button className={`nm-menu-item ${pdfAnnotateMode ? 'on' : ''}`} disabled={!pdfUrl} onClick={() => setPdfAnnotateMode((prev) => !prev)}>{pdfAnnotateMode ? '✓ ' : ''}{t('注释')}</button>
                            <div className="nm-menu-sep" />
                            <button className="nm-menu-item" disabled={!pdfUrl} onClick={() => forwardSyncRef.current()}>{t('Source → PDF')}</button>
                            <button className="nm-menu-item" disabled={!pdfUrl} onClick={() => reverseSyncFromPdf()}>{t('PDF → Source')}</button>
                            <div className="nm-menu-sep" />
                            <button className="nm-menu-item" onClick={popOutPdf}>{t('Open PDF in a separate window')}</button>
                            <div className="nm-menu-sep" />
                            <button className="nm-menu-item" onClick={() => setDiagnosticsOpen(true)}>{t('Problems')}</button>
                            <button className="nm-menu-item" onClick={() => setRightView('log')}>{t('Full log')}</button>
                          </div>
                        </>
                      )}
                    </div>
                  </div>
                  {missingFiles.length > 0 && (
                    <div className="nm-missing" role="alert">
                      <div className="nm-missing-title">
                        {missingFiles.length === 1 ? t('LaTeX can’t find a file') : t('LaTeX can’t find {{count}} files', { count: missingFiles.length })}
                        <button className="nm-icon-btn borderless" onClick={() => setMissingFiles([])} title={t('Hide')}><IconClose size={13} /></button>
                      </div>
                      {missingFiles.map((m) => {
                        const when = m.at ? new Date(m.at).toLocaleString([], { dateStyle: 'short', timeStyle: 'short' }) : '';
                        const back = m.folderMove ? { from: m.folderMove.to, to: m.folderMove.from } : m.movedTo ? { from: m.movedTo, to: m.file } : m.foundAt && !m.deleted ? { from: m.foundAt, to: m.file } : null;
                        return (
                          <div key={m.file} className="nm-missing-row">
                            <code>{m.file}</code>
                            <span className="nm-missing-why">
                              {m.folderMove
                                ? t('its folder {{from}} was moved to {{to}}', { from: m.folderMove.from, to: m.folderMove.to })
                                : m.movedTo
                                  ? t('was moved to {{to}}', { to: m.movedTo })
                                  : m.deleted
                                    ? t('was deleted')
                                    : m.foundAt
                                      ? t('isn’t there, but {{found}} has the same name', { found: m.foundAt })
                                      : t('isn’t in the project — check the name in \\input / \\includegraphics / \\bibliography, or add the file')}
                              {m.by && (m.movedTo || m.deleted || m.folderMove) ? ` ${t('by {{name}}', { name: m.by })}` : ''}
                              {when && (m.movedTo || m.deleted || m.folderMove) ? ` · ${when}` : ''}
                              {m.deleted && m.foundAt ? ` — ${t('a file with the same name is in {{found}}', { found: m.foundAt })}` : ''}
                            </span>
                            {back && !viewOnly && (
                              <button
                                className="btn small nm-primary"
                                disabled={Boolean(missingBusy)}
                                onClick={async () => {
                                  if (!projectId) return;
                                  setMissingBusy(m.file);
                                  try {
                                    await renamePath(projectId, back.from, back.to);
                                    await refreshTree();
                                    setStatus(t('Moved {{from}} back to {{to}}', { from: back.from, to: back.to }));
                                    setMissingFiles((list) => list.filter((x) => x.file !== m.file));
                                    compileRef.current().catch(() => {});
                                  } catch (err) {
                                    setStatus(t('Couldn’t move it back: {{error}}', { error: (err as Error).message }));
                                  } finally {
                                    setMissingBusy('');
                                  }
                                }}
                              >
                                {missingBusy === m.file ? t('Moving…') : m.foundAt && !m.movedTo && !m.folderMove ? t('Move it here') : t('Move it back')}
                              </button>
                            )}
                            {m.deleted && (
                              <Link className="btn small ghost" to={`/history/${projectId}`}>{t('Open History')}</Link>
                            )}
                          </div>
                        );
                      })}
                    </div>
                  )}
                  {pdfUrl && pdfFind.open && (
                    <div className="nm-pdf-find" role="search">
                      <input
                        ref={pdfFindInputRef}
                        className="input nm-pdf-find-input"
                        placeholder={t('Search in the PDF')}
                        value={pdfFind.query}
                        onChange={(e) => {
                          const q = e.target.value;
                          setPdfFind((f) => ({ ...f, query: q }));
                          window.clearTimeout(pdfFindTimerRef.current);
                          pdfFindTimerRef.current = window.setTimeout(() => runPdfFind(q, 0).catch(() => {}), 250);
                        }}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') { e.preventDefault(); runPdfFind(pdfFind.query, e.shiftKey ? -1 : 1).catch(() => {}); }
                          if (e.key === 'Escape') { e.preventDefault(); closePdfFind(); }
                        }}
                        spellCheck={false}
                      />
                      <span className="muted nm-pdf-find-count">
                        {pdfFind.busy ? '…' : pdfFind.query.trim() ? (pdfFind.total ? `${pdfFind.index} / ${pdfFind.total}` : t('No matches')) : ''}
                      </span>
                      <button className="nm-icon-btn borderless" onClick={() => runPdfFind(pdfFind.query, -1)} disabled={!pdfFind.total} title={t('Previous (Shift + Enter)')}>↑</button>
                      <button className="nm-icon-btn borderless" onClick={() => runPdfFind(pdfFind.query, 1)} disabled={!pdfFind.total} title={t('Next (Enter)')}>↓</button>
                      <button className="nm-icon-btn borderless" onClick={closePdfFind} title={t('Close (Esc)')}><IconClose size={14} /></button>
                    </div>
                  )}
                  {pdfUrl ? (
                    <PdfViewer
                      ref={pdfViewerRef}
                      pdfUrl={pdfUrl}
                      spread={pdfSpread}
                      onOutline={handlePdfOutline}
                      onZoomChange={setPdfZoom}
                      onPageChange={(page, total) => setPdfPage({ page, total })}
                      rememberKey={`maziar.numenor.${projectId}.pdfPos`}
                      onReverseSync={(page, x, y) => {
                        reverseSync(page, x, y).catch(() => {});
                      }}
                      annotations={pdfAnnotations}
                      annotateMode={pdfAnnotateMode}
                      onAddAnnotation={addPdfAnnotation}
                      containerRef={pdfContainerRef}
                    />
                  ) : (
                    <div className="muted pdf-empty-message">{t('尚未生成 PDF')}</div>
                  )}

                  {diagnosticsOpen && (
                    <div className="diag-panel open">
                      <div className="diag-header">
                        <span className="diag-title">{t('Problems')}</span>
                        <span className={`diag-count error ${diagnosticCounts.error ? '' : 'zero'}`}>{t('{{count}} errors', { count: diagnosticCounts.error })}</span>
                        <span className={`diag-count warning ${diagnosticCounts.warning ? '' : 'zero'}`}>{t('{{count}} warnings', { count: diagnosticCounts.warning })}</span>
                        {diagnosticCounts.badbox > 0 && <span className="diag-count badbox">{t('{{count}} layout', { count: diagnosticCounts.badbox })}</span>}
                        <span className="diag-spacer" />
                        <button
                          className="btn ghost small"
                          onClick={(event) => {
                            event.stopPropagation();
                            setRightView('log');
                          }}
                        >
                          {t('Full log')}
                        </button>
                        <button className="nm-icon-btn borderless" onClick={() => setDiagnosticsOpen(false)} aria-label={t('Close')}><IconClose size={14} /></button>
                      </div>
                      {diagnosticsOpen && (
                        <div className="diag-list">
                          {diagnostics.length === 0 && <div className="muted diag-empty">{t('No errors or warnings in the last compile.')}</div>}
                          {diagnostics.map((d: LatexDiagnostic, idx: number) => {
                            const linkable = Boolean(d.file && projectFileSet.has(d.file));
                            return (
                              <button
                                key={`${d.severity}-${d.file}-${d.line}-${idx}`}
                                className={`diag-item ${d.severity} ${linkable ? 'linkable' : ''}`}
                                onClick={() => linkable && jumpToError(d)}
                                title={d.detail || d.message}
                              >
                                <span className="diag-sev">{d.severity === 'error' ? '✕' : d.severity === 'warning' ? '!' : '▭'}</span>
                                <span className="diag-msg">{d.message}</span>
                                {d.file && <span className="diag-loc">{d.file}{d.line ? `:${d.line}` : ''}</span>}
                              </button>
                            );
                          })}
                        </div>
                      )}
                    </div>
                  )}
                  {pdfAnnotations.length > 0 && (
                    <div className="pdf-annotations">
                      <div className="muted">{t('注释')}</div>
                      <div className="annotation-list">
                        {pdfAnnotations.map((note) => (
                          <div key={note.id} className="annotation-item">
                            <button
                              className="annotation-link"
                              onClick={() => scrollToPdfPage(note.page)}
                            >
                              P{note.page}
                            </button>
                            <div className="annotation-text">{note.text}</div>
                            <button
                              className="annotation-remove"
                              onClick={() =>
                                setPdfAnnotations((prev) => prev.filter((item) => item.id !== note.id))
                              }
                            >
                              ✕
                            </button>
                          </div>
                        ))}
                      </div>
                    </div>
                  )}
              </div>
              {rightView === 'toc' && (
                <div className="toc-panel">
                  <div className="toc-title">{t('目录')}</div>
                  {pdfOutline.length === 0 ? (
                    <div className="muted">{t('暂无目录信息。')}</div>
                  ) : (
                    <div className="toc-list">
                      {pdfOutline.map((item, idx) => (
                        <button
                          key={`${item.title}-${idx}`}
                          className={`toc-item level-${item.level}`}
                          onClick={() => {
                            if (item.page) {
                              setRightView('pdf');
                              scrollToPdfPage(item.page);
                            }
                          }}
                        >
                          <span className="toc-title-text">{item.title}</span>
                          {item.page && <span className="toc-page">P{item.page}</span>}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )}
              {rightView === 'figures' && (
                <div className="figure-panel-v2">
                  <div className="figure-topbar">
                    <div className="ios-select-wrapper" style={{ flex: 1 }}>
                      <button className="ios-select-trigger" onClick={() => setFigureDropdownOpen(!figureDropdownOpen)}>
                        <span>{selectedFigure || t('选择图片进行预览。')}</span>
                        <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={figureDropdownOpen ? 'rotate' : ''}>
                          <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                        </svg>
                      </button>
                      {figureDropdownOpen && (
                        <div className="ios-dropdown dropdown-down">
                          {figureFiles.map((item) => (
                            <div key={item.path} className={`ios-dropdown-item ${selectedFigure === item.path ? 'active' : ''}`} onClick={() => { setSelectedFigure(item.path); setFigureDropdownOpen(false); }}>
                              {item.path}
                              {selectedFigure === item.path && (
                                <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                              )}
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                    {selectedFigure && (
                      <button
                        className="figure-insert-btn"
                        onClick={() => insertFigureSnippet(selectedFigure)}
                      >
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 5v14"/><path d="M5 12h14"/></svg>
                        {t('插入到光标')}
                      </button>
                    )}
                  </div>
                  <div className="figure-display">
                    {selectedFigure ? (
                      selectedFigure.toLowerCase().endsWith('.pdf') ? (
                        <object data={blobUrl(projectId, selectedFigure)} type="application/pdf" />
                      ) : (
                        <img src={blobUrl(projectId, selectedFigure)} alt={selectedFigure} />
                      )
                    ) : (
                      <div className="figure-empty">
                        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg>
                        <span>{t('选择图片进行预览。')}</span>
                      </div>
                    )}
                  </div>
                </div>
              )}
              {rightView === 'diff' && (
                <div className="diff-panel">
                  <div className="diff-title">{t('Diff Preview ({{count}})', { count: pendingGrouped.length })}</div>
                  {pendingGrouped.length === 0 && <div className="muted">{t('暂无待确认修改。')}</div>}
                  {pendingGrouped.map((change) => (
                    (() => {
                      const rows = buildSplitDiff(change.original, change.proposed);
                      return (
                        <div key={change.filePath} className="diff-item">
                          <div className="diff-header">
                            <div className="diff-path">{change.filePath}</div>
                            <button className="btn ghost" onClick={() => setDiffFocus(change)}>{t('放大')}</button>
                          </div>
                          <SplitDiffView rows={rows} />
                          <div className="row">
                            <button className="btn" onClick={() => applyPending(change)}>{t('应用此修改')}</button>
                            <button className="btn ghost" onClick={() => discardPending(change)}>{t('放弃')}</button>
                          </div>
                        </div>
                      );
                    })()
                  ))}
                  {pendingGrouped.length > 1 && (
                    <div className="row">
                      <button className="btn" onClick={() => applyPending()}>{t('应用全部')}</button>
                      <button className="btn ghost" onClick={() => discardPending()}>{t('全部放弃')}</button>
                    </div>
                  )}
                </div>
              )}
              {rightView === 'log' && (
                <div className="log-panel">
                  <div className="log-title">
                    {t('Compile Log')}
                    <button className="btn ghost log-action" onClick={diagnoseCompile} disabled={diagnoseBusy}>
                      {diagnoseBusy ? (
                        <span className="suggestion-loading">
                          <span className="spinner" />
                          {t('诊断中...')}
                        </span>
                      ) : (
                        t('一键诊断')
                      )}
                    </button>
                  </div>
                  {diagnostics.length > 0 && (
                    <div className="log-errors">
                      {diagnostics.map((error, idx) => (
                        <button
                          key={`${error.message}-${idx}`}
                          className={`error-item diag-${error.severity}`}
                          onClick={() => jumpToError(error)}
                          title={error.detail || error.message}
                        >
                          <span className="error-tag">{error.severity === 'error' ? '!' : 'w'}</span>
                          <span className="error-text">{error.message}</span>
                          {error.line && <span className="error-line">{error.file ? `${error.file}:` : 'L'}{error.line}</span>}
                        </button>
                      ))}
                    </div>
                  )}
                  <pre className="log-content">{compileLog || t('暂无编译日志')}</pre>
                </div>
              )}
              {rightView === 'review' && (
                <div className="log-panel">
                  <div className="log-title">{t('评审报告')}</div>
                  <div className="log-content markdown-body">
                    {reviewReport ? (
                      <ReactMarkdown remarkPlugins={[remarkGfm]}>{reviewReport}</ReactMarkdown>
                    ) : (
                      t('暂无评审报告')
                    )}
                  </div>
                </div>
              )}
            </div>
          </div>
        </section>
      </main>

      {/* Redesign: slim status bar — compile/save state, problem counts, latest message, log. */}
      <footer className="nm-statusbar" role="status">
        <span className={`nm-stat ${isCompiling ? 'busy' : compileState === 'failed' ? 'bad' : compileState === 'ok' ? 'good' : ''}`}>
          {isCompiling ? <IconSpinner size={15} className="nm-spin" /> : compileState === 'failed' ? <IconAlert size={15} /> : compileState === 'ok' ? <IconCheckCircle size={15} /> : <IconAlert size={15} />}
          {isCompiling ? t('Compiling…') : compileState === 'failed' ? t('Compile failed') : compileState === 'ok' ? t('Compiled') : t('Not compiled')}
        </span>
        <span className="nm-stat-sep" />
        <span className={`nm-stat ${isSaving ? 'busy' : isDirty ? 'warn' : 'good'} ${savePulse ? 'pulse' : ''}`}>
          {isSaving ? <IconSpinner size={15} className="nm-spin" /> : isDirty ? <span className="nm-dirty-dot" /> : <IconCheckCircle size={15} />}
          {isSaving ? t('保存中...') : isDirty ? t('未保存') : t('已保存')}
        </span>
        <span className="nm-stat-sep" />
        <button className={`nm-stat-btn ${diagnosticCounts.error ? 'bad' : ''}`} onClick={() => { setRightView('pdf'); setDiagnosticsOpen(true); }}>
          {t('{{count}} errors', { count: diagnosticCounts.error })}
        </button>
        <span className="nm-stat-sep" />
        <button className={`nm-stat-btn ${diagnosticCounts.warning ? 'warn' : ''}`} onClick={() => { setRightView('pdf'); setDiagnosticsOpen(true); }}>
          {t('{{count}} warnings', { count: diagnosticCounts.warning })}
        </button>
        <span className="nm-stat-sep" />
        <button className="nm-stat-btn" onClick={() => { setRightView('pdf'); setDiagnosticsOpen(true); }} title={t('Overfull and underfull boxes')}>
          <IconLayers size={15} /> {t('{{count}} layout', { count: diagnosticCounts.badbox })}
        </button>
        {spellAvailable && (
          <>
            <span className="nm-stat-sep" />
            <span className="nm-stat-spell">
              <button
                className={`nm-stat-btn spell-toggle ${spellEnabled ? 'active' : ''} ${spellEnabled && spellApplies && !spellInfo.checking && spellInfo.count > 0 ? 'bad' : ''}`}
                onClick={() => (spellEnabled ? setSpellPanelOpen((open) => !open) : setSpellEnabled(true))}
                title={spellInfo.error || (spellEnabled ? t('Show the spelling and grammar mistakes in this file') : t('Turn spelling & grammar checking on (macOS)'))}
                aria-expanded={spellPanelOpen}
              >
                {t('Spelling')}
                {spellEnabled && spellApplies && (
                  <span className={`spell-badge ${spellInfo.error ? 'error' : ''}`}>{spellInfo.checking ? '…' : spellInfo.error ? '!' : spellInfo.count}</span>
                )}
              </button>
              <select
                className="spell-lang"
                value={spellLanguage}
                onChange={(event) => setSpellLanguage(event.target.value)}
                disabled={!spellEnabled}
                title={t('Document language')}
              >
                {['en_US', 'en_GB', ...spellLanguageList.filter((code) => !['en', 'en_US', 'en_GB'].includes(code))]
                  .concat(spellLanguageList.length || ['en_US', 'en_GB'].includes(spellLanguage) ? [] : [spellLanguage])
                  .map((code) => (
                    <option key={code} value={code}>
                      {code === 'en_US' ? t('English (US)') : code === 'en_GB' ? t('English (UK)') : languageName(code)}
                    </option>
                  ))}
              </select>
              {spellPanelOpen && spellEnabled && (
                <>
                  <div className="nm-menu-backdrop" onClick={() => setSpellPanelOpen(false)} />
                  <div className="nm-spell-panel" role="dialog" aria-label={t('Spelling')}>
                    <div className="nm-spell-panel-head">
                      <b>{t('Spelling & grammar')}</b>
                      <span className="muted">{activePath ? activePath.split('/').pop() : ''}</span>
                    </div>
                    <div className="nm-spell-panel-list">
                      {!spellApplies ? (
                        <div className="muted nm-spell-panel-empty">{t('This file type isn’t checked.')}</div>
                      ) : spellInfo.error ? (
                        <div className="share-error">{spellInfo.error}</div>
                      ) : spellInfo.checking && !(spellInfo.issues || []).length ? (
                        <div className="muted nm-spell-panel-empty">{t('Checking…')}</div>
                      ) : !(spellInfo.issues || []).length ? (
                        <div className="muted nm-spell-panel-empty">{t('No mistakes found.')}</div>
                      ) : (
                        (spellInfo.issues || []).map((issue, i) => {
                          const view = cmViewRef.current;
                          const pos = Math.min(issue.from, view ? view.state.doc.length : issue.from);
                          const line = view ? view.state.doc.lineAt(pos).number : 0;
                          return (
                            <button
                              key={`${issue.from}-${i}`}
                              className={`nm-spell-row ${issue.kind}`}
                              title={issue.message}
                              onClick={() => {
                                const v = cmViewRef.current;
                                if (!v) return;
                                const from = Math.min(issue.from, v.state.doc.length);
                                const to = Math.min(issue.to, v.state.doc.length);
                                v.dispatch({ selection: { anchor: from, head: to }, effects: EditorView.scrollIntoView(from, { y: 'center' }) });
                                v.focus();
                                setSpellPanelOpen(false);
                              }}
                            >
                              <span className="nm-spell-word">{issue.word || issue.message}</span>
                              <span className="nm-spell-hint">
                                {issue.kind === 'spelling'
                                  ? issue.suggestions.length ? `→ ${issue.suggestions.slice(0, 2).join(', ')}` : t('Spelling')
                                  : issue.message}
                              </span>
                              <span className="nm-spell-line">{t('line {{n}}', { n: line })}</span>
                            </button>
                          );
                        })
                      )}
                    </div>
                    <div className="nm-spell-panel-tip muted">{t('Right-click an underlined word to add it to your spelling vocabulary.')}</div>
                    <button className="nm-spell-vocab-toggle" onClick={() => setVocabOpen((open) => !open)} aria-expanded={vocabOpen}>
                      <IconChevronRight size={13} className={vocabOpen ? 'nm-rot90' : ''} /> {t('Spelling vocabulary ({{n}})', { n: vocabWords.length })}
                    </button>
                    {vocabOpen && (
                      <div className="nm-spell-vocab">
                        {vocabWords.length === 0 ? (
                          <div className="muted nm-spell-panel-empty">{t('No words yet.')}</div>
                        ) : (
                          vocabWords.map((word) => (
                            <span key={word} className="nm-spell-vocab-word">
                              {word}
                              <button onClick={() => removeFromVocabulary(word)} title={t('Remove from vocabulary')} aria-label={t('Remove {{word}}', { word })}>×</button>
                            </span>
                          ))
                        )}
                      </div>
                    )}
                    <div className="nm-spell-panel-foot">
                      <button className="btn ghost" onClick={() => { setSpellEnabled(false); setSpellPanelOpen(false); }}>{t('Turn off spelling')}</button>
                    </div>
                  </div>
                </>
              )}
            </span>
          </>
        )}
        <span className="nm-stat-msg" title={status}>{status}</span>
        <button className="nm-icon-btn nm-viewlog" onClick={() => setRightView('log')}>
          <IconLog size={15} /> {t('View log')}
        </button>
      </footer>

      {/* Top-bar dropdown portals — rendered outside top-bar to escape backdrop-filter stacking context */}
      {(mainFileDropdownOpen || engineDropdownOpen || langDropdownOpen) && (
        <div className="topbar-dropdown-backdrop" onClick={() => { setMainFileDropdownOpen(false); setEngineDropdownOpen(false); setLangDropdownOpen(false); }} />
      )}
      {mainFileDropdownOpen && topBarDropdownRect && (
        <div className="ios-dropdown dropdown-fixed" style={{ top: topBarDropdownRect.top, left: topBarDropdownRect.left, minWidth: topBarDropdownRect.width }}>
          {(mainCandidates.length > 0 ? mainCandidates : ['main.tex']).map((p) => (
            <div key={p} className={`ios-dropdown-item ${mainFile === p ? 'active' : ''}`} onClick={() => {
              setMainFile(p);
              setMainFileDropdownOpen(false);
              // Saved in the project, so it is the main file for everyone (view-only people can't change it).
              if (projectId && !viewOnly) {
                setProjectMainFileState(p);
                setProjectMainFile(projectId, p).catch(() => {});
              }
            }}>
              {p}
              {mainFile === p && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
            </div>
          ))}
        </div>
      )}
      {engineDropdownOpen && topBarDropdownRect && (
        <div className="ios-dropdown dropdown-fixed" style={{ top: topBarDropdownRect.top, left: topBarDropdownRect.left, minWidth: topBarDropdownRect.width }}>
          {([['pdflatex','pdfLaTeX'],['xelatex','XeLaTeX'],['lualatex','LuaLaTeX'],['latexmk','Latexmk'],['tectonic','Tectonic']] as [string,string][]).map(([val, lbl]) => (
            <div key={val} className={`ios-dropdown-item ${compileEngine === val ? 'active' : ''}`} onClick={() => { setSettings((prev) => ({ ...prev, compileEngine: val as CompileEngine })); setEngineDropdownOpen(false); }}>
              {lbl}
              {compileEngine === val && <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>}
            </div>
          ))}
        </div>
      )}

      {fileContextMenu && (
        <div className="ctx-menu-backdrop" onClick={() => setFileContextMenu(null)} onContextMenu={(e) => { e.preventDefault(); setFileContextMenu(null); }}>
          <div className="ctx-menu" style={{ left: fileContextMenu.x, top: fileContextMenu.y }} onClick={(e) => e.stopPropagation()}>
            <div className="ctx-menu-group">{t('创建')}</div>
            <button className="ctx-menu-item" onClick={() => { beginInlineCreate('new-file'); setFileContextMenu(null); }}>{t('新建文件')}</button>
            <button className="ctx-menu-item" onClick={() => { beginInlineCreate('new-folder'); setFileContextMenu(null); }}>{t('新建文件夹')}</button>
            <button className="ctx-menu-item" onClick={() => { createBibFile(); setFileContextMenu(null); }}>{t('新建 Bib')}</button>
            <div className="ctx-menu-sep" />
            <div className="ctx-menu-group">{t('上传')}</div>
            <button className="ctx-menu-item" onClick={() => { fileInputRef.current?.click(); setFileContextMenu(null); }}>{t('上传文件')}</button>
            <button className="ctx-menu-item" onClick={() => { folderInputRef.current?.click(); setFileContextMenu(null); }}>{t('上传文件夹')}</button>
            <div className="ctx-menu-sep" />
            <button className="ctx-menu-item" onClick={() => { setAllFolders(true); setFileContextMenu(null); }}>{t('展开全部')}</button>
            <button className="ctx-menu-item" onClick={() => { setAllFolders(false); setFileContextMenu(null); }}>{t('收起全部')}</button>
            <button className="ctx-menu-item" onClick={() => { beginInlineRename(); setFileContextMenu(null); }}>{t('重命名')}</button>
            <div className="ctx-menu-sep" />
            <button className="ctx-menu-item ctx-menu-danger" onClick={() => { handleDeleteFile(); setFileContextMenu(null); }}>{t('删除')}</button>
            <button className="ctx-menu-item" onClick={() => { refreshTree(); setFileContextMenu(null); }}>{t('刷新')}</button>
          </div>
        </div>
      )}
      {settingsOpen && (
        <div className="modal-backdrop" onClick={() => setSettingsOpen(false)}>
          <SettingsLocationLoader
            projectId={isGuest ? '' : projectId || ''}
            onLoad={(loc) => { setProjectLocation(loc); setLocationNote(''); }}
          />
          <div className="modal nm-settings-modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('Numenor Settings')}</div>
              <button className="icon-btn" onClick={() => setSettingsOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              {projectLocation && (
                <div className="field nm-location">
                  <label>{t('Where this project is saved')}</label>
                  <div className="nm-location-place">{projectLocation.place}</div>
                  <code className="nm-location-path" title={projectLocation.path}>{projectLocation.path}</code>
                  <div className="nm-location-actions">
                    <button
                      className="btn small"
                      onClick={() => {
                        if (!projectId) return;
                        revealProject(projectId)
                          .then(() => setLocationNote(t('Opened in Finder.')))
                          .catch((err) => setLocationNote((err as Error).message));
                      }}
                    >
                      {t('Show in Finder')}
                    </button>
                    <button
                      className="btn small ghost"
                      onClick={() => {
                        navigator.clipboard.writeText(projectLocation.path)
                          .then(() => setLocationNote(t('Path copied.')))
                          .catch(() => setLocationNote(t('Couldn’t copy — select the path above instead.')));
                      }}
                    >
                      {t('Copy path')}
                    </button>
                    {locationNote && <span className="muted nm-location-note">{locationNote}</span>}
                  </div>
                  <div className="muted">
                    {t('The project’s files (.tex, .txt, .bib, images) are in this folder. Its history is in the hidden .numenor-history folder inside it. To keep it somewhere else, use Move… on the Projects page.')}
                  </div>
                </div>
              )}
              <div className="field">
                <label>{t('Language')}</label>
                <select className="input" value={i18n.language === 'zh-CN' ? 'zh-CN' : 'en-US'} onChange={(e) => i18n.changeLanguage(e.target.value)}>
                  <option value="en-US">English</option>
                  <option value="zh-CN">中文</option>
                </select>
                <div className="muted">{t('The language of Numenor’s menus and buttons.')}</div>
              </div>
              <div className="field">
                <label>{t('LLM Endpoint')}</label>
                <input
                  className="input"
                  value={llmEndpoint}
                  onChange={(e) => setSettings((prev) => ({ ...prev, llmEndpoint: e.target.value }))}
                  placeholder="https://api.openai.com/v1/chat/completions"
                />
                <div className="muted">{t('支持 OpenAI 兼容的 base_url，例如 https://api.apiyi.com/v1')}</div>
              </div>
              <div className="field">
                <label>{t('LLM Model')}</label>
                <input
                  className="input"
                  value={llmModel}
                  onChange={(e) => setSettings((prev) => ({ ...prev, llmModel: e.target.value }))}
                  placeholder="gpt-4o-mini"
                />
              </div>
              <div className="field">
                <label>{t('LLM API Key')}</label>
                <input
                  className="input"
                  value={llmApiKey}
                  onChange={(e) => setSettings((prev) => ({ ...prev, llmApiKey: e.target.value }))}
                  placeholder="sk-..."
                  type="password"
                />
                {!llmApiKey && (
                  <div className="muted">{t('未配置 API Key 时将使用后端环境变量。')}</div>
                )}
              </div>
              <div className="field">
                <label>{t('Search LLM Endpoint (可选)')}</label>
                <input
                  className="input"
                  value={searchEndpoint}
                  onChange={(e) => setSettings((prev) => ({ ...prev, searchEndpoint: e.target.value }))}
                  placeholder="https://api.apiyi.com/v1"
                />
                <div className="muted">{t('仅用于“检索/websearch”任务，留空则复用 LLM Endpoint。')}</div>
              </div>
              <div className="field">
                <label>{t('Search LLM Model (可选)')}</label>
                <input
                  className="input"
                  value={searchModel}
                  onChange={(e) => setSettings((prev) => ({ ...prev, searchModel: e.target.value }))}
                  placeholder="claude-sonnet-4-5-20250929-all"
                />
              </div>
              <div className="field">
                <label>{t('Search LLM API Key (可选)')}</label>
                <input
                  className="input"
                  value={searchApiKey}
                  onChange={(e) => setSettings((prev) => ({ ...prev, searchApiKey: e.target.value }))}
                  placeholder="sk-..."
                  type="password"
                />
              </div>
              <div className="field">
                <label>{t('VLM Endpoint (可选)')}</label>
                <input
                  className="input"
                  value={visionEndpoint}
                  onChange={(e) => setSettings((prev) => ({ ...prev, visionEndpoint: e.target.value }))}
                  placeholder="https://api.apiyi.com/v1"
                />
                <div className="muted">{t('仅用于图像识别，留空则复用 LLM Endpoint。')}</div>
              </div>
              <div className="field">
                <label>{t('VLM Model (可选)')}</label>
                <input
                  className="input"
                  value={visionModel}
                  onChange={(e) => setSettings((prev) => ({ ...prev, visionModel: e.target.value }))}
                  placeholder="gpt-4o"
                />
              </div>
              <div className="field">
                <label>{t('VLM API Key (可选)')}</label>
                <input
                  className="input"
                  value={visionApiKey}
                  onChange={(e) => setSettings((prev) => ({ ...prev, visionApiKey: e.target.value }))}
                  placeholder="sk-..."
                  type="password"
                />
              </div>
            </div>
            <div className="modal-actions">
              <button className="btn ghost" onClick={() => setSettingsOpen(false)}>{t('关闭')}</button>
              <button className="btn" onClick={() => setSettingsOpen(false)}>{t('完成')}</button>
            </div>
          </div>
        </div>
      )}
      {diffFocus && (
        <div className="modal-backdrop" onClick={() => setDiffFocus(null)}>
          <div className="modal diff-modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('Diff')} · {diffFocus.filePath}</div>
              <button className="icon-btn" onClick={() => setDiffFocus(null)}>✕</button>
            </div>
            <div className="modal-body diff-modal-body">
              <SplitDiffView rows={buildSplitDiff(diffFocus.original, diffFocus.proposed)} />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
