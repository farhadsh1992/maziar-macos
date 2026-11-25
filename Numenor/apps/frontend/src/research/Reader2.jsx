import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { Details, Feedback, Splitter, ThemeSelect, research, useReport, useResearchSettings } from './common';
import { ResearchPDF, Thumbnail } from './ResearchPDF';
import { NotebookPanel } from './NotebookPanel';
import ReaderAI from './ReaderAI';
import './research.css';

function Outline({ items, jump }) {
  return <ul className="r2-outline">{items.map((item, i) => <li key={i}>
    {item.dest ? <button onClick={() => jump(item.dest)}>{item.title}</button>
      : item.url && /^https?:\/\//i.test(item.url) ? <a href={item.url} target="_blank" rel="noreferrer">{item.title}</a> : <span>{item.title}</span>}
    {!!item.items?.length && <Outline items={item.items} jump={jump} />}
  </li>)}</ul>;
}

export default function Reader2() {
  const { paperId } = useParams();
  return <PaperReader key={paperId} id={paperId} />;
}

function PaperReader({ id }) {
  const [query] = useSearchParams();
  const navigate = useNavigate();
  const { settings, save, error: settingsError } = useResearchSettings('reader');
  const { status, error, report, fail } = useReport();
  const [record, setRecord] = useState(null);
  const [progress, setProgress] = useState({});
  const [page, setPage] = useState(1);
  const [document, setDocument] = useState(null);
  const [outline, setOutline] = useState([]);
  const [leftTab, setLeftTab] = useState('Outline');
  const [rightTab, setRightTab] = useState('Notes');
  const [focus, setFocus] = useState(false);
  const [selection, setSelection] = useState(null);
  const [noteDraft, setNoteDraft] = useState('');
  const [leftWidth, setLeftWidth] = useState(null);
  const [rightWidth, setRightWidth] = useState(null);
  const pdf = useRef(null);
  const notebook = useRef(null);
  const initialQuery = useRef(query.get('page'));
  const requestedPage = Number(query.get('page'));
  const persisted = useRef(null);

  useEffect(() => {
    let active = true;
    research('/paper/' + id).then((data) => {
      if (!active) return;
      const hint = Number(initialQuery.current);
      const initial = Number.isInteger(hint) && hint > 0 ? hint : data.progress.page ?? 1;
      persisted.current = data.progress.page;
      setPage(initial);
      setProgress(data.progress);
      setRecord({ ...data, initial });
      void save({ selected: id }).catch(fail);
    }).catch((error) => { if (active) fail(error); });
    return () => { active = false; };
  }, [id]);

  useEffect(() => {
    if (document && Number.isInteger(requestedPage) && requestedPage > 0) {
      if (requestedPage !== record?.initial) pdf.current?.jump(requestedPage);
      navigate('/reader2/' + id, { replace: true });
    }
  }, [document, requestedPage, id]);

  async function patch(body) {
    const next = await research('/paper/' + id, { method: 'PATCH', body });
    setProgress(next);
  }
  const jump = (number, boxes) => pdf.current?.jump(number, boxes);
  const mark = async (kind, value) => {
    try {
      await patch({ add: { kind, value: { id: crypto.randomUUID(), ...value } } });
      report(kind === 'notes' ? 'Note saved.' : kind === 'highlights' ? 'Highlight saved.' : 'Bookmark saved.');
    } catch (error) { fail(error); }
  };
  const remove = (kind, item) => void patch({ remove: { kind, id: item.id } }).catch(fail);
  const itemList = (kind, items, showText = true) => items.length ? <ul className="r2-mark-list">
    {items.map((item) => <li key={item.id}>
      <div className="r2-actions"><button className="r2-page-link" onClick={() => jump(item.page, item.boxes)}>Page {item.page}</button>
        <button className="r2-remove" onClick={() => remove(kind, item)} aria-label={'Remove ' + kind.slice(0, -1) + ' on page ' + item.page}>×</button></div>
      {showText && <p>{item.text}</p>}
    </li>)}
  </ul> : <p className="r2-muted">No {kind} yet.</p>;
  const selectRight = (tab) => {
    setRightTab(tab);
    if (settings.right !== true) void save({ right: true }).catch(fail);
  };

  const paper = record?.paper;
  const left = leftWidth ?? settings.leftWidth ?? 180;
  const right = rightWidth ?? settings.rightWidth ?? 380;
  const leftOpen = settings.left !== false;
  const rightOpen = settings.right === true;
  const marks = progress.highlights ?? [];
  const notes = progress.notes ?? [];

  return <main className="r2-app" data-r2-theme={settings.theme}>
    <header className="r2-header">
      <div className="r2-reader-title"><h1>Reader2</h1>{paper && <strong title={paper.title}>{paper.title}</strong>}</div>
      <div className="r2-actions">
        <Link to="/library2">Library2</Link>
        <ThemeSelect theme={settings.theme} onChange={(theme) => void save({ theme }).catch(fail)} />
        <button aria-pressed={!focus && leftOpen} disabled={focus} onClick={() => void save({ left: !leftOpen }).catch(fail)}>Navigation</button>
        <button aria-pressed={!focus && rightOpen} disabled={focus} onClick={() => void save({ right: !rightOpen }).catch(fail)}>Annotations</button>
        <button aria-pressed={focus} onClick={() => setFocus(!focus)}>{focus ? 'Exit Focus' : 'Focus'}</button>
      </div>
    </header>
    <Feedback status={status} error={error || settingsError} />
    {!paper ? <p className="r2-empty">{error ? 'Open another paper in Library2.' : 'Loading paper…'}</p> : <div className="r2-split">
      {!focus && leftOpen && <>
        <aside className="r2-reader-nav" style={{ width: left }} aria-label="PDF navigation">
          <div className="r2-tabs">
            {['Outline', 'Thumbnails', 'Bookmarks'].map((tab) => <button key={tab} aria-pressed={leftTab === tab} onClick={() => setLeftTab(tab)}>{tab}</button>)}
          </div>
          <div className="r2-pane-scroll">
            {leftTab === 'Bookmarks' ? <>
              <button className="r2-primary" disabled={!document}
                onClick={() => void mark('bookmarks', { page, text: 'Page ' + page })}>Bookmark Page {page}</button>
              {itemList('bookmarks', progress.bookmarks ?? [], false)}
            </> : leftTab === 'Outline' && outline.length ? <Outline items={outline} jump={(dest) => pdf.current?.outline(dest)} />
              : document ? <>
                {leftTab === 'Outline' && <p className="r2-muted">No embedded outline. Showing thumbnails.</p>}
                <div className="r2-thumbnails">{Array.from({ length: document.numPages }, (_, index) =>
                  <Thumbnail key={index} pdf={document} page={index + 1} current={page} jump={jump} />)}</div>
              </> : <p className="r2-muted">Waiting for the PDF…</p>}
          </div>
        </aside>
        <Splitter label="Reader navigation width" value={left} onChange={setLeftWidth} onFinish={(leftWidth) => void save({ leftWidth }).catch(fail)} min={140} max={400} />
      </>}
      <section className="r2-preview" aria-label="Reader2 PDF">
        {paper.hasPDF ? <ResearchPDF id={paper.id} ref={pdf} initialPage={record.initial} marks={marks}
          onSelection={setSelection} onReady={(pdf, outline) => { setDocument(pdf); setOutline(outline); }}
          onPage={(number) => {
            setPage(number);
            if (persisted.current !== number) {
              persisted.current = number;
              void patch({ page: number }).catch(fail);
            }
          }} /> : <p className="r2-empty">The PDF is missing or offline. Reconnect the source folder in Library2.</p>}
        {!focus && (selection || document) && <div className="r2-selection-bar">
          {selection && <span className="r2-selection-quote" title={selection.text}>Page {selection.page} · {selection.text}</span>}
          <button disabled={!selection} onClick={() => void mark('highlights', selection)}>Highlight Selection</button>
          <button onClick={() => selectRight('Notes')}>Add Note</button>
          {selection && <button onClick={() => setSelection(null)} aria-label="Clear captured selection">×</button>}
        </div>}
      </section>
      {!focus && rightOpen && <Splitter label="Annotations width" value={right} onChange={setRightWidth}
        onFinish={(rightWidth) => void save({ rightWidth }).catch(fail)} min={260} max={1100} reverse />}
      <aside className="r2-reader-annotations" hidden={focus || !rightOpen} style={{ width: right }} aria-label="Reading tools">
        <div className="r2-tabs">{['Notes', 'Highlights', 'Details', 'Local AI'].map((tab) =>
          <button key={tab} aria-pressed={rightTab === tab} onClick={() => setRightTab(tab)}>{tab}</button>)}</div>
        <div className="r2-notes-pane" hidden={rightTab !== 'Notes'}>
          <details className="r2-note-editor" open>
            <summary>Page-linked notes</summary>
            <form className="r2-stack" onSubmit={async (event) => {
              event.preventDefault();
              if (!noteDraft.trim()) return;
              await mark('notes', { page: selection?.page ?? page, boxes: selection?.boxes, text: noteDraft.trim() });
              setNoteDraft('');
            }}>
              <textarea aria-label="Page note" rows={2} maxLength={60000} value={noteDraft} onChange={(event) => setNoteDraft(event.target.value)}
                placeholder={'Write a note for page ' + (selection?.page ?? page)} />
              <button disabled={!noteDraft.trim() || !document}>Save Page Note</button>
            </form>
            {itemList('notes', notes)}
            {record.originalNotes && <details><summary>Original Library notes</summary><div className="r2-original-notes">{record.originalNotes}</div></details>}
          </details>
          <NotebookPanel ref={notebook} paper={paper} settings={settings} saveSettings={save} selection={selection} onSourcePage={jump} />
        </div>
        {rightTab === 'Highlights' && <div className="r2-pane-scroll">{itemList('highlights', marks)}</div>}
        {rightTab === 'Details' && <div className="r2-pane-scroll"><Details paper={paper} />
          <label>Reading status <select value={progress.status ?? 'unread'} onChange={(event) => void patch({ status: event.target.value }).catch(fail)}>
            <option value="unread">Unread</option><option value="queue">Reading Queue</option><option value="reading">Reading</option>
            <option value="finished">Finished</option><option value="archive">Archived</option></select></label>
        </div>}
        {rightTab === 'Local AI' && <div className="r2-pane-scroll">
          <ReaderAI paper={paper} page={page} selection={selection} notes={notes} pdf={pdf} settings={settings} save={save}
            applyDraft={async (draft) => {
              const applied = await notebook.current?.appendDraft(draft.text, draft.page);
              setRightTab('Notes');
              if (applied) report('Reviewed draft added to the notebook.');
            }} />
        </div>}
      </aside>
    </div>}
  </main>;
}
