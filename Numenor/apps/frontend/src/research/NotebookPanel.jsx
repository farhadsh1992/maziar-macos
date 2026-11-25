import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { Feedback, research, useReport } from './common';


export function passageMarkdown(paper, passage, sourceLink) {
  const delimiter = '`'.repeat(Math.max(3, ...Array.from(passage.text.matchAll(/`+/g), (match) => match[0].length + 1)));
  return `### ${paper.title.replace(/([\\[\]<>])/g, '\\$1')}\n\n[Page ${passage.page}](${sourceLink}?page=${passage.page})\n\n${delimiter}text\n${passage.text}\n${delimiter}`;
}

export const NotebookPanel = forwardRef(function NotebookPanel({ paper, settings, saveSettings, selection, onSourcePage }, ref) {
  const [connection, setConnection] = useState(null);
  const [serverLabel, setServerLabel] = useState('Checking JupyterLab…');
  const [owned, setOwned] = useState(false);
  const [ready, setReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [command, setCommand] = useState('');
  const [token, setToken] = useState('');
  const [copiedMarkdown, setCopiedMarkdown] = useState('');
  const frame = useRef(null);
  const waiting = useRef(null);
  const frameOrigin = useRef(null);
  const sourcePage = useRef(onSourcePage);
  sourcePage.current = onSourcePage;
  const [frameVersion, setFrameVersion] = useState(0);
  const { report, fail, status, error } = useReport();

  const refresh = () => research('/notebook/status').then(({ label, owned }) => {
    setServerLabel(label);
    setOwned(owned);
  }).catch(fail);
  useEffect(() => { void refresh(); }, []);
  useEffect(() => { setCommand(settings.jupyterCommand ?? ''); }, [settings.jupyterCommand]);

  useEffect(() => {
    const receive = (event) => {
      if (event.origin !== frameOrigin.current || event.source !== frame.current?.contentWindow) return;
      if (event.data?.type === 'reader2:notebook-ready') {
        setReady(true);
        report('Notebook is open.');
      }
      if (event.data?.type === 'reader2:source-page' && Number.isInteger(event.data.page) && event.data.page > 0) {
        sourcePage.current?.(event.data.page);
      }
      if (event.data?.type !== 'reader2:append-result' || event.data.id !== waiting.current?.id) return;
      const { finish, timer } = waiting.current;
      waiting.current = null;
      clearTimeout(timer);
      finish(event.data);
    };
    window.addEventListener('message', receive);
    return () => {
      window.removeEventListener('message', receive);
      if (waiting.current) {
        clearTimeout(waiting.current.timer);
        waiting.current.finish({ error: 'The notebook pane was closed.' });
        waiting.current = null;
      }
    };
  }, []);

  useEffect(() => {
    if (!connection?.embedURL || ready) return;
    const timer = setTimeout(() => fail(new Error('The embedded notebook did not become ready. Open it in JupyterLab to continue.')), 25000);
    return () => clearTimeout(timer);
  }, [connection, ready, frameVersion]);

  const open = async () => {
    if (ready) { report('Notebook is already open.'); return; }
    setBusy(true);
    setReady(false);
    report('Starting or connecting to JupyterLab on port 6666…');
    try {
      const data = await research('/paper/' + paper.id + '/notebook', { method: 'POST' });
      frameOrigin.current = data.embedURL ? new URL(data.embedURL).origin : null;
      setConnection(data);
      setFrameVersion((previous) => previous + 1);
      setOwned(data.owned);
      setServerLabel(data.label);
      report(data.embedURL ? 'Opening the notebook editor…' : 'Open this notebook in your browser. Copy Markdown to add it without disturbing a live notebook.');
    } catch (error) { fail(error); }
    finally { setBusy(false); }
  };

  const append = async (markdown) => {
    if (!ready || !frame.current?.contentWindow) throw new Error('Open and wait for the embedded notebook first.');
    if (waiting.current) throw new Error('A notebook change is still being saved.');
    if (markdown.length > 100_000) throw new Error('Select a shorter passage or note.');
    const id = crypto.randomUUID();
    const result = await new Promise((finish) => {
      const timer = setTimeout(() => {
        waiting.current = null;
        finish({ error: 'JupyterLab did not confirm the update. Check the notebook before retrying.' });
      }, 12000);
      waiting.current = { id, finish, timer };
      frame.current.contentWindow.postMessage({ type: 'reader2:append', id, markdown }, frameOrigin.current);
    });
    if (result.error) throw new Error(result.error);
    report('Markdown cell added and saved.');
  };

  useImperativeHandle(ref, () => ({
    async appendDraft(text, page) {
      const link = connection?.sourceLink ?? (window.location.origin + '/reader2/' + paper.id);
      const title = paper.title.replace(/([\\[\]<>])/g, '\\$1');
      const markdown = `### ${title}\n\n[Page ${page}](${link}?page=${page})\n\n${text}`;
      if (connection?.embedURL) {
        await append(markdown);
        return true;
      }
      if (!connection) throw new Error('Open the paper’s notebook from Notes first.');
      setCopiedMarkdown(markdown);
      return false;
    }
  }));

  return <div className="r2-notebook">
    <div className="r2-notebook-controls">
      <h3>JupyterLab</h3>
      <p className="r2-muted">{serverLabel}{ready ? ' · Notebook ready' : ''}</p>
      <div className="r2-actions">
        <button className="r2-primary" disabled={busy} onClick={() => void open()}>Open Notebook</button>
        {connection?.browserURL && <a href={connection.browserURL} target="_blank" rel="noreferrer">Open in JupyterLab</a>}
        {owned && <button disabled={busy} onClick={async () => {
          setBusy(true);
          try {
            const { label, owned } = await research('/notebook/stop', { method: 'POST' });
            setConnection(null);
            setReady(false);
            setServerLabel(label);
            setOwned(owned);
            report('Stop requested for Maziar’s JupyterLab.');
          } catch (error) { fail(error); } finally { setBusy(false); }
        }}>Stop</button>}
        {selection && connection && <button disabled={Boolean(connection.embedURL) && !ready} onClick={async () => {
          const markdown = passageMarkdown(paper, selection, connection.sourceLink);
          if (!connection.embedURL) { setCopiedMarkdown(markdown); return; }
          try { await append(markdown); } catch (error) { fail(error); }
        }}>{connection.embedURL ? 'Send Selection to Notebook' : 'Prepare Selection as Markdown'}</button>}
      </div>
      <details className="r2-settings">
        <summary>JupyterLab connection settings</summary>
        <form className="r2-stack" onSubmit={async (event) => {
          event.preventDefault();
          try {
            await saveSettings({ jupyterCommand: command.trim(), ...(token ? { jupyterToken: token.trim() } : {}) });
            setToken('');
            report('JupyterLab settings saved.');
          } catch (error) { fail(error); }
        }}>
          <label>Jupyter executable <input value={command} placeholder={settings.defaultJupyterCommand || 'jupyter'}
            onChange={(event) => setCommand(event.target.value)} /></label>
          <label>Token for an existing server <input type="password" autoComplete="off" value={token}
            placeholder={settings.hasJupyterToken ? 'Token saved' : 'Paste an access token'} onChange={(event) => setToken(event.target.value)} /></label>
          <p className="r2-muted">Install JupyterLab in the environment you want Reader2 to use with <code>python -m pip install jupyterlab</code>. Enter that environment’s full <code>jupyter</code> path if it is outside Maziar’s PATH.</p>
          <div className="r2-actions"><button>Save settings</button>{settings.hasJupyterToken && <button type="button"
            onClick={() => void saveSettings({ jupyterToken: '' }).then(() => report('Saved token removed.')).catch(fail)}>Clear token</button>}</div>
        </form>
      </details>
      {copiedMarkdown && <div className="r2-stack">
        <textarea aria-label="Notebook Markdown" rows={5} readOnly value={copiedMarkdown} />
        <div className="r2-actions"><button onClick={() => void navigator.clipboard.writeText(copiedMarkdown).then(() => report('Markdown copied.')).catch(fail)}>Copy Markdown</button>
          <button onClick={() => setCopiedMarkdown('')}>Dismiss</button></div>
      </div>}
      <Feedback status={status} error={error} />
    </div>
    {connection?.embedURL && <iframe key={frameVersion} className="r2-notebook-frame" title="Reader2 JupyterLab" ref={frame}
      src={connection.embedURL} referrerPolicy="no-referrer" />}
  </div>;
});
