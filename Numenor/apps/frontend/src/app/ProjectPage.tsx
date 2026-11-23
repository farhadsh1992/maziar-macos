import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  createProject,
  copyProject,
  deleteProject,
  importArxivSSE,
  importZip,
  listProjects,
  listTemplates,
  renameProject,
  archiveProject,
  trashProject,
  updateProjectTags,
  permanentDeleteProject,
  uploadTemplate,
  listFolders,
  addFolder,
  removeFolder,
  moveProject,
  projectDownloadUrl,
  addSharedWithMe
} from '../api/client';
import type { ProjectMeta, TemplateMeta, TemplateCategory, ProjectFolder } from '../api/client';
import TransferPanel from './TransferPanel';
import FolderPicker from './FolderPicker';
import {
  NumenorMark, IconFolder, IconFile, IconArchive, IconTrash, IconTag, IconGear, IconSearch, IconChevronDown,
  IconPlus, IconDots, IconStar, IconCopy, IconCheck, IconShare, IconLink
} from './icons';
import SharedWithMe from './SharedWithMe';

const TARGET_FOLDER_KEY = 'numenor.projects.targetFolder';

/** "Numenor / data" — the last two parts of a folder path, as a readable label. */
function folderLabel(p: string) {
  const parts = p.split('/').filter(Boolean);
  return parts.slice(-2).join(' / ') || p;
}

/** "…/My Drive/Papers" — the last two parts of a folder path, for compact labels. */
function shortFolder(p: string) {
  const parts = p.split('/').filter(Boolean);
  return parts.length <= 2 ? p : `…/${parts.slice(-2).join('/')}`;
}

type ViewFilter = 'all' | 'mine' | 'archived' | 'trash';
type SortBy = 'updatedAt' | 'name' | 'createdAt';

const SETTINGS_KEY = 'numenor-settings-v1';

interface LLMSettings {
  llmEndpoint: string;
  llmApiKey: string;
  llmModel: string;
}

const DEFAULT_LLM: LLMSettings = {
  llmEndpoint: 'https://api.openai.com/v1/chat/completions',
  llmApiKey: '',
  llmModel: 'gpt-4o-mini',
};

function loadLLMSettings(): LLMSettings {
  try {
    const raw = window.localStorage.getItem(SETTINGS_KEY);
    if (!raw) return DEFAULT_LLM;
    const parsed = JSON.parse(raw);
    return {
      llmEndpoint: parsed.llmEndpoint ?? DEFAULT_LLM.llmEndpoint,
      llmApiKey: parsed.llmApiKey ?? DEFAULT_LLM.llmApiKey,
      llmModel: parsed.llmModel ?? DEFAULT_LLM.llmModel,
    };
  } catch {
    return DEFAULT_LLM;
  }
}

function saveLLMSettings(s: LLMSettings) {
  try {
    const raw = window.localStorage.getItem(SETTINGS_KEY);
    const prev = raw ? JSON.parse(raw) : {};
    window.localStorage.setItem(SETTINGS_KEY, JSON.stringify({ ...prev, ...s }));
  } catch {}
}

function formatRelativeTime(iso: string, t: (k: string, o?: Record<string, unknown>) => string): string {
  const now = Date.now();
  const then = new Date(iso).getTime();
  const diff = now - then;
  if (diff < 60_000) return t('刚刚');
  if (diff < 3_600_000) return t('{{n}} 分钟前', { n: Math.floor(diff / 60_000) });
  if (diff < 86_400_000) return t('{{n}} 小时前', { n: Math.floor(diff / 3_600_000) });
  return t('{{n}} 天前', { n: Math.floor(diff / 86_400_000) });
}

export default function ProjectPage() {
  const navigate = useNavigate();
  const { t, i18n } = useTranslation();

  const [projects, setProjects] = useState<ProjectMeta[]>([]);
  // Project folders: the main one plus any added ones (e.g. inside Google Drive).
  const [folders, setFolders] = useState<ProjectFolder[]>([]);
  const [folderFilter, setFolderFilter] = useState('');
  const [folderPickerOpen, setFolderPickerOpen] = useState(false);
  const [copiedFolder, setCopiedFolder] = useState('');
  const [moveTarget, setMoveTarget] = useState<ProjectMeta | null>(null);
  const [moveBusy, setMoveBusy] = useState(false);
  const [moreMenuId, setMoreMenuId] = useState('');
  const [undoTrash, setUndoTrash] = useState<{ id: string; name: string } | null>(null);
  const pendingMoveRef = useRef<ProjectMeta | null>(null);
  const [targetFolder, setTargetFolder] = useState(() => {
    try { return localStorage.getItem(TARGET_FOLDER_KEY) || ''; } catch { return ''; }
  });
  const [templates, setTemplates] = useState<TemplateMeta[]>([]);
  const [categories, setCategories] = useState<TemplateCategory[]>([]);
  const [status, setStatus] = useState('');
  const [filter, setFilter] = useState('');

  const [viewFilter, setViewFilter] = useState<ViewFilter>('all');
  const [sharedView, setSharedView] = useState(false);
  const [sharedCount, setSharedCount] = useState<number | null>(null);
  const [activeTag, setActiveTag] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<SortBy>('updatedAt');
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [tagsExpanded, setTagsExpanded] = useState(true);

  const [createOpen, setCreateOpen] = useState(false);
  const [sharedLinkOpen, setSharedLinkOpen] = useState(false);
  const [sharedLink, setSharedLink] = useState('');
  const [sharedLinkBusy, setSharedLinkBusy] = useState(false);
  const [sharedLinkError, setSharedLinkError] = useState('');
  const [sharedReload, setSharedReload] = useState(0);
  const [createName, setCreateName] = useState('');
  const [createTemplate, setCreateTemplate] = useState('');
  const [renameState, setRenameState] = useState<{ id: string; value: string } | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [arxivInput, setArxivInput] = useState('');
  const [importing, setImporting] = useState(false);
  const [importProgress, setImportProgress] = useState<{ phase: string; percent: number } | null>(null);
  const zipInputRef = useRef<HTMLInputElement | null>(null);
  const [langDropdownOpen, setLangDropdownOpen] = useState(false);
  const [templateDropdownOpen, setTemplateDropdownOpen] = useState(false);

  // Settings modal state
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [settingsForm, setSettingsForm] = useState<LLMSettings>(loadLLMSettings);

  const [templateGalleryOpen, setTemplateGalleryOpen] = useState(false);
  const [galleryCat, setGalleryCat] = useState('all');
  const [galleryFeatured, setGalleryFeatured] = useState(false);
  const [gallerySearch, setGallerySearch] = useState('');
  const [tagEditId, setTagEditId] = useState<string | null>(null);
  const [tagInput, setTagInput] = useState('');
  const [newSidebarTag, setNewSidebarTag] = useState('');
  const [addingSidebarTag, setAddingSidebarTag] = useState(false);
  const [sortDropdownOpen, setSortDropdownOpen] = useState(false);

  // Transfer modal state
  const [transferOpen, setTransferOpen] = useState(false);
  const [transferSource, setTransferSource] = useState<{ id: string; name: string } | null>(null);

  // Active transfer job (persists after modal close)
  const [activeJob, setActiveJob] = useState<{
    jobId: string; status: string; progressLog: string[]; error?: string;
    sourceName?: string;
  } | null>(null);
  const [jobWidgetOpen, setJobWidgetOpen] = useState(true);

  // Template upload state
  const templateZipRef = useRef<HTMLInputElement | null>(null);
  const [uploadingTemplate, setUploadingTemplate] = useState(false);

  const loadProjects = useCallback(async () => {
    const res = await listProjects();
    setProjects(res.projects || []);
  }, []);

  const loadFolders = useCallback(async () => {
    try {
      const res = await listFolders();
      setFolders(res.folders);
    } catch {
      setFolders([]);
    }
  }, []);

  useEffect(() => {
    loadFolders();
  }, [loadFolders]);

  const primaryFolder = folders.find((f) => f.primary)?.path || '';
  // Where new projects go: the chosen folder if it's still in the list, else the main one.
  const newProjectFolder = folders.some((f) => f.path === targetFolder) ? targetFolder : primaryFolder;
  const chooseTargetFolder = (path: string) => {
    setTargetFolder(path);
    try { localStorage.setItem(TARGET_FOLDER_KEY, path); } catch { /* ignore */ }
  };

  /** Copies a folder's full path; falls back to a hidden text field where the clipboard API isn't allowed. */
  const copyFolderPath = async (path: string) => {
    let ok = false;
    try {
      await navigator.clipboard.writeText(path);
      ok = true;
    } catch {
      const area = document.createElement('textarea');
      area.value = path;
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      try { ok = document.execCommand('copy'); } catch { ok = false; }
      area.remove();
    }
    if (ok) {
      setCopiedFolder(path);
      window.setTimeout(() => setCopiedFolder((current) => (current === path ? '' : current)), 1600);
    } else {
      setStatus(t('Couldn’t copy — select the path and copy it by hand.'));
    }
  };

  const handleAddFolder = async (path: string) => {
    const res = await addFolder(path);
    setFolders(res.folders);
    await loadProjects();
    setFolderPickerOpen(false);
    setStatus(t('Added {{path}}', { path }));
    // Came from the Move dialog's "Add a Google Drive folder…": go back to it.
    if (pendingMoveRef.current) {
      const project = pendingMoveRef.current;
      pendingMoveRef.current = null;
      setMoveTarget(project);
    }
  };

  const handleRemoveFolder = async (folder: ProjectFolder) => {
    const ok = window.confirm(t('Stop listing projects from {{path}}? The folder and its projects stay on disk.', { path: folder.path }));
    if (!ok) return;
    try {
      const res = await removeFolder(folder.path);
      setFolders(res.folders);
      if (folderFilter === folder.path) setFolderFilter('');
      await loadProjects();
    } catch (err) {
      setStatus(String((err as Error).message || err));
    }
  };

  useEffect(() => {
    loadProjects().catch((err) => setStatus(t('加载项目失败: {{error}}', { error: String(err) })));
  }, [loadProjects, t]);

  useEffect(() => {
    listTemplates()
      .then((res) => {
        setTemplates(res.templates || []);
        setCategories(res.categories || []);
        if (res.templates?.length && !createTemplate) {
          setCreateTemplate(res.templates[0].id);
        }
      })
      .catch((err) => setStatus(t('模板加载失败: {{error}}', { error: String(err) })));
  }, [createTemplate, t]);

  const allTags = useMemo(() => {
    const s = new Set<string>();
    projects.forEach((p) => (p.tags || []).forEach((tag) => s.add(tag)));
    return Array.from(s).sort();
  }, [projects]);

  const filteredProjects = useMemo(() => {
    let list = projects;
    if (viewFilter === 'archived') list = list.filter((p) => p.archived && !p.trashed);
    else if (viewFilter === 'trash') list = list.filter((p) => p.trashed);
    else if (viewFilter === 'mine') list = list.filter((p) => !p.archived && !p.trashed);
    else list = list.filter((p) => !p.trashed);
    if (activeTag) list = list.filter((p) => (p.tags || []).includes(activeTag));
    if (folderFilter) list = list.filter((p) => p.folder === folderFilter);
    const term = filter.trim().toLowerCase();
    if (term) list = list.filter((p) => p.name.toLowerCase().includes(term));
    list = [...list].sort((a, b) => {
      if (sortBy === 'name') return a.name.localeCompare(b.name);
      if (sortBy === 'createdAt') return new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime();
      return new Date(b.updatedAt || b.createdAt).getTime() - new Date(a.updatedAt || a.createdAt).getTime();
    });
    return list;
  }, [projects, viewFilter, activeTag, filter, sortBy, folderFilter]);

  const viewCounts = useMemo(() => ({
    all: projects.filter((p) => !p.trashed).length,
    mine: projects.filter((p) => !p.archived && !p.trashed).length,
    archived: projects.filter((p) => p.archived && !p.trashed).length,
    trash: projects.filter((p) => p.trashed).length,
  }), [projects]);

  const galleryTemplates = useMemo(() => {
    let list = templates;
    if (galleryCat !== 'all') list = list.filter((tpl) => tpl.category === galleryCat);
    if (galleryFeatured) list = list.filter((tpl) => tpl.featured);
    const term = gallerySearch.trim().toLowerCase();
    if (term) list = list.filter((tpl) =>
      tpl.label.toLowerCase().includes(term) ||
      (tpl.description || '').toLowerCase().includes(term) ||
      (tpl.descriptionEn || '').toLowerCase().includes(term)
    );
    return list;
  }, [templates, galleryCat, galleryFeatured, gallerySearch]);

  const handleCreate = async () => {
    const name = createName.trim();
    if (!name) {
      setStatus(t('请输入项目名称。'));
      return;
    }
    try {
      const created = await createProject({ name, template: createTemplate || undefined, folder: newProjectFolder || undefined });
      setCreateOpen(false);
      setCreateName('');
      await loadProjects();
      navigate(`/editor/${created.id}`);
    } catch (err) {
      setStatus(t('创建失败: {{error}}', { error: String(err) }));
    }
  };

  const handleRename = async () => {
    if (!renameState) return;
    const name = renameState.value.trim();
    if (!name) {
      setRenameState(null);
      return;
    }
    try {
      await renameProject(renameState.id, name);
      setRenameState(null);
      await loadProjects();
    } catch (err) {
      setStatus(t('重命名失败: {{error}}', { error: String(err) }));
    }
  };

  // Delete moves the project to Trash (with Undo); "Delete forever" in Trash removes it from disk.
  const handleDelete = async (id: string, name: string) => {
    try {
      await deleteProject(id);
      await loadProjects();
      setUndoTrash({ id, name });
      setStatus(t('Moved “{{name}}” to Trash.', { name }));
    } catch (err) {
      setStatus(t('删除失败: {{error}}', { error: String(err) }));
    }
  };

  const undoDelete = async () => {
    if (!undoTrash) return;
    try {
      await trashProject(undoTrash.id, false);
      await loadProjects();
      setStatus(t('Restored “{{name}}”.', { name: undoTrash.name }));
    } catch (err) {
      setStatus(String(err));
    } finally {
      setUndoTrash(null);
    }
  };

  const downloadZip = (project: ProjectMeta) => {
    const link = document.createElement('a');
    link.href = projectDownloadUrl(project.id);
    link.download = `${project.name || 'project'}.zip`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setStatus(t('Downloading “{{name}}” as a .zip…', { name: project.name }));
  };

  const handleMove = async (folder: string) => {
    if (!moveTarget) return;
    setMoveBusy(true);
    try {
      const res = await moveProject(moveTarget.id, folder);
      await Promise.all([loadProjects(), loadFolders()]);
      setStatus(res.unchanged ? t('“{{name}}” is already there.', { name: moveTarget.name }) : t('Moved “{{name}}” to {{folder}}', { name: moveTarget.name, folder }));
      setMoveTarget(null);
    } catch (err) {
      setStatus(t('Couldn’t move: {{error}}', { error: (err as Error).message }));
    } finally {
      setMoveBusy(false);
    }
  };

  const handleArchive = async (id: string, archived: boolean) => {
    try {
      await archiveProject(id, archived);
      await loadProjects();
    } catch (err) {
      setStatus(t('操作失败: {{error}}', { error: String(err) }));
    }
  };

  const handleTrash = async (id: string, trashed: boolean) => {
    try {
      await trashProject(id, trashed);
      await loadProjects();
    } catch (err) {
      setStatus(t('操作失败: {{error}}', { error: String(err) }));
    }
  };

  const handlePermanentDelete = async (id: string, name: string) => {
    if (!window.confirm(t('Delete “{{name}}” forever? Its folder and all its files are removed from disk. This can’t be undone.', { name }))) return;
    try {
      await permanentDeleteProject(id);
      await loadProjects();
    } catch (err) {
      setStatus(t('删除失败: {{error}}', { error: String(err) }));
    }
  };

  const handleEmptyTrash = async () => {
    if (!window.confirm(t('确定清空回收站？所有项目将被永久删除。'))) return;
    const trashItems = projects.filter((p) => p.trashed);
    for (const p of trashItems) {
      try { await permanentDeleteProject(p.id); } catch {}
    }
    await loadProjects();
  };

  // Bulk actions on the checked rows.
  const bulkRun = async (action: (id: string) => Promise<unknown>) => {
    const ids = [...selectedIds];
    for (const id of ids) {
      try { await action(id); } catch (err) { setStatus(String(err)); }
    }
    setSelectedIds(new Set());
    await Promise.all([loadProjects(), loadFolders()]);
  };

  const bulkDeleteForever = async () => {
    if (!window.confirm(t('Delete {{count}} projects forever? Their folders are removed from disk. This can’t be undone.', { count: selectedIds.size }))) return;
    await bulkRun((id) => permanentDeleteProject(id));
  };

  const handleAddTag = async (id: string, tag: string) => {
    const proj = projects.find((p) => p.id === id);
    if (!proj) return;
    const tags = [...new Set([...(proj.tags || []), tag])];
    try {
      await updateProjectTags(id, tags);
      await loadProjects();
    } catch (err) {
      setStatus(t('操作失败: {{error}}', { error: String(err) }));
    }
  };

  const handleRemoveTag = async (id: string, tag: string) => {
    const proj = projects.find((p) => p.id === id);
    if (!proj) return;
    const tags = (proj.tags || []).filter((t) => t !== tag);
    try {
      await updateProjectTags(id, tags);
      await loadProjects();
    } catch (err) {
      setStatus(t('操作失败: {{error}}', { error: String(err) }));
    }
  };

  const handleCreateFromTemplate = async (tplId: string) => {
    const tpl = templates.find((t) => t.id === tplId);
    const name = createName.trim() || tpl?.label || 'Untitled';
    try {
      const created = await createProject({ name, template: tplId });
      setTemplateGalleryOpen(false);
      setCreateName('');
      await loadProjects();
      navigate(`/editor/${created.id}`);
    } catch (err) {
      setStatus(t('创建失败: {{error}}', { error: String(err) }));
    }
  };

  const handleUploadTemplate = async (file: File) => {
    const baseName = file.name.replace(/\.zip$/i, '').replace(/[^a-zA-Z0-9_-]/g, '_');
    const templateId = baseName.toLowerCase();
    const templateLabel = baseName;
    setUploadingTemplate(true);
    try {
      await uploadTemplate(templateId, templateLabel, file);
      const res = await listTemplates();
      setTemplates(res.templates || []);
      setCategories(res.categories || []);
      setStatus(t('模板上传成功'));
    } catch (err) {
      setStatus(t('模板上传失败: {{error}}', { error: String(err) }));
    } finally {
      setUploadingTemplate(false);
      if (templateZipRef.current) templateZipRef.current.value = '';
    }
  };

  const handleCopy = async (id: string, originalName: string) => {
    try {
      const res = await copyProject(id, `${originalName} (Copy)`);
      if (!res.ok || !res.project) throw new Error(res.error || 'Copy failed');
      await loadProjects();
    } catch (err) {
      setStatus(t('复制失败: {{error}}', { error: String(err) }));
    }
  };

  const handleImportZip = async (file: File) => {
    setImporting(true);
    try {
      const res = await importZip({ file, projectName: file.name.replace(/\.zip$/i, '') || t('Imported Project'), folder: newProjectFolder || undefined });
      if (!res.ok || !res.project) {
        throw new Error(res.error || t('导入失败'));
      }
      setImportOpen(false);
      await loadProjects();
      navigate(`/editor/${res.project.id}`);
    } catch (err) {
      setStatus(t('Zip 导入失败: {{error}}', { error: String(err) }));
    } finally {
      setImporting(false);
    }
  };

  const handleImportArxiv = async () => {
    if (!arxivInput.trim()) {
      setStatus(t('请输入 arXiv URL 或 ID。'));
      return;
    }
    setImporting(true);
    setImportProgress({ phase: 'download', percent: 0 });
    try {
      const res = await importArxivSSE(
        { arxivIdOrUrl: arxivInput.trim(), folder: newProjectFolder || undefined },
        (prog) => setImportProgress(prog)
      );
      if (!res.ok || !res.project) {
        throw new Error(res.error || t('导入失败'));
      }
      setArxivInput('');
      setImportOpen(false);
      await loadProjects();
      navigate(`/editor/${res.project.id}`);
    } catch (err) {
      setStatus(t('arXiv 导入失败: {{error}}', { error: String(err) }));
    } finally {
      setImporting(false);
      setImportProgress(null);
    }
  };


  const navIcons: Record<ViewFilter, React.ReactNode> = {
    all: <IconFolder size={18} />,
    mine: <IconFile size={18} />,
    archived: <IconArchive size={18} />,
    trash: <IconTrash size={18} />,
  };
  const navItems: { key: ViewFilter; label: string }[] = [
    { key: 'all', label: t('所有项目') },
    { key: 'mine', label: t('我的项目') },
    { key: 'archived', label: t('已归档') },
    { key: 'trash', label: t('回收站') },
  ];

  const submitSharedLink = async () => {
    const link = sharedLink.trim();
    if (!link || sharedLinkBusy) return;
    setSharedLinkBusy(true);
    setSharedLinkError('');
    try {
      await addSharedWithMe(link);
      setSharedLinkOpen(false);
      setSharedLink('');
      setSharedView(true);
      setActiveTag(null);
      setSharedReload((n) => n + 1);
    } catch (err) {
      setSharedLinkError((err as Error).message);
    } finally {
      setSharedLinkBusy(false);
    }
  };

  return (
    <div className="project-shell">
      {/* ── Sidebar ── */}
      <aside className="project-sidebar">
        <div className="sidebar-brand nm-brand">
          <NumenorMark size={40} />
          <div>
            <div className="brand-title">Numenor</div>
            <div className="brand-sub">{t('Projects Workspace')}</div>
          </div>
        </div>

        <button className="sidebar-create-btn nm-primary" onClick={() => setCreateOpen(true)}>
          <IconPlus size={16} /> {t('新建项目')}
        </button>
        <div className="sidebar-actions-row">
          <button className="btn ghost" style={{ flex: 1 }} onClick={() => setImportOpen(true)}>{t('导入项目')}</button>
          <button className="btn ghost" style={{ flex: 1 }} onClick={() => setTemplateGalleryOpen(true)}>{t('模板库')}</button>
        </div>
        <button className="btn ghost nm-add-shared-btn" onClick={() => { setSharedLink(''); setSharedLinkError(''); setSharedLinkOpen(true); }} title={t('Add a project someone shared with you, using the link they sent')}>
          <IconLink size={15} /> {t('Add shared link')}
        </button>

        <nav className="sidebar-nav">
          {navItems.map((item) => (
            <div
              key={item.key}
              className={`sidebar-nav-item${viewFilter === item.key && !activeTag && !sharedView ? ' active' : ''}`}
              onClick={() => { setViewFilter(item.key); setActiveTag(null); setSharedView(false); }}
            >
              <span className="sidebar-nav-icon">{navIcons[item.key]}</span>
              <span className="sidebar-nav-label">{item.label}</span>
              <span className="sidebar-nav-count">{viewCounts[item.key]}</span>
            </div>
          ))}
          <div className={`sidebar-nav-item${sharedView ? ' active' : ''}`} onClick={() => { setSharedView(true); setActiveTag(null); }}>
            <span className="sidebar-nav-icon"><IconShare size={18} /></span>
            <span className="sidebar-nav-label">{t('Shared with me')}</span>
            <span className="sidebar-nav-count">{sharedCount ?? ''}</span>
          </div>
        </nav>

        <div className="sidebar-tags-section">
          <div className="sidebar-tags-header" onClick={() => setTagsExpanded(!tagsExpanded)}>
            <span className="nm-tags-title"><IconTag size={16} /> {t('Tags')}</span>
            <span className="nm-tags-caret">{tagsExpanded ? <IconChevronDown size={14} /> : <IconChevronDown size={14} style={{ transform: 'rotate(-90deg)' }} />}</span>
          </div>
          {tagsExpanded && (
            <div className="sidebar-tags-list">
              {allTags.map((tag) => (
                <div
                  key={tag}
                  className={`sidebar-tag-item${activeTag === tag ? ' active' : ''}`}
                  onClick={() => setActiveTag(activeTag === tag ? null : tag)}
                >
                  <span className="tag-dot" />
                  <span>{tag}</span>
                </div>
              ))}
              {addingSidebarTag ? (
                <input
                  className="sidebar-tag-input"
                  autoFocus
                  value={newSidebarTag}
                  onChange={(e) => setNewSidebarTag(e.target.value)}
                  placeholder={t('输入标签名称')}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && newSidebarTag.trim()) {
                      setAddingSidebarTag(false);
                      setNewSidebarTag('');
                    }
                    if (e.key === 'Escape') { setAddingSidebarTag(false); setNewSidebarTag(''); }
                  }}
                  onBlur={() => { setAddingSidebarTag(false); setNewSidebarTag(''); }}
                />
              ) : (
                <div className="sidebar-new-tag-btn" onClick={() => setAddingSidebarTag(true)}>
                  <IconPlus size={13} /> {t('新建标签')}
                </div>
              )}
            </div>
          )}
        </div>
      </aside>

      {/* ── Main Content ── */}
      <div className="project-main">
        <header className="project-main-header">
          <h1 className="project-main-title">
            {sharedView ? t('Shared with me') : activeTag ? `${t('标签')}: ${activeTag}` : navItems.find((n) => n.key === viewFilter)?.label || t('所有项目')}
          </h1>
          <div className="project-main-header-actions">
            {viewFilter === 'trash' && viewCounts.trash > 0 && (
              <button className="btn ghost" onClick={handleEmptyTrash}>{t('清空回收站')}</button>
            )}
            <div className="ios-select-wrapper">
              <button className="ios-select-trigger" onClick={() => setLangDropdownOpen(!langDropdownOpen)}>
                <span>{i18n.language === 'en-US' ? t('English') : t('中文')}</span>
                <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={langDropdownOpen ? 'rotate' : ''}>
                  <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </button>
              {langDropdownOpen && (
                <div className="ios-dropdown dropdown-down">
                  {([['zh-CN', t('中文')], ['en-US', t('English')]] as [string, string][]).map(([val, label]) => (
                    <div key={val} className={`ios-dropdown-item ${i18n.language === val ? 'active' : ''}`} onClick={() => { i18n.changeLanguage(val); setLangDropdownOpen(false); }}>
                      {label}
                      {i18n.language === val && (
                        <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
            <button className="nm-icon-btn" onClick={() => setSettingsOpen(true)}><IconGear size={16} /> {t('设置')}</button>
          </div>
        </header>

        {sharedView ? <SharedWithMe key={sharedReload} onCount={setSharedCount} /> : (<>
        {folders.length > 0 && (
          <div className="nm-folders" aria-label={t('Project folders')}>
            <div className="nm-folders-label">{t('Project folders')}</div>
            <div className="nm-folders-chips">
              {folders.map((folder) => {
                const isTarget = newProjectFolder === folder.path;
                return (
                  <div
                    key={folder.path}
                    className={`nm-folder-chip ${folderFilter === folder.path ? 'active' : ''} ${folder.exists ? '' : 'missing'}`}
                    title={`${folder.path}${folder.exists ? '' : ` — ${t('not available right now')}`}\n${folderFilter === folder.path ? t('Click to show all projects') : t('Click to show only this folder')}`}
                  >
                    <button className="nm-folder-main" onClick={() => setFolderFilter(folderFilter === folder.path ? '' : folder.path)}>
                      <IconFolder size={17} />
                      <span className="nm-folder-name">
                        <span className="nm-folder-label">{folder.cloud === 'google' ? `Google Drive / ${folderLabel(folder.path).split(' / ').pop()}` : folderLabel(folder.path)}</span>
                        <span className="nm-folder-path">{folder.path}</span>
                      </span>
                    </button>
                    <button
                      className={`nm-folder-copy ${copiedFolder === folder.path ? 'done' : ''}`}
                      onClick={() => copyFolderPath(folder.path)}
                      title={copiedFolder === folder.path ? t('Copied') : t('Copy the full path')}
                      aria-label={t('Copy the full path')}
                    >
                      {copiedFolder === folder.path ? <IconCheck size={15} /> : <IconCopy size={15} />}
                    </button>
                    <button
                      className={`nm-folder-star ${isTarget ? 'on' : ''}`}
                      onClick={() => chooseTargetFolder(folder.path)}
                      title={isTarget ? t('New projects are created here') : t('Create new projects here')}
                      aria-label={isTarget ? t('Default location') : t('Make default location')}
                    >
                      <IconStar size={15} filled={isTarget} />
                    </button>
                    <span className="nm-folder-count">{folder.projectCount}</span>
                    {!folder.primary && (
                      <button className="nm-folder-remove" onClick={() => handleRemoveFolder(folder)} title={t('Stop listing this folder (files are kept)')} aria-label={t('Remove folder')}>
                        ×
                      </button>
                    )}
                  </div>
                );
              })}
            </div>
            <button className="nm-icon-btn nm-folders-add" onClick={() => setFolderPickerOpen(true)}>
              <IconPlus size={14} /> {t('Add folder')}
            </button>
          </div>
        )}

        {folderPickerOpen && (
          <FolderPicker
            existing={folders.map((f) => f.path)}
            onChoose={handleAddFolder}
            onClose={() => {
              setFolderPickerOpen(false);
              if (pendingMoveRef.current) {
                setMoveTarget(pendingMoveRef.current);
                pendingMoveRef.current = null;
              }
            }}
          />
        )}

        {moveTarget && (
          <div className="modal-backdrop" onClick={() => !moveBusy && setMoveTarget(null)}>
            <div className="modal move-modal" onClick={(e) => e.stopPropagation()}>
              <div className="modal-header">
                <div>{t('Move “{{name}}”', { name: moveTarget.name })}</div>
                <button className="icon-btn" onClick={() => setMoveTarget(null)} disabled={moveBusy}>✕</button>
              </div>
              <div className="modal-body">
                <div className="muted move-hint">{t('Choose where this project should live. Moving into a Google Drive folder uploads it to Google Drive (through Google Drive for desktop); moving it back out removes it from Google Drive.')}</div>
                <div className="move-list">
                  {folders.map((folder) => {
                    const here = moveTarget.folder === folder.path;
                    return (
                      <button
                        key={folder.path}
                        className={`move-option ${here ? 'here' : ''} ${folder.cloud === 'google' ? 'google' : ''}`}
                        onClick={() => !here && handleMove(folder.path)}
                        disabled={moveBusy || here || !folder.exists}
                        title={folder.path}
                      >
                        <span className="move-icon">{folder.cloud === 'google' ? '☁︎' : folder.primary ? '🏠' : '📁'}</span>
                        <span className="move-text">
                          <span className="move-name">{folder.primary ? t('Main folder (this Mac)') : folder.cloud === 'google' ? t('Google Drive') : shortFolder(folder.path)}</span>
                          <span className="move-path">{folder.path}</span>
                        </span>
                        <span className="move-state">{here ? t('Here now') : moveBusy ? '…' : folder.cloud === 'google' ? t('Upload') : t('Move here')}</span>
                      </button>
                    );
                  })}
                </div>
                {!folders.some((f) => f.cloud === 'google') && (
                  <div className="move-drive-cta">
                    <div>{t('No Google Drive folder added yet.')}</div>
                    <button
                      className="btn small"
                      onClick={() => {
                        pendingMoveRef.current = moveTarget;
                        setMoveTarget(null);
                        setFolderPickerOpen(true);
                      }}
                    >
                      {t('Add a Google Drive folder…')}
                    </button>
                  </div>
                )}
              </div>
            </div>
          </div>
        )}

        {status && (
          <div className="status-bar">
            <div>{status}</div>
            {undoTrash && (
              <button className="btn ghost small" onClick={() => undoDelete()}>{t('Undo')}</button>
            )}
          </div>
        )}

        <div className="project-toolbar">
          <label className="nm-search">
            <IconSearch size={17} />
            <input
              className="project-search"
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder={t('搜索项目...')}
            />
          </label>
          <div className="ios-select-wrapper">
            <button className="ios-select-trigger" onClick={() => setSortDropdownOpen(!sortDropdownOpen)}>
              <span>{sortBy === 'updatedAt' ? t('最近修改') : sortBy === 'name' ? t('按名称') : t('创建时间')}</span>
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={sortDropdownOpen ? 'rotate' : ''}>
                <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </button>
            {sortDropdownOpen && (
              <div className="ios-dropdown dropdown-down">
                {([['updatedAt', t('最近修改')], ['name', t('按名称')], ['createdAt', t('创建时间')]] as [SortBy, string][]).map(([val, label]) => (
                  <div key={val} className={`ios-dropdown-item ${sortBy === val ? 'active' : ''}`} onClick={() => { setSortBy(val); setSortDropdownOpen(false); }}>
                    {label}
                    {sortBy === val && (
                      <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        {selectedIds.size > 0 && (
          <div className="nm-bulk">
            <span>{t('{{count}} selected', { count: selectedIds.size })}</span>
            {viewFilter === 'trash' ? (
              <>
                <button className="nm-icon-btn" onClick={() => bulkRun((id) => trashProject(id, false))}>{t('恢复')}</button>
                <button className="nm-icon-btn danger-text" onClick={() => bulkDeleteForever()}>{t('Delete forever')}</button>
              </>
            ) : (
              <>
                <button className="nm-icon-btn" onClick={() => bulkRun((id) => archiveProject(id, viewFilter !== 'archived'))}>
                  <IconArchive size={15} /> {viewFilter === 'archived' ? t('取消归档') : t('归档')}
                </button>
                <button className="nm-icon-btn danger-text" onClick={() => bulkRun((id) => deleteProject(id))}>
                  <IconTrash size={15} /> {t('Move to Trash')}
                </button>
              </>
            )}
            <button className="nm-icon-btn borderless" onClick={() => setSelectedIds(new Set())}>{t('Clear selection')}</button>
          </div>
        )}

        {/* ── Project Table ── */}
        <div className="project-table-wrapper">
          <table className="project-table">
            <thead>
              <tr>
                <th className="col-check">
                  <input
                    type="checkbox"
                    checked={filteredProjects.length > 0 && selectedIds.size === filteredProjects.length}
                    onChange={(e) => {
                      if (e.target.checked) setSelectedIds(new Set(filteredProjects.map((p) => p.id)));
                      else setSelectedIds(new Set());
                    }}
                  />
                </th>
                <th className="col-name">{t('名称')}</th>
                <th className="col-tags">{t('标签')}</th>
                <th className="col-modified">{t('最后修改')}</th>
                <th className="col-actions">{t('操作')}</th>
              </tr>
            </thead>
            <tbody>
              {filteredProjects.map((project) => (
                <tr key={project.id} className={`project-table-row${selectedIds.has(project.id) ? ' selected' : ''}`}>
                  <td className="col-check">
                    <input
                      type="checkbox"
                      checked={selectedIds.has(project.id)}
                      onChange={(e) => {
                        const next = new Set(selectedIds);
                        if (e.target.checked) next.add(project.id); else next.delete(project.id);
                        setSelectedIds(next);
                      }}
                    />
                  </td>
                  <td className="col-name">
                    {renameState?.id === project.id ? (
                      <input
                        className="inline-input"
                        autoFocus
                        value={renameState.value}
                        onChange={(e) => setRenameState({ ...renameState, value: e.target.value })}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') { e.preventDefault(); handleRename(); }
                          if (e.key === 'Escape') { e.preventDefault(); setRenameState(null); }
                        }}
                        onBlur={() => setRenameState(null)}
                      />
                    ) : (
                      <span className="nm-name">
                        <IconFile size={18} />
                        <span className="project-name-link" onClick={() => navigate(`/editor/${project.id}`)} title={project.name}>
                          {project.name}
                        </span>
                        {project.archived && !project.trashed && <span className="nm-badge">{t('已归档')}</span>}
                      </span>
                    )}
                    {project.folder && project.folder !== primaryFolder && renameState?.id !== project.id && (
                      <span className="project-folder-badge" title={project.folder}>
                        {/CloudStorage\/GoogleDrive-|\/Google Drive\//.test(project.folder) ? '☁︎ ' : '📁 '}
                        {shortFolder(project.folder)}
                      </span>
                    )}
                  </td>
                  <td className="col-tags">
                    <div style={{ display: 'flex', gap: '4px', flexWrap: 'wrap', alignItems: 'center' }}>
                      {(project.tags || []).map((tag) => (
                        <span key={tag} className="project-tag-pill" onClick={() => setActiveTag(tag)}>
                          {tag}
                          {viewFilter !== 'trash' && (
                            <span style={{ marginLeft: 4, cursor: 'pointer' }} onClick={(e) => { e.stopPropagation(); handleRemoveTag(project.id, tag); }}>&times;</span>
                          )}
                        </span>
                      ))}
                      {viewFilter !== 'trash' && (
                        tagEditId === project.id ? (
                          <input
                            className="sidebar-tag-input"
                            style={{ width: 80, fontSize: 12 }}
                            autoFocus
                            value={tagInput}
                            onChange={(e) => setTagInput(e.target.value)}
                            placeholder={t('添加标签')}
                            onKeyDown={(e) => {
                              if (e.key === 'Enter' && tagInput.trim()) {
                                handleAddTag(project.id, tagInput.trim());
                                setTagInput('');
                                setTagEditId(null);
                              }
                              if (e.key === 'Escape') { setTagEditId(null); setTagInput(''); }
                            }}
                            onBlur={() => { setTagEditId(null); setTagInput(''); }}
                          />
                        ) : (
                          <button
                            className="nm-tag-add"
                            onClick={() => { setTagEditId(project.id); setTagInput(''); }}
                            title={t('添加标签')}
                            aria-label={t('添加标签')}
                          ><IconPlus size={13} /></button>
                        )
                      )}
                    </div>
                  </td>
                  <td className="col-modified">
                    {formatRelativeTime(project.updatedAt || project.createdAt, t)}
                  </td>
                  <td className="col-actions">
                    <div className="col-actions-inner">
                      {viewFilter === 'trash' ? (
                        <button className="nm-open" onClick={() => handleTrash(project.id, false)}>{t('恢复')}</button>
                      ) : (
                        <button className="nm-open" onClick={() => navigate(`/editor/${project.id}`)}>{t('打开')}</button>
                      )}
                      <div className="nm-menu">
                        <button
                          className="nm-icon-btn nm-dots"
                          onClick={() => setMoreMenuId(moreMenuId === project.id ? '' : project.id)}
                          aria-label={t('More actions')}
                          aria-haspopup="menu"
                          aria-expanded={moreMenuId === project.id}
                        >
                          <IconDots size={18} />
                        </button>
                        {moreMenuId === project.id && (
                          <>
                            <div className="nm-menu-backdrop" onClick={() => setMoreMenuId('')} />
                            <div className="nm-menu-list" role="menu" onClick={() => setMoreMenuId('')}>
                              {viewFilter === 'trash' ? (
                                <button className="nm-menu-item danger" role="menuitem" onClick={() => handlePermanentDelete(project.id, project.name)}>{t('Delete forever')}</button>
                              ) : (
                                <>
                                  <button className="nm-menu-item" role="menuitem" onClick={() => setRenameState({ id: project.id, value: project.name })}>{t('重命名')}</button>
                                  <button className="nm-menu-item" role="menuitem" onClick={() => handleCopy(project.id, project.name)}>{t('复制')}</button>
                                  <button className="nm-menu-item" role="menuitem" onClick={() => { setTransferSource({ id: project.id, name: project.name }); setTransferOpen(true); }}>{t('转换')}</button>
                                  {project.archived
                                    ? <button className="nm-menu-item" role="menuitem" onClick={() => handleArchive(project.id, false)}>{t('取消归档')}</button>
                                    : <button className="nm-menu-item" role="menuitem" onClick={() => handleArchive(project.id, true)}>{t('归档')}</button>}
                                  <div className="nm-menu-sep" />
                                  <button className="nm-menu-item" role="menuitem" onClick={() => setMoveTarget(project)}>{t('Move to folder…')}</button>
                                  <button className="nm-menu-item" role="menuitem" onClick={() => downloadZip(project)}>{t('Download .zip')}</button>
                                  <div className="nm-menu-sep" />
                                  <button className="nm-menu-item danger" role="menuitem" onClick={() => handleDelete(project.id, project.name)}>{t('Move to Trash')}</button>
                                </>
                              )}
                            </div>
                          </>
                        )}
                      </div>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {filteredProjects.length === 0 && (
            <div className="project-table-empty">{t('暂无项目。')}</div>
          )}
        </div>

        <div className="project-footer">
          {filteredProjects.length === 1 ? t('1 project') : t('{{count}} projects', { count: filteredProjects.length })}
        </div>
        </>)}
      </div>

      <input
        ref={zipInputRef}
        type="file"
        accept=".zip"
        style={{ display: 'none' }}
        onChange={(event) => {
          const file = event.target.files?.[0];
          if (file) {
            handleImportZip(file);
          }
          if (event.target) {
            event.target.value = '';
          }
        }}
      />

      {sharedLinkOpen && (
        <div className="modal-backdrop" onClick={() => !sharedLinkBusy && setSharedLinkOpen(false)}>
          <div className="modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('Add shared link')}</div>
              <button className="icon-btn" onClick={() => setSharedLinkOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>{t('Invite link')}</label>
                <input
                  className="input"
                  autoFocus
                  value={sharedLink}
                  onChange={(event) => setSharedLink(event.target.value)}
                  onKeyDown={(event) => event.key === 'Enter' && submitSharedLink()}
                  placeholder="https://…/collab?token=…"
                />
              </div>
              <div className="muted">{t('Paste the link someone sent you for their Numenor project (it contains “/collab?token=”). It is saved under “Shared with me”, so you can open it from here any time while its owner is sharing.')}</div>
              {sharedLinkError && <div className="share-error">{sharedLinkError}</div>}
            </div>
            <div className="modal-actions">
              <button className="btn ghost" onClick={() => setSharedLinkOpen(false)}>{t('取消')}</button>
              <button className="btn nm-primary" onClick={submitSharedLink} disabled={sharedLinkBusy || !sharedLink.trim()}>{sharedLinkBusy ? t('Checking…') : t('Add shared project')}</button>
            </div>
          </div>
        </div>
      )}

      {createOpen && (
        <div className="modal-backdrop" onClick={() => setCreateOpen(false)}>
          <div className="modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('新建项目')}</div>
              <button className="icon-btn" onClick={() => setCreateOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>{t('项目名称')}</label>
                <input
                  className="input"
                  value={createName}
                  onChange={(event) => setCreateName(event.target.value)}
                  placeholder={t('My Paper')}
                />
              </div>
              {folders.length > 1 && (
                <div className="field">
                  <label>{t('Location')}</label>
                  <select className="input" value={newProjectFolder} onChange={(e) => chooseTargetFolder(e.target.value)}>
                    {folders.map((f) => (
                      <option key={f.path} value={f.path}>{f.primary ? `${t('Main folder')} — ${f.path}` : f.path}</option>
                    ))}
                  </select>
                </div>
              )}
              <div className="field">
                <label>{t('模板')}</label>
                <div className="ios-select-wrapper">
                  <button className="ios-select-trigger" onClick={() => setTemplateDropdownOpen(!templateDropdownOpen)}>
                    <span>{templates.find((tpl) => tpl.id === createTemplate)?.label || '—'}</span>
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" className={templateDropdownOpen ? 'rotate' : ''}>
                      <path d="M3 5L6 8L9 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                    </svg>
                  </button>
                  {templateDropdownOpen && (
                    <div className="ios-dropdown dropdown-down">
                      {templates.map((tpl) => (
                        <div key={tpl.id} className={`ios-dropdown-item ${createTemplate === tpl.id ? 'active' : ''}`} onClick={() => { setCreateTemplate(tpl.id); setTemplateDropdownOpen(false); }}>
                          {tpl.label}
                          {createTemplate === tpl.id && (
                            <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M3 8L6.5 11.5L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                          )}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </div>
            <div className="modal-actions">
              <button className="btn ghost" onClick={() => setCreateOpen(false)}>{t('取消')}</button>
              <button className="btn" onClick={handleCreate}>{t('创建')}</button>
            </div>
          </div>
        </div>
      )}

      {importOpen && (
        <div className="modal-backdrop" onClick={() => setImportOpen(false)}>
          <div className="modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('导入项目')}</div>
              <button className="icon-btn" onClick={() => setImportOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>{t('上传 Zip 文件')}</label>
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                  <button
                    className="btn"
                    onClick={() => zipInputRef.current?.click()}
                    disabled={importing}
                  >
                    {t('选择文件')}
                  </button>
                  {importing && <span className="muted">{t('导入中...')}</span>}
                </div>
              </div>
              <div className="field" style={{ borderTop: '1px solid var(--border, #e0e0e0)', paddingTop: '12px', marginTop: '4px' }}>
                <label>{t('arXiv 链接导入')}</label>
                <input
                  className="input"
                  value={arxivInput}
                  onChange={(event) => setArxivInput(event.target.value)}
                  placeholder={t('arXiv URL 或 ID，例如 2301.00001')}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') {
                      event.preventDefault();
                      handleImportArxiv();
                    }
                  }}
                />
              </div>
              {importProgress && (
                <div className="field" style={{ paddingTop: '8px' }}>
                  <label>
                    {importProgress.phase === 'download'
                      ? importProgress.percent >= 0
                        ? t('下载中... {{percent}}%', { percent: importProgress.percent })
                        : t('下载中...')
                      : t('解压中...')}
                  </label>
                  <div style={{
                    width: '100%',
                    height: '6px',
                    background: 'var(--border, #e0e0e0)',
                    borderRadius: '3px',
                    overflow: 'hidden',
                    marginTop: '4px'
                  }}>
                    <div style={{
                      width: importProgress.percent >= 0 ? `${importProgress.percent}%` : '100%',
                      height: '100%',
                      background: 'var(--accent, #4a90d9)',
                      borderRadius: '3px',
                      transition: 'width 0.3s ease',
                      animation: importProgress.percent < 0 ? 'indeterminate 1.5s infinite linear' : undefined
                    }} />
                  </div>
                </div>
              )}
            </div>
            <div className="modal-actions">
              <button className="btn ghost" onClick={() => setImportOpen(false)}>{t('取消')}</button>
              <button className="btn" onClick={handleImportArxiv} disabled={importing || !arxivInput.trim()}>
                {t('导入 arXiv')}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Template Gallery Modal ── */}
      {templateGalleryOpen && (
        <div className="modal-backdrop" onClick={() => setTemplateGalleryOpen(false)}>
          <div className="modal template-gallery-modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div className="template-gallery-header-left">
                <button className="btn ghost" onClick={() => setTemplateGalleryOpen(false)}>{t('返回')}</button>
                <span>{t('模板库')}</span>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input
                  ref={templateZipRef}
                  type="file"
                  accept=".zip"
                  style={{ display: 'none' }}
                  onChange={(e) => {
                    const f = e.target.files?.[0];
                    if (f) handleUploadTemplate(f);
                  }}
                />
                <button
                  className="btn ghost"
                  disabled={uploadingTemplate}
                  onClick={() => templateZipRef.current?.click()}
                >
                  {uploadingTemplate ? t('上传中...') : t('上传模板')}
                </button>
                <button className="icon-btn" onClick={() => setTemplateGalleryOpen(false)}>✕</button>
              </div>
            </div>
            <div className="modal-body">
              <div className="template-gallery-subtitle">{t('选择模板快速开始您的项目')}</div>

              <div className="template-gallery-categories">
                {[{ id: 'all', label: t('全部'), labelEn: 'All' }, ...(categories || [])].map((cat) => (
                  <button
                    key={cat.id}
                    className={`template-cat-tab${galleryCat === cat.id ? ' active' : ''}`}
                    onClick={() => setGalleryCat(cat.id)}
                  >
                    {i18n.language === 'en-US' ? cat.labelEn : cat.label}
                  </button>
                ))}
              </div>

              <div className="template-gallery-filters">
                <label style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 13 }}>
                  <input type="checkbox" checked={galleryFeatured} onChange={(e) => setGalleryFeatured(e.target.checked)} />
                  {t('精选模板')}
                </label>
                <input
                  className="project-search"
                  value={gallerySearch}
                  onChange={(e) => setGallerySearch(e.target.value)}
                  placeholder={t('搜索模板...')}
                  style={{ maxWidth: 240 }}
                />
              </div>

              <div className="template-gallery-grid">
                {galleryTemplates.map((tpl) => (
                  <div key={tpl.id} className="template-card" onClick={() => handleCreateFromTemplate(tpl.id)}>
                    <div className="template-card-thumb">
                      {tpl.featured && <span className="template-card-badge">Featured</span>}
                    </div>
                    <div className="template-card-body">
                      <div className="template-card-title">{tpl.label}</div>
                      <div className="template-card-desc">
                        {i18n.language === 'en-US' ? (tpl.descriptionEn || tpl.description) : tpl.description}
                      </div>
                      {tpl.tags?.length > 0 && (
                        <div className="template-card-tags">
                          {tpl.tags.map((tag) => <span key={tag} className="project-tag-pill">{tag}</span>)}
                        </div>
                      )}
                      {tpl.author && <div className="template-card-author">{tpl.author}</div>}
                    </div>
                  </div>
                ))}
              </div>
              {galleryTemplates.length === 0 && (
                <div className="template-gallery-empty">{t('暂无匹配模板')}</div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Transfer Modal */}
      {transferOpen && transferSource && (
        <div className="modal-backdrop" onClick={() => setTransferOpen(false)}>
          <div className="modal" onClick={(event) => event.stopPropagation()}>
            <div className="modal-header">
              <div>{t('模板转换')} — {transferSource.name}</div>
              <button className="icon-btn" onClick={() => setTransferOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <TransferPanel
                projectId={transferSource.id}
                onJobUpdate={(job) => {
                  setActiveJob({ ...job, sourceName: transferSource.name });
                  setJobWidgetOpen(true);
                  if (job.status === 'success') loadProjects();
                }}
              />
            </div>
          </div>
        </div>
      )}

      {/* Floating transfer progress widget */}
      {activeJob && !transferOpen && jobWidgetOpen && (
        <div className="transfer-widget">
          <div className="transfer-widget-header">
            <span>{t('模板转换')} — {activeJob.sourceName || ''}</span>
            <div style={{ display: 'flex', gap: 4 }}>
              <button className="icon-btn" onClick={() => {
                setTransferOpen(true);
                if (transferSource) setTransferSource(transferSource);
              }} title={t('展开')}>&#x2197;</button>
              <button className="icon-btn" onClick={() => setJobWidgetOpen(false)}>✕</button>
            </div>
          </div>
          <div className="transfer-widget-status">
            <strong>{t('状态')}:</strong> {activeJob.status}
          </div>
          {activeJob.error && (
            <div className="transfer-widget-error">{activeJob.error}</div>
          )}
          {activeJob.progressLog.length > 0 && (
            <div className="transfer-widget-log">
              {activeJob.progressLog.map((line, i) => (
                <div key={i}>{line}</div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Settings Modal */}
      {settingsOpen && (
        <div className="modal-backdrop" onClick={() => setSettingsOpen(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <div>{t('设置')}</div>
              <button className="icon-btn" onClick={() => setSettingsOpen(false)}>✕</button>
            </div>
            <div className="modal-body">
              <div className="field">
                <label>{t('LLM Endpoint')}</label>
                <input
                  className="input"
                  type="text"
                  placeholder="https://api.openai.com/v1/chat/completions"
                  value={settingsForm.llmEndpoint}
                  onChange={(e) => setSettingsForm((p) => ({ ...p, llmEndpoint: e.target.value }))}
                />
              </div>
              <div className="field">
                <label>{t('LLM API Key')}</label>
                <input
                  className="input"
                  type="password"
                  placeholder="sk-..."
                  value={settingsForm.llmApiKey}
                  onChange={(e) => setSettingsForm((p) => ({ ...p, llmApiKey: e.target.value }))}
                />
              </div>
              <div className="field">
                <label>{t('LLM Model')}</label>
                <input
                  className="input"
                  type="text"
                  placeholder="gpt-4o"
                  value={settingsForm.llmModel}
                  onChange={(e) => setSettingsForm((p) => ({ ...p, llmModel: e.target.value }))}
                />
              </div>
              <div style={{ fontSize: 11, color: 'var(--muted)', marginTop: 4 }}>
                {t('未配置 API Key 时将使用后端环境变量。')}
              </div>
            </div>
            <div className="modal-actions">
              <button className="btn ghost" onClick={() => { setSettingsForm(loadLLMSettings()); setSettingsOpen(false); }}>{t('取消')}</button>
              <button className="btn" onClick={() => { saveLLMSettings(settingsForm); setSettingsOpen(false); }}>{t('保存')}</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
