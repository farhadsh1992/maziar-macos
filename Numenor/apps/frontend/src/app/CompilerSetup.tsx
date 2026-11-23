import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { getCompilerSetup, installCompiler, type CompilerDistribution, type CompilerSetupStatus } from '../api/client';

const engineNames = {
  pdflatex: 'pdfLaTeX',
  xelatex: 'XeLaTeX',
  lualatex: 'LuaLaTeX',
  latexmk: 'Latexmk',
  tectonic: 'Tectonic'
} as const;

export default function CompilerSetup() {
  const { t } = useTranslation();
  const [status, setStatus] = useState<CompilerSetupStatus>();
  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(window.location.hostname);

  async function refresh() {
    try {
      setStatus(await getCompilerSetup());
      setError('');
    } catch (failure) {
      setError(String(failure instanceof Error ? failure.message : failure));
    }
  }

  useEffect(() => {
    if (local) void refresh();
  }, [local]);

  useEffect(() => {
    if (!status?.job.running) return;
    const timer = window.setInterval(() => void refresh(), 2000);
    return () => window.clearInterval(timer);
  }, [status?.job.running]);

  if (!local) return null;

  async function install(distribution: CompilerDistribution) {
    setSubmitting(true);
    setError('');
    try {
      setStatus(await installCompiler(distribution));
    } catch (failure) {
      setError(String(failure instanceof Error ? failure.message : failure));
    } finally {
      setSubmitting(false);
    }
  }

  const canInstall = status?.platform === 'darwin' && status.homebrew && !status.managedByMaziar;
  const macTeXReady = status && status.engines.pdflatex && status.engines.xelatex
    && status.engines.lualatex && status.engines.latexmk;
  const busy = submitting || status?.job.running;
  const message = error || status?.job.error;

  return (
    <section className="field" aria-label={t('LaTeX compilers')}>
      <label>{t('LaTeX compilers')}</label>
      {status && (
        <ul>
          {(Object.keys(engineNames) as (keyof typeof engineNames)[]).map((engine) => (
            <li key={engine}>{engineNames[engine]} · {status.engines[engine] ? t('Available') : t('Missing')}</li>
          ))}
        </ul>
      )}
      {status?.managedByMaziar && <div className="muted">{t('Compiler setup is managed by Maziar.')}</div>}
      {status?.platform === 'darwin' && !status.homebrew && !status.managedByMaziar && (
        <div className="muted">
          {t('In-app installation requires Homebrew. You can also download MacTeX directly.')} {' '}
          <a href="https://www.tug.org/mactex/" target="_blank" rel="noreferrer">MacTeX</a>
        </div>
      )}
      {status && status.platform !== 'darwin' && (
        <div className="muted">{t('Install TeX Live or Tectonic using your system package manager, then refresh.')}</div>
      )}
      {canInstall && (
        <>
          <div className="muted">{t('MacTeX installs pdfLaTeX, XeLaTeX, LuaLaTeX and Latexmk. It is a large download and macOS will ask for administrator authorization.')}</div>
          <button type="button" className="btn" disabled={busy || macTeXReady} onClick={() => void install('mactex')}>
            {t('Install MacTeX')}
          </button>
          <button type="button" className="btn" disabled={busy || status.engines.tectonic} onClick={() => void install('tectonic')}>
            {t('Install Tectonic')}
          </button>
        </>
      )}
      <button type="button" className="btn ghost" disabled={submitting} onClick={() => void refresh()}>{t('Refresh compiler status')}</button>
      {busy && (
        <div role="status">{status?.job.distribution === 'mactex' ? t('Installing MacTeX…') : t('Installing compiler…')}</div>
      )}
      {message && <div role="alert">{message}</div>}
    </section>
  );
}
