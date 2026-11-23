// Sending invite emails straight from Numenor, through the owner's own email account (SMTP). Settings —
// including the app password — stay on this computer only, in STATE_DIR/mail-settings.json (owner-only file).
import fs from 'node:fs';
import path from 'node:path';
import nodemailer from 'nodemailer';
import { STATE_DIR } from '../config/constants.js';

const FILE = path.join(STATE_DIR, 'mail-settings.json');

export const MAIL_PRESETS = {
  gmail: { host: 'smtp.gmail.com', port: 465, secure: true },
  outlook: { host: 'smtp-mail.outlook.com', port: 587, secure: false },
  icloud: { host: 'smtp.mail.me.com', port: 587, secure: false },
  other: null
};

function load() {
  try {
    const data = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    return data && typeof data === 'object' ? data : null;
  } catch {
    return null;
  }
}

function save(data) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const tmp = `${FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, FILE);
}

/** What the browser may see: never the password. */
export function mailStatus() {
  const s = load();
  if (!s?.user || !s?.pass) return { configured: false };
  return { configured: true, provider: s.provider, host: s.host, port: s.port, user: s.user, fromName: s.fromName || '' };
}

function transportFor(s) {
  return nodemailer.createTransport({
    host: s.host,
    port: s.port,
    secure: Boolean(s.secure),
    auth: { user: s.user, pass: s.pass },
    connectionTimeout: 15000,
    greetingTimeout: 15000,
    socketTimeout: 20000
  });
}

function friendlyError(err, provider) {
  const text = String(err?.response || err?.message || err);
  if (err?.code === 'EAUTH' || /^AUTH/i.test(err?.command || '') || /535|534|auth/i.test(text)) {
    if (provider === 'gmail') return 'Gmail didn’t accept the email and app password. Use an app password (myaccount.google.com/apppasswords — needs 2-Step Verification), not your normal Gmail password.';
    return 'The email server didn’t accept that email and password. Many providers need an “app password” instead of your normal password.';
  }
  if (['ECONNECTION', 'ETIMEDOUT', 'ESOCKET', 'ENOTFOUND', 'ECONNREFUSED'].includes(err?.code)) {
    return 'Couldn’t reach the email server — check the server name and port, and your internet connection.';
  }
  return `Email error: ${text.slice(0, 300)}`;
}

/** Checks the login with the server before saving. Empty password = keep the saved one. */
export async function saveMailSettings(input = {}) {
  const old = load() || {};
  const provider = Object.hasOwn(MAIL_PRESETS, input.provider) ? input.provider : 'other';
  const preset = MAIL_PRESETS[provider];
  const port = Number(preset ? preset.port : input.port) || 587;
  const next = {
    provider,
    host: preset ? preset.host : String(input.host || '').trim(),
    port,
    secure: preset ? preset.secure : port === 465,
    user: String(input.user || '').trim(),
    // Gmail shows app passwords in groups of four ("abcd efgh ijkl mnop") — spaces aren't part of it.
    pass: String(input.pass || '').replace(/\s+/g, '') || (old.user === String(input.user || '').trim() ? old.pass : ''),
    fromName: String(input.fromName || '').trim().slice(0, 80)
  };
  if (!next.host) return { error: 'Enter the email server name (for example smtp.example.com).' };
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(next.user)) return { error: 'Enter your email address.' };
  if (!next.pass) return { error: 'Enter the app password.' };
  try {
    await transportFor(next).verify();
  } catch (err) {
    return { error: friendlyError(err, provider) };
  }
  save(next);
  return mailStatus();
}

export function clearMailSettings() {
  try { fs.unlinkSync(FILE); } catch { /* already gone */ }
  return mailStatus();
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export async function sendMail({ to, subject, text, html }) {
  const s = load();
  if (!s?.user || !s?.pass) return { error: 'Set up email in the Share dialog first.' };
  try {
    const from = s.fromName ? { name: s.fromName, address: s.user } : s.user;
    const info = await transportFor(s).sendMail({ from, to, subject, text, html, replyTo: s.user });
    return { ok: true, messageId: info.messageId };
  } catch (err) {
    return { error: friendlyError(err, s.provider) };
  }
}

export function inviteEmail({ name, owner, projectName, role, link, code }) {
  const pretty = code ? `${code.slice(0, 4)}-${code.slice(4)}` : '';
  const who = owner && owner !== 'Owner' ? owner : (load()?.fromName || 'Someone');
  const rights = role === 'view' ? 'view it' : 'view and edit it';
  const subject = `${who} shared “${projectName}” with you on Numenor`;
  const text = [
    `Hi ${name},`,
    '',
    `${who} shared the LaTeX project “${projectName}” with you on Numenor — you can ${rights}.`,
    '',
    'Open it in your web browser (nothing to install):',
    link,
    '',
    `Your access code: ${pretty}`,
    'The browser asks for it each time you open the link. Keep it to yourself — it is only for you.',
    '',
    'If you use Numenor on your own computer, you can also keep it there: Projects → Add shared link, paste the link and the code once, and it remembers them.',
    '',
    `The link works while ${who}’s computer is on and sharing.`
  ].join('\n');
  const html = `<div style="font-family:Georgia,serif;font-size:15px;color:#14213d;line-height:1.5;max-width:560px">
<p>Hi ${esc(name)},</p>
<p><b>${esc(who)}</b> shared the LaTeX project <b>“${esc(projectName)}”</b> with you on Numenor — you can ${rights}.</p>
<p style="margin:24px 0"><a href="${esc(link)}" style="background:#14213d;color:#fff;text-decoration:none;padding:11px 20px;border-radius:6px;font-family:-apple-system,Helvetica,Arial,sans-serif;font-weight:600">Open “${esc(projectName)}”</a></p>
<p style="margin:0 0 6px">Your access code:</p>
<p style="margin:0 0 6px"><span style="display:inline-block;font-family:Menlo,Consolas,monospace;font-size:22px;letter-spacing:3px;font-weight:700;background:#f7f4ec;border:1px solid #b8892b;border-radius:6px;padding:6px 14px">${esc(pretty)}</span></p>
<p style="color:#555;font-size:13px;margin-top:0">The browser asks for it each time you open the link. Keep it to yourself — it is only for you.</p>
<p style="color:#555;font-size:13px">Opens in your web browser — nothing to install. If the button doesn’t work, copy this link:<br><a href="${esc(link)}" style="color:#9a7224;word-break:break-all">${esc(link)}</a></p>
<p style="color:#555;font-size:13px">If you use Numenor on your own computer, you can also keep it there: Projects → <b>Add shared link</b>, paste the link and the code once, and it remembers them.</p>
<p style="color:#555;font-size:13px">The link works while ${esc(who)}’s computer is on and sharing.</p>
</div>`;
  return { subject, text, html };
}
