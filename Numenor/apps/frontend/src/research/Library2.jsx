import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Details, Feedback, Splitter, ThemeSelect, research, useReport, useResearchSettings } from './common';
import { ResearchPDF } from './ResearchPDF';
import './research.css';

const views = [['all', 'All Papers'], ['reading', 'Continue Reading'], ['queue', 'Reading Queue'], ['archive', 'Archive']];
const statuses = [['unread', 'Unread'], ['queue', 'Reading Queue'], ['reading', 'Reading'], ['finished', 'Finished'], ['archive', 'Archived']];
const statusOf = (paper) => paper.progress?.status ?? (paper.archived ? 'archive' : 'unread');
const statusName = (value) => statuses.find(([id]) => id === value)?.[1] ?? value;

export default function Library2() {
  const navigate = useNavigate();
  const { settings, save, error: settingsError } = useResearchSettings('library');
  const { status, error, report, fail } = useReport();
  const [catalog, setCatalog] = useState(null);
  const [selection, setSelection] = useState(null);
  const [currentPage, setCurrentPage] = useState(1);
  const [scope, setScope] = useState('all');
  const [search, setSearch] = useState('');
  const [sort, setSort] = useState('title');
  const [year, setYear] = useState('');
  const [venue, setVenue] = useState('');
  const [readingStatus, setReadingStatus] = useState('');
  const [expanded, setExpanded] = useState(false);
  const [newCollection, setNewCollection] = useState(null);
  const [leftWidth, setLeftWidth] = useState(null);
  const [listWidth, setListWidth] = useState(null);
  const upload = useRef(null);
  const resume = useRef(settings.selected);
  resume.current = settings.selected;
  const rememberedPaper = useRef(null);

  const select = (paper, persist = true) => {
    if (rememberedPaper.current === paper.id) return;
    rememberedPaper.current = paper.id;
    const page = paper.progress?.page ?? 1;
    setSelection({ id: paper.id, page });
    setCurrentPage(page);
    if (persist) void save({ selected: paper.id }).catch(fail);
  };
  const reload = () => research('/catalog').then((data) => {
    setCatalog(data);
    if (!rememberedPaper.current) {
      const saved = data.papers.find((paper) => paper.id === (data.settings?.selected || resume.current));
      if (saved) select(saved, false);
    }
  }).catch(fail);
  useEffect(() => { void reload(); }, []);

  const papers = catalog?.papers ?? [];
  const paper = papers.find((item) => item.id === selection?.id);
  const patchPaper = async (paper, body) => {
    const progress = await research('/paper/' + paper.id, { method: 'PATCH', body });
    setCatalog((previous) => previous && ({ ...previous, papers: previous.papers.map((item) => item.id === paper.id ? { ...item, progress } : item) }));
  };
  const open = (item) => {
    const page = item.id === paper?.id ? currentPage : item.progress?.page ?? 1;
    navigate('/reader2/' + item.id + '?page=' + page);
  };
  const visible = papers.filter((item) => {
    const state = statusOf(item);
    if (scope === 'archive' ? state !== 'archive' : state === 'archive') return false;
    if ((scope === 'queue' || scope === 'reading') && state !== scope) return false;
    if (scope.startsWith('group:') && !item.collections?.includes(scope.slice(6))) return false;
    if (scope.startsWith('subgroup:') && !item.subgroupIDs?.includes(scope.slice(9))) return false;
    if (scope.startsWith('local:') && !item.progress?.collections?.includes(scope.slice(6))) return false;
    if (year && item.year !== year || venue && item.venue !== venue || readingStatus && state !== readingStatus) return false;
    const haystack = [item.title, item.authors, item.year, item.venue, item.doi, ...(item.tags ?? [])].filter(Boolean).join(' ').toLowerCase();
    return search.toLowerCase().trim().split(/\s+/).every((word) => haystack.includes(word));
  }).sort((a, b) => {
    if (sort === 'recent') return (b.progress?.viewed ?? b.added ?? '').localeCompare(a.progress?.viewed ?? a.added ?? '') || a.title.localeCompare(b.title);
    if (sort === 'year') return (Number(b.year) || 0) - (Number(a.year) || 0) || a.title.localeCompare(b.title);
    return a.title.localeCompare(b.title);
  });
  const years = [...new Set(papers.map((paper) => paper.year).filter(Boolean))].sort().reverse();
  const venues = [...new Set(papers.map((paper) => paper.venue).filter(Boolean))].sort();
  const filters = [[year, setYear], [venue, setVenue], [readingStatus && statusName(readingStatus), setReadingStatus]];
  const left = leftWidth ?? settings.leftWidth ?? 205;
  const list = listWidth ?? settings.listWidth ?? 320;

  return <main className="r2-app" data-r2-theme={settings.theme}>
    <header className="r2-header">
      <h1>Library2</h1>
      <div className="r2-actions">
        <ThemeSelect theme={settings.theme} onChange={(theme) => void save({ theme }).catch(fail)} />
        <button onClick={() => void reload()}>Refresh</button>
        <button className="r2-primary" onClick={() => upload.current?.click()}>Import PDF</button>
        <input ref={upload} type="file" accept="application/pdf,.pdf" hidden onChange={async (event) => {
          const file = event.target.files?.[0];
          event.target.value = '';
          if (!file) return;
          const body = new FormData();
          body.append('file', file);
          report('Importing PDF…');
          try {
            const imported = await research('/import', { method: 'POST', body });
            await reload();
            select(imported);
            report('PDF imported.');
          } catch (error) { fail(error); }
        }} />
      </div>
    </header>
    <Feedback status={status} error={error || settingsError} />
    <div className="r2-split">
      {!expanded && <>
        <nav className="r2-library-nav" aria-label="Paper collections" style={{ width: left }}>
          <div className="r2-nav-scroll">
            {views.map(([id, label]) => <button key={id} aria-pressed={scope === id} onClick={() => setScope(id)}>{label}</button>)}
            <h2>Collections</h2>
            {catalog?.groups.map((group) => <details key={group.id}>
              <summary>{group.name}</summary>
              <button aria-pressed={scope === 'group:' + group.id} onClick={() => setScope('group:' + group.id)}>All in {group.name}</button>
              {group.subgroups?.map((sub) => <button key={sub.id} aria-pressed={scope === 'subgroup:' + sub.id}
                onClick={() => setScope('subgroup:' + sub.id)}>{sub.name}</button>)}
            </details>)}
            {settings.collections?.map((group) => <button key={group.id} aria-pressed={scope === 'local:' + group.id}
              onClick={() => setScope('local:' + group.id)}>{group.name}</button>)}
            {newCollection !== null ? <form className="r2-stack" onSubmit={async (event) => {
              event.preventDefault();
              if (!newCollection.trim()) return;
              try {
                await save({ addCollection: { id: crypto.randomUUID(), name: newCollection.trim() } });
                setNewCollection(null);
              } catch (error) { fail(error); }
            }}><input aria-label="Collection name" autoFocus maxLength={120} value={newCollection}
              onChange={(event) => setNewCollection(event.target.value)} /><button className="r2-primary">Add collection</button></form>
              : <button onClick={() => setNewCollection('')}>New collection</button>}
          </div>
          <footer>{catalog?.folder || 'No connected folder'}{catalog && !catalog.available && <small>Folder unavailable. Connect it in Library or import a PDF.</small>}</footer>
        </nav>
        <Splitter label="Collections width" value={left} onChange={setLeftWidth} onFinish={(leftWidth) => void save({ leftWidth }).catch(fail)} min={150} max={350} />
        <section className="r2-paper-list" aria-label="Paper list" style={{ width: list }}>
          <div className="r2-list-filters">
            <input type="search" aria-label="Search papers" placeholder="Search papers" value={search} onChange={(event) => setSearch(event.target.value)} />
            <div className="r2-actions">
              <select aria-label="Sort papers" value={sort} onChange={(event) => setSort(event.target.value)}>
                <option value="title">Title</option><option value="year">Newest year</option><option value="recent">Last read</option></select>
              <select aria-label="Filter by year" value={year} onChange={(event) => setYear(event.target.value)}>
                <option value="">Year</option>{years.map((value) => <option key={value}>{value}</option>)}</select>
              <select aria-label="Filter by venue" value={venue} onChange={(event) => setVenue(event.target.value)}>
                <option value="">Venue</option>{venues.map((value) => <option key={value}>{value}</option>)}</select>
              <select aria-label="Filter by reading status" value={readingStatus} onChange={(event) => setReadingStatus(event.target.value)}>
                <option value="">Status</option>{statuses.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select>
            </div>
            {filters.some(([label]) => label) && <div className="r2-actions" aria-label="Active filters">
              {filters.map(([label, clear], index) => label && <button key={index} onClick={() => clear('')} aria-label={'Remove ' + label + ' filter'}>{label} ×</button>)}</div>}
            <span className="r2-muted">{catalog ? visible.length + (visible.length === 1 ? ' paper' : ' papers') : 'Loading papers…'}</span>
          </div>
          <div className="r2-list-scroll">
            {catalog && visible.length === 0 && <p className="r2-empty">No papers match this view.</p>}
            {visible.map((item) => <button key={item.id} className="r2-paper-row" aria-pressed={item.id === paper?.id}
              onClick={() => select(item)} onDoubleClick={() => open(item)}
              onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); open(item); } }}>
              <strong>{item.title}</strong>
              <span>{[item.authors, item.year, item.venue].filter(Boolean).join(' · ') || 'Bibliographic details unavailable'}</span>
              <small>{statusName(statusOf(item))}{!item.hasPDF && ' · PDF missing'}</small>
            </button>)}
          </div>
        </section>
        <Splitter label="Paper list width" value={list} onChange={setListWidth} onFinish={(listWidth) => void save({ listWidth }).catch(fail)} min={200} max={620} />
      </>}
      <section className="r2-preview" aria-label="PDF preview">
        {paper ? <>
          <div className="r2-preview-header">
            <strong title={paper.title}>{paper.title}</strong>
            <div className="r2-actions">
              <button onClick={() => setExpanded(!expanded)}>{expanded ? 'Restore Panes' : 'Expand Preview'}</button>
              <button className="r2-primary" onClick={() => open(paper)}>Open in Reader2</button>
            </div>
          </div>
          {paper.hasPDF ? <ResearchPDF key={paper.id} id={paper.id} initialPage={selection.page}
            onPage={(page) => {
              setCurrentPage(page);
              if (paper.progress?.page !== page) void patchPaper(paper, { page }).catch(fail);
            }} /> : <p className="r2-empty">This PDF is missing or offline. Reconnect the source folder, then refresh.</p>}
          <details className="r2-inspector">
            <summary>Paper details</summary>
            <div className="r2-inspector-body">
              <div className="r2-actions">
                <label className="r2-inline">Reading status <select value={statusOf(paper)}
                  onChange={(event) => void patchPaper(paper, { status: event.target.value }).catch(fail)}>
                  {statuses.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select></label>
                {settings.collections?.map((group) => <label key={group.id} className="r2-inline">
                  <input type="checkbox" checked={paper.progress?.collections?.includes(group.id) ?? false} onChange={(event) => {
                    const memberships = paper.progress?.collections ?? [];
                    void patchPaper(paper, { collections: event.target.checked ? [...memberships, group.id] : memberships.filter((id) => id !== group.id) }).catch(fail);
                  }} /> {group.name}</label>)}
              </div>
              <Details paper={paper} />
            </div>
          </details>
        </> : <p className="r2-empty">Select a paper to preview its PDF.</p>}
      </section>
    </div>
  </main>;
}
