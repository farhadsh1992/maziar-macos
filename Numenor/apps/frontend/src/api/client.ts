export interface ProjectMeta {
  id: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  tags: string[];
  archived: boolean;
  trashed: boolean;
  trashedAt: string | null;
  /** The project folder it lives in (absolute path). */
  folder?: string;
}

export interface FileItem {
  path: string;
  type: 'file' | 'dir';
}

export interface FileOrderMap {
  [folder: string]: string[];
}

export interface LLMConfig {
  endpoint: string;
  apiKey: string;
  model: string;
}

export interface TemplateMeta {
  id: string;
  label: string;
  mainFile: string;
  category: string;
  description: string;
  descriptionEn: string;
  tags: string[];
  author: string;
  featured: boolean;
}

export interface TemplateCategory {
  id: string;
  label: string;
  labelEn: string;
}

export interface ArxivPaper {
  title: string;
  abstract: string;
  authors: string[];
  url: string;
  arxivId: string;
}

const API_BASE = '';
const LANG_KEY = 'numenor-lang';
const COLLAB_TOKEN_KEY = 'numenor-collab-token';
const COLLAB_SERVER_KEY = 'numenor-collab-server';

function getLangHeader() {
  if (typeof window === 'undefined') return 'zh-CN';
  const stored = window.localStorage.getItem(LANG_KEY);
  return stored === 'en-US' ? 'en-US' : 'zh-CN';
}

export function setCollabToken(token: string) {
  if (typeof window === 'undefined') return;
  if (!token) return;
  window.sessionStorage.setItem(COLLAB_TOKEN_KEY, token);
}

export function clearCollabToken() {
  if (typeof window === 'undefined') return;
  window.sessionStorage.removeItem(COLLAB_TOKEN_KEY);
}

// The invite link's own token (not the pass), so a guest can copy their link for their own Numenor.
const COLLAB_INVITE_KEY = 'numenor-collab-invite';
export function setCollabInviteToken(token: string) {
  if (typeof window === 'undefined') return;
  window.sessionStorage.setItem(COLLAB_INVITE_KEY, token);
}
export function getCollabInviteToken() {
  if (typeof window === 'undefined') return '';
  return window.sessionStorage.getItem(COLLAB_INVITE_KEY) || '';
}

export function getCollabToken() {
  if (typeof window === 'undefined') return '';
  return window.sessionStorage.getItem(COLLAB_TOKEN_KEY) || '';
}

export function setCollabServer(server: string) {
  if (typeof window === 'undefined') return;
  if (!server) return;
  window.localStorage.setItem(COLLAB_SERVER_KEY, server);
}

export function getCollabServer() {
  if (typeof window === 'undefined') return '';
  return window.localStorage.getItem(COLLAB_SERVER_KEY) || '';
}

function getAuthHeader(): Record<string, string> {
  const token = getCollabToken();
  if (!token) return {};
  return { Authorization: `Bearer ${token}` };
}

async function request<T>(url: string, options?: RequestInit): Promise<T> {
  const lang = getLangHeader();
  const mergedHeaders: Record<string, string> = {
    'x-lang': lang,
    ...getAuthHeader(),
    ...(options?.headers as Record<string, string> || {})
  };
  if (options?.body) {
    mergedHeaders['Content-Type'] = 'application/json';
  }
  const res = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers: mergedHeaders
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<T>;
}

export function listProjects() {
  return request<{ projects: ProjectMeta[] }>('/api/projects');
}

export function createProject(payload: { name: string; template?: string; folder?: string }) {
  return request<ProjectMeta>('/api/projects', {
    method: 'POST',
    body: JSON.stringify(payload)
  });
}

export function renameProject(id: string, name: string) {
  return request<{ ok: boolean; project?: ProjectMeta; error?: string }>(`/api/projects/${id}/rename-project`, {
    method: 'POST',
    body: JSON.stringify({ name })
  });
}

export function copyProject(id: string, name?: string) {
  return request<{ ok: boolean; project?: ProjectMeta; error?: string }>(`/api/projects/${id}/copy`, {
    method: 'POST',
    body: JSON.stringify({ name })
  });
}

export function deleteProject(id: string) {
  return request<{ ok: boolean; error?: string }>(`/api/projects/${id}`, {
    method: 'DELETE'
  });
}

export function permanentDeleteProject(id: string) {
  return request<{ ok: boolean }>(`/api/projects/${id}/permanent`, {
    method: 'DELETE'
  });
}

export function updateProjectTags(id: string, tags: string[]) {
  return request<{ ok: boolean; project?: ProjectMeta }>(`/api/projects/${id}/tags`, {
    method: 'PATCH',
    body: JSON.stringify({ tags })
  });
}

export function archiveProject(id: string, archived: boolean) {
  return request<{ ok: boolean; project?: ProjectMeta }>(`/api/projects/${id}/archive`, {
    method: 'PATCH',
    body: JSON.stringify({ archived })
  });
}

export function trashProject(id: string, trashed: boolean) {
  return request<{ ok: boolean; project?: ProjectMeta }>(`/api/projects/${id}/trash`, {
    method: 'PATCH',
    body: JSON.stringify({ trashed })
  });
}

export function getProjectTree(id: string) {
  return request<{ items: FileItem[]; fileOrder?: FileOrderMap }>(`/api/projects/${id}/tree`);
}

export function getFile(id: string, filePath: string) {
  const qs = new URLSearchParams({ path: filePath }).toString();
  return request<{ content: string }>(`/api/projects/${id}/file?${qs}`);
}

export function writeFile(id: string, filePath: string, content: string) {
  return request<{ ok: boolean }>(`/api/projects/${id}/file`, {
    method: 'PUT',
    body: JSON.stringify({ path: filePath, content })
  });
}

export function getAllFiles(id: string) {
  return request<{ files: { path: string; content: string; encoding?: 'utf8' | 'base64' }[] }>(
    `/api/projects/${id}/files`
  );
}

export function createFolder(id: string, folderPath: string) {
  return request<{ ok: boolean }>(`/api/projects/${id}/folder`, {
    method: 'POST',
    body: JSON.stringify({ path: folderPath })
  });
}

export function renamePath(id: string, from: string, to: string) {
  return request<{ ok: boolean }>(`/api/projects/${id}/rename`, {
    method: 'POST',
    body: JSON.stringify({ from, to })
  });
}

export async function deleteFile(id: string, filePath: string) {
  const qs = new URLSearchParams({ path: filePath }).toString();
  const res = await fetch(`/api/projects/${id}/file?${qs}`, {
    method: 'DELETE',
    headers: {
      'x-lang': getLangHeader()
    }
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<{ ok: boolean; error?: string }>;
}

export function updateFileOrder(id: string, folder: string, order: string[]) {
  return request<{ ok: boolean }>(`/api/projects/${id}/file-order`, {
    method: 'POST',
    body: JSON.stringify({ folder, order })
  });
}

export async function uploadFiles(projectId: string, files: File[], basePath?: string) {
  const form = new FormData();
  files.forEach((file) => {
    const rel = (file as File & { webkitRelativePath?: string }).webkitRelativePath || file.name;
    const finalPath = basePath ? `${basePath}/${rel}` : rel;
    // Maziar: the server reads the destination from this field — a multipart filename loses its folders.
    form.append('relpath', finalPath);
    form.append('files', file, finalPath);
  });
  const res = await fetch(`/api/projects/${projectId}/upload`, {
    method: 'POST',
    body: form,
    headers: {
      'x-lang': getLangHeader(),
      ...getAuthHeader()
    }
  });
  const text = await res.text();
  let body: { ok?: boolean; files?: string[]; error?: string; message?: string } = {};
  try {
    body = JSON.parse(text);
  } catch {
    body = { error: text };
  }
  if (!res.ok || body.ok === false) {
    throw new Error(body.error || body.message || `Upload failed (HTTP ${res.status})`);
  }
  return body as { ok: boolean; files?: string[] };
}

// Maziar: SyncTeX navigation and spelling/grammar checking.

async function maziarRequest<T>(url: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${url}`, {
    ...options,
    headers: {
      'x-lang': getLangHeader(),
      ...getAuthHeader(),
      ...(options?.body ? { 'Content-Type': 'application/json' } : {})
    }
  });
  let body: any = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  if (!res.ok || !body || body.ok === false) {
    throw new Error(body?.error || `HTTP ${res.status}`);
  }
  return body as T;
}

export type SynctexBox = { page: number; h: number; v: number; width: number; height: number };

export function synctexForward(projectId: string, file: string, line: number, column = 0) {
  const q = new URLSearchParams({ file, line: String(line), column: String(column) });
  return maziarRequest<{ ok: true; boxes: SynctexBox[] }>(`/api/projects/${projectId}/synctex/forward?${q}`);
}

export function synctexReverse(projectId: string, page: number, x: number, y: number) {
  const q = new URLSearchParams({ page: String(page), x: x.toFixed(2), y: y.toFixed(2) });
  return maziarRequest<{ ok: true; file: string; line: number; column: number }>(`/api/projects/${projectId}/synctex/reverse?${q}`);
}

export type SpellIssue = {
  from: number;
  to: number;
  kind: 'spelling' | 'grammar';
  message: string;
  word: string;
  suggestions: string[];
};

export function spellStatus() {
  return maziarRequest<{ ok: true; available: boolean }>('/api/spell/status');
}

export function spellLanguages() {
  return maziarRequest<{ ok: true; languages: string[] }>('/api/spell/languages');
}

export function spellCheck(text: string, language: string, grammar = true) {
  return maziarRequest<{ ok: true; issues: SpellIssue[] }>('/api/spell/check', {
    method: 'POST',
    body: JSON.stringify({ text, language, grammar })
  });
}

/** Spelling vocabulary — words marked as correct, kept on the computer running Numenor. */
export function getSpellVocabulary() {
  return maziarRequest<{ ok: true; words: string[] }>('/api/spell/vocabulary');
}

export function addSpellWord(word: string) {
  return maziarRequest<{ ok: true; words: string[] }>('/api/spell/vocabulary', { method: 'POST', body: JSON.stringify({ word }) });
}

export function removeSpellWord(word: string) {
  return maziarRequest<{ ok: true; words: string[] }>(`/api/spell/vocabulary?word=${encodeURIComponent(word)}`, { method: 'DELETE' });
}

export function spellLearn(word: string) {
  return maziarRequest<{ ok: true }>('/api/spell/learn', { method: 'POST', body: JSON.stringify({ word }) });
}

export function createCollabInvite(id: string) {
  return request<{ ok: boolean; token: string }>(`/api/projects/${id}/collab/invite`, {
    method: 'POST',
    body: JSON.stringify({})
  });
}

export function resolveCollabToken(token: string) {
  const qs = new URLSearchParams({ token }).toString();
  return request<{ ok: boolean; needsCode?: boolean; projectId: string; projectName: string; role: string; name?: string; owner?: string }>(`/api/collab/resolve?${qs}`);
}

/** Invite link token + access code → a pass for the editor. */
export function unlockCollab(token: string, code: string) {
  return request<{ ok: boolean; session: string; hours: number; projectId: string; projectName: string; role: string }>('/api/collab/unlock', {
    method: 'POST',
    body: JSON.stringify({ token, code })
  });
}

export function flushCollabFile(id: string, filePath: string) {
  return request<{ ok: boolean }>(`/api/projects/${id}/collab/flush`, {
    method: 'POST',
    body: JSON.stringify({ path: filePath })
  });
}

export function getCollabStatus(id: string, filePath: string) {
  const qs = new URLSearchParams({ path: filePath }).toString();
  return request<{ ok: boolean; diagnostics: { conns: number; lastError: string | null } | null }>(
    `/api/projects/${id}/collab/status?${qs}`
  );
}

export function runAgent(payload: {
  task: string;
  prompt: string;
  selection: string;
  content: string;
  mode: 'direct' | 'tools';
  projectId?: string;
  activePath?: string;
  compileLog?: string;
  llmConfig?: Partial<LLMConfig>;
  interaction?: 'chat' | 'agent';
  history?: { role: 'user' | 'assistant'; content: string }[];
}) {
  return request<{ ok: boolean; reply: string; suggestion: string; patches?: { path: string; diff: string; content: string }[] }>(`/api/agent/run`, {
    method: 'POST',
    body: JSON.stringify(payload)
  });
}

export function compileProject(payload: {
  projectId: string;
  mainFile: string;
  engine: 'pdflatex' | 'xelatex' | 'lualatex' | 'latexmk' | 'tectonic';
}) {
  return request<{ ok: boolean; pdf?: string; log?: string; status?: number; engine?: string; error?: string }>(
    `/api/compile`,
    {
      method: 'POST',
      body: JSON.stringify(payload)
    }
  );
}

export function listTemplates() {
  return request<{ templates: TemplateMeta[]; categories?: TemplateCategory[] }>('/api/templates');
}

export async function uploadTemplate(templateId: string, templateLabel: string, file: File) {
  const form = new FormData();
  form.append('templateId', templateId);
  form.append('templateLabel', templateLabel);
  form.append('file', file);
  const lang = getLangHeader();
  const res = await fetch(`${API_BASE}/api/templates/upload`, {
    method: 'POST',
    headers: { 'x-lang': lang, ...getAuthHeader() },
    body: form,
  });
  if (!res.ok) throw new Error(await res.text());
  return res.json() as Promise<{ ok: boolean; templateId?: string; error?: string }>;
}

export function arxivSearch(payload: { query: string; maxResults?: number }) {
  return request<{ ok: boolean; papers?: ArxivPaper[]; error?: string }>(
    '/api/arxiv/search',
    {
      method: 'POST',
      body: JSON.stringify(payload)
    }
  );
}

export function arxivBibtex(payload: { arxivId: string }) {
  return request<{ ok: boolean; bibtex?: string; entry?: ArxivPaper; error?: string }>(
    '/api/arxiv/bibtex',
    {
      method: 'POST',
      body: JSON.stringify(payload)
    }
  );
}

export function plotFromTable(payload: {
  projectId: string;
  tableLatex: string;
  chartType: string;
  title?: string;
  prompt?: string;
  filename?: string;
  retries?: number;
  llmConfig?: Partial<LLMConfig>;
}) {
  return request<{ ok: boolean; assetPath?: string; error?: string }>(
    '/api/plot/from-table',
    {
      method: 'POST',
      body: JSON.stringify(payload)
    }
  );
}

export function callLLM(payload: {
  messages: { role: 'system' | 'user' | 'assistant'; content: string }[];
  model?: string;
  llmConfig?: Partial<LLMConfig>;
}) {
  return request<{ ok: boolean; content?: string; error?: string }>('/api/llm', {
    method: 'POST',
    body: JSON.stringify(payload)
  });
}

export async function importZip(payload: { file: File; projectName?: string; folder?: string }) {
  const form = new FormData();
  form.append('zip', payload.file);
  if (payload.projectName) {
    form.append('projectName', payload.projectName);
  }
  const res = await fetch(`/api/projects/import-zip${payload.folder ? `?folder=${encodeURIComponent(payload.folder)}` : ''}`, {
    method: 'POST',
    body: form,
    headers: {
      'x-lang': getLangHeader(),
      ...getAuthHeader()
    }
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<{ ok: boolean; project?: ProjectMeta; error?: string }>;
}

export function importArxivSSE(
  payload: { arxivIdOrUrl: string; projectName?: string; folder?: string },
  onProgress?: (data: { phase: string; percent: number; received?: number; total?: number }) => void
): Promise<{ ok: boolean; project?: ProjectMeta; error?: string }> {
  return new Promise((resolve, reject) => {
    const params = new URLSearchParams({ arxivIdOrUrl: payload.arxivIdOrUrl });
    if (payload.projectName) params.set('projectName', payload.projectName);
    if (payload.folder) params.set('folder', payload.folder);
    const token = getCollabToken();
    if (token) params.set('token', token);
    const es = new EventSource(`/api/projects/import-arxiv-sse?${params.toString()}`);

    es.addEventListener('progress', (e) => {
      if (onProgress) {
        try { onProgress(JSON.parse(e.data)); } catch {}
      }
    });
    es.addEventListener('done', (e) => {
      es.close();
      try { resolve(JSON.parse(e.data)); } catch { resolve({ ok: true }); }
    });
    es.addEventListener('error', (e) => {
      es.close();
      const me = e as MessageEvent;
      if (me.data) {
        try {
          const d = JSON.parse(me.data);
          resolve({ ok: false, error: d.error || 'Unknown error' });
          return;
        } catch {}
      }
      reject(new Error('SSE connection failed'));
    });
  });
}

export async function visionToLatex(payload: {
  projectId: string;
  file: File;
  mode: string;
  prompt?: string;
  llmConfig?: Partial<LLMConfig>;
}) {
  const form = new FormData();
  form.append('image', payload.file);
  form.append('projectId', payload.projectId);
  form.append('mode', payload.mode);
  if (payload.prompt) {
    form.append('prompt', payload.prompt);
  }
  if (payload.llmConfig) {
    form.append('llmConfig', JSON.stringify(payload.llmConfig));
  }
  const res = await fetch('/api/vision/latex', {
    method: 'POST',
    body: form,
    headers: {
      'x-lang': getLangHeader(),
      ...getAuthHeader()
    }
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<{ ok: boolean; latex?: string; assetPath?: string; error?: string }>;
}

// ─── Transfer Agent API ───

export interface TransferStartPayload {
  sourceProjectId: string;
  sourceMainFile: string;
  targetTemplateId: string;
  targetMainFile: string;
  engine?: string;
  layoutCheck?: boolean;
  llmConfig?: Partial<LLMConfig>;
}

export interface TransferStepResult {
  status: string;
  progressLog: string[];
  error?: string;
}

export interface PageImage {
  page: number;
  base64: string;
  mime: string;
}

export function transferStart(payload: TransferStartPayload) {
  return request<{ jobId: string }>('/api/transfer/start', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
}

export function transferStep(jobId: string) {
  return request<TransferStepResult>('/api/transfer/step', {
    method: 'POST',
    body: JSON.stringify({ jobId }),
  });
}

export function transferSubmitImages(jobId: string, images: PageImage[]) {
  return request<{ ok: boolean }>('/api/transfer/submit-images', {
    method: 'POST',
    body: JSON.stringify({ jobId, images }),
  });
}

export function transferStatus(jobId: string) {
  return request<TransferStepResult>(`/api/transfer/status/${jobId}`);
}

// ─── MinerU Transfer API ───

export interface MineruConfig {
  apiBase?: string;
  token?: string;
  modelVersion?: string;
}

export interface MineruTransferStartPayload {
  sourceProjectId?: string;
  sourceMainFile?: string;
  targetTemplateId: string;
  targetMainFile: string;
  engine?: string;
  layoutCheck?: boolean;
  llmConfig?: Partial<LLMConfig>;
  mineruConfig?: MineruConfig;
}

export function mineruTransferStart(payload: MineruTransferStartPayload) {
  return request<{ jobId: string; newProjectId: string }>(
    '/api/transfer/start-mineru',
    { method: 'POST', body: JSON.stringify(payload) },
  );
}

export async function mineruTransferUploadPdf(jobId: string, pdfFile: File) {
  const form = new FormData();
  form.append('jobId', jobId);
  form.append('pdf', pdfFile);
  const res = await fetch('/api/transfer/upload-pdf', {
    method: 'POST',
    body: form,
    headers: {
      'x-lang': getLangHeader(),
      ...getAuthHeader(),
    },
  });
  if (!res.ok) {
    throw new Error(await res.text());
  }
  return res.json() as Promise<{ ok: boolean; pdfPath?: string }>;
}

// Project folders (the main one plus any added, e.g. inside Google Drive).

export type ProjectFolder = { path: string; primary: boolean; exists: boolean; projectCount: number; cloud: 'google' | null };
export type FolderSuggestion = { label: string; path: string; kind: string };
export type FolderListing = { path: string; parent: string | null; entries: { name: string; path: string; isProject: boolean }[]; projectCount: number };

export function listFolders() {
  return maziarRequest<{ ok: true; primary: string; folders: ProjectFolder[] }>('/api/folders');
}

export function folderSuggestions() {
  return maziarRequest<{ ok: true; suggestions: FolderSuggestion[]; home: string }>('/api/folders/suggestions');
}

export function addFolder(path: string) {
  return maziarRequest<{ ok: true; primary: string; folders: ProjectFolder[] }>('/api/folders', { method: 'POST', body: JSON.stringify({ path }) });
}

export function removeFolder(path: string) {
  return maziarRequest<{ ok: true; primary: string; folders: ProjectFolder[] }>(`/api/folders?path=${encodeURIComponent(path)}`, { method: 'DELETE' });
}

export function browseFolder(path?: string) {
  return maziarRequest<{ ok: true } & FolderListing>(`/api/folders/browse${path ? `?path=${encodeURIComponent(path)}` : ''}`);
}

export function makeFolder(parent: string, name: string) {
  return maziarRequest<{ ok: true; path: string }>('/api/folders/mkdir', { method: 'POST', body: JSON.stringify({ parent, name }) });
}

// Sharing (a public link for invited collaborators; only the computer running Numenor can turn it on).

export type ShareState = { active: boolean; starting: boolean; url: string; provider: string; note: string; error: string; startedAt: string | null; fixed?: boolean; fixedDomain?: string };

export function shareStatus() {
  return maziarRequest<{ ok: true } & ShareState>('/api/share/status');
}

export function startShare() {
  return maziarRequest<{ ok: true } & ShareState>('/api/share/start', { method: 'POST', body: JSON.stringify({}) });
}

/** The fixed ngrok address share links use ('' = a new temporary address each time). */
export function setShareDomain(ngrokDomain: string) {
  return maziarRequest<{ ok: true } & ShareState>('/api/share/settings', { method: 'PUT', body: JSON.stringify({ ngrokDomain }) });
}

export function stopShare() {
  return maziarRequest<{ ok: true } & ShareState>('/api/share/stop', { method: 'POST', body: JSON.stringify({}) });
}

/** URL of a project file for <img>/<object> — carries the invite token for invited visitors. */
export function blobUrl(projectId: string, filePath: string) {
  const token = getCollabToken();
  return `/api/projects/${projectId}/blob?path=${encodeURIComponent(filePath)}${token ? `&token=${encodeURIComponent(token)}` : ''}`;
}

/** Link that downloads a project as a .zip. */
export function projectDownloadUrl(projectId: string) {
  const token = getCollabToken();
  return `/api/projects/${projectId}/download${token ? `?token=${encodeURIComponent(token)}` : ''}`;
}

export function moveProject(projectId: string, folder: string) {
  return maziarRequest<{ ok: true; folder: string; unchanged?: boolean }>(`/api/projects/${projectId}/move`, {
    method: 'POST',
    body: JSON.stringify({ folder })
  });
}

// People with access to a project (owner only) — one invite per person, each with its own link.

export type Invite = { id: string; projectId: string; name: string; email: string; role: 'edit' | 'view'; createdAt: string; lastSeenAt: string | null; emailedAt?: string | null; code: string; token: string };

export function listInvites(projectId: string) {
  return maziarRequest<{ ok: true; invites: Invite[] }>(`/api/projects/${projectId}/invites`);
}

export function createInvite(projectId: string, data: { name: string; email: string; role: 'edit' | 'view' }) {
  return maziarRequest<{ ok: true; invite: Invite }>(`/api/projects/${projectId}/invites`, { method: 'POST', body: JSON.stringify(data) });
}

export function updateInvite(projectId: string, inviteId: string, data: { role?: 'edit' | 'view'; name?: string; newCode?: boolean }) {
  return maziarRequest<{ ok: true; invite: Invite }>(`/api/projects/${projectId}/invites/${inviteId}`, { method: 'PATCH', body: JSON.stringify(data) });
}

export type MailStatus = { configured: boolean; provider?: 'gmail' | 'outlook' | 'icloud' | 'other'; host?: string; port?: number; user?: string; fromName?: string };
export type MailSettingsInput = { provider: string; user: string; pass: string; fromName: string; host?: string; port?: number };

export function getMailSettings() {
  return maziarRequest<{ ok: true } & MailStatus>('/api/mail/settings');
}

export function saveMailSettings(data: MailSettingsInput) {
  return maziarRequest<{ ok: true } & MailStatus>('/api/mail/settings', { method: 'PUT', body: JSON.stringify(data) });
}

export function clearMailSettings() {
  return maziarRequest<{ ok: true } & MailStatus>('/api/mail/settings', { method: 'DELETE' });
}

export function sendTestMail() {
  return maziarRequest<{ ok: true }>('/api/mail/test', { method: 'POST', body: '{}' });
}

export function emailInvite(projectId: string, inviteId: string, projectName: string) {
  return maziarRequest<{ ok: true; invite: Invite }>(`/api/projects/${projectId}/invites/${inviteId}/email`, { method: 'POST', body: JSON.stringify({ projectName }) });
}

export function revokeInvite(projectId: string, inviteId: string) {
  return maziarRequest<{ ok: true }>(`/api/projects/${projectId}/invites/${inviteId}`, { method: 'DELETE' });
}

export function inviteLink(base: string, token: string) {
  return `${base.replace(/\/$/, '')}/collab?token=${encodeURIComponent(token)}`;
}

export type Me = { ok: true; kind: 'owner' | 'guest'; name: string; role: 'owner' | 'edit' | 'view'; projectId?: string; key?: string };

/** Someone who has the project open (seen in the last ~25 s). key: 'owner' or 'invite:<id>'. */
export type PresencePerson = { key: string; name: string; kind: 'owner' | 'guest'; role: 'owner' | 'edit' | 'view'; file: string; lastSeen: string };

/** Says "I'm here, looking at `file`" and returns everyone who has the project open. */
export function presence(projectId: string, file: string, leave = false) {
  const qs = new URLSearchParams({ file });
  if (leave) qs.set('leave', '1');
  return maziarRequest<{ ok: true; you: string; people: PresencePerson[] }>(`/api/projects/${encodeURIComponent(projectId)}/presence?${qs}`);
}

export function whoAmI() {
  return maziarRequest<Me>('/api/me');
}

// A project's change history.

export type HistoryEntry = {
  id: string; time: string; author: string; kind: 'owner' | 'guest';
  action: 'edit' | 'create' | 'upload' | 'delete' | 'rename' | 'folder';
  path: string; to?: string; added: number; removed: number;
};
export type DiffPart = { value: string; added: boolean; removed: boolean };

export function getHistory(projectId: string, file = '') {
  const qs = file ? `?file=${encodeURIComponent(file)}` : '';
  return maziarRequest<{ ok: true; entries: HistoryEntry[] }>(`/api/projects/${projectId}/history${qs}`);
}

export function getHistoryEntry(projectId: string, entryId: string) {
  return maziarRequest<{ ok: true; entry: HistoryEntry; parts: DiffPart[] }>(`/api/projects/${projectId}/history/${entryId}`);
}

export function restoreHistoryEntry(projectId: string, entryId: string, which: 'before' | 'after') {
  return maziarRequest<{ ok: true; path: string }>(`/api/projects/${projectId}/history/${entryId}/restore`, { method: 'POST', body: JSON.stringify({ which }) });
}

// Projects other people shared with me (kept on this computer).

export type SharedProject = {
  id: string; origin: string; projectId: string; projectName: string; role: 'edit' | 'view'; owner: string;
  addedAt: string; lastOnlineAt: string | null; state: 'ok' | 'offline' | 'revoked' | 'invalid'; link: string; hasCode?: boolean;
};

/** "ABCDEFGH" → "ABCD-EFGH" (easier to read out). */
export function prettyCode(code: string) {
  return code && code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
}

export function listSharedWithMe() {
  return maziarRequest<{ ok: true; items: SharedProject[] }>('/api/shared-with-me');
}

export function addSharedWithMe(link: string, code: string) {
  return maziarRequest<{ ok: true; item: SharedProject }>('/api/shared-with-me', { method: 'POST', body: JSON.stringify({ link, code }) });
}

/** A ready-to-open address for a saved shared project (the saved code is used, never shown). */
export function openSharedWithMe(id: string) {
  return maziarRequest<{ ok: true; url: string }>(`/api/shared-with-me/${id}/open`, { method: 'POST', body: '{}' });
}

export function setSharedWithMeCode(id: string, code: string) {
  return maziarRequest<{ ok: true }>(`/api/shared-with-me/${id}/code`, { method: 'PUT', body: JSON.stringify({ code }) });
}

export function removeSharedWithMe(id: string) {
  return maziarRequest<{ ok: true }>(`/api/shared-with-me/${id}`, { method: 'DELETE' });
}

// "Keep a copy in…": folders (Google Drive, SharePoint via OneDrive, Dropbox…) a project is mirrored to on every save.
export type SyncTarget = {
  id: string;
  dest: string;
  includePdf: boolean;
  enabled: boolean;
  createdAt: string;
  lastSyncAt: string | null;
  lastError: string | null;
  fileCount: number;
  running: boolean;
  exists: boolean;
};

export function listSyncTargets(projectId: string) {
  return maziarRequest<{ ok: true; targets: SyncTarget[] }>(`/api/sync/${encodeURIComponent(projectId)}`);
}

export function addSyncTarget(projectId: string, parent: string, includePdf = true) {
  return maziarRequest<{ ok: true; target: SyncTarget; targets: SyncTarget[] }>(`/api/sync/${encodeURIComponent(projectId)}`, {
    method: 'POST',
    body: JSON.stringify({ parent, includePdf })
  });
}

export function updateSyncTarget(projectId: string, targetId: string, changes: { enabled?: boolean; includePdf?: boolean }) {
  return maziarRequest<{ ok: true; targets: SyncTarget[] }>(`/api/sync/${encodeURIComponent(projectId)}/${targetId}`, {
    method: 'PATCH',
    body: JSON.stringify(changes)
  });
}

export function removeSyncTarget(projectId: string, targetId: string) {
  return maziarRequest<{ ok: true; targets: SyncTarget[] }>(`/api/sync/${encodeURIComponent(projectId)}/${targetId}`, { method: 'DELETE' });
}

export function syncNow(projectId: string) {
  return maziarRequest<{ ok: true; targets: SyncTarget[] }>(`/api/sync/${encodeURIComponent(projectId)}/now`, { method: 'POST', body: '{}' });
}

// Version and updates from GitHub.
export type VersionInfo = { version: string; label: string; display: string };
export type UpdateCheck = {
  ok: true;
  current: VersionInfo;
  latest: VersionInfo;
  available: boolean;
  notes: string;
  method: 'git' | 'archive';
  checkedAt: string;
};
export type UpdateProgress = {
  state: 'idle' | 'downloading' | 'installing' | 'building' | 'restarting' | 'error';
  step: string;
  error: string;
  log: string;
  current: VersionInfo;
};

export function getVersion() {
  return maziarRequest<{ ok: true; supervised: boolean } & VersionInfo>('/api/version');
}

export function checkForUpdate(force = false) {
  return maziarRequest<UpdateCheck>(`/api/update/check${force ? '?force=1' : ''}`);
}

export function startUpdate() {
  return maziarRequest<{ ok: true } & UpdateProgress>('/api/update/apply', { method: 'POST', body: '{}' });
}

export function updateStatus() {
  return maziarRequest<{ ok: true } & UpdateProgress>('/api/update/status');
}
