// The PDF preview in a window of its own ("Open PDF in a separate window" in the editor), so the editor gets
// the whole width. The editor stays in charge: it sends every new PDF here, and forward sync (source → PDF)
// lands here; double-clicking or "← Source" here jumps the editor to the spot. Talks to the editor that
// opened it through window.opener / postMessage.
import { useCallback, useEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import PdfViewer, { type PdfViewerHandle, type PdfZoomMode } from './PdfViewer';
import { IconChevronLeft, IconChevronRight, IconMinus, IconPlus, IconPopIn, IconSync } from './icons';

export type PdfWindowMessage =
  | { type: 'nm-pdf:hello' }
  | { type: 'nm-pdf:pdf'; bytes: ArrayBuffer | null; title?: string }
  | { type: 'nm-pdf:reveal'; box: { page: number; h: number; v: number; width: number; height: number } }
  | { type: 'nm-pdf:status'; compiling: boolean; title?: string }
  | { type: 'nm-pdf:reverse'; page: number; x: number; y: number }
  | { type: 'nm-pdf:reverse-request' }
  | { type: 'nm-pdf:compile' }
  | { type: 'nm-pdf:dock' }
  | { type: 'nm-pdf:closed' }
  | { type: 'nm-pdf:editor-closed' };

export default function PdfWindowPage() {
  const { projectId = '' } = useParams();
  const { t } = useTranslation();
  const [pdfUrl, setPdfUrl] = useState('');
  const [title, setTitle] = useState('');
  const [compiling, setCompiling] = useState(false);
  const [page, setPage] = useState({ page: 0, total: 0 });
  const [zoom, setZoom] = useState<{ scale: number; mode: PdfZoomMode }>({ scale: 1, mode: 'fitWidth' });
  const [orphan, setOrphan] = useState(false);
  const viewerRef = useRef<PdfViewerHandle | null>(null);
  const urlRef = useRef('');
  const pendingReveal = useRef<PdfWindowMessage | null>(null);

  const send = useCallback((msg: PdfWindowMessage) => {
    try {
      if (window.opener && !window.opener.closed) window.opener.postMessage(msg, window.location.origin);
      else setOrphan(true);
    } catch {
      setOrphan(true);
    }
  }, []);

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.origin !== window.location.origin || event.source !== window.opener) return;
      const msg = event.data as PdfWindowMessage;
      if (!msg || typeof msg !== 'object' || !String(msg.type).startsWith('nm-pdf:')) return;
      if (msg.type === 'nm-pdf:pdf') {
        if (msg.title) setTitle(msg.title);
        if (!msg.bytes) return;
        const next = URL.createObjectURL(new Blob([msg.bytes], { type: 'application/pdf' }));
        if (urlRef.current) URL.revokeObjectURL(urlRef.current);
        urlRef.current = next;
        setPdfUrl(next);
      } else if (msg.type === 'nm-pdf:status') {
        setCompiling(msg.compiling);
        if (msg.title) setTitle(msg.title);
      } else if (msg.type === 'nm-pdf:reveal') {
        if (viewerRef.current) viewerRef.current.revealBox(msg.box);
        else pendingReveal.current = msg;
        window.focus();
      } else if (msg.type === 'nm-pdf:reverse-request') {
        const point = viewerRef.current?.sourcePoint();
        if (point) send({ type: 'nm-pdf:reverse', ...point });
      } else if (msg.type === 'nm-pdf:editor-closed') {
        window.close();
      }
    };
    window.addEventListener('message', onMessage);
    send({ type: 'nm-pdf:hello' });
    const onUnload = () => send({ type: 'nm-pdf:closed' });
    window.addEventListener('beforeunload', onUnload);
    // If the editor window goes away, say so (and offer to close).
    const watch = window.setInterval(() => {
      if (!window.opener || window.opener.closed) setOrphan(true);
    }, 2000);
    return () => {
      window.removeEventListener('message', onMessage);
      window.removeEventListener('beforeunload', onUnload);
      window.clearInterval(watch);
    };
  }, [send]);

  useEffect(() => {
    document.title = title ? `${t('PDF Preview')} — ${title}` : t('PDF Preview');
  }, [title, t]);

  useEffect(() => {
    if (pdfUrl && pendingReveal.current?.type === 'nm-pdf:reveal') {
      const { box } = pendingReveal.current;
      pendingReveal.current = null;
      window.setTimeout(() => viewerRef.current?.revealBox(box), 300);
    }
  }, [pdfUrl]);

  const scaleLabel = `${Math.round(zoom.scale * 100)}%`;

  return (
    <div className="nm-pdf-window">
      <div className="pdf-toolbar nm-pdf-toolbar">
        <div className="nm-pager">
          <button className="nm-icon-btn borderless" disabled={!pdfUrl || page.page <= 1} onClick={() => viewerRef.current?.scrollToPage(page.page - 1)} aria-label={t('Previous page')}><IconChevronLeft size={16} /></button>
          <span className="nm-page-pill">{page.total ? `${page.page} / ${page.total}` : '– / –'}</span>
          <button className="nm-icon-btn borderless" disabled={!pdfUrl || page.page >= page.total} onClick={() => viewerRef.current?.scrollToPage(page.page + 1)} aria-label={t('Next page')}><IconChevronRight size={16} /></button>
        </div>
        <div className="nm-seg">
          <button className="nm-icon-btn borderless" onClick={() => viewerRef.current?.zoomOut()} disabled={!pdfUrl} aria-label={t('Zoom out')}><IconMinus size={15} /></button>
          <button className="nm-icon-btn borderless" onClick={() => viewerRef.current?.fitWidth()} disabled={!pdfUrl} title={t('适合宽度')}>{zoom.mode === 'fitWidth' ? t('适合宽度') : scaleLabel}</button>
          <button className="nm-icon-btn borderless" onClick={() => viewerRef.current?.zoomIn()} disabled={!pdfUrl} aria-label={t('Zoom in')}><IconPlus size={15} /></button>
        </div>
        <button className="nm-icon-btn" disabled={!pdfUrl || orphan} onClick={() => {
          const point = viewerRef.current?.sourcePoint();
          if (point) send({ type: 'nm-pdf:reverse', ...point });
        }} title={t('Show the text selected in the PDF (or where you last clicked) in the LaTeX — or double-click the PDF')}>
          <IconSync size={15} /> {t('Source')}
        </button>
        <div className="nm-spacer" />
        {compiling && <span className="muted nm-pdf-window-status">{t('编译中...')}</span>}
        <button className="btn nm-primary" disabled={orphan || compiling} onClick={() => send({ type: 'nm-pdf:compile' })}>{t('编译 PDF')}</button>
        <button className="nm-icon-btn" disabled={orphan} onClick={() => { send({ type: 'nm-pdf:dock' }); window.close(); }} title={t('Put the PDF back into the editor window')}>
          <IconPopIn size={15} /> {t('Back to editor')}
        </button>
      </div>
      {orphan && (
        <div className="share-note nm-pdf-window-orphan">
          {t('The editor this preview belongs to was closed.')} <button className="btn ghost" onClick={() => window.close()}>{t('Close')}</button>
        </div>
      )}
      <div className="nm-pdf-window-body">
        {pdfUrl ? (
          <PdfViewer
            ref={viewerRef}
            pdfUrl={pdfUrl}
            spread={false}
            annotations={[]}
            annotateMode={false}
            onZoomChange={setZoom}
            onPageChange={(p, total) => setPage({ page: p, total })}
            rememberKey={`maziar.numenor.${projectId}.pdfPos`}
            onReverseSync={(p, x, y) => send({ type: 'nm-pdf:reverse', page: p, x, y })}
          />
        ) : (
          <div className="muted pdf-empty-message">{compiling ? t('编译中...') : t('尚未生成 PDF')}</div>
        )}
      </div>
    </div>
  );
}
