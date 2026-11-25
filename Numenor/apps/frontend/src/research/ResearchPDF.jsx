import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import { getDocument, GlobalWorkerOptions, AnnotationEditorType } from 'pdfjs-dist';
import worker from 'pdfjs-dist/build/pdf.worker.min.js?url';
import { EventBus, PDFLinkService, PDFFindController, PDFViewer } from 'pdfjs-dist/web/pdf_viewer.js';
import 'pdfjs-dist/web/pdf_viewer.css';

GlobalWorkerOptions.workerSrc = worker;

function selectedPassage(container) {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || !container.contains(selection.anchorNode) || !container.contains(selection.focusNode)) return null;
  const range = selection.getRangeAt(0);
  const start = range.startContainer;
  const page = (start.nodeType === Node.ELEMENT_NODE ? start : start.parentElement)?.closest('.page');
  if (!page) return null;
  const bounds = page.getBoundingClientRect();
  const clamp = (value) => Math.max(0, Math.min(1, value));
  const boxes = [...range.getClientRects()].filter((rect) =>
    rect.width > 0 && rect.height > 0 && rect.bottom > bounds.top && rect.top < bounds.bottom
  ).slice(0, 800).map((rect) => [
    clamp((rect.left - bounds.left) / bounds.width), clamp((rect.top - bounds.top) / bounds.height),
    clamp((rect.right - bounds.left) / bounds.width), clamp((rect.bottom - bounds.top) / bounds.height)
  ]);
  const text = selection.toString();
  return text.trim() ? { page: Number(page.dataset.pageNumber), text, boxes } : null;
}

export const ResearchPDF = forwardRef(function ResearchPDF({ id, initialPage = 1, marks = [], onPage, onReady, onSelection }, ref) {
  const viewport = useRef(null);
  const instance = useRef(null);
  const paint = useRef(null);
  const callbacks = useRef({ onPage, onReady, onSelection, marks });
  callbacks.current = { onPage, onReady, onSelection, marks };
  const [phase, setPhase] = useState('Loading PDF…');
  const [page, setPage] = useState(initialPage);
  const [jump, setJump] = useState(String(initialPage));
  const [total, setTotal] = useState(0);
  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState('');
  const [zoom, setZoom] = useState('Fit Width');

  useImperativeHandle(ref, () => ({
    jump(target, boxes) {
      const api = instance.current;
      if (!api?.document) return;
      const pageNumber = Math.max(1, Math.min(api.document.numPages, target));
      api.viewer.currentPageNumber = pageNumber;
      if (boxes?.length) requestAnimationFrame(() => {
        const element = api.viewer.getPageView(pageNumber - 1)?.div;
        if (element) viewport.current?.scrollBy({ top: element.getBoundingClientRect().top
          - viewport.current.getBoundingClientRect().top + boxes[0][1] * element.clientHeight - 45 });
      });
    },
    outline(dest) { void instance.current?.link.goToDestination(dest); },
    async pageText(number) {
      const pdf = instance.current?.document;
      if (!pdf) throw new Error('The PDF is still loading.');
      const content = await (await pdf.getPage(number)).getTextContent();
      return content.items.map((item) => item.str ? item.str + (item.hasEOL ? '\n' : ' ') : '').join('');
    }
  }), []);

  useEffect(() => {
    const container = viewport.current;
    const eventBus = new EventBus();
    const link = new PDFLinkService({ eventBus, externalLinkRel: 'noopener noreferrer' });
    const find = new PDFFindController({ eventBus, linkService: link });
    const viewer = new PDFViewer({ container, eventBus, linkService: link, findController: find,
      textLayerMode: 1, annotationEditorMode: AnnotationEditorType.DISABLE, enableScripting: false, removePageBorders: true });
    link.setViewer(viewer);
    instance.current = { viewer, link, eventBus };
    let active = true;
    let ready = false;
    let resizing;
    const resize = new ResizeObserver(() => {
      cancelAnimationFrame(resizing);
      resizing = requestAnimationFrame(() => {
        if (ready && viewer.currentScaleValue === 'page-width') viewer.currentScaleValue = 'page-width';
      });
    });
    resize.observe(container);

    const draw = (number) => {
      const element = viewer.getPageView(number - 1)?.div;
      if (!element) return;
      element.querySelector('.r2-pdf-marks')?.remove();
      const boxes = callbacks.current.marks.filter((mark) => mark.page === number).flatMap((mark) => mark.boxes ?? []);
      if (!boxes.length) return;
      const overlay = document.createElement('div');
      overlay.className = 'r2-pdf-marks';
      overlay.setAttribute('aria-hidden', 'true');
      for (const [x, y, right, bottom] of boxes) {
        const box = document.createElement('span');
        Object.assign(box.style, { left: x * 100 + '%', top: y * 100 + '%',
          width: (right - x) * 100 + '%', height: (bottom - y) * 100 + '%' });
        overlay.append(box);
      }
      element.append(overlay);
    };
    paint.current = () => Array.from(container.querySelectorAll('.page[data-loaded]')).forEach((item) => draw(Number(item.dataset.pageNumber)));
    eventBus.on('pagerendered', ({ pageNumber }) => draw(pageNumber));
    eventBus.on('pagechanging', ({ pageNumber }) => {
      setPage(pageNumber);
      setJump(String(pageNumber));
      if (ready) callbacks.current.onPage?.(pageNumber);
    });
    eventBus.on('pagesinit', () => {
      viewer.currentScaleValue = 'page-width';
      const target = Math.max(1, Math.min(initialPage, viewer.pagesCount));
      viewer.currentPageNumber = target;
      setPage(target);
      setJump(String(target));
      ready = true;
      callbacks.current.onPage?.(target);
    });
    const updateMatches = ({ matchesCount }) => {
      if (matchesCount?.total) setMatches(matchesCount.current + ' of ' + matchesCount.total);
    };
    eventBus.on('updatefindmatchescount', updateMatches);
    eventBus.on('updatefindcontrolstate', (state) => {
      if (state.state === 1) setMatches('No matches');
      else updateMatches(state);
    });
    const trackSelection = () => {
      const passage = selectedPassage(container);
      if (passage) callbacks.current.onSelection?.(passage);
    };
    document.addEventListener('selectionchange', trackSelection);
    const task = getDocument({ url: '/api/research2/paper/' + id + '/pdf', isEvalSupported: false });
    task.promise.then(async (pdf) => {
      if (!active) return;
      instance.current.document = pdf;
      viewer.setDocument(pdf);
      link.setDocument(pdf);
      setTotal(pdf.numPages);
      setPhase('');
      const outline = await pdf.getOutline().catch(() => null);
      if (active) callbacks.current.onReady?.(pdf, outline ?? []);
    }).catch((error) => {
      if (active) setPhase(error.name === 'PasswordException' ? 'This PDF is password protected.' : 'The PDF could not be opened. Check that it is available on this Mac.');
    });
    return () => {
      active = false;
      ready = false;
      resize.disconnect();
      cancelAnimationFrame(resizing);
      document.removeEventListener('selectionchange', trackSelection);
      viewer.setDocument(null);
      link.setDocument(null);
      void task.destroy().catch(() => {});
      instance.current = null;
      paint.current = null;
    };
  }, [id, initialPage]);

  useEffect(() => { paint.current?.(); }, [marks]);

  const go = (number) => {
    const viewer = instance.current?.viewer;
    if (viewer?.pagesCount && Number.isInteger(number)) viewer.currentPageNumber = Math.max(1, Math.min(total, number));
  };
  const scale = (factor) => {
    const viewer = instance.current?.viewer;
    if (!viewer?.pagesCount) return;
    if (!factor) {
      viewer.currentScaleValue = 'page-width';
      setZoom('Fit Width');
    } else {
      viewer.currentScale = Math.max(0.3, Math.min(4, viewer.currentScale * factor));
      setZoom(Math.round(viewer.currentScale * 100) + '%');
    }
  };
  const find = (value, previous = false, again = false) => {
    setMatches('');
    instance.current?.eventBus.dispatch('find', { type: again ? 'again' : '', query: value,
      caseSensitive: false, entireWord: false, highlightAll: true, findPrevious: previous, matchDiacritics: false });
  };
  return <div className="r2-pdf">
    <div className="r2-pdf-toolbar">
      <button disabled={!total || page <= 1} onClick={() => go(page - 1)} aria-label="Previous page">‹</button>
      <form className="r2-inline" onSubmit={(event) => { event.preventDefault(); go(Number(jump)); }}>
        <input className="r2-page-field" aria-label="PDF page" inputMode="numeric" value={jump} onChange={(event) => setJump(event.target.value)} />
        <span>/ {total || '–'}</span>
      </form>
      <button disabled={!total || page >= total} onClick={() => go(page + 1)} aria-label="Next page">›</button>
      <button onClick={() => scale(1 / 1.15)} aria-label="Zoom out">−</button>
      <button onClick={() => scale(1.15)} aria-label="Zoom in">+</button>
      <button onClick={() => scale(0)} title={zoom}>Fit Width</button>
      {zoom !== 'Fit Width' && <span className="r2-muted">{zoom}</span>}
      <form className="r2-inline" onSubmit={(event) => { event.preventDefault(); find(query, false, true); }}>
        <input type="search" aria-label="Find in PDF" placeholder="Find in PDF" value={query}
          onChange={(event) => { setQuery(event.target.value); find(event.target.value); }} />
        {query && <><button type="button" onClick={() => find(query, true, true)} aria-label="Previous match">↑</button>
          <button type="submit" aria-label="Next match">↓</button><span role="status" className="r2-muted">{matches}</span></>}
      </form>
    </div>
    <div className="r2-pdf-stage">
      {phase && <p role="status" className="r2-pdf-message">{phase}</p>}
      <div ref={viewport} className="r2-pdf-scroll" tabIndex={0} aria-label="PDF document"><div className="pdfViewer" /></div>
    </div>
  </div>;
});

export function Thumbnail({ pdf, page, current, jump }) {
  const canvas = useRef(null);
  useEffect(() => {
    const target = canvas.current;
    let active = true;
    let task;
    const observer = new IntersectionObserver(async ([entry]) => {
      if (!entry.isIntersecting) return;
      observer.disconnect();
      try {
        const sheet = await pdf.getPage(page);
        if (!active) return;
        const viewport = sheet.getViewport({ scale: 96 / sheet.getViewport({ scale: 1 }).width });
        target.width = Math.ceil(viewport.width);
        target.height = Math.ceil(viewport.height);
        task = sheet.render({ canvasContext: target.getContext('2d'), viewport, annotationMode: 0 });
        await task.promise;
      } catch { /* Main viewer reports PDF errors. */ }
    });
    observer.observe(target);
    return () => { active = false; observer.disconnect(); task?.cancel(); };
  }, [pdf, page]);
  return <button className="r2-thumbnail" aria-current={page === current ? 'page' : undefined} onClick={() => jump(page)}>
    <canvas ref={canvas} width="96" height="126" aria-hidden="true" /><span>Page {page}</span>
  </button>;
}
