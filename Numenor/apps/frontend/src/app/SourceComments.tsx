import { useEffect, useId, useLayoutEffect, useRef, useState, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import { useTranslation } from 'react-i18next';
import type { CommentAnchor, SourceComment } from '../api/client';

export function CommentIcon({ size = 15 }: { size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M20 11a7 7 0 0 1-7 7H8l-4 3v-7a7 7 0 0 1 7-10h2a7 7 0 0 1 7 7Z" />
  </svg>;
}

export function CommentBorder({ width, height }: { width: number; height: number }) {
  return <svg className="nm-comments-pass" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-hidden="true">
    <rect x="1" y="1" width={width - 2} height={height - 2} rx="5" pathLength="100" />
  </svg>;
}

export default function SourceComments({ anchor, comments, file, draft, selected, close, select, save }: {
  anchor: RefObject<HTMLButtonElement>; comments: readonly SourceComment[]; file: string;
  draft?: CommentAnchor; selected?: string; close: () => void;
  select: (comment: SourceComment) => void; save: (anchor: CommentAnchor, note: string) => Promise<void>;
}) {
  const { t } = useTranslation();
  const noteId = useId();
  const panel = useRef<HTMLDivElement>(null);
  const [filter, setFilter] = useState<'file' | 'project'>('file');
  const [position, setPosition] = useState({ left: 8, bottom: 40 });
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const visible = filter === 'file' ? comments.filter((comment) => comment.file === file) : comments;
  useLayoutEffect(() => {
    const place = () => {
      const bounds = anchor.current?.getBoundingClientRect();
      if (!bounds) return;
      const width = panel.current?.offsetWidth ?? 0;
      setPosition({
        left: Math.max(8, Math.min(bounds.left, window.innerWidth - width - 8)),
        bottom: Math.max(8, window.innerHeight - bounds.top + 6)
      });
    };
    place();
    window.addEventListener('resize', place);
    window.addEventListener('scroll', place, true);
    return () => {
      window.removeEventListener('resize', place);
      window.removeEventListener('scroll', place, true);
    };
  }, [anchor]);
  useEffect(() => {
    const outside = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!saving && !panel.current?.contains(target) && !anchor.current?.contains(target)) close();
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !saving) { close(); anchor.current?.focus(); }
    };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => {
      document.removeEventListener('pointerdown', outside);
      document.removeEventListener('keydown', escape);
    };
  }, [anchor, close, saving]);
  return createPortal(
    <div ref={panel} className="nm-comments-popover" role="dialog" aria-label={t('Comments')} style={position}>
      <div className="nm-comments-head"><strong>{t('Comments')}</strong>
        <button type="button" className="icon-btn" aria-label={t('Close')} onClick={() => { close(); anchor.current?.focus(); }}>×</button>
      </div>
      {draft && <form className="nm-comment-compose" onSubmit={async (event) => {
        event.preventDefault();
        if (!note.trim() || saving) return;
        setSaving(true);
        setError('');
        try { await save(draft, note); setNote(''); }
        catch (err) { setError(err instanceof Error ? err.message : String(err)); }
        finally { setSaving(false); }
      }}>
        <blockquote>{draft.quote.length > 160 ? draft.quote.slice(0, 160) + '…' : draft.quote}</blockquote>
        <div className="field"><label htmlFor={noteId}>{t('Comment note')}</label>
          <textarea id={noteId} autoFocus className="input" rows={3} maxLength={4000} value={note} disabled={saving}
            onChange={(event) => setNote(event.target.value)} />
        </div>
        <button className="btn" type="submit" disabled={saving || !note.trim()}>{t('Add Comment')}</button>
        {error && <p role="alert">{error}</p>}
      </form>}
      <div className="nm-comments-filters">
        <button className="nm-stat-btn" aria-pressed={filter === 'file'} onClick={() => setFilter('file')}>{t('This File')}</button>
        <button className="nm-stat-btn" aria-pressed={filter === 'project'} onClick={() => setFilter('project')}>{t('Project')}</button>
      </div>
      <div className="nm-comments-list">
        {visible.length === 0 && <span className="muted">{t('No comments here yet.')}</span>}
        {visible.map((comment) => (
          <button type="button" className="nm-comment-row" key={comment.id} aria-current={selected === comment.id ? 'true' : undefined}
            onClick={() => select(comment)}>
            <span>{comment.note}</span>
            <small>{filter === 'project' ? `${comment.file} · ` : ''}{t('Line {{line}}', { line: comment.line })}</small>
          </button>
        ))}
      </div>
    </div>, document.body
  );
}
