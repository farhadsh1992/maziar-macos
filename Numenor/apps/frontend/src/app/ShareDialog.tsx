// "Share" in the editor: invite people one by one (name + email, can edit / can view), email them their
// link, see who has access and when they last opened it, change their role or remove their access.
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  clearMailSettings,
  createInvite,
  emailInvite,
  getMailSettings,
  inviteLink,
  listInvites,
  prettyCode,
  revokeInvite,
  saveMailSettings,
  sendTestMail,
  setShareDomain,
  shareStatus,
  startShare,
  stopShare,
  updateInvite,
  whoAmI,
  type Invite,
  type MailStatus,
  type ShareState
} from '../api/client';
import { IconCheck, IconClose, IconCopy, IconTrash } from './icons';

type Props = {
  projectId: string;
  projectName: string;
  onClose: () => void;
  onStatus?: (text: string) => void;
};

const initials = (name: string) =>
  name
    .split(/[\s@._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join('') || '?';

function ago(iso: string | null, t: (k: string, o?: Record<string, unknown>) => string) {
  if (!iso) return t('Hasn’t opened it yet');
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 90) return t('Active now');
  if (s < 3600) return t('Opened {{n}} min ago', { n: Math.round(s / 60) });
  if (s < 86400) return t('Opened {{n}} h ago', { n: Math.round(s / 3600) });
  return t('Opened {{date}}', { date: new Date(iso).toLocaleDateString() });
}

export default function ShareDialog({ projectId, projectName, onClose, onStatus }: Props) {
  const { t } = useTranslation();
  const [share, setShare] = useState<ShareState | null>(null);
  const [invites, setInvites] = useState<Invite[]>([]);
  const [owner, setOwner] = useState('');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [role, setRole] = useState<'edit' | 'view'>('edit');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [justAdded, setJustAdded] = useState<string>('');
  const [copied, setCopied] = useState('');
  const [domainOpen, setDomainOpen] = useState(false);
  const [domain, setDomain] = useState('');
  const [domainBusy, setDomainBusy] = useState(false);
  const [domainError, setDomainError] = useState('');
  const [mail, setMail] = useState<MailStatus | null>(null);
  const [mailOpen, setMailOpen] = useState(false);
  const [mailForm, setMailForm] = useState({ provider: 'gmail', user: '', pass: '', fromName: '', host: '', port: '587' });
  const [mailBusy, setMailBusy] = useState(false);
  const [mailError, setMailError] = useState('');
  const [mailNote, setMailNote] = useState('');
  const [sending, setSending] = useState('');

  const refresh = useCallback(async () => {
    try {
      const [s, list] = await Promise.all([shareStatus(), listInvites(projectId)]);
      setShare(s);
      setInvites(list.invites);
    } catch (err) {
      setError((err as Error).message);
    }
  }, [projectId]);

  useEffect(() => {
    refresh();
    whoAmI().then((me) => setOwner(me.name)).catch(() => {});
    getMailSettings().then((m) => setMail(m)).catch(() => setMail({ configured: false }));
    const timer = window.setInterval(refresh, 8000);
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener('keydown', onKey);
    };
  }, [refresh, onClose]);

  const base = share?.active ? share.url : '';
  const linkFor = (inv: Invite) => (base ? inviteLink(base, inv.token) : '');

  const mailto = useCallback(
    (inv: Invite) => {
      const link = linkFor(inv);
      const who = owner && owner !== 'Owner' ? owner : t('I');
      const subject = t('{{owner}} shared “{{project}}” with you on Numenor', { owner: who, project: projectName });
      const body = [
        t('Hi {{name}},', { name: inv.name }),
        '',
        t('{{owner}} shared the Numenor project “{{project}}” with you — you can {{rights}}.', {
          owner: who,
          project: projectName,
          rights: inv.role === 'view' ? t('view it') : t('view and edit it')
        }),
        '',
        t('Open it in your browser:'),
        link,
        '',
        t('Your access code: {{code}}', { code: prettyCode(inv.code) }),
        t('The browser asks for it each time you open the link. Keep it to yourself — it is only for you.'),
        '',
        t('If you use Numenor on your own Mac or PC, you can also keep it there: open Numenor → Projects → Add shared link, paste the link and the code once, and it remembers them.'),
        '',
        t('The link works while my computer is on and sharing.')
      ].join('\n');
      return `mailto:${encodeURIComponent(inv.email)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [owner, projectName, base, t]
  );

  const ensureSharing = async () => {
    let current = share && share.active ? share : await shareStatus();
    if (!current.active) {
      onStatus?.(t('Starting a share link… (can take up to 30 seconds)'));
      current = await startShare();
    }
    setShare(current);
    return current;
  };

  // Sends this person their link from your email account (set up under "Email invites").
  const sendInviteEmail = async (inv: Invite) => {
    setSending(inv.id);
    setError('');
    try {
      if (!share?.active) await ensureSharing();
      const { invite: updated } = await emailInvite(projectId, inv.id, projectName);
      setInvites((list) => list.map((i) => (i.id === inv.id ? updated : i)));
      onStatus?.(t('Invite emailed to {{email}}.', { email: inv.email }));
      return true;
    } catch (err) {
      setError(t('Couldn’t email {{name}}: {{error}}', { name: inv.name, error: (err as Error).message }));
      return false;
    } finally {
      setSending('');
    }
  };

  const shareText = (inv: Invite, link: string) => `${link}\n${t('Access code: {{code}}', { code: prettyCode(inv.code) })}`;

  const newCode = async (inv: Invite) => {
    if (!window.confirm(t('Give {{name}} a new access code? The old one stops working right away — they need the new one to open the project.', { name: inv.name }))) return;
    try {
      const { invite: updated } = await updateInvite(projectId, inv.id, { newCode: true });
      setInvites((list) => list.map((i) => (i.id === inv.id ? updated : i)));
      onStatus?.(t('New access code for {{name}}: {{code}}', { name: inv.name, code: prettyCode(updated.code) }));
    } catch (err) {
      setError((err as Error).message);
    }
  };

  const copyCode = async (inv: Invite) => {
    try {
      await navigator.clipboard.writeText(prettyCode(inv.code));
      onStatus?.(t('Access code copied.'));
    } catch {
      window.prompt(t('Access code:'), prettyCode(inv.code));
    }
  };

  const invite = async () => {
    if (!name.trim() && !email.trim()) {
      setError(t('Enter a name or an email.'));
      return;
    }
    setBusy(true);
    setError('');
    try {
      const current = await ensureSharing();
      const { invite: inv } = await createInvite(projectId, { name, email, role });
      setInvites((list) => [...list, inv]);
      setJustAdded(inv.id);
      setName('');
      setEmail('');
      const link = inviteLink(current.url, inv.token);
      try {
        await navigator.clipboard.writeText(shareText(inv, link));
        onStatus?.(t('Link and access code for {{name}} copied.', { name: inv.name }));
      } catch {
        /* the link is shown in the list */
      }
      if (inv.email && mail?.configured) {
        await sendInviteEmail(inv);
      } else if (inv.email) {
        setMailNote(t('Link copied. To email invites automatically, set up “Email invites” below.'));
      }
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const copy = async (inv: Invite) => {
    let link = linkFor(inv);
    if (!link) {
      try {
        const current = await ensureSharing();
        link = inviteLink(current.url, inv.token);
      } catch (err) {
        setError((err as Error).message);
        return;
      }
    }
    try {
      await navigator.clipboard.writeText(shareText(inv, link));
      setCopied(inv.id);
      window.setTimeout(() => setCopied((c) => (c === inv.id ? '' : c)), 1600);
    } catch {
      window.prompt(t('Copy this link and code:'), shareText(inv, link));
    }
  };

  const remove = async (inv: Invite) => {
    if (!window.confirm(t('Remove {{name}}’s access to “{{project}}”? Their link stops working right away.', { name: inv.name, project: projectName }))) return;
    try {
      await revokeInvite(projectId, inv.id);
      setInvites((list) => list.filter((i) => i.id !== inv.id));
      onStatus?.(t('{{name}} no longer has access.', { name: inv.name }));
    } catch (err) {
      setError((err as Error).message);
    }
  };

  const changeRole = async (inv: Invite, next: 'edit' | 'view') => {
    try {
      const { invite: updated } = await updateInvite(projectId, inv.id, { role: next });
      setInvites((list) => list.map((i) => (i.id === inv.id ? updated : i)));
    } catch (err) {
      setError((err as Error).message);
    }
  };

  const stopAll = async () => {
    setBusy(true);
    try {
      setShare(await stopShare());
      onStatus?.(t('Sharing paused — nobody can open your projects until you share again.'));
    } finally {
      setBusy(false);
    }
  };

  const saveDomain = async (value: string) => {
    setDomainBusy(true);
    setDomainError('');
    try {
      const next = await setShareDomain(value);
      setShare(next);
      setDomainOpen(false);
      if (!value) onStatus?.(t('Fixed address turned off — share links get a new address each time sharing starts.'));
      else if (next.active && next.fixed) onStatus?.(t('Share links now always use {{domain}}.', { domain: next.fixedDomain }));
      else if (next.active) setDomainError(next.note || t('That address couldn’t be used.'));
      else onStatus?.(t('Saved — the next time sharing starts it uses {{domain}}.', { domain: next.fixedDomain }));
    } catch (err) {
      setDomainError((err as Error).message);
    } finally {
      setDomainBusy(false);
    }
  };

  const openMailSetup = () => {
    setMailForm({
      provider: mail?.provider || 'gmail',
      user: mail?.user || '',
      pass: '',
      fromName: mail?.fromName || (owner && owner !== 'Owner' ? owner : ''),
      host: mail?.provider === 'other' ? mail?.host || '' : '',
      port: String(mail?.provider === 'other' ? mail?.port || 587 : 587)
    });
    setMailError('');
    setMailNote('');
    setMailOpen(true);
  };

  const saveMail = async () => {
    setMailBusy(true);
    setMailError('');
    try {
      const next = await saveMailSettings({ ...mailForm, port: Number(mailForm.port) || 587 });
      setMail(next);
      setMailOpen(false);
      setMailNote(t('Email is set up — invites to people with an email address are sent from {{user}}.', { user: next.user }));
    } catch (err) {
      setMailError((err as Error).message);
    } finally {
      setMailBusy(false);
    }
  };

  const testMail = async () => {
    setMailBusy(true);
    setMailError('');
    try {
      await sendTestMail();
      setMailNote(t('Test email sent to {{user}} — check your inbox.', { user: mail?.user || '' }));
    } catch (err) {
      setMailError((err as Error).message);
    } finally {
      setMailBusy(false);
    }
  };

  const turnOffMail = async () => {
    if (!window.confirm(t('Stop sending invite emails from {{user}}? The saved password is deleted from this computer.', { user: mail?.user || '' }))) return;
    setMail(await clearMailSettings());
    setMailNote('');
  };

  const fixedDomain = share?.fixedDomain || '';

  const sorted = useMemo(() => [...invites].sort((a, b) => a.createdAt.localeCompare(b.createdAt)), [invites]);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal nm-share-modal" onClick={(e) => e.stopPropagation()} role="dialog" aria-label={t('Share')}>
        <div className="modal-header">
          <div>{t('Share “{{project}}”', { project: projectName })}</div>
          <button className="nm-icon-btn borderless" onClick={onClose} aria-label={t('Close')}><IconClose size={16} /></button>
        </div>
        <div className="modal-body nm-share-body">
          <div className="nm-share-form">
            <input className="input" placeholder={t('Name')} value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && invite()} />
            <input className="input" type="email" placeholder={mail?.configured ? t('Email (they get the link by email)') : t('Email (optional)')} value={email} onChange={(e) => setEmail(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && invite()} />
            <select className="input nm-share-role" value={role} onChange={(e) => setRole(e.target.value as 'edit' | 'view')} aria-label={t('Access')}>
              <option value="edit">{t('Can edit')}</option>
              <option value="view">{t('Can view')}</option>
            </select>
            <button className="btn nm-primary" onClick={invite} disabled={busy}>{busy ? t('Working…') : t('Invite')}</button>
          </div>
          {error && <div className="share-error">{error}</div>}

          <div className="nm-share-section-title">{t('People with access')}</div>
          <div className="nm-share-people">
            <div className="nm-share-person owner">
              <span className="nm-avatar">{initials(owner || 'You')}</span>
              <div className="nm-share-who">
                <div className="nm-share-name">{owner && owner !== 'Owner' ? owner : t('You')} <span className="muted">({t('you')})</span></div>
                <div className="muted nm-share-sub">{t('Owner — the project lives on this computer')}</div>
              </div>
            </div>
            {sorted.length === 0 && <div className="muted nm-share-empty">{t('Nobody else yet. Add someone above — each person gets their own link, which you can cancel any time.')}</div>}
            {sorted.map((inv) => (
              <div key={inv.id} className={`nm-share-person ${justAdded === inv.id ? 'new' : ''}`}>
                <span className="nm-avatar">{initials(inv.name)}</span>
                <div className="nm-share-who">
                  <div className="nm-share-name">{inv.name}{inv.email && <span className="muted nm-share-email"> · {inv.email}</span>}</div>
                  <div className="muted nm-share-sub">
                    <button className="nm-share-code" onClick={() => copyCode(inv)} title={t('Access code — click to copy')}>{prettyCode(inv.code)}</button>
                    <button className="nm-share-newcode" onClick={() => newCode(inv)} title={t('Make a new access code (the old one stops working)')}>{t('New code')}</button>
                    {' · '}{ago(inv.lastSeenAt, t)}{inv.emailedAt && <> · {t('Emailed {{date}}', { date: new Date(inv.emailedAt).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) })}</>}</div>
                </div>
                <select className="input nm-share-role small" value={inv.role} onChange={(e) => changeRole(inv, e.target.value as 'edit' | 'view')} aria-label={t('Access for {{name}}', { name: inv.name })}>
                  <option value="edit">{t('Can edit')}</option>
                  <option value="view">{t('Can view')}</option>
                </select>
                <button className="nm-icon-btn" onClick={() => copy(inv)} title={t('Copy {{name}}’s link and access code', { name: inv.name })} aria-label={t('Copy link')}>
                  {copied === inv.id ? <IconCheck size={15} /> : <IconCopy size={15} />}
                </button>
                {inv.email && mail?.configured && (
                  <button className="nm-icon-btn nm-share-mail" onClick={() => sendInviteEmail(inv)} disabled={sending === inv.id} title={t('Send {{name}} their link by email', { name: inv.name })}>
                    {sending === inv.id ? t('Sending…') : inv.emailedAt ? t('Resend') : t('Send email')}
                  </button>
                )}
                {inv.email && !mail?.configured && (
                  <a className={`nm-icon-btn nm-share-mail ${base ? '' : 'disabled'}`} href={base ? mailto(inv) : undefined} title={base ? t('Email the invite') : t('Turn sharing on first')} onClick={(e) => !base && e.preventDefault()}>
                    {t('Email')}
                  </a>
                )}
                <button className="nm-icon-btn danger" onClick={() => remove(inv)} title={t('Remove access')} aria-label={t('Remove access for {{name}}', { name: inv.name })}>
                  <IconTrash size={15} />
                </button>
              </div>
            ))}
          </div>

          <div className={`nm-share-foot ${share?.active ? 'on' : ''}`}>
            <span className={`share-dot ${share?.active ? 'on' : share?.starting ? 'starting' : ''}`} />
            <div className="nm-share-foot-text">
              {share?.active ? (
                <>
                  {t('Sharing is on')} <span className="muted">· {share.provider}</span>
                  <div className="muted">{t('Links work while this computer is on and Numenor is running. People open the project in their browser, or add it to their own Numenor under “Shared with me”.')}</div>
                </>
              ) : (
                <>
                  {t('Sharing is paused')}
                  <div className="muted">{t('Inviting someone turns it on. Removing a person cancels only their link.')}</div>
                </>
              )}
              {share?.note && <div className="share-note">{share.note}</div>}
            </div>
            {share?.active && <button className="btn ghost" onClick={stopAll} disabled={busy}>{t('Pause sharing')}</button>}
          </div>

          <div className="nm-share-fixed">
            <div className="nm-share-fixed-row">
              <div className="nm-share-fixed-text">
                <b>{t('Same link every time')}</b>
                <div className="muted">
                  {fixedDomain
                    ? share?.active && !share.fixed
                      ? t('Set to {{domain}}, but it isn’t being used right now — links are temporary until it works.', { domain: fixedDomain })
                      : t('Links always use {{domain}}, so they keep working after a restart.', { domain: fixedDomain })
                    : t('Off — links get a new address each time sharing starts, so you’d have to resend them.')}
                </div>
              </div>
              {!domainOpen && (
                <button className="btn ghost" onClick={() => { setDomain(fixedDomain); setDomainError(''); setDomainOpen(true); }}>
                  {fixedDomain ? t('Change') : t('Set up')}
                </button>
              )}
            </div>
            {domainOpen && (
              <div className="nm-share-fixed-edit">
                <div className="muted">
                  {t('A free ngrok account includes one fixed address. Copy it from')}{' '}
                  <a href="https://dashboard.ngrok.com/domains" target="_blank" rel="noreferrer">dashboard.ngrok.com/domains</a>{' '}
                  {t('(it looks like something.ngrok-free.app) and paste it here.')}
                </div>
                <div className="nm-share-fixed-inputs">
                  <input className="input" autoFocus placeholder="your-name.ngrok-free.app" value={domain} onChange={(e) => setDomain(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && saveDomain(domain)} />
                  <button className="btn nm-primary" onClick={() => saveDomain(domain)} disabled={domainBusy || !domain.trim()}>{domainBusy ? t('Checking…') : t('Use this address')}</button>
                  {fixedDomain && <button className="btn ghost" onClick={() => saveDomain('')} disabled={domainBusy}>{t('Turn off')}</button>}
                  <button className="btn ghost" onClick={() => setDomainOpen(false)} disabled={domainBusy}>{t('Cancel')}</button>
                </div>
                <div className="muted">{t('If sharing is on, it restarts with the new address — people with your old temporary links need the new ones once.')}</div>
              </div>
            )}
            {domainError && <div className="share-error">{domainError}</div>}
          </div>

          <div className="nm-share-fixed nm-share-mailsetup">
            <div className="nm-share-fixed-row">
              <div className="nm-share-fixed-text">
                <b>{t('Email invites')}</b>
                <div className="muted">
                  {mail?.configured
                    ? t('On — inviting someone with an email address sends them their link from {{user}}.', { user: mail.user })
                    : t('Off — set up your email once and Numenor sends each person their link when you invite them.')}
                </div>
              </div>
              {!mailOpen && (
                <div className="nm-share-mail-actions">
                  {mail?.configured && <button className="btn ghost" onClick={testMail} disabled={mailBusy}>{mailBusy ? t('Sending…') : t('Send test')}</button>}
                  <button className="btn ghost" onClick={openMailSetup}>{mail?.configured ? t('Change') : t('Set up')}</button>
                  {mail?.configured && <button className="btn ghost" onClick={turnOffMail} disabled={mailBusy}>{t('Turn off')}</button>}
                </div>
              )}
            </div>
            {mailOpen && (
              <div className="nm-share-fixed-edit nm-mail-form">
                <div className="nm-mail-grid">
                  <label>{t('Email service')}
                    <select className="input" value={mailForm.provider} onChange={(e) => setMailForm({ ...mailForm, provider: e.target.value })}>
                      <option value="gmail">Gmail</option>
                      <option value="outlook">Outlook / Hotmail</option>
                      <option value="icloud">iCloud Mail</option>
                      <option value="other">{t('Other (SMTP server)')}</option>
                    </select>
                  </label>
                  <label>{t('Your name (shown as sender)')}
                    <input className="input" value={mailForm.fromName} onChange={(e) => setMailForm({ ...mailForm, fromName: e.target.value })} placeholder={t('Your name')} />
                  </label>
                  <label>{t('Your email address')}
                    <input className="input" type="email" autoFocus value={mailForm.user} onChange={(e) => setMailForm({ ...mailForm, user: e.target.value })} placeholder="you@gmail.com" />
                  </label>
                  <label>{t('App password')}
                    <input className="input" type="password" autoComplete="new-password" value={mailForm.pass} onChange={(e) => setMailForm({ ...mailForm, pass: e.target.value })} placeholder={mail?.configured ? t('Leave empty to keep the saved one') : 'abcd efgh ijkl mnop'} onKeyDown={(e) => e.key === 'Enter' && saveMail()} />
                  </label>
                  {mailForm.provider === 'other' && (
                    <>
                      <label>{t('SMTP server')}
                        <input className="input" value={mailForm.host} onChange={(e) => setMailForm({ ...mailForm, host: e.target.value })} placeholder="smtp.example.com" />
                      </label>
                      <label>{t('Port')}
                        <input className="input" value={mailForm.port} onChange={(e) => setMailForm({ ...mailForm, port: e.target.value.replace(/\D/g, '') })} placeholder="587" />
                      </label>
                    </>
                  )}
                </div>
                <div className="muted">
                  {mailForm.provider === 'gmail' ? (
                    <>
                      {t('Gmail needs an app password, not your normal password: turn on 2-Step Verification, then create one at')}{' '}
                      <a href="https://myaccount.google.com/apppasswords" target="_blank" rel="noreferrer">myaccount.google.com/apppasswords</a>{' '}
                      {t('and paste the 16 letters here.')}
                    </>
                  ) : mailForm.provider === 'icloud' ? (
                    <>
                      {t('iCloud needs an app-specific password — create one at')}{' '}
                      <a href="https://account.apple.com" target="_blank" rel="noreferrer">account.apple.com</a>{' '}
                      {t('→ Sign-In and Security → App-Specific Passwords.')}
                    </>
                  ) : mailForm.provider === 'outlook' ? (
                    t('Use your Outlook password, or an app password if your account has two-step verification.')
                  ) : (
                    t('Use the SMTP settings from your email provider (port 465 = SSL, 587 = STARTTLS).')
                  )}{' '}
                  {t('The password is checked with the server, then kept only on this computer.')}
                </div>
                <div className="nm-share-fixed-inputs">
                  <button className="btn nm-primary" onClick={saveMail} disabled={mailBusy || !mailForm.user.trim() || (!mailForm.pass.trim() && !mail?.configured)}>{mailBusy ? t('Checking…') : t('Save')}</button>
                  <button className="btn ghost" onClick={() => setMailOpen(false)} disabled={mailBusy}>{t('Cancel')}</button>
                </div>
              </div>
            )}
            {mailError && <div className="share-error">{mailError}</div>}
            {mailNote && !mailError && <div className="nm-share-mail-note">{mailNote}</div>}
          </div>
        </div>
      </div>
    </div>
  );
}
