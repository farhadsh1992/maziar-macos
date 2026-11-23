// Numenor: choose a folder on this computer to keep projects in — e.g. a folder inside Google Drive.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { browseFolder, folderSuggestions, makeFolder, type FolderListing, type FolderSuggestion } from '../api/client';

const KIND_ICON: Record<string, string> = { google: '☁︎', icloud: '☁︎', dropbox: '☁︎', onedrive: '☁︎', sharepoint: '☁︎', folder: '📁' };

export default function FolderPicker({
  onChoose,
  onClose,
  existing,
  title,
  subtitle,
  chooseLabel
}: {
  onChoose: (path: string) => Promise<void>;
  onClose: () => void;
  existing: string[];
  title?: string;
  subtitle?: string;
  chooseLabel?: string;
}) {
  const { t } = useTranslation();
  const [listing, setListing] = useState<FolderListing | null>(null);
  const [pathInput, setPathInput] = useState('');
  const [suggestions, setSuggestions] = useState<FolderSuggestion[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [newName, setNewName] = useState<string | null>(null);

  const open = useCallback(async (path?: string) => {
    setError('');
    try {
      const res = await browseFolder(path);
      setListing(res);
      setPathInput(res.path);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  useEffect(() => {
    folderSuggestions()
      .then((res) => {
        setSuggestions(res.suggestions);
        const drive = res.suggestions.find((s) => s.kind === 'google');
        open(drive?.path || res.home).catch(() => {});
      })
      .catch((err) => {
        setError((err as Error).message);
        open().catch(() => {});
      });
  }, [open]);

  const crumbs = listing ? listing.path.split('/').filter(Boolean) : [];
  const alreadyAdded = listing ? existing.includes(listing.path) : false;

  const choose = async () => {
    if (!listing) return;
    setBusy(true);
    setError('');
    try {
      await onChoose(listing.path);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const createFolder = async () => {
    if (!listing || !newName?.trim()) return;
    try {
      const res = await makeFolder(listing.path, newName.trim());
      setNewName(null);
      await open(res.path);
    } catch (err) {
      setError((err as Error).message);
    }
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal folder-picker" onClick={(e) => e.stopPropagation()}>
        <div className="folder-picker-head">
          <div>
            <div className="folder-picker-title">{title || t('Add a projects folder')}</div>
            <div className="muted folder-picker-sub">
              {subtitle || t('Numenor lists the projects in this folder and can create new ones there. A folder inside Google Drive keeps them synced by Google Drive for desktop.')}
            </div>
          </div>
          <button className="icon-btn" onClick={onClose}>✕</button>
        </div>
        <div className="folder-picker-body">
          <aside className="folder-picker-side">
            {suggestions.map((s) => (
              <button
                key={s.path}
                className={`folder-shortcut ${listing?.path.startsWith(s.path) ? 'active' : ''} ${s.kind === 'google' ? 'google' : ''}`}
                onClick={() => open(s.path)}
                title={s.path}
              >
                <span className="folder-shortcut-icon">{KIND_ICON[s.kind] || '📁'}</span>
                <span className="folder-shortcut-label">{s.label}</span>
              </button>
            ))}
            {suggestions.every((s) => s.kind !== 'google') && (
              <div className="muted folder-picker-hint">
                {t('No Google Drive folder found. Install Google Drive for desktop to keep projects in Google Drive.')}
              </div>
            )}
          </aside>
          <section className="folder-picker-main">
            <form
              className="folder-path-row"
              onSubmit={(e) => {
                e.preventDefault();
                open(pathInput).catch(() => {});
              }}
            >
              <button type="button" className="btn ghost small" disabled={!listing?.parent} onClick={() => listing?.parent && open(listing.parent)}>↑</button>
              <input className="input folder-path-input" value={pathInput} onChange={(e) => setPathInput(e.target.value)} spellCheck={false} />
              <button type="submit" className="btn ghost small">{t('Go')}</button>
            </form>
            <div className="folder-crumbs">
              <button onClick={() => open('/')}>/</button>
              {crumbs.map((part, i) => (
                <button key={i} onClick={() => open('/' + crumbs.slice(0, i + 1).join('/'))}>{part}</button>
              ))}
            </div>
            <div className="folder-list">
              {listing?.entries.length === 0 && <div className="muted folder-empty">{t('No sub-folders here.')}</div>}
              {listing?.entries.map((entry) => (
                <button
                  key={entry.path}
                  className={`folder-entry ${entry.isProject ? 'project' : ''}`}
                  onDoubleClick={() => !entry.isProject && open(entry.path)}
                  onClick={() => !entry.isProject && open(entry.path)}
                  title={entry.isProject ? t('A Numenor project') : entry.path}
                  disabled={entry.isProject}
                >
                  <span>{entry.isProject ? '📄' : '📁'}</span>
                  <span className="folder-entry-name">{entry.name}</span>
                  {entry.isProject && <span className="folder-entry-tag">{t('project')}</span>}
                </button>
              ))}
            </div>
            <div className="folder-new">
              {newName === null ? (
                <button className="btn ghost small" onClick={() => setNewName('Numenor Projects')} disabled={!listing}>
                  + {t('New folder here')}
                </button>
              ) : (
                <form
                  className="folder-new-form"
                  onSubmit={(e) => {
                    e.preventDefault();
                    createFolder().catch(() => {});
                  }}
                >
                  <input className="input" autoFocus value={newName} onChange={(e) => setNewName(e.target.value)} />
                  <button className="btn small" type="submit">{t('Create')}</button>
                  <button className="btn ghost small" type="button" onClick={() => setNewName(null)}>{t('Cancel')}</button>
                </form>
              )}
            </div>
          </section>
        </div>
        {error && <div className="folder-picker-error">{error}</div>}
        <div className="folder-picker-foot">
          <div className="muted folder-picker-selected">
            {listing && (
              <>
                {t('Folder')}: <b title={listing.path}>{listing.path}</b>
                {listing.projectCount > 0 && <> · {t('{{count}} projects inside', { count: listing.projectCount })}</>}
              </>
            )}
          </div>
          <button className="btn ghost" onClick={onClose}>{t('Cancel')}</button>
          <button className="btn" onClick={choose} disabled={!listing || busy || alreadyAdded}>
            {alreadyAdded ? t('Already added') : chooseLabel || t('Use this folder')}
          </button>
        </div>
      </div>
    </div>
  );
}
