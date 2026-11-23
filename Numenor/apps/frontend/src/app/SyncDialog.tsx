// "Copies" in the editor: keep this project copied into other folders — Google Drive, a SharePoint library
// (synced by the OneDrive app), Dropbox, iCloud… — and updated a few seconds after every save.
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  addSyncTarget,
  folderSuggestions,
  listSyncTargets,
  removeSyncTarget,
  syncNow,
  updateSyncTarget,
  type FolderSuggestion,
  type SyncTarget
} from '../api/client';
import FolderPicker from './FolderPicker';
import { IconClose, IconTrash } from './icons';

type Props = { projectId: string; projectName: string; onClose: () => void };

/** Where a copy lives, in words: "Google Drive › My Drive › Papers › EDGE-AI-Overleaf". */
export function describeDestination(dest: string) {
  const cloud = dest.match(/\/Library\/CloudStorage\/([^/]+)\/?(.*)$/);
  if (cloud) {
    const [, provider, rest] = cloud;
    let service = provider;
    let kind = 'folder';
    if (provider.startsWith('GoogleDrive-')) { service = 'Google Drive'; kind = 'google'; }
    else if (provider.startsWith('OneDrive-SharedLibraries')) { service = 'SharePoint'; kind = 'sharepoint'; }
    else if (provider.startsWith('OneDrive')) { service = 'OneDrive'; kind = 'onedrive'; }
    else if (provider.startsWith('Dropbox')) { service = 'Dropbox'; kind = 'dropbox'; }
    return { kind, service, path: [service, ...rest.split('/').filter(Boolean)].join(' › ') };
  }
  const icloud = dest.match(/\/Library\/Mobile Documents\/com~apple~CloudDocs\/?(.*)$/);
  if (icloud) return { kind: 'icloud', service: 'iCloud Drive', path: ['iCloud Drive', ...icloud[1].split('/').filter(Boolean)].join(' › ') };
  return { kind: 'folder', service: '', path: dest.replace(/^\/Users\/[^/]+/, '~') };
}

const BADGE: Record<string, string> = { google: 'G', sharepoint: 'S', onedrive: 'O', dropbox: 'D', icloud: 'i', folder: '📁' };

function since(iso: string | null, t: (k: string, o?: Record<string, unknown>) => string) {
  if (!iso) return t('Not copied yet');
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return t('Updated just now');
  if (s < 3600) return t('Updated {{n}} min ago', { n: Math.round(s / 60) });
  if (s < 86400) return t('Updated {{n}} h ago', { n: Math.round(s / 3600) });
  return t('Updated {{date}}', { date: new Date(iso).toLocaleString() });
}

export default function SyncDialog({ projectId, projectName, onClose }: Props) {
  const { t } = useTranslation();
  const [targets, setTargets] = useState<SyncTarget[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [picking, setPicking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [places, setPlaces] = useState<FolderSuggestion[]>([]);

  const reload = useCallback(async () => {
    try {
      const res = await listSyncTargets(projectId);
      setTargets(res.targets);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoaded(true);
    }
  }, [projectId]);

  useEffect(() => {
    reload().catch(() => {});
    folderSuggestions().then((r) => setPlaces(r.suggestions)).catch(() => {});
    const timer = window.setInterval(() => reload().catch(() => {}), 3000);
    return () => window.clearInterval(timer);
  }, [reload]);

  const act = async (fn: () => Promise<{ targets: SyncTarget[] }>) => {
    setBusy(true);
    setError('');
    try {
      const res = await fn();
      setTargets(res.targets);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const remove = (target: SyncTarget) => {
    const where = describeDestination(target.dest).path;
    if (!window.confirm(t('Stop keeping a copy in {{where}}? The files already there stay.', { where }))) return;
    act(() => removeSyncTarget(projectId, target.id)).catch(() => {});
  };

  const hasSharePoint = places.some((p) => p.kind === 'sharepoint');
  const hasDrive = places.some((p) => p.kind === 'google');

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal nm-share-modal nm-sync-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={t('Copies')}>
        <div className="modal-header">
          <div>{t('Keep copies of “{{project}}”', { project: projectName })}</div>
          <button className="nm-icon-btn borderless" onClick={onClose} aria-label={t('Close')}><IconClose size={16} /></button>
        </div>
        <div className="modal-body nm-share-body">
          <div className="muted nm-sync-intro">
            {t('Every save (yours or an invited person’s) and every new PDF updates these copies a few seconds later. Choose a folder in Google Drive, SharePoint, OneDrive, Dropbox or iCloud and its app uploads the changes with the account it is signed in with — Numenor needs no password.')}
          </div>

          {loaded && targets.length === 0 && (
            <div className="nm-sync-empty muted">{t('No copies yet.')}</div>
          )}
          <div className="nm-sync-list">
            {targets.map((target) => {
              const d = describeDestination(target.dest);
              return (
                <div key={target.id} className={`nm-sync-row ${target.enabled ? '' : 'paused'}`}>
                  <span className={`nm-sync-badge ${d.kind}`}>{BADGE[d.kind] || '📁'}</span>
                  <div className="nm-sync-main">
                    <div className="nm-sync-path" title={target.dest}>{d.path}</div>
                    <div className={`nm-sync-status ${target.lastError ? 'error' : ''}`}>
                      {target.running ? (
                        <><span className="nm-spinner" /> {t('Copying…')}</>
                      ) : target.lastError ? (
                        target.lastError
                      ) : !target.enabled ? (
                        t('Paused')
                      ) : (
                        <>{since(target.lastSyncAt, t)}{target.fileCount ? ` · ${t('{{count}} files', { count: target.fileCount })}` : ''}</>
                      )}
                    </div>
                  </div>
                  <label className="nm-sync-pdf" title={t('Also copy the compiled PDF')}>
                    <input
                      type="checkbox"
                      checked={target.includePdf}
                      onChange={(e) => act(() => updateSyncTarget(projectId, target.id, { includePdf: e.target.checked }))}
                    />
                    PDF
                  </label>
                  <button className="btn ghost small" onClick={() => act(() => updateSyncTarget(projectId, target.id, { enabled: !target.enabled }))} disabled={busy}>
                    {target.enabled ? t('Pause') : t('Resume')}
                  </button>
                  <button className="nm-icon-btn borderless" onClick={() => remove(target)} title={t('Stop copying here')} disabled={busy}>
                    <IconTrash size={15} />
                  </button>
                </div>
              );
            })}
          </div>

          {error && <div className="share-error">{error}</div>}

          <div className="nm-sync-actions">
            <button className="btn nm-primary" onClick={() => setPicking(true)} disabled={busy}>+ {t('Add a folder…')}</button>
            {targets.length > 0 && (
              <button className="btn ghost" onClick={() => act(() => syncNow(projectId))} disabled={busy}>{t('Update all now')}</button>
            )}
          </div>

          <details className="nm-sync-help" open={!hasSharePoint && targets.length === 0}>
            <summary>{t('How to add SharePoint or Google Drive')}</summary>
            <p>
              <b>SharePoint / Teams:</b>{' '}
              {t('open the document library in your browser (signed in with your work account) and click “Sync” — or “Add shortcut to My files”. The OneDrive app (signed in with the same account) then shows it on this Mac, and it appears under SharePoint in the folder list here.')}
              {!hasSharePoint && <> {t('No SharePoint library is synced on this Mac yet.')}</>}
            </p>
            <p>
              <b>Google Drive:</b>{' '}
              {hasDrive
                ? t('pick any folder under Google Drive in the folder list.')
                : t('install Google Drive for desktop and sign in; your Drive then appears in the folder list.')}
            </p>
            <p className="muted">{t('Numenor puts the copy in a folder named after the project inside the folder you choose. It only removes files it copied itself, so other files in a shared folder are never touched.')}</p>
          </details>
        </div>
      </div>
      {picking && (
        <div onClick={(e) => e.stopPropagation()}>
          <FolderPicker
            title={t('Keep a copy in…')}
            subtitle={t('Choose where the copy goes. Numenor creates a “{{project}}” folder inside it and keeps it updated.', { project: projectName })}
            chooseLabel={t('Copy here')}
            existing={[]}
            onClose={() => setPicking(false)}
            onChoose={async (path) => {
              const res = await addSyncTarget(projectId, path);
              setTargets(res.targets);
              setPicking(false);
            }}
          />
        </div>
      )}
    </div>
  );
}
