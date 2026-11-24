import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { LatexHeading } from '../latex/structure';

export type OutlineSnapshot = {
  file: string; items: LatexHeading[]; current?: number; latex: boolean; theme?: string;
};

export function OutlineList({ snapshot, jump }: { snapshot: OutlineSnapshot; jump: (item: LatexHeading) => void }) {
  const { t } = useTranslation();
  if (!snapshot.latex || snapshot.items.length === 0) {
    return <div className="muted outline-empty">
      {t(snapshot.latex ? '未发现 Section 标题。' : 'Open a LaTeX file to show its Outline.')}
    </div>;
  }
  return <div className="outline-list">
    {snapshot.items.map((item) => (
      <button key={item.pos} type="button" aria-current={snapshot.current === item.pos ? 'location' : undefined}
        className={`outline-item level-${item.level}`} onClick={() => jump(item)}>
        <span className="outline-title">{item.title}</span>
        <span className="outline-line">L{item.line}</span>
      </button>
    ))}
  </div>;
}

export default function OutlineWindow() {
  const { t } = useTranslation();
  const [snapshot, setSnapshot] = useState<OutlineSnapshot>();
  useEffect(() => {
    document.title = t('Outline');
    const receive = (event: MessageEvent) => {
      if (event.origin !== window.location.origin || event.source !== window.opener || event.data?.type !== 'nm-outline:update') return;
      setSnapshot(event.data.snapshot);
      const { theme } = event.data.snapshot;
      if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
      else delete document.documentElement.dataset.theme;
    };
    window.addEventListener('message', receive);
    window.opener?.postMessage({ type: 'nm-outline:ready' }, window.location.origin);
    return () => window.removeEventListener('message', receive);
  }, [t]);
  return <main className="nm-outline-window">
    <h1>{t('Outline')}</h1>
    {snapshot && <><p className="muted">{snapshot.file}</p><OutlineList snapshot={snapshot} jump={(item) => {
      window.opener?.postMessage({ type: 'nm-outline:jump', file: snapshot.file, position: item.pos }, window.location.origin);
    }} /></>}
  </main>;
}
