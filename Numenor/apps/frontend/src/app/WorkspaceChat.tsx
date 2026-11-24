import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import ReactMarkdown from 'react-markdown';
import { aiAction, runAgent, type AIStatus } from '../api/client';
import AIModels from './AIModels';

type Message = { role: 'user' | 'assistant'; content: string };

function latexDraft(reply: string) {
  const source = reply.match(/\x60\x60\x60(?:latex|tex)?\s*([\s\S]*?)\x60\x60\x60/i)?.[1].trim() ?? reply.trim();
  return /^\\documentclass\b/.test(source) && /\\end\{document\}\s*$/.test(source) ? source + '\n' : '';
}

export default function WorkspaceChat({ visible, status, onStatus, close, create }: {
  visible: boolean; status?: AIStatus; onStatus: (status: AIStatus) => void;
  close: () => void; create: (source?: string) => void;
}) {
  const { t, i18n } = useTranslation();
  const [messages, setMessages] = useState<Message[]>([]);
  const [prompt, setPrompt] = useState('');
  const [busy, setBusy] = useState(false);
  const [settings, setSettings] = useState(false);
  const [mode, setMode] = useState<'chat' | 'draft'>('chat');

  if (!visible) return null;
  return (
    <div className="modal-backdrop" onClick={close} onKeyDown={(event) => { if (event.key === 'Escape') close(); }}>
      <div className="modal nm-workspace-chat" role="dialog" aria-label={t('Workspace AI')}
        onClick={(event) => event.stopPropagation()}>
        <header className="modal-header">
          <strong>{t(settings ? 'AI & Models' : 'Workspace AI')}</strong>
          <button type="button" className="icon-btn" aria-label={t('Close')} onClick={close}>×</button>
        </header>
        {settings ? <>
          <div className="modal-body"><AIModels status={status} onUpdate={onStatus} /></div>
          <div className="modal-actions"><button type="button" className="btn" onClick={() => setSettings(false)}>{t('Back to Chat')}</button></div>
        </> : <>
          <div className="nm-workspace-chat-mode">
            <button type="button" className="nm-stat-btn" aria-pressed={mode === 'chat'} onClick={() => setMode('chat')}>{t('Chat')}</button>
            <button type="button" className="nm-stat-btn" aria-pressed={mode === 'draft'} onClick={() => setMode('draft')}>{t('Draft a LaTeX project')}</button>
            <button type="button" className="nm-stat-btn" onClick={() => setSettings(true)}>{t('AI & Models')}</button>
          </div>
          <div className="chat-messages" aria-live="polite">
            {messages.map((message, index) => {
              const source = message.role === 'assistant' ? latexDraft(message.content) : '';
              return <div className={`chat-msg ${message.role}`} key={index}>
                <div className="content">{message.role === 'assistant'
                  ? <ReactMarkdown>{message.content}</ReactMarkdown> : message.content}</div>
                {source && <button type="button" className="btn ghost" onClick={() => create(source)}>{t('Use draft in a new project')}</button>}
              </div>;
            })}
          </div>
          <form className="chat-controls" onSubmit={async (event) => {
            event.preventDefault();
            const question = prompt.trim();
            if (!question || busy || !status || status.active === 'off' || status.generating) return;
            const history = messages.slice(-8);
            setMessages((current) => [...current, { role: 'user', content: question }]);
            setPrompt('');
            setBusy(true);
            const language = i18n.resolvedLanguage === 'pt-PT' ? 'Reply in European Portuguese. ' : '';
            const request = mode === 'draft' ? 'Draft one complete, self-contained LaTeX document. Return it in a single fenced latex code block, beginning with \\documentclass and ending with \\end{document}. Request: ' : '';
            try {
              const result = await runAgent({ task: 'custom', prompt: language + request + question, selection: '', content: '', mode: 'direct', interaction: 'chat', history });
              setMessages((current) => [...current, { role: 'assistant', content: result.reply }]);
            } catch (error) {
              setMessages((current) => [...current, { role: 'assistant', content: t('请求失败: {{error}}', { error: String(error) }) }]);
            } finally { setBusy(false); }
          }}>
            <textarea className="chat-input" autoFocus aria-label={t('Chat message')} value={prompt}
              onChange={(event) => setPrompt(event.target.value)} placeholder={t('Ask a question or describe a new project.')} />
            <div className="row">
              {status?.active === 'off'
                ? <button type="button" className="btn" onClick={() => setSettings(true)}>{t('Choose an AI model')}</button>
                : <button type="submit" className="btn" disabled={!status || !prompt.trim() || busy || status.generating}>{t('发送')}</button>}
              {busy && <button type="button" className="btn ghost"
                onClick={() => { void aiAction('cancel-generation').catch(() => {}); }}>{t('Cancel AI')}</button>}
              <button type="button" className="btn ghost" onClick={() => create()}>{t('新建项目')}</button>
            </div>
          </form>
        </>}
      </div>
    </div>
  );
}
