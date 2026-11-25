import { useEffect, useState } from 'react';
import { Feedback, research, useReport } from './common';

export default function ReaderAI({ paper, page, selection, notes, pdf, settings, save, applyDraft }) {
  const [endpoint, setEndpoint] = useState(settings.aiEndpoint ?? '');
  const [model, setModel] = useState(settings.aiModel ?? '');
  const [connection, setConnection] = useState('Local AI is disconnected');
  const [context, setContext] = useState('selection');
  const [chosen, setChosen] = useState([]);
  const [draft, setDraft] = useState(null);
  const [busy, setBusy] = useState(false);
  const { status, error, report, fail } = useReport();

  const check = () => research('/ai/status').then(({ label }) => setConnection(label)).catch(() => setConnection('Local AI is disconnected'));
  useEffect(() => { void check(); }, []);

  async function run(action, source) {
    setBusy(true);
    report('Waiting for the local model…');
    try {
      let text;
      let pages;
      if (source === 'selection') {
        text = selection?.text;
        pages = selection ? [selection.page] : [];
      } else if (source === 'page') {
        text = await pdf.current?.pageText(page);
        pages = [page];
      } else {
        const selected = notes.filter((note) => chosen.includes(note.id));
        text = selected.map((note) => `Page ${note.page}: ${note.text}`).join('\n\n');
        pages = [...new Set(selected.map((note) => note.page))].slice(0, 100);
      }
      if (!text?.trim()) throw new Error('Choose context with text before asking Local AI.');
      const result = await research('/ai/draft', { method: 'POST', body: {
        action, title: paper.title.slice(0, 500), pages, context: text.slice(0, 32000)
      } });
      setDraft({ text: result.text, page: pages[0] || page, pages });
      report('Draft ready for review.');
    } catch (error) { fail(error); } finally { setBusy(false); }
  }

  return <div className="r2-stack">
    <p className="r2-muted" role="status">{connection}</p>
    <details className="r2-settings" open={!settings.aiEndpoint ? true : undefined}>
      <summary>Local AI connection</summary>
      <form className="r2-stack" onSubmit={async (event) => {
        event.preventDefault();
        try {
          await save({ aiEndpoint: endpoint.trim(), aiModel: model.trim() });
          await check();
        } catch (error) { fail(error); }
      }}>
        <label>Endpoint <input value={endpoint} placeholder="http://127.0.0.1:11434/v1" onChange={(event) => setEndpoint(event.target.value)} /></label>
        <label>Model ID <input value={model} onChange={(event) => setModel(event.target.value)} /></label>
        <button>Save and check</button>
      </form>
    </details>
    <label>Context for notebook draft <select value={context} onChange={(event) => setContext(event.target.value)}>
      <option value="selection">Selected text</option><option value="page">Current page</option><option value="notes">Selected notes</option>
    </select></label>
    {context === 'notes' && notes.map((note) => <label key={note.id}>
      <input type="checkbox" checked={chosen.includes(note.id)} onChange={(event) => setChosen(event.target.checked
        ? [...chosen, note.id] : chosen.filter((id) => id !== note.id))} /> Page {note.page} · {note.text.slice(0, 120)}
    </label>)}
    <div className="r2-actions">
      <button disabled={busy || !selection} onClick={() => void run('Explain Selection', 'selection')}>Explain Selection</button>
      <button disabled={busy} onClick={() => void run('Summarize Page', 'page')}>Summarize Page</button>
      <button className="r2-primary" disabled={busy} onClick={() => void run('Draft Notebook Note', context)}>Draft Notebook Note</button>
    </div>
    {draft && <div className="r2-stack">
      <h3>Review notebook draft</h3>
      <span className="r2-muted">Source pages {draft.pages.join(', ')}</span>
      <textarea aria-label="Proposed notebook text" rows={8} value={draft.text}
        onChange={(event) => setDraft({ ...draft, text: event.target.value })} />
      <div className="r2-actions"><button className="r2-primary" disabled={!draft.text.trim() || busy} onClick={async () => {
        setBusy(true);
        try { await applyDraft(draft); setDraft(null); }
        catch (error) { fail(error); } finally { setBusy(false); }
      }}>Apply to Notebook</button><button onClick={() => setDraft(null)}>Discard</button></div>
    </div>}
    <Feedback status={status} error={error} />
  </div>;
}
