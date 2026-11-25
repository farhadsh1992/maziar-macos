import { useEffect, useState } from 'react';

export async function research(path, options = {}) {
  const { body, ...request } = options;
  const response = await fetch('/api/research2' + path, {
    ...request,
    ...(body instanceof FormData ? { body } : body === undefined ? {} : {
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    })
  });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Request failed.');
  return data;
}

export function useResearchSettings(module, initial = {}) {
  const [settings, setSettings] = useState(initial);
  const [error, setError] = useState('');
  useEffect(() => {
    let active = true;
    research('/settings/' + module).then((data) => { if (active) setSettings(data); })
      .catch((error) => { if (active) setError(error.message); });
    return () => { active = false; };
  }, [module]);
  function save(patch) {
    const { addCollection, jupyterToken, ...publicPatch } = patch;
    setSettings((previous) => ({ ...previous, ...publicPatch }));
    return research('/settings/' + module, { method: 'PATCH', body: patch }).then((data) => {
      setSettings(data);
      return data;
    }).catch((error) => { setError(error.message); throw error; });
  }
  return { settings, save, error };
}

export function ThemeSelect({ theme, onChange }) {
  return <label className="r2-inline">Appearance <select value={theme ?? 'system'} onChange={(event) => onChange(event.target.value)}>
    <option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option>
  </select></label>;
}

export function Splitter({ label, value, onFinish, onChange, reverse = false, min = 150, max = 550 }) {
  const clamp = (width) => Math.round(Math.max(min, Math.min(max, width)));
  return <div className="r2-splitter" role="separator" aria-label={label} aria-orientation="vertical"
    aria-valuenow={value} aria-valuemin={min} aria-valuemax={max} tabIndex={0}
    onKeyDown={(event) => {
      if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      event.preventDefault();
      const next = clamp(value + (event.key === 'ArrowRight' ? 20 : -20) * (reverse ? -1 : 1));
      onChange(next);
      onFinish(next);
    }}
    onPointerDown={(event) => {
      const handle = event.currentTarget;
      const start = event.clientX;
      let latest = value;
      handle.setPointerCapture(event.pointerId);
      const move = (pointer) => {
        latest = clamp(value + (pointer.clientX - start) * (reverse ? -1 : 1));
        onChange(latest);
      };
      const stop = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('lostpointercapture', stop);
        onFinish(latest);
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('lostpointercapture', stop);
    }} />;
}

export function Details({ paper }) {
  return <dl className="r2-details">
    {Object.entries({ Title: paper.title, Authors: paper.authors, Year: paper.year, Venue: paper.venue, DOI: paper.doi,
      Tags: paper.tags?.join(', '), Abstract: paper.abstract }).filter(([, value]) => value).map(([label, value]) =>
        <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}
    {!paper.abstract && <div><dt>Abstract</dt><dd>No abstract in the library catalog.</dd></div>}
  </dl>;
}

export function useReport() {
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const fail = (error) => { setStatus(''); setError(error.message ?? String(error)); };
  const report = (message) => { setError(''); setStatus(message); };
  return { status, error, report, fail };
}

export function Feedback({ status, error }) {
  return error ? <p className="r2-error" role="alert">{error}</p> : status ? <p className="r2-status" role="status">{status}</p> : null;
}
