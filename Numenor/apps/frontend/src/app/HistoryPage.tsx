// A project's history: who changed which file, when, and the exact lines (added in green, removed in red).
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import {
  getHistory,
  getHistoryEntry,
  listProjects,
  restoreHistoryEntry,
  whoAmI,
  type DiffPart,
  type HistoryEntry,
  type Me
} from '../api/client';
import { IconArrowLeft, IconChevronRight, NumenorMark } from './icons';

const PALETTE = ['#c8902a', '#2f7fa8', '#8a5bb8', '#2f9e5b', '#c0533a', '#3b6fd6', '#b8457a', '#5b8a2f'];
function colorFor(name: string) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}
const initials = (name: string) =>
  name.split(/[\s&@._-]+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join('') || '?';

function dayLabel(d: Date, t: (k: string) => string) {
  const today = new Date();
  const yesterday = new Date(Date.now() - 86400000);
  if (d.toDateString() === today.toDateString()) return t('Today');
  if (d.toDateString() === yesterday.toDateString()) return t('Yesterday');
  return d.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
}

type Row = { kind: 'ctx' | 'add' | 'del' | 'gap'; text: string; a?: number; b?: number };

/** Line-by-line rows with old/new line numbers; long unchanged stretches fold to 3 lines of context. */
function toRows(parts: DiffPart[]): Row[] {
  const rows: Row[] = [];
  let a = 1;
  let b = 1;
  parts.forEach((part, idx) => {
    const lines = part.value.replace(/\n$/, '').split('\n');
    if (part.added) lines.forEach((text) => rows.push({ kind: 'add', text, b: b++ }));
    else if (part.removed) lines.forEach((text) => rows.push({ kind: 'del', text, a: a++ }));
    else {
      const first = idx === 0;
      const last = idx === parts.length - 1;
      const keepHead = first ? 0 : 3;
      const keepTail = last ? 0 : 3;
      if (lines.length > keepHead + keepTail + 1) {
        lines.slice(0, keepHead).forEach((text) => rows.push({ kind: 'ctx', text, a: a++, b: b++ }));
        const hidden = lines.length - keepHead - keepTail;
        rows.push({ kind: 'gap', text: String(hidden) });
        a += hidden;
        b += hidden;
        lines.slice(lines.length - keepTail).forEach((text) => rows.push({ kind: 'ctx', text, a: a++, b: b++ }));
      } else lines.forEach((text) => rows.push({ kind: 'ctx', text, a: a++, b: b++ }));
    }
  });
  return rows;
}

export default function HistoryPage() {
  const { projectId = '' } = useParams();
  const { t } = useTranslation();
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [selected, setSelected] = useState<string>('');
  const [detail, setDetail] = useState<{ entry: HistoryEntry; parts: DiffPart[] } | null>(null);
  const [fileFilter, setFileFilter] = useState('');
  const [personFilter, setPersonFilter] = useState('');
  const [projectName, setProjectName] = useState('');
  const [me, setMe] = useState<Me | null>(null);
  const [status, setStatus] = useState('');

  const load = useCallback(async () => {
    try {
      const res = await getHistory(projectId);
      setEntries(res.entries);
      setError('');
      setSelected((cur) => cur || res.entries.find((e) => e.action === 'edit' || e.action === 'create')?.id || '');
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [projectId]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 15000);
    whoAmI().then(setMe).catch(() => {});
    listProjects().then((res) => setProjectName(res.projects.find((p) => p.id === projectId)?.name || '')).catch(() => {});
    return () => window.clearInterval(timer);
  }, [load, projectId]);

  useEffect(() => {
    document.title = projectName ? `${t('History')} — ${projectName}` : t('History');
  }, [projectName, t]);

  useEffect(() => {
    if (!selected) {
      setDetail(null);
      return;
    }
    let stop = false;
    getHistoryEntry(projectId, selected)
      .then((res) => !stop && setDetail({ entry: res.entry, parts: res.parts }))
      .catch(() => !stop && setDetail(null));
    return () => {
      stop = true;
    };
  }, [projectId, selected]);

  const files = useMemo(() => [...new Set(entries.map((e) => e.path))].sort(), [entries]);
  const people = useMemo(() => [...new Set(entries.map((e) => e.author))].sort(), [entries]);
  const shown = entries.filter((e) => (!fileFilter || e.path === fileFilter || e.to === fileFilter) && (!personFilter || e.author === personFilter));
  const groups = useMemo(() => {
    const out: { label: string; items: HistoryEntry[] }[] = [];
    for (const e of shown) {
      const label = dayLabel(new Date(e.time), t);
      if (!out.length || out[out.length - 1].label !== label) out.push({ label, items: [] });
      out[out.length - 1].items.push(e);
    }
    return out;
  }, [shown, t]);

  const rows = useMemo(() => (detail ? toRows(detail.parts) : []), [detail]);
  const canRestore = me && me.role !== 'view';

  const describe = (e: HistoryEntry) => {
    switch (e.action) {
      case 'create': return t('created');
      case 'upload': return t('uploaded');
      case 'delete': return t('deleted');
      case 'rename': return t('renamed');
      case 'folder': return t('made folder');
      default: return t('edited');
    }
  };

  const restore = async (which: 'before' | 'after') => {
    if (!detail) return;
    const what = which === 'before' ? t('the version before this change') : t('the version right after this change');
    if (!window.confirm(t('Put {{file}} back to {{what}}? The current text is kept in the history.', { file: detail.entry.path, what }))) return;
    try {
      await restoreHistoryEntry(projectId, detail.entry.id, which);
      setStatus(t('{{file}} restored.', { file: detail.entry.path }));
      setSelected('');
      await load();
    } catch (err) {
      setStatus((err as Error).message);
    }
  };

  return (
    <div className="nm-history">
      <header className="top-bar nm-topbar">
        <div className="nm-topbar-left">
          <Link to="/projects" className="nm-brand-link" title={t('Projects')}>
            <NumenorMark size={30} />
            <span className="nm-wordmark">Numenor</span>
          </Link>
          <span className="nm-topbar-sep" />
          <Link to={`/editor/${projectId}`} className="nm-crumb-link"><IconArrowLeft size={15} /> {projectName || t('Project')}</Link>
          <IconChevronRight size={14} className="nm-crumb-sep" />
          <span className="nm-project-name">{t('History')}</span>
        </div>
        <div className="nm-topbar-right">
          <select className="input nm-history-filter" value={personFilter} onChange={(e) => setPersonFilter(e.target.value)} aria-label={t('Person')}>
            <option value="">{t('Everyone')}</option>
            {people.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
          <select className="input nm-history-filter" value={fileFilter} onChange={(e) => setFileFilter(e.target.value)} aria-label={t('File')}>
            <option value="">{t('All files')}</option>
            {files.map((f) => <option key={f} value={f}>{f}</option>)}
          </select>
        </div>
      </header>
      <div className="nm-history-body">
        <aside className="nm-history-list">
          {loading && <div className="muted nm-history-empty">{t('Loading…')}</div>}
          {error && <div className="share-error">{error}</div>}
          {!loading && !error && shown.length === 0 && (
            <div className="muted nm-history-empty">{t('No changes recorded yet. From now on every save — yours and the people you share with — shows up here.')}</div>
          )}
          {groups.map((g) => (
            <div key={g.label} className="nm-history-group">
              <div className="nm-history-day">{g.label}</div>
              {g.items.map((e) => (
                <button key={e.id} className={`nm-history-item ${selected === e.id ? 'on' : ''}`} onClick={() => setSelected(e.id)}>
                  <span className="nm-avatar" style={{ background: colorFor(e.author) }}>{initials(e.author)}</span>
                  <span className="nm-history-main">
                    <span className="nm-history-line">
                      <b>{e.author}</b> <span className="muted">{describe(e)}</span> <span className="nm-history-file">{e.path}{e.to ? ` → ${e.to}` : ''}</span>
                    </span>
                    <span className="nm-history-meta">
                      <span className="muted">{new Date(e.time).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}</span>
                      {e.kind === 'guest' && <span className="nm-badge">{t('invited')}</span>}
                      {(e.added > 0 || e.removed > 0) && (
                        <span className="nm-history-counts"><span className="add">+{e.added}</span> <span className="del">−{e.removed}</span></span>
                      )}
                    </span>
                  </span>
                </button>
              ))}
            </div>
          ))}
        </aside>
        <section className="nm-history-detail">
          {detail ? (
            <>
              <div className="nm-history-detail-head">
                <div>
                  <div className="nm-history-detail-title">{detail.entry.path}</div>
                  <div className="muted">
                    {t('{{who}} {{what}} on {{when}}', { who: detail.entry.author, what: describe(detail.entry), when: new Date(detail.entry.time).toLocaleString() })}
                    {(detail.entry.added > 0 || detail.entry.removed > 0) && (
                      <> · <span className="nm-history-counts"><span className="add">+{detail.entry.added}</span> <span className="del">−{detail.entry.removed}</span></span></>
                    )}
                  </div>
                </div>
                {canRestore && detail.parts.length > 0 && (
                  <div className="nm-history-actions">
                    <button className="btn ghost" onClick={() => restore('before')}>{t('Restore version before')}</button>
                    <button className="btn ghost" onClick={() => restore('after')}>{t('Restore this version')}</button>
                  </div>
                )}
              </div>
              {status && <div className="share-note">{status}</div>}
              {detail.parts.length ? (
                <div className="nm-diff" role="table">
                  {rows.map((r, i) =>
                    r.kind === 'gap' ? (
                      <div key={i} className="nm-diff-row gap"><span className="nm-diff-gap">⋯ {t('{{n}} unchanged lines', { n: r.text })}</span></div>
                    ) : (
                      <div key={i} className={`nm-diff-row ${r.kind}`}>
                        <span className="nm-diff-num">{r.a ?? ''}</span>
                        <span className="nm-diff-num">{r.b ?? ''}</span>
                        <span className="nm-diff-sign">{r.kind === 'add' ? '+' : r.kind === 'del' ? '−' : ''}</span>
                        <span className="nm-diff-text">{r.text || ' '}</span>
                      </div>
                    )
                  )}
                </div>
              ) : (
                <div className="muted nm-history-empty">{t('No text changes to show for this entry.')}</div>
              )}
            </>
          ) : (
            <div className="muted nm-history-empty">{entries.length ? t('Choose a change on the left to see exactly what was written or removed.') : ''}</div>
          )}
        </section>
      </div>
    </div>
  );
}
