// Opening an invite link: the link says who it's for, the 8-character access code proves it. In a browser
// the code is asked each visit (the pass lives only in this tab). Someone's own Numenor ("Shared with me")
// saves the code and arrives here with ?session=… instead, so they are never asked.
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { resolveCollabToken, setCollabInviteToken, setCollabServer, setCollabToken, unlockCollab } from '../api/client';
import { NumenorMark } from './icons';

function errorInfo(err: unknown) {
  const raw = String((err as Error)?.message || err);
  try {
    const data = JSON.parse(raw);
    return { message: String(data.error || raw), data };
  } catch {
    return { message: raw, data: {} as Record<string, unknown> };
  }
}

export default function CollabJoinPage() {
  const navigate = useNavigate();
  const { t } = useTranslation();
  const [status, setStatus] = useState(t('Checking your invite…'));
  const [ask, setAsk] = useState<{ token: string; projectName: string; owner: string; role: string } | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const session = params.get('session') || '';
    const token = params.get('token') || '';
    setCollabServer(window.location.origin);
    const fail = (err: unknown) => {
      const { message, data } = errorInfo(err);
      if (data.revoked || /removed/i.test(message)) setStatus(t('Your access to this project was removed by its owner.'));
      else if (data.expired) setStatus(t('This sign-in has ended. Open your invite link again and enter your access code.'));
      else if (/invalid token/i.test(message)) setStatus(t('This link doesn’t match this Numenor — it is probably an old link. The share address changes each time the owner starts sharing (unless they set “Same link every time”), so ask them to send your link again. Your access code stays the same.'));
      else setStatus(t('Couldn’t open the project: {{error}}', { error: message }));
    };
    if (session) {
      resolveCollabToken(session)
        .then((res) => {
          if (!res.ok || !res.projectId || res.needsCode) return setStatus(t('This sign-in isn’t valid any more.'));
          setCollabToken(session);
          navigate(`/editor/${res.projectId}`, { replace: true });
        })
        .catch(fail);
      return;
    }
    if (!token) {
      setStatus(t('This invite link is incomplete — ask the owner to send it again.'));
      return;
    }
    resolveCollabToken(token)
      .then((res) => {
        if (!res.ok || !res.projectId) return setStatus(t('This invite link isn’t valid.'));
        setAsk({ token, projectName: res.projectName, owner: res.owner && res.owner !== 'Owner' ? res.owner : '', role: res.role });
      })
      .catch(fail);
  }, [navigate, t]);

  useEffect(() => {
    if (ask) inputRef.current?.focus();
  }, [ask]);

  const submit = async () => {
    if (!ask || busy) return;
    const clean = code.toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (clean.length !== 8) {
      setError(t('The access code has 8 characters.'));
      return;
    }
    setBusy(true);
    setError('');
    try {
      const res = await unlockCollab(ask.token, clean);
      setCollabToken(res.session);
      setCollabInviteToken(ask.token);
      navigate(`/editor/${res.projectId}`, { replace: true });
    } catch (err) {
      const { message, data } = errorInfo(err);
      if (data.wrongCode) setError(t('That access code isn’t right. Check it and try again.'));
      else if (data.locked) setError(t('Too many wrong codes — try again in 15 minutes, or ask the owner for your code.'));
      else if (data.revoked) setError(t('Your access to this project was removed by its owner.'));
      else setError(message);
    } finally {
      setBusy(false);
    }
  };

  const formatted = (() => {
    const clean = code.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
    return clean.length > 4 ? `${clean.slice(0, 4)}-${clean.slice(4)}` : clean;
  })();

  return (
    <div className="collab-join">
      <div className="panel collab-join-card nm-join-card">
        <div className="nm-join-brand"><NumenorMark size={44} /><span>Numenor</span></div>
        {ask ? (
          <>
            <div className="nm-join-title">{ask.projectName}</div>
            <div className="muted nm-join-sub">
              {ask.owner ? t('Shared by {{owner}}', { owner: ask.owner }) : t('Shared with you')} · {ask.role === 'view' ? t('View only') : t('Can edit')}
            </div>
            <label className="nm-join-label" htmlFor="nm-join-code">{t('Enter your access code')}</label>
            <input
              id="nm-join-code"
              ref={inputRef}
              className="input nm-join-code"
              value={formatted}
              onChange={(e) => setCode(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && submit()}
              placeholder="XXXX-XXXX"
              autoComplete="one-time-code"
              autoCapitalize="characters"
              spellCheck={false}
              maxLength={9}
            />
            {error && <div className="share-error">{error}</div>}
            <button className="btn nm-primary nm-join-btn" onClick={submit} disabled={busy}>{busy ? t('Checking…') : t('Open project')}</button>
            <div className="muted nm-join-help">
              {t('The 8-character code came with your invite (in the email or message with the link). It’s asked each time you open the link in a browser. In your own Numenor app, add the link under Projects → Add shared link and you only enter it once.')}
            </div>
          </>
        ) : (
          <div className="muted nm-join-status">{status}</div>
        )}
      </div>
    </div>
  );
}
