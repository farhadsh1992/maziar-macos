// Projects page → "Shared with me": projects other people shared with you. Paste an invite link once and it
// stays here, showing whether the owner's computer is reachable right now. Opening one opens the owner's
// Numenor (the project stays on their computer).
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { addSharedWithMe, listSharedWithMe, openSharedWithMe, removeSharedWithMe, setSharedWithMeCode, type SharedProject } from '../api/client';
import { IconLink, IconShare, IconTrash } from './icons';

export function openSharedProject(link: string) {
  const win = window.open(link, '_blank');
  if (!win) window.location.href = link;
}

/** Opens a saved shared project with its saved access code (asks for the code if it's missing or changed). */
export async function openSavedShared(item: SharedProject, t: (k: string, o?: Record<string, unknown>) => string): Promise<string | null> {
  // Open the window now (a click), fill it in when the address is ready — otherwise it's a blocked pop-up.
  const win = window.open('', '_blank');
  const go = (url: string) => {
    if (win && !win.closed) win.location.href = url;
    else window.location.href = url;
  };
  const errorOf = (err: unknown) => {
    try { return JSON.parse((err as Error).message); } catch { return { error: (err as Error).message }; }
  };
  try {
    go((await openSharedWithMe(item.id)).url);
    return null;
  } catch (err) {
    const data = errorOf(err);
    if (!data.needsCode) {
      win?.close();
      return String(data.error || err);
    }
    const entered = window.prompt(`${data.error || t('Enter the access code for this project once.')}\n\n${t('Access code for “{{name}}” (8 characters):', { name: item.projectName })}`);
    if (!entered) {
      win?.close();
      return null;
    }
    try {
      await setSharedWithMeCode(item.id, entered);
      go((await openSharedWithMe(item.id)).url);
      return null;
    } catch (again) {
      win?.close();
      return String(errorOf(again).error || again);
    }
  }
}

export default function SharedWithMe({ onCount }: { onCount?: (n: number) => void }) {
  const { t } = useTranslation();
  const [items, setItems] = useState<SharedProject[]>([]);
  const [loading, setLoading] = useState(true);
  const [link, setLink] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      const res = await listSharedWithMe();
      setItems(res.items);
      onCount?.(res.items.length);
      setError('');
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [onCount]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 30000);
    return () => window.clearInterval(timer);
  }, [load]);

  const add = async () => {
    if (!link.trim() || !code.trim()) return;
    setBusy(true);
    setError('');
    try {
      await addSharedWithMe(link.trim(), code);
      setLink('');
      setCode('');
      await load();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const remove = async (item: SharedProject) => {
    if (!window.confirm(t('Remove “{{name}}” from this list? (It stays with its owner — you can add it again with the link.)', { name: item.projectName }))) return;
    await removeSharedWithMe(item.id).catch(() => {});
    load();
  };

  const stateLabel = (s: SharedProject['state']) =>
    s === 'ok' ? t('Available') : s === 'offline' ? t('Owner’s computer is offline') : s === 'revoked' ? t('Access removed') : t('Link no longer valid');

  return (
    <div className="nm-shared">
      <div className="nm-shared-add">
        <div className="nm-shared-add-text">
          <b>{t('Add a project someone shared with you')}</b>
          <span className="muted">{t('Paste the invite link they sent you and its 8-character access code. Numenor remembers the code, so you only enter it once.')}</span>
        </div>
        <div className="nm-shared-add-row">
          <label className="nm-search nm-shared-input">
            <IconLink size={16} />
            <input className="project-search" value={link} onChange={(e) => setLink(e.target.value)} placeholder="https://…/collab?token=…" onKeyDown={(e) => e.key === 'Enter' && add()} />
          </label>
          <input className="input nm-code-input" value={code} onChange={(e) => setCode(e.target.value)} placeholder={t('Access code')} maxLength={9} spellCheck={false} onKeyDown={(e) => e.key === 'Enter' && add()} />
          <button className="btn nm-primary" onClick={add} disabled={busy || !link.trim() || !code.trim()}>{busy ? t('Checking…') : t('Add shared project')}</button>
        </div>
        {error && <div className="share-error">{error}</div>}
      </div>

      {loading ? (
        <div className="muted nm-shared-empty">{t('Loading…')}</div>
      ) : items.length === 0 ? (
        <div className="nm-shared-empty">
          <IconShare size={28} />
          <div>{t('Nothing shared with you yet.')}</div>
          <div className="muted">{t('When someone shares a Numenor project with you, paste their link above and it stays here.')}</div>
        </div>
      ) : (
        <div className="nm-shared-list">
          {items.map((item) => (
            <div key={item.id} className={`nm-shared-item ${item.state}`}>
              <div className="nm-shared-main">
                <div className="nm-shared-name">{item.projectName}</div>
                <div className="muted nm-shared-sub">
                  {item.owner && item.owner !== 'Owner' ? t('Shared by {{owner}}', { owner: item.owner }) : t('Shared with you')}
                  {' · '}{item.role === 'view' ? t('View only') : t('Can edit')}
                  {' · '}<span className="nm-shared-host" title={item.origin}>{item.origin.replace(/^https?:\/\//, '')}</span>
                </div>
              </div>
              <span className={`nm-shared-state ${item.state}`}><span className="share-dot" />{stateLabel(item.state)}</span>
              <button className="btn nm-primary" disabled={item.state !== 'ok'} onClick={async () => { const err = await openSavedShared(item, t); if (err) setError(err); }}>{t('Open')}</button>
              <button className="nm-icon-btn danger" onClick={() => remove(item)} title={t('Remove from this list')} aria-label={t('Remove')}><IconTrash size={15} /></button>
            </div>
          ))}
        </div>
      )}
      <div className="muted nm-shared-foot">{t('A shared project opens only while its owner’s computer is on and sharing. If their link changes, ask them to send it again and add it here — it replaces the old one.')}</div>
    </div>
  );
}
