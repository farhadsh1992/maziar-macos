// Numenor's version, the "update available" notice and the one-click update from GitHub.
// The notice checks when Numenor opens and every few hours after; only the computer running Numenor can
// check or update (people who joined through an invite link never see it).
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { useLocation } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { checkForUpdate, getCollabToken, getVersion, startUpdate, updateStatus, type UpdateCheck, type UpdateProgress, type VersionInfo } from '../api/client';

const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;
const DISMISS_KEY = 'numenor.update.dismissed';

type Ctx = {
  version: VersionInfo | null;
  check: UpdateCheck | null;
  checking: boolean;
  checkError: string;
  runCheck: (force?: boolean) => Promise<void>;
  openUpdate: () => void;
};

const UpdateContext = createContext<Ctx | null>(null);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export function UpdateProvider({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  const location = useLocation();
  const [version, setVersion] = useState<VersionInfo | null>(null);
  const [check, setCheck] = useState<UpdateCheck | null>(null);
  const [checking, setChecking] = useState(false);
  const [checkError, setCheckError] = useState('');
  const [dismissed, setDismissed] = useState(() => {
    try { return sessionStorage.getItem(DISMISS_KEY) || ''; } catch { return ''; }
  });
  const [panel, setPanel] = useState(false);
  const [progress, setProgress] = useState<UpdateProgress | null>(null);
  const [showLog, setShowLog] = useState(false);
  const polling = useRef(false);
  const guest = Boolean(getCollabToken()) || location.pathname.startsWith('/collab') || location.pathname.startsWith('/pdf-window');

  const runCheck = useCallback(async (force = false) => {
    setChecking(true);
    setCheckError('');
    try {
      const res = await checkForUpdate(force);
      setCheck(res);
      setVersion(res.current);
    } catch (err) {
      setCheckError((err as Error).message);
    } finally {
      setChecking(false);
    }
  }, []);

  useEffect(() => {
    getVersion().then((v) => setVersion(v)).catch(() => {});
  }, []);

  useEffect(() => {
    if (guest) return;
    runCheck().catch(() => {});
    const timer = window.setInterval(() => runCheck().catch(() => {}), CHECK_EVERY_MS);
    return () => window.clearInterval(timer);
  }, [guest, runCheck]);

  /** Follows the update until the new version answers, then reloads the page. */
  const follow = useCallback(async () => {
    if (polling.current) return;
    polling.current = true;
    const before = version?.display || '';
    try {
      for (let i = 0; i < 900; i += 1) {
        await sleep(1000);
        try {
          const st = await updateStatus();
          setProgress(st);
          if (st.state === 'error') return;
          if (st.state === 'restarting' || st.state === 'idle') {
            // The server goes away and comes back with the new code.
            for (let j = 0; j < 180; j += 1) {
              await sleep(1000);
              try {
                const v = await getVersion();
                const st2 = await updateStatus().catch(() => null);
                if (v.display !== before || (st2 && st2.state === 'idle')) {
                  window.location.reload();
                  return;
                }
              } catch {
                /* still restarting */
              }
            }
            return;
          }
        } catch {
          // Server not answering: it's restarting.
          setProgress((p) => (p ? { ...p, state: 'restarting', step: t('Restarting Numenor…') } : p));
        }
      }
    } finally {
      polling.current = false;
    }
  }, [t, version]);

  const begin = async () => {
    setShowLog(false);
    try {
      const st = await startUpdate();
      setProgress(st);
      follow().catch(() => {});
    } catch (err) {
      setProgress({ state: 'error', step: '', error: (err as Error).message, log: '', current: version || { version: '', label: '', display: '' } });
    }
  };

  const later = () => {
    if (check?.latest.version) {
      try { sessionStorage.setItem(DISMISS_KEY, check.latest.version); } catch { /* ignore */ }
      setDismissed(check.latest.version);
    }
    setPanel(false);
  };

  const ctx: Ctx = { version, check, checking, checkError, runCheck, openUpdate: () => setPanel(true) };
  const showToast = !guest && !panel && check?.available && dismissed !== check.latest.version;
  const busy = progress && ['downloading', 'installing', 'building', 'restarting'].includes(progress.state);

  return (
    <UpdateContext.Provider value={ctx}>
      {children}
      {showToast && check && (
        <div className="nm-update-toast" role="status">
          <div className="nm-update-toast-text">
            <b>{t('Numenor {{version}} is available', { version: check.latest.display })}</b>
            <span className="muted">{t('You have {{version}}.', { version: check.current.display })}</span>
          </div>
          <div className="nm-update-toast-actions">
            <button className="btn ghost small" onClick={later}>{t('Later')}</button>
            <button className="btn nm-primary small" onClick={() => setPanel(true)}>{t('Update…')}</button>
          </div>
        </div>
      )}
      {panel && (
        <div className="modal-backdrop" onClick={() => !busy && setPanel(false)}>
          <div className="modal nm-update-modal" onClick={(e) => e.stopPropagation()}>
            <div className="nm-update-head">
              <div className="nm-update-title">{t('Update Numenor')}</div>
              {!busy && <button className="icon-btn" onClick={() => setPanel(false)}>✕</button>}
            </div>
            <div className="nm-update-versions">
              <div><span className="muted">{t('Installed')}</span><b>{version?.display || '—'}</b></div>
              <div><span className="muted">{t('On GitHub')}</span><b>{check?.latest.display || '—'}</b></div>
            </div>
            {!progress && check?.available && check.notes && (
              <pre className="nm-update-notes">{check.notes}</pre>
            )}
            {!progress && check && !check.available && <div className="muted">{t('Numenor is up to date.')}</div>}
            {checkError && !progress && <div className="share-error">{checkError}</div>}
            {progress && (
              <div className="nm-update-progress">
                {progress.state === 'error' ? (
                  <div className="share-error">{t('The update didn’t finish: {{error}}', { error: progress.error })}</div>
                ) : (
                  <div className="nm-update-step"><span className="nm-spinner" /> {progress.step || t('Starting…')}</div>
                )}
                {progress.log && (
                  <button className="btn ghost small" onClick={() => setShowLog((v) => !v)}>{showLog ? t('Hide details') : t('Show details')}</button>
                )}
                {showLog && <pre className="nm-update-log">{progress.log}</pre>}
              </div>
            )}
            <div className="muted nm-update-help">
              {t('This updates Numenor only. Your projects and settings are kept. To update the full Maziar app, use Maziar’s own updater.')}
            </div>
            <div className="nm-update-foot">
              <button className="btn ghost" onClick={() => runCheck(true)} disabled={checking || Boolean(busy)}>{checking ? t('Checking…') : t('Check again')}</button>
              {!busy && <button className="btn ghost" onClick={later}>{t('Later')}</button>}
              {check?.available && (
                <button className="btn nm-primary" onClick={begin} disabled={Boolean(busy)}>
                  {busy ? t('Updating…') : progress?.state === 'error' ? t('Try again') : t('Update now')}
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </UpdateContext.Provider>
  );
}

/** "Numenor Beta 1.0.5" with a link to check for updates — for the Projects page sidebar. */
export function VersionBadge() {
  const { t } = useTranslation();
  const ctx = useContext(UpdateContext);
  if (!ctx?.version) return null;
  return (
    <div className="nm-version">
      <span>Numenor {ctx.version.display}</span>
      <button
        className={`nm-version-link ${ctx.check?.available ? 'available' : ''}`}
        onClick={() => {
          ctx.openUpdate();
          if (!ctx.check?.available) ctx.runCheck(true).catch(() => {});
        }}
      >
        {ctx.check?.available ? t('Update to {{version}}', { version: ctx.check.latest.display }) : t('Check for updates')}
      </button>
    </div>
  );
}
