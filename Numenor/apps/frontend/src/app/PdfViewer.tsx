// Maziar: the PDF preview, rewritten for Overleaf-style viewing.
//
//  * Recompiling keeps your place — the new PDF is laid out off-screen and swapped in at the same page,
//    offset and zoom (clamped to the last page when the document got shorter), instead of jumping to page 1.
//  * Pages are sized up front and only the visible ones are rendered, so zooming is instant: pages resize
//    immediately (the text layer follows through pdf.js's `--scale-factor`) and are re-rendered sharp a
//    moment later.
//  * Pinch-to-zoom (Safari gesture events and Chrome's ctrl+wheel), Cmd/Ctrl + wheel, all anchored on the
//    pointer; plain wheel/trackpad scrolling is left alone. Space+drag or middle-button drag pans.
//  * Double-click (or Cmd/Ctrl+click) a spot to jump to its LaTeX source via SyncTeX; `revealBox` scrolls to
//    and briefly highlights a SyncTeX position coming the other way.
import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, type RefObject } from 'react';
import { useTranslation } from 'react-i18next';
import { getDocument, renderTextLayer, type PDFDocumentProxy, type PDFPageProxy } from 'pdfjs-dist';

export type PdfZoomMode = 'fitWidth' | 'fitPage' | 'custom';

export type PdfViewerHandle = {
  zoomIn: () => void;
  zoomOut: () => void;
  fitWidth: () => void;
  fitPage: () => void;
  actualSize: () => void;
  scrollToPage: (page: number) => void;
  revealBox: (box: { page: number; h: number; v: number; width: number; height: number }) => void;
  /** The PDF spot to look up in the source: the selected text, else the last place clicked, else the
   *  middle of the view. Page number plus PDF points from the page's top-left. */
  sourcePoint: () => { page: number; x: number; y: number } | null;
  /** Search the PDF's text (Cmd/Ctrl + F with the PDF last clicked). Highlights every match and scrolls to
   *  the current one; `step` 1 / -1 moves to the next / previous, 0 starts again at the first match on or
   *  after the page in view. Resolves to the current match (1-based) and the number of matches. */
  find: (query: string, step: 0 | 1 | -1) => Promise<{ index: number; total: number }>;
  clearFind: () => void;
  /** Text selected in the PDF, if any (to start a search with). */
  selectedText: () => string;
};

type FindRect = { left: number; top: number; width: number; height: number }; // fractions of the page
type PageText = { text: string; items: { start: number; end: number; x: number; y: number; w: number; h: number }[] };

type Annotation = { id: string; page: number; x: number; y: number; text: string };

type Props = {
  pdfUrl: string;
  spread: boolean;
  annotations: Annotation[];
  annotateMode: boolean;
  onAddAnnotation?: (page: number, x: number, y: number) => void;
  onOutline?: (items: { title: string; page?: number; level: number }[]) => void;
  onZoomChange?: (info: { scale: number; mode: PdfZoomMode }) => void;
  /** PDF point (origin top-left of the page, in PDF points) the user asked to see in the source. */
  onReverseSync?: (page: number, x: number, y: number) => void;
  /** localStorage key under which the reading position is remembered, so the first PDF shown for a
   *  project (e.g. after reopening it) opens where you left off. */
  rememberKey?: string;
  /** Page at the top of the view and the page count, whenever either changes. */
  onPageChange?: (page: number, total: number) => void;
  containerRef?: RefObject<HTMLDivElement>;
};

type PageSlot = {
  number: number;
  width: number; // PDF points at scale 1
  height: number;
  wrapper: HTMLDivElement;
  canvas: HTMLCanvasElement | null;
  renderedScale: number;
  rendering: { cancel: () => void } | null;
  textLayerDone: boolean;
};

const MIN_SCALE = 0.25;
const MAX_SCALE = 5;
const PAGE_GAP = 12;
const PADDING = 12;
const ZOOM_STEP = 1.2;
const MAX_CANVAS_PIXELS = 16_000_000;
const STORE_KEY = 'maziar.pdfViewer.zoom';

function clampScale(value: number) {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, value));
}

function loadZoom(): { mode: PdfZoomMode; scale: number } {
  try {
    const raw = JSON.parse(localStorage.getItem(STORE_KEY) || 'null');
    if (raw && (raw.mode === 'fitWidth' || raw.mode === 'fitPage' || raw.mode === 'custom') && Number.isFinite(raw.scale)) {
      return { mode: raw.mode, scale: clampScale(raw.scale) };
    }
  } catch {
    /* ignore */
  }
  return { mode: 'fitWidth', scale: 1 };
}

const PdfViewer = forwardRef<PdfViewerHandle, Props>(function PdfViewer(
  { pdfUrl, spread, annotations, annotateMode, onAddAnnotation, onOutline, onZoomChange, onReverseSync, rememberKey, onPageChange, containerRef: externalRef },
  ref
) {
  const { t } = useTranslation();
  const localRef = useRef<HTMLDivElement | null>(null);
  const containerRef = externalRef || localRef;
  const docRef = useRef<PDFDocumentProxy | null>(null);
  const slotsRef = useRef<PageSlot[]>([]);
  const innerRef = useRef<HTMLDivElement | null>(null);
  const zoomRef = useRef(loadZoom());
  const observerRef = useRef<IntersectionObserver | null>(null);
  const visibleRef = useRef<Set<number>>(new Set());
  const rerenderTimerRef = useRef<number | null>(null);
  const loadSeqRef = useRef(0);
  const lastClickRef = useRef<{ page: number; x: number; y: number } | null>(null);
  const spreadRef = useRef(spread);
  const rememberKeyRef = useRef(rememberKey);
  rememberKeyRef.current = rememberKey;
  const annotationsRef = useRef(annotations);
  const callbacksRef = useRef({ onZoomChange, onReverseSync, onAddAnnotation, onOutline, annotateMode, onPageChange });
  callbacksRef.current = { onZoomChange, onReverseSync, onAddAnnotation, onOutline, annotateMode, onPageChange };
  const lastPageRef = useRef({ page: 0, total: 0 });
  const reportPage = () => {
    const anchor = slotsRef.current.length ? captureAnchor() : null;
    const total = slotsRef.current.length;
    const page = anchor ? Math.min(anchor.page + (anchor.fy > 0.55 ? 1 : 0), total) : 0;
    if (page !== lastPageRef.current.page || total !== lastPageRef.current.total) {
      lastPageRef.current = { page, total };
      callbacksRef.current.onPageChange?.(page, total);
    }
  };
  annotationsRef.current = annotations;

  const reportZoom = useCallback(() => {
    const { mode, scale } = zoomRef.current;
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ mode, scale }));
    } catch {
      /* ignore */
    }
    callbacksRef.current.onZoomChange?.({ scale, mode });
  }, []);

  // ---------- geometry ----------

  const fitScale = useCallback((mode: PdfZoomMode, slots: PageSlot[]) => {
    const container = containerRef.current;
    // Hidden (another view is showing) — keep the current scale instead of fitting to zero width.
    if (!container || slots.length === 0 || container.clientWidth <= PADDING * 2) return zoomRef.current.scale;
    const maxW = Math.max(...slots.map((s) => s.width));
    const maxH = Math.max(...slots.map((s) => s.height));
    const columns = spreadRef.current ? 2 : 1;
    const availW = container.clientWidth - PADDING * 2 - (columns - 1) * PAGE_GAP;
    const availH = container.clientHeight - PADDING * 2;
    const byWidth = availW / (maxW * columns);
    if (mode === 'fitPage') return clampScale(Math.min(byWidth, availH / maxH));
    return clampScale(byWidth);
  }, [containerRef]);

  const effectiveScale = useCallback((slots: PageSlot[]) => {
    const z = zoomRef.current;
    return z.mode === 'custom' ? z.scale : fitScale(z.mode, slots);
  }, [fitScale]);

  const sizeSlots = (slots: PageSlot[], scale: number) => {
    for (const slot of slots) {
      slot.wrapper.style.width = `${slot.width * scale}px`;
      slot.wrapper.style.height = `${slot.height * scale}px`;
      slot.wrapper.style.setProperty('--scale-factor', String(scale));
    }
  };

  /** Top-left of a page relative to the scroll content. */
  const slotOffset = (slot: PageSlot) => {
    const container = containerRef.current!;
    const c = container.getBoundingClientRect();
    const r = slot.wrapper.getBoundingClientRect();
    return { left: r.left - c.left + container.scrollLeft, top: r.top - c.top + container.scrollTop };
  };

  /** The page under a client point, plus where in it (0–1 fractions). */
  const locate = (clientX: number, clientY: number) => {
    const slots = slotsRef.current;
    let best: { slot: PageSlot; fx: number; fy: number; dist: number } | null = null;
    for (const slot of slots) {
      const r = slot.wrapper.getBoundingClientRect();
      const dy = clientY < r.top ? r.top - clientY : clientY > r.bottom ? clientY - r.bottom : 0;
      const dx = clientX < r.left ? r.left - clientX : clientX > r.right ? clientX - r.right : 0;
      const dist = dy * 4 + dx;
      if (!best || dist < best.dist) {
        best = {
          slot,
          fx: r.width ? (clientX - r.left) / r.width : 0,
          fy: r.height ? (clientY - r.top) / r.height : 0,
          dist
        };
      }
      if (dist === 0) break;
    }
    return best;
  };

  /** Where the reader currently is: the page at the top of the view and how far into it. */
  const captureAnchor = () => {
    const container = containerRef.current;
    if (!container || slotsRef.current.length === 0) return null;
    const c = container.getBoundingClientRect();
    const hit = locate(c.left + c.width / 2, c.top + 1);
    if (!hit) return null;
    const pageRect = hit.slot.wrapper.getBoundingClientRect();
    return {
      page: hit.slot.number,
      fy: pageRect.height ? (c.top - pageRect.top) / pageRect.height : 0,
      fxScroll: container.scrollWidth > container.clientWidth ? container.scrollLeft / (container.scrollWidth - container.clientWidth) : 0
    };
  };

  const restoreAnchor = (anchor: ReturnType<typeof captureAnchor>) => {
    const container = containerRef.current;
    const slots = slotsRef.current;
    if (!container || !anchor || slots.length === 0) return;
    const slot = slots[Math.min(anchor.page, slots.length) - 1];
    const fy = anchor.page > slots.length ? 0 : anchor.fy;
    const top = slotOffset(slot).top + fy * slot.wrapper.getBoundingClientRect().height;
    container.scrollTop = Math.max(0, top);
    if (container.scrollWidth > container.clientWidth) {
      container.scrollLeft = anchor.fxScroll * (container.scrollWidth - container.clientWidth);
    }
  };

  // ---------- rendering ----------

  /** Selectable text over the page. Laid out once in PDF units and stretched by `--scale-factor`, so it
   *  follows zoom without being rebuilt. pdf.js reads that variable from the DOM, so the page must be
   *  attached first — pages pre-rendered off-screen get their text layer on the next pass. */
  const addTextLayer = async (slot: PageSlot, doc: PDFDocumentProxy) => {
    if (slot.textLayerDone || !slot.wrapper.isConnected) return;
    slot.textLayerDone = true;
    const textLayer = document.createElement('div');
    textLayer.className = 'textLayer';
    slot.wrapper.appendChild(textLayer);
    try {
      const page = await doc.getPage(slot.number);
      const textContent = await page.getTextContent();
      // pdf.js lays text out in PDF units either way; passing the current scale just matches its sanity check.
      const scale = parseFloat(slot.wrapper.style.getPropertyValue('--scale-factor')) || 1;
      renderTextLayer({ textContentSource: textContent, container: textLayer, viewport: page.getViewport({ scale }) });
    } catch {
      /* text layer is optional */
    }
  };

  const renderSlot = useCallback(async (slot: PageSlot, scale: number, seq: number) => {
    const doc = docRef.current;
    if (!doc) return;
    if (slot.canvas && Math.abs(slot.renderedScale - scale) < 0.001) {
      if (!slot.textLayerDone) await addTextLayer(slot, doc);
      return;
    }
    slot.rendering?.cancel();
    let page: PDFPageProxy;
    try {
      page = await doc.getPage(slot.number);
    } catch {
      return;
    }
    if (seq !== loadSeqRef.current) return;
    const dpr = window.devicePixelRatio || 1;
    let pixelRatio = dpr;
    const cssW = slot.width * scale;
    const cssH = slot.height * scale;
    if (cssW * cssH * pixelRatio * pixelRatio > MAX_CANVAS_PIXELS) {
      pixelRatio = Math.sqrt(MAX_CANVAS_PIXELS / (cssW * cssH));
    }
    const viewport = page.getViewport({ scale: scale * pixelRatio });
    const canvas = document.createElement('canvas');
    canvas.width = Math.floor(viewport.width);
    canvas.height = Math.floor(viewport.height);
    canvas.className = 'pdf-canvas';
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const task = page.render({ canvasContext: ctx, viewport });
    slot.rendering = { cancel: () => task.cancel() };
    try {
      await task.promise;
    } catch {
      return; // cancelled or failed — a later pass will redo it
    }
    slot.rendering = null;
    if (seq !== loadSeqRef.current) return;
    if (slot.canvas) slot.canvas.replaceWith(canvas);
    else slot.wrapper.prepend(canvas);
    slot.canvas = canvas;
    slot.renderedScale = scale;

    await addTextLayer(slot, doc);
  }, []);

  const renderVisible = useCallback(() => {
    const slots = slotsRef.current;
    if (!slots.length) return;
    const scale = effectiveScale(slots);
    const seq = loadSeqRef.current;
    const wanted = new Set<number>();
    visibleRef.current.forEach((n) => {
      wanted.add(n);
      wanted.add(n - 1);
      wanted.add(n + 1);
    });
    for (const slot of slots) {
      if (wanted.has(slot.number)) {
        renderSlot(slot, scale, seq);
      } else if (slot.canvas && Math.abs(slot.renderedScale - scale) > 0.001) {
        // Far away and stale: drop the bitmap to save memory; it is re-rendered when it comes into view.
        slot.canvas.remove();
        slot.canvas = null;
      }
    }
  }, [effectiveScale, renderSlot]);

  const scheduleRender = useCallback((delay = 120) => {
    if (rerenderTimerRef.current) window.clearTimeout(rerenderTimerRef.current);
    rerenderTimerRef.current = window.setTimeout(() => {
      rerenderTimerRef.current = null;
      renderVisible();
    }, delay);
  }, [renderVisible]);

  const placeAnnotations = useCallback(() => {
    const inner = innerRef.current;
    if (!inner) return;
    inner.querySelectorAll('.pdf-annotation').forEach((node) => node.remove());
    for (const note of annotationsRef.current) {
      const slot = slotsRef.current[note.page - 1];
      if (!slot) continue;
      const marker = document.createElement('div');
      marker.className = 'pdf-annotation';
      marker.style.left = `${note.x * 100}%`;
      marker.style.top = `${note.y * 100}%`;
      marker.title = note.text;
      marker.dataset.annotationId = note.id;
      slot.wrapper.appendChild(marker);
    }
  }, []);

  /** Lay the pages out (in single or two-page rows) into a fresh content element. */
  const buildInner = (slots: PageSlot[]) => {
    const inner = document.createElement('div');
    inner.className = 'pdf-pages';
    if (spreadRef.current) {
      for (let i = 0; i < slots.length; i += 2) {
        const row = document.createElement('div');
        row.className = 'pdf-spread';
        row.appendChild(slots[i].wrapper);
        if (slots[i + 1]) row.appendChild(slots[i + 1].wrapper);
        inner.appendChild(row);
      }
    } else {
      slots.forEach((slot) => inner.appendChild(slot.wrapper));
    }
    return inner;
  };

  const observe = (slots: PageSlot[]) => {
    observerRef.current?.disconnect();
    visibleRef.current = new Set();
    const container = containerRef.current;
    if (!container) return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const n = Number((entry.target as HTMLElement).dataset.pageNumber);
          if (entry.isIntersecting) visibleRef.current.add(n);
          else visibleRef.current.delete(n);
        }
        scheduleRender(30);
      },
      { root: container, rootMargin: '50% 0px' }
    );
    slots.forEach((slot) => observer.observe(slot.wrapper));
    observerRef.current = observer;
  };

  /** Zooms to `nextScale`, keeping the point under (clientX, clientY) — or the view's top — in place. */
  const zoomTo = useCallback((nextScale: number, mode: PdfZoomMode, clientX?: number, clientY?: number) => {
    const container = containerRef.current;
    const slots = slotsRef.current;
    if (!container) return;
    if (!slots.length) {
      zoomRef.current = { mode, scale: clampScale(nextScale) };
      reportZoom();
      return;
    }
    const c = container.getBoundingClientRect();
    const px = clientX ?? c.left + c.width / 2;
    const py = clientY ?? c.top + 1;
    const hit = locate(px, py);
    zoomRef.current = { mode, scale: clampScale(nextScale) };
    const scale = effectiveScale(slots);
    zoomRef.current.scale = scale;
    sizeSlots(slots, scale);
    if (hit) {
      const r = hit.slot.wrapper.getBoundingClientRect();
      container.scrollLeft += r.left + hit.fx * r.width - px;
      container.scrollTop += r.top + hit.fy * r.height - py;
    }
    reportZoom();
    scheduleRender();
  }, [containerRef, effectiveScale, reportZoom, scheduleRender]);

  // ---------- loading a (new) PDF ----------

  useEffect(() => {
    const container = containerRef.current;
    if (!container || !pdfUrl) return;
    const seq = ++loadSeqRef.current;
    let cancelled = false;

    (async () => {
      try {
        const doc = await getDocument(pdfUrl).promise;
        if (cancelled || seq !== loadSeqRef.current) {
          doc.destroy();
          return;
        }
        const slots: PageSlot[] = [];
        for (let n = 1; n <= doc.numPages; n += 1) {
          const page = await doc.getPage(n);
          const vp = page.getViewport({ scale: 1 });
          const wrapper = document.createElement('div');
          wrapper.className = 'pdf-page';
          wrapper.dataset.pageNumber = String(n);
          slots.push({ number: n, width: vp.width, height: vp.height, wrapper, canvas: null, renderedScale: 0, rendering: null, textLayerDone: false });
        }
        if (cancelled || seq !== loadSeqRef.current) {
          doc.destroy();
          return;
        }

        // Where the reader is in the PDF being replaced — captured now, just before the swap. For the
        // first PDF of a session there's nothing on screen yet, so use the position saved last time.
        let anchor = captureAnchor();
        if (!anchor && rememberKeyRef.current) {
          try {
            const saved = JSON.parse(localStorage.getItem(rememberKeyRef.current) || 'null');
            if (saved && Number.isFinite(saved.page) && Number.isFinite(saved.fy)) {
              anchor = { page: saved.page, fy: saved.fy, fxScroll: Number(saved.fxScroll) || 0 };
            }
          } catch {
            /* ignore */
          }
        }
        const previousDoc = docRef.current;
        docRef.current = doc;
        const scale = effectiveScale(slots);
        zoomRef.current.scale = scale;
        sizeSlots(slots, scale);

        // Render the pages that will be on screen before swapping, so the view never flashes blank.
        const firstPage = anchor ? Math.min(anchor.page, slots.length) : 1;
        // …but never wait long: pdf.js draws on animation frames, which the browser pauses while the window or
        // tab is hidden, and the pages must still appear (they fill in once rendering catches up).
        await Promise.race([
          Promise.all(
            [firstPage, firstPage + 1].filter((n) => n <= slots.length).map((n) => renderSlot(slots[n - 1], scale, seq))
          ),
          new Promise((resolve) => window.setTimeout(resolve, 1500))
        ]);
        if (cancelled || seq !== loadSeqRef.current) return;

        const inner = buildInner(slots);
        slotsRef.current.forEach((slot) => slot.rendering?.cancel());
        if (innerRef.current && innerRef.current.parentNode === container) container.replaceChild(inner, innerRef.current);
        else {
          container.innerHTML = '';
          container.appendChild(inner);
        }
        innerRef.current = inner;
        slotsRef.current = slots;
        restoreAnchor(anchor);
        observe(slots);
        placeAnnotations();
        reportZoom();
        reportPage();
        previousDoc?.destroy();

        const onOutline = callbacksRef.current.onOutline;
        if (onOutline) {
          try {
            const outline = await doc.getOutline();
            const items: { title: string; page?: number; level: number }[] = [];
            const walk = async (entries: any[], level: number) => {
              for (const entry of entries || []) {
                let pageNumber: number | undefined;
                try {
                  const dest = typeof entry.dest === 'string' ? await doc.getDestination(entry.dest) : entry.dest;
                  if (Array.isArray(dest) && dest.length > 0) pageNumber = (await doc.getPageIndex(dest[0])) + 1;
                } catch {
                  pageNumber = undefined;
                }
                items.push({ title: entry.title || t('(untitled)'), page: pageNumber, level });
                if (entry.items?.length) await walk(entry.items, level + 1);
              }
            };
            await walk(outline || [], 1);
            onOutline(items);
          } catch {
            onOutline([]);
          }
        }
      } catch (err) {
        if (cancelled) return;
        console.error('PDF render error:', err);
        container.innerHTML = `<div class="muted">${t('PDF 渲染失败')}</div>`;
        innerRef.current = null;
        slotsRef.current = [];
      }
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pdfUrl]);

  // Switching single/two-page layout re-flows the same pages.
  useEffect(() => {
    if (spreadRef.current === spread) return;
    spreadRef.current = spread;
    const container = containerRef.current;
    const slots = slotsRef.current;
    if (!container || !slots.length || !innerRef.current) return;
    const anchor = captureAnchor();
    const inner = buildInner(slots);
    container.replaceChild(inner, innerRef.current);
    innerRef.current = inner;
    const scale = effectiveScale(slots);
    zoomRef.current.scale = scale;
    sizeSlots(slots, scale);
    restoreAnchor(anchor);
    observe(slots);
    reportZoom();
    scheduleRender(0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [spread]);

  useEffect(() => {
    placeAnnotations();
  }, [annotations, placeAnnotations]);

  // Fit modes follow the panel's width (e.g. when the divider is dragged).
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let last = container.clientWidth;
    const observer = new ResizeObserver(() => {
      if (container.clientWidth === 0 || Math.abs(container.clientWidth - last) < 2) return;
      last = container.clientWidth;
      if (zoomRef.current.mode !== 'custom' && slotsRef.current.length) {
        zoomTo(zoomRef.current.scale, zoomRef.current.mode);
      }
    });
    observer.observe(container);
    return () => observer.disconnect();
  }, [containerRef, zoomTo]);

  // ---------- input: zoom, pan, reverse sync ----------

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const onWheel = (event: WheelEvent) => {
      // Chrome reports a trackpad pinch as ctrl+wheel; Cmd/Ctrl+wheel is the mouse equivalent.
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      const delta = event.deltaMode === 1 ? event.deltaY * 33 : event.deltaY;
      // A mouse-wheel notch arrives as one large delta: zoom one gentle step. A trackpad pinch arrives as
      // many small deltas: follow it continuously (same curve pdf.js uses).
      const factor = Math.abs(delta) >= 50
        ? (delta < 0 ? 1.1 : 1 / 1.1)
        : Math.exp(-delta / 100);
      zoomTo(zoomRef.current.scale * factor, 'custom', event.clientX, event.clientY);
    };

    // Safari / WKWebView deliver a trackpad pinch as gesture events.
    let gestureStart = 1;
    const onGestureStart = (event: Event) => {
      event.preventDefault();
      gestureStart = zoomRef.current.scale;
    };
    const onGestureChange = (event: Event) => {
      event.preventDefault();
      const e = event as Event & { scale: number; clientX: number; clientY: number };
      zoomTo(gestureStart * e.scale, 'custom', e.clientX, e.clientY);
    };

    let spaceDown = false;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.code === 'Space' && !spaceDown && container.matches(':hover')) {
        const target = event.target as HTMLElement | null;
        if (target && (target.isContentEditable || /INPUT|TEXTAREA|SELECT/.test(target.tagName))) return;
        spaceDown = true;
        container.classList.add('pan-ready');
        event.preventDefault();
      }
    };
    const onKeyUp = (event: KeyboardEvent) => {
      if (event.code === 'Space') {
        spaceDown = false;
        container.classList.remove('pan-ready');
      }
    };

    let pan: { x: number; y: number; left: number; top: number } | null = null;
    const onMouseDown = (event: MouseEvent) => {
      const pageEl = (event.target as HTMLElement | null)?.closest('.pdf-page') as HTMLElement | null;
      const clicked = pageEl ? slotsRef.current[Number(pageEl.dataset.pageNumber) - 1] : undefined;
      if (pageEl && clicked) {
        const r = pageEl.getBoundingClientRect();
        lastClickRef.current = {
          page: clicked.number,
          x: ((event.clientX - r.left) / r.width) * clicked.width,
          y: ((event.clientY - r.top) / r.height) * clicked.height
        };
      }
      if (event.button === 1 || (event.button === 0 && spaceDown)) {
        event.preventDefault();
        pan = { x: event.clientX, y: event.clientY, left: container.scrollLeft, top: container.scrollTop };
        container.classList.add('panning');
      }
    };
    const onMouseMove = (event: MouseEvent) => {
      if (!pan) return;
      container.scrollLeft = pan.left - (event.clientX - pan.x);
      container.scrollTop = pan.top - (event.clientY - pan.y);
    };
    const onMouseUp = () => {
      if (!pan) return;
      pan = null;
      container.classList.remove('panning');
    };

    const reverseAt = (event: MouseEvent) => {
      const pageEl = (event.target as HTMLElement | null)?.closest('.pdf-page') as HTMLElement | null;
      if (!pageEl) return false;
      const slot = slotsRef.current[Number(pageEl.dataset.pageNumber) - 1];
      if (!slot) return false;
      const r = pageEl.getBoundingClientRect();
      const x = ((event.clientX - r.left) / r.width) * slot.width;
      const y = ((event.clientY - r.top) / r.height) * slot.height;
      callbacksRef.current.onReverseSync?.(slot.number, x, y);
      return true;
    };
    const onDblClick = (event: MouseEvent) => {
      if (callbacksRef.current.annotateMode) return;
      if (reverseAt(event)) {
        window.getSelection()?.removeAllRanges();
      }
    };
    const onClick = (event: MouseEvent) => {
      if (callbacksRef.current.annotateMode) {
        const pageEl = (event.target as HTMLElement | null)?.closest('.pdf-page') as HTMLElement | null;
        if (pageEl && callbacksRef.current.onAddAnnotation) {
          const r = pageEl.getBoundingClientRect();
          callbacksRef.current.onAddAnnotation(Number(pageEl.dataset.pageNumber || 1), (event.clientX - r.left) / r.width, (event.clientY - r.top) / r.height);
        }
        return;
      }
      if ((event.metaKey || event.ctrlKey) && reverseAt(event)) event.preventDefault();
    };

    let saveTimer: number | null = null;
    const onScroll = () => {
      reportPage();
      if (saveTimer) window.clearTimeout(saveTimer);
      saveTimer = window.setTimeout(() => {
        saveTimer = null;
        const key = rememberKeyRef.current;
        const anchor = slotsRef.current.length ? captureAnchor() : null;
        if (!key || !anchor) return;
        try {
          localStorage.setItem(key, JSON.stringify(anchor));
        } catch {
          /* ignore */
        }
      }, 300);
    };

    container.addEventListener('scroll', onScroll, { passive: true });
    container.addEventListener('wheel', onWheel, { passive: false });
    container.addEventListener('gesturestart', onGestureStart as EventListener, { passive: false } as AddEventListenerOptions);
    container.addEventListener('gesturechange', onGestureChange as EventListener, { passive: false } as AddEventListenerOptions);
    container.addEventListener('mousedown', onMouseDown);
    container.addEventListener('dblclick', onDblClick);
    container.addEventListener('click', onClick);
    window.addEventListener('mousemove', onMouseMove);
    window.addEventListener('mouseup', onMouseUp);
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('keyup', onKeyUp);
    return () => {
      container.removeEventListener('scroll', onScroll);
      if (saveTimer) window.clearTimeout(saveTimer);
      container.removeEventListener('wheel', onWheel);
      container.removeEventListener('gesturestart', onGestureStart as EventListener);
      container.removeEventListener('gesturechange', onGestureChange as EventListener);
      container.removeEventListener('mousedown', onMouseDown);
      container.removeEventListener('dblclick', onDblClick);
      container.removeEventListener('click', onClick);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('keyup', onKeyUp);
    };
  }, [containerRef, zoomTo]);

  useEffect(() => () => {
    observerRef.current?.disconnect();
    if (rerenderTimerRef.current) window.clearTimeout(rerenderTimerRef.current);
    docRef.current?.destroy();
    docRef.current = null;
  }, []);

  // ---------- imperative API for the toolbar and SyncTeX ----------

  // ---------- find in PDF ----------
  const textCacheRef = useRef<{ doc: PDFDocumentProxy | null; pages: Map<number, PageText> }>({ doc: null, pages: new Map() });
  const findRef = useRef<{ query: string; matches: { page: number; rects: FindRect[] }[]; current: number }>({ query: '', matches: [], current: -1 });

  const pageText = async (doc: PDFDocumentProxy, n: number): Promise<PageText> => {
    if (textCacheRef.current.doc !== doc) textCacheRef.current = { doc, pages: new Map() };
    const cached = textCacheRef.current.pages.get(n);
    if (cached) return cached;
    const page = await doc.getPage(n);
    const content = await page.getTextContent();
    let text = '';
    const items: PageText['items'] = [];
    for (const raw of content.items as { str?: string; transform?: number[]; width?: number; height?: number; hasEOL?: boolean }[]) {
      if (typeof raw.str !== 'string' || !raw.transform) continue;
      const [a, b, , , e, f] = raw.transform;
      const h = raw.height || Math.hypot(a, b) || 10;
      items.push({ start: text.length, end: text.length + raw.str.length, x: e, y: f, w: raw.width || 0, h });
      text += raw.str;
      if (raw.hasEOL) text += ' ';
    }
    const result = { text: text.toLowerCase(), items };
    textCacheRef.current.pages.set(n, result);
    return result;
  };

  /** Rectangles (fractions of the page) covering characters [start, end) of a page's text. */
  const rectsFor = async (doc: PDFDocumentProxy, n: number, pt: PageText, start: number, end: number) => {
    const vp = (await doc.getPage(n)).getViewport({ scale: 1 });
    const rects: FindRect[] = [];
    for (const it of pt.items) {
      if (it.end <= start || it.start >= end || it.end === it.start) continue;
      const len = it.end - it.start;
      const a = Math.max(start, it.start) - it.start;
      const b = Math.min(end, it.end) - it.start;
      const x0 = it.x + (it.w * a) / len;
      const x1 = it.x + (it.w * b) / len;
      const [px0, py0] = vp.convertToViewportPoint(x0, it.y + it.h * 0.88);
      const [px1, py1] = vp.convertToViewportPoint(x1, it.y - it.h * 0.24);
      rects.push({
        left: Math.min(px0, px1) / vp.width,
        top: Math.min(py0, py1) / vp.height,
        width: Math.max(Math.abs(px1 - px0), 2) / vp.width,
        height: Math.max(Math.abs(py1 - py0), 4) / vp.height
      });
    }
    return rects;
  };

  const clearFindMarks = () => {
    containerRef.current?.querySelectorAll('.pdf-find-hit').forEach((el) => el.remove());
  };

  const drawFind = (scrollToCurrent: boolean) => {
    clearFindMarks();
    const { matches, current } = findRef.current;
    matches.forEach((m, i) => {
      const slot = slotsRef.current[m.page - 1];
      if (!slot) return;
      for (const r of m.rects) {
        const el = document.createElement('div');
        el.className = `pdf-find-hit${i === current ? ' current' : ''}`;
        el.style.left = `${r.left * 100}%`;
        el.style.top = `${r.top * 100}%`;
        el.style.width = `${r.width * 100}%`;
        el.style.height = `${r.height * 100}%`;
        slot.wrapper.appendChild(el);
      }
    });
    const m = matches[current];
    const container = containerRef.current;
    if (!scrollToCurrent || !m || !container) return;
    const slot = slotsRef.current[m.page - 1];
    if (!slot || !m.rects[0]) return;
    const box = slot.wrapper.getBoundingClientRect();
    const offset = slotOffset(slot);
    container.scrollTo({
      top: Math.max(0, offset.top + m.rects[0].top * box.height - container.clientHeight / 3),
      left: Math.max(0, offset.left + m.rects[0].left * box.width - container.clientWidth / 3),
      behavior: 'smooth'
    });
  };

  const runFind = async (query: string, step: 0 | 1 | -1) => {
    // Right after a compile the new PDF may still be loading.
    for (let i = 0; i < 40 && (!docRef.current || !slotsRef.current.length); i += 1) await new Promise((r) => setTimeout(r, 100));
    const doc = docRef.current;
    const q = query.trim().toLowerCase();
    if (!doc || !q) {
      findRef.current = { query: '', matches: [], current: -1 };
      clearFindMarks();
      return { index: 0, total: 0 };
    }
    const state = findRef.current;
    if (state.query !== q || textCacheRef.current.doc !== doc || step === 0) {
      const matches: { page: number; rects: FindRect[] }[] = [];
      for (let n = 1; n <= doc.numPages; n += 1) {
        const pt = await pageText(doc, n);
        let from = 0;
        for (;;) {
          const at = pt.text.indexOf(q, from);
          if (at < 0) break;
          matches.push({ page: n, rects: await rectsFor(doc, n, pt, at, at + q.length) });
          from = at + Math.max(1, q.length);
        }
      }
      if (docRef.current !== doc) return { index: 0, total: 0 };
      // Start at the first match on or after the page in view.
      const inView = lastPageRef.current.page || 1;
      const first = matches.findIndex((m) => m.page >= inView);
      findRef.current = { query: q, matches, current: matches.length ? (first >= 0 ? first : 0) : -1 };
    } else if (state.matches.length) {
      state.current = (state.current + step + state.matches.length) % state.matches.length;
    }
    drawFind(true);
    const { matches, current } = findRef.current;
    return { index: current + 1, total: matches.length };
  };

  useImperativeHandle(ref, () => ({
    find: (query, step) => runFind(query, step),
    clearFind: () => {
      findRef.current = { query: '', matches: [], current: -1 };
      clearFindMarks();
    },
    selectedText: () => {
      const selection = window.getSelection();
      const container = containerRef.current;
      if (!selection || selection.isCollapsed || !container || !container.contains(selection.anchorNode)) return '';
      return selection.toString().replace(/\s+/g, ' ').trim().slice(0, 200);
    },
    zoomIn: () => zoomTo(zoomRef.current.scale * ZOOM_STEP, 'custom'),
    zoomOut: () => zoomTo(zoomRef.current.scale / ZOOM_STEP, 'custom'),
    fitWidth: () => zoomTo(zoomRef.current.scale, 'fitWidth'),
    fitPage: () => zoomTo(zoomRef.current.scale, 'fitPage'),
    actualSize: () => zoomTo(1, 'custom'),
    scrollToPage: (page: number) => {
      const slot = slotsRef.current[page - 1];
      const container = containerRef.current;
      if (!slot || !container) return;
      container.scrollTo({ top: slotOffset(slot).top - PADDING, behavior: 'smooth' });
    },
    sourcePoint: () => {
      const container = containerRef.current;
      const slots = slotsRef.current;
      if (!container || !slots.length) return null;
      const pointAt = (clientX: number, clientY: number) => {
        const hit = locate(clientX, clientY);
        if (!hit) return null;
        return { page: hit.slot.number, x: hit.fx * hit.slot.width, y: hit.fy * hit.slot.height };
      };
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed && selection.rangeCount && container.contains(selection.anchorNode)) {
        const rect = selection.getRangeAt(0).getBoundingClientRect();
        if (rect.width || rect.height) return pointAt(rect.left + Math.min(rect.width / 2, 20), rect.top + rect.height / 2);
      }
      if (lastClickRef.current && slots[lastClickRef.current.page - 1]) return lastClickRef.current;
      const c = container.getBoundingClientRect();
      return pointAt(c.left + c.width / 2, c.top + c.height / 2);
    },
    revealBox: (box) => {
      const slot = slotsRef.current[box.page - 1];
      const container = containerRef.current;
      if (!slot || !container) return;
      // SyncTeX reports h/v as the box's left edge and baseline; the box extends `height` above it.
      const top = Math.max(0, box.v - Math.max(box.height, 8));
      const height = Math.max(box.height, 10);
      const highlight = document.createElement('div');
      highlight.className = 'pdf-sync-highlight';
      highlight.style.left = `${(Math.max(0, box.h) / slot.width) * 100}%`;
      highlight.style.top = `${(top / slot.height) * 100}%`;
      highlight.style.width = `${(Math.max(box.width, 40) / slot.width) * 100}%`;
      highlight.style.height = `${((height + 4) / slot.height) * 100}%`;
      slot.wrapper.appendChild(highlight);
      window.setTimeout(() => highlight.classList.add('fade'), 1400);
      window.setTimeout(() => highlight.remove(), 2400);
      const scale = slot.wrapper.getBoundingClientRect().height / slot.height;
      const offset = slotOffset(slot);
      container.scrollTo({
        top: Math.max(0, offset.top + top * scale - container.clientHeight / 3),
        left: Math.max(0, offset.left + box.h * scale - container.clientWidth / 3),
        behavior: 'smooth'
      });
    }
  }), [containerRef, zoomTo]);

  return <div className={`pdf-preview ${annotateMode ? 'annotate' : ''}`} ref={containerRef} />;
});

export default PdfViewer;
