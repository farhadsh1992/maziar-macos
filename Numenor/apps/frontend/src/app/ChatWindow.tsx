import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { IconPopIn } from './icons';
import { aiAction } from '../api/client';

export type ChatSnapshot = {
  messages: { role: 'user' | 'assistant' | 'system'; content: string }[];
  draft: string;
  off: boolean;
  busy: boolean;
  generating: boolean;
  theme?: string;
};

export default function ChatWindow() {
  const { t } = useTranslation();
  const [snapshot, setSnapshot] = useState<ChatSnapshot>();
  const [draft, setDraft] = useState<string>();
  const send = (type: string, text?: string) => window.opener?.postMessage({ type, text }, window.location.origin);
  useEffect(() => {
    document.title = t('Chat');
    const update = (event: MessageEvent) => {
      if (event.origin !== window.location.origin || event.source !== window.opener || event.data?.type !== 'nm-chat:update') return;
      const next: ChatSnapshot = event.data.snapshot;
      setSnapshot(next);
      setDraft((current) => current ?? next.draft);
      if (next.theme === 'light' || next.theme === 'dark') document.documentElement.dataset.theme = next.theme;
      else delete document.documentElement.dataset.theme;
    };
    window.addEventListener('message', update);
    window.opener?.postMessage({ type: 'nm-chat:ready' }, window.location.origin);
    return () => window.removeEventListener('message', update);
  }, [t]);
  return (
    <main className="nm-chat-window">
      <header className="panel-header">
        <strong>{t('Chat')}</strong>
        <button type="button" className="nm-icon-btn" onClick={() => send('nm-chat:dock')}>
          <IconPopIn size={15} />{t('Return Chat to editor')}
        </button>
      </header>
      {snapshot && <>
        <div className="chat-messages" aria-live="polite">
          {snapshot.messages.length === 0 && <div className="muted">{t('输入问题，进行只读对话。')}</div>}
          {snapshot.messages.map((message, index) => (
            <div key={index} className={`chat-msg ${message.role}`}>
              <div className="role">{message.role}</div>
              <div className={`content ${message.role === 'assistant' ? 'markdown-body' : ''}`}>
                {message.role === 'assistant'
                  ? <ReactMarkdown remarkPlugins={[remarkGfm]}>{message.content}</ReactMarkdown> : message.content}
              </div>
            </div>
          ))}
        </div>
        <form className="chat-controls" onSubmit={(event) => {
          event.preventDefault();
          if (!snapshot.off && !snapshot.busy && draft?.trim()) send('nm-chat:send', draft);
        }}>
          <textarea autoFocus className="chat-input" aria-label={t('Chat message')} value={draft ?? ''}
            onChange={(event) => { setDraft(event.target.value); send('nm-chat:draft', event.target.value); }}
            placeholder={t('例如：帮我解释这一段的实验设计。')} />
          <div className="row">
            {snapshot.off
              ? <button type="button" className="btn" onClick={() => send('nm-chat:settings')}>{t('Choose an AI model')}</button>
              : <button type="submit" className="btn" disabled={snapshot.busy || !draft?.trim()}>{t('发送')}</button>}
            {snapshot.generating && <button type="button" className="btn ghost"
              onClick={() => { void aiAction('cancel-generation').catch(() => {}); }}>{t('Cancel AI')}</button>}
          </div>
        </form>
      </>}
    </main>
  );
}
