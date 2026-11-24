import { useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { useTranslation } from 'react-i18next';
import type { FileWritingStatus } from '../api/client';

const labels = { todo: 'To do', 'in-progress': 'In progress', done: 'Done' } as const;
type Status = FileWritingStatus['status'];

function StatusIcon({ status }: { status?: Status }) {
  return (
    <svg className={`nm-writing-icon nm-writing-${status ?? 'empty'}`} width="17" height="17" viewBox="0 0 20 20" aria-hidden="true">
      {!status ? <path d="M5 10h10M10 5v10" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        : status === 'todo' ? <>
          <circle cx="10" cy="10" r="7.3" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="M10 5.8v4.4l2.8 1.7" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </> : <>
          <circle cx="10" cy="10" r="8" fill="currentColor" />
          {status === 'done'
            ? <path d="m6.2 10 2.5 2.5 5-5" fill="none" stroke="var(--nm-writing-symbol)" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
            : <path d="M8 6.5v7l6-3.5z" fill="var(--nm-writing-symbol)" />}
        </>}
    </svg>
  );
}

export default function WritingStatus({ name, tag, readOnly, save }: {
  name: string;
  tag?: FileWritingStatus;
  readOnly: boolean;
  save: (tag: FileWritingStatus | null) => Promise<void>;
}) {
  const { t } = useTranslation();
  const id = useId();
  const anchor = useRef<HTMLButtonElement>(null);
  const popover = useRef<HTMLFormElement>(null);
  const [draft, setDraft] = useState<FileWritingStatus>();
  const [position, setPosition] = useState({ top: 0, left: 0 });
  const [hint, setHint] = useState({ hover: false, focus: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const open = Boolean(draft);
  const details = tag?.status === 'done' ? undefined : tag;
  const date = details?.date
    ? new Intl.DateTimeFormat(navigator.languages, { dateStyle: 'medium', timeZone: 'UTC' }).format(new Date(details.date))
    : '';

  const close = () => {
    setDraft(undefined);
    anchor.current?.focus();
  };

  useLayoutEffect(() => {
    if (!open) return;
    const place = () => {
      const row = anchor.current?.getBoundingClientRect();
      const panel = popover.current;
      if (!row || !panel) return;
      const { width, height } = panel.getBoundingClientRect();
      const top = row.bottom + 5 + height <= window.innerHeight - 8 ? row.bottom + 5 : row.top - height - 5;
      setPosition({
        left: Math.max(8, Math.min(row.right - width, window.innerWidth - width - 8)),
        top: Math.max(8, Math.min(top, window.innerHeight - height - 8))
      });
    };
    place();
    const observer = new ResizeObserver(place);
    if (popover.current) observer.observe(popover.current);
    window.addEventListener('resize', place);
    window.addEventListener('scroll', place, true);
    popover.current?.querySelector<HTMLInputElement>('input:checked')?.focus();
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', place);
      window.removeEventListener('scroll', place, true);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => {
      const node = event.target as Node;
      if (!busy && !popover.current?.contains(node) && !anchor.current?.contains(node)) setDraft(undefined);
    };
    document.addEventListener('pointerdown', outside);
    return () => document.removeEventListener('pointerdown', outside);
  }, [open, busy]);

  const persist = async (value: FileWritingStatus | null) => {
    setBusy(true);
    setError('');
    try {
      await save(value);
      close();
    } catch (error) {
      setError(error instanceof Error ? error.message : String(error));
    } finally { setBusy(false); }
  };

  const handleKeys = (event: KeyboardEvent<HTMLFormElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      if (!busy) close();
    }
    if (event.key !== 'Tab') return;
    const targets = Array.from(event.currentTarget.querySelectorAll<HTMLElement>(
      'input:not([disabled]):not([type="radio"]), input[type="radio"]:checked:not([disabled]), button:not([disabled]), textarea:not([disabled])'
    ));
    const first = targets[0], last = targets[targets.length - 1];
    if (event.shiftKey ? document.activeElement === first : document.activeElement === last) {
      event.preventDefault();
      (event.shiftKey ? last : first)?.focus();
    }
  };

  if (readOnly && !tag) return <span className="nm-writing-slot" />;
  const rect = anchor.current?.getBoundingClientRect();
  const showHint = Boolean(tag && !open && (hint.hover || hint.focus) && rect);
  return (
    <span className="nm-writing-slot">
      <button ref={anchor} type="button" className="nm-writing-trigger"
        data-empty={!tag} aria-label={t(readOnly ? 'Writing status for {{name}}' : 'Set writing status for {{name}}', { name })}
        aria-haspopup={readOnly ? undefined : 'dialog'} aria-expanded={readOnly ? undefined : open}
        aria-describedby={tag ? id : undefined} draggable={false}
        onDragStart={(event) => { event.preventDefault(); event.stopPropagation(); }}
        onMouseEnter={() => setHint((value) => ({ ...value, hover: true }))}
        onMouseLeave={() => setHint((value) => ({ ...value, hover: false }))}
        onFocus={() => setHint((value) => ({ ...value, focus: true }))}
        onBlur={() => setHint((value) => ({ ...value, focus: false }))}
        onClick={() => {
          if (readOnly || busy) return;
          setError('');
          if (open) close();
          else setDraft(tag ?? { status: 'todo', note: '', date: '' });
        }}>
        <StatusIcon status={tag?.status} />
      </button>
      {tag && createPortal(
        <div id={id} role="tooltip" className={`nm-writing-tooltip${showHint ? '' : ' nm-writing-hidden'}`}
          style={showHint && rect ? {
            left: Math.max(8, Math.min(rect.right - 230, window.innerWidth - 238)),
            top: rect.bottom > window.innerHeight / 2 ? rect.top - 5 : rect.bottom + 5,
            transform: rect.bottom > window.innerHeight / 2 ? 'translateY(-100%)' : undefined
          } : undefined}>
          <strong>{t(labels[tag.status])}</strong>
          {date && <div>{date}</div>}
          {details?.note.trim() && <div>{details.note}</div>}
        </div>, document.body
      )}
      {draft && createPortal(
        <form ref={popover} className="nm-writing-popover" aria-labelledby={id + '-title'} role="dialog" aria-modal="true"
          style={position} onKeyDown={handleKeys} onContextMenu={(event) => event.stopPropagation()}
          onSubmit={(event) => { event.preventDefault(); if (!busy) void persist(draft); }}>
          <strong id={id + '-title'}>{t('Writing status')}</strong>
          <fieldset disabled={busy} aria-label={t('Writing status')}>
            {(Object.keys(labels) as Status[]).map((status) => (
              <label className="nm-writing-option" key={status}>
                <input type="radio" name={id + '-status'} checked={draft.status === status}
                  onChange={() => setDraft({ ...draft, status })} />
                <StatusIcon status={status} />{t(labels[status])}
              </label>
            ))}
          </fieldset>
          {draft.status !== 'done' && <>
            <div className="field"><label htmlFor={id + '-note'}>{t('Note')}</label><textarea id={id + '-note'} className="input" rows={3} maxLength={2000}
              value={draft.note} disabled={busy} onChange={(event) => setDraft({ ...draft, note: event.target.value })} /></div>
            <div className="field"><label htmlFor={id + '-date'}>{t('Date')}</label><input id={id + '-date'} className="input" type="date" value={draft.date}
              disabled={busy} onChange={(event) => setDraft({ ...draft, date: event.target.value })} /></div>
            {draft.date && <button type="button" className="btn ghost" disabled={busy}
              onClick={() => {
                setDraft({ ...draft, date: '' });
                popover.current?.querySelector<HTMLInputElement>('[type=date]')?.focus();
              }}>{t('Clear date')}</button>}
          </>}
          {error && <p role="alert">{error}</p>}
          <div className="nm-writing-actions">
            <button type="submit" className="btn" disabled={busy}>{t('Save')}</button>
            <button type="button" className="btn ghost" disabled={busy} onClick={close}>{t('Cancel')}</button>
            <button type="button" className="btn ghost" disabled={busy || !tag}
              onClick={() => void persist(null)}>{t('Clear status')}</button>
          </div>
        </form>, document.body
      )}
    </span>
  );
}
