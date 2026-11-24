import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { aiAction, getAIStatus, type AIModel, type AIProvider, type AIStatus, type RemoteAIProvider } from '../api/client';

const providerNames: Record<AIProvider, string> = {
  off: 'Off', local: 'Local models', apple: 'Apple Foundation Models', ollama: 'Ollama endpoint',
  openai: 'OpenAI-compatible endpoint', gemini: 'Gemini API'
};

export function useAIStatus(enabled: boolean) {
  const [status, setStatus] = useState<AIStatus>();
  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    let timer: number;
    const refresh = async () => {
      try { setStatus(await getAIStatus(controller.signal)); } catch {}
      if (!controller.signal.aborted) timer = window.setTimeout(refresh, 1400);
    };
    void refresh();
    return () => { controller.abort(); window.clearTimeout(timer); };
  }, [enabled]);
  return { status, setStatus };
}

function isLoopback(endpoint: string) {
  try { return ['localhost', '127.0.0.1', '[::1]'].includes(new URL(endpoint).hostname); }
  catch { return false; }
}

export function AIIndicator({ status, open, label: buttonLabel }: { status?: AIStatus; open: () => void; label?: string }) {
  const { t } = useTranslation();
  const state = status?.localStatus;
  let label = status ? t(status.active === 'off' ? 'AI Off' : providerNames[status.active]) : '';
  if (status?.active === 'local') {
    const model = status.catalog.find((item) => item.id === status.local);
    label = !model?.installed || state?.runtime === 'unavailable' ? t('Local AI unavailable')
      : state?.runtime === 'loading' ? t('AI loading') : status.generating ? t('AI generating')
        : state?.runtime === 'ready' ? t('AI ready') : model.name;
  } else if (status?.generating) {
    label = t('AI generating');
  }
  const active = status?.active;
  const remote = active === 'openai' || active === 'gemini' || active === 'ollama';
  const offDevice = remote && !isLoopback(status?.remote[active]?.endpoint ?? '');
  const action = buttonLabel ?? t('Open AI chat');
  const title = [action, label, offDevice ? t('Off-device') : '', status?.lastError].filter(Boolean).join(' · ');
  return (
    <div className="nm-ai-indicator">
      <button type="button" className="nm-icon-btn nm-ai-star" onClick={open} title={title} aria-label={action}>
        <span aria-hidden="true">✦</span>
      </button>
      {status?.generating && (
        <button type="button" className="nm-icon-btn" onClick={() => { void aiAction('cancel-generation').catch(() => {}); }}>
          {t('Cancel AI')}
        </button>
      )}
    </div>
  );
}

const size = (bytes: number) => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(2)} GB` : `${Math.round(bytes / 1e6)} MB`;

function errorMessage(error: unknown) {
  if (!(error instanceof Error)) return String(error);
  try { return JSON.parse(error.message).error ?? error.message; }
  catch { return error.message; }
}

type Run = (action: string, fields?: object) => Promise<boolean>;

function RemoteForm({ provider, status, run, busy }: {
  provider: RemoteAIProvider; status: AIStatus; run: Run; busy: boolean;
}) {
  const { t } = useTranslation();
  const saved = status.remote[provider];
  const [endpoint, setEndpoint] = useState(saved?.endpoint ?? (provider === 'ollama' ? 'http://127.0.0.1:11434' : ''));
  const [model, setModel] = useState(saved?.model ?? '');
  const [key, setKey] = useState('');
  const [models, setModels] = useState<string[]>([]);
  const [test, setTest] = useState('');
  const [testing, setTesting] = useState(false);
  const fields = { provider, endpoint, model, ...(key.trim() ? { key } : {}) };
  const locked = busy || testing;
  return (
    <div className="nm-ai-form">
      {provider === 'gemini' ? (
        <p>{t('Gemini sends the requested content to Google for cloud inference.')}{' '}
          <a href="https://ai.google.dev/gemini-api/docs/pricing" target="_blank" rel="noreferrer">{t('Pricing')}</a>{' · '}
          <a href="https://ai.google.dev/gemini-api/terms" target="_blank" rel="noreferrer">{t('Data-use terms')}</a></p>
      ) : (
        <>
          <label className="field">{t('Base URL')}<input className="input" value={endpoint} onChange={(e) => {
            setEndpoint(e.target.value);
            setModels([]);
            setTest('');
            if (provider === 'ollama') setModel('');
          }}
            placeholder={provider === 'openai' ? 'http://evo-x2:8080/v1' : undefined} /></label>
          <p>{isLoopback(endpoint) ? t('Requests go to an endpoint on this Mac.') : t('Requests send the selected content to the configured server.')}</p>
        </>
      )}
      <label className="field">{t('API key')}<input className="input" type="password" value={key}
        autoComplete="off" onChange={(e) => setKey(e.target.value)} placeholder={t('Leave blank to keep the saved key')} /></label>
      {provider === 'openai' ? (
        <label className="field">{t('Model ID')}<input className="input" value={model} onChange={(e) => setModel(e.target.value)} /></label>
      ) : (
        <label className="field">{t('Model')}<select className="input" aria-label={t('Model')} value={model} onChange={(e) => setModel(e.target.value)}>
          <option value="">{t('Test connection to list models')}</option>
          {Array.from(new Set([model, ...models])).filter(Boolean).map((id) => <option key={id}>{id}</option>)}
        </select></label>
      )}
      <div className="nm-ai-actions">
        <button type="button" className="btn ghost" disabled={locked} onClick={async () => {
          setTesting(true);
          setTest('');
          try {
            const result = await aiAction<{ models: string[] }>('test', fields);
            setModels(result.models);
            if (!model && result.models[0]) setModel(result.models[0]);
            setTest(t('Connected. {{count}} models available.', { count: result.models.length }));
          } catch (error) { setTest(errorMessage(error)); }
          finally { setTesting(false); }
        }}>{testing ? t('Testing…') : t('Test connection')}</button>
        <button type="button" className="btn ghost" disabled={locked || !model} onClick={async () => {
          if (await run('configure', fields)) setKey('');
        }}>{t('Save settings')}</button>
        <button type="button" className="btn" disabled={locked || !model} onClick={async () => {
          if (await run('configure', fields)) {
            setKey('');
            await run('select', { provider });
          }
        }}>{t('Use provider')}</button>
        {saved && <button type="button" className="btn ghost" disabled={locked} onClick={async () => {
          if (await run('configure', { provider, ...saved, key: '' })) setKey('');
        }}>{t('Clear saved key')}</button>}
      </div>
      {test && <p role="status">{test}</p>}
    </div>
  );
}

export default function AIModels({ status, onUpdate }: { status?: AIStatus; onUpdate: (status: AIStatus) => void }) {
  const { t } = useTranslation();
  const [provider, setProvider] = useState<AIProvider>(status?.active ?? 'off');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [confirmation, setConfirmation] = useState<{ remove: AIModel; next?: AIModel }>();

  const run: Run = async (action, fields) => {
    setBusy(true);
    setMessage('');
    try {
      onUpdate(await aiAction(action, fields));
      return true;
    } catch (error) {
      setMessage(errorMessage(error));
      return false;
    } finally { setBusy(false); }
  };

  if (!status) return <p role="status">{t('Loading AI settings…')}</p>;
  const { localStatus } = status;
  const progress = localStatus.progress;
  const installing = Boolean(progress && ['checking', 'runtime', 'model', 'verifying'].includes(progress.phase));
  const activeModel = status.active === 'local' ? status.catalog.find((item) => item.id === status.local && item.installed) : undefined;
  return (
    <fieldset className="nm-ai-settings">
      <legend>{t('AI & Models')}</legend>
      <p>{t('Active provider')}: <strong>{t(providerNames[status.active])}{activeModel && ` · ${activeModel.name}`}</strong></p>
      <label className="field">{t('Provider')}<select className="input" aria-label={t('Provider')} value={provider} onChange={(e) => {
        setProvider(e.target.value as AIProvider);
        setMessage('');
        setConfirmation(undefined);
      }}>
        {(Object.keys(providerNames) as AIProvider[]).map((id) => <option value={id} key={id}>{t(providerNames[id])}</option>)}
      </select></label>
      {provider === 'off' && (
        <button type="button" className="btn" disabled={busy || status.active === 'off'} onClick={() => run('select', { provider })}>
          {t('Turn off AI')}
        </button>
      )}
      {provider === 'local' && (
        <>
          <p>{t('Local inference stays on this Mac. Download size is disk storage. Runtime memory also includes the 2,048-token context and inference buffers.')}</p>
          {!localStatus.compatible && <p>{t('Managed models require Apple Silicon and macOS 14 or later.')}</p>}
          {localStatus.error && (
            <div role="alert" className="nm-ai-actions">
              <span>{localStatus.error}</span>
              {activeModel && <button type="button" className="btn ghost" disabled={busy || installing}
                onClick={() => run('install', { id: activeModel.id })}>{t('Check local installation')}</button>}
            </div>
          )}
          {status.active === 'local' && !activeModel && <p role="alert">{t('The active model is unavailable. Install it again or choose another model below.')}</p>}
          {status.catalog.map((model) => (
            <div className="nm-ai-model" key={model.id}>
              <div><strong>{model.name}</strong> · {model.quantization}</div>
              <div>{t('{{size}} download', { size: size(model.bytes) })} · {model.installed ? t('Installed') : t('Available')}</div>
              <div className="muted">{t(model.role)}{' · '}
                <a href={model.license} target="_blank" rel="noreferrer">Apache 2.0</a>
              </div>
              <div className="nm-ai-actions">
                {model.installed ? (
                  <>
                    <button type="button" className="btn" disabled={busy || activeModel?.id === model.id}
                      onClick={() => run('select', { provider: 'local', id: model.id })}>{t('Use model')}</button>
                    <button type="button" className="btn ghost" disabled={busy || installing}
                      onClick={() => setConfirmation({ remove: model })}>{t('Remove')}</button>
                  </>
                ) : (
                  <>
                    <button type="button" className="btn" disabled={busy || installing || !localStatus.compatible}
                      onClick={() => run('install', { id: model.id })}>
                      {progress?.id === model.id && ['failed', 'cancelled'].includes(progress.phase) ? t('Retry download') : t('Download & Install')}
                    </button>
                    {activeModel && <button type="button" className="btn ghost" disabled={busy || installing}
                      onClick={() => setConfirmation({ remove: activeModel, next: model })}>{t('Remove current model and install another')}</button>}
                  </>
                )}
              </div>
              {progress?.id === model.id && (
                <div role="status">
                  {progress.phase === 'runtime' ? t('Downloading runtime') : progress.phase === 'model' ? t('Downloading model')
                    : progress.phase === 'verifying' ? t('Verifying checksum') : t(progress.phase)}
                  {installing && (
                    <div className="nm-ai-actions">
                      <progress aria-label={t('Download progress')} max={progress.total} value={progress.bytes} />
                      <button type="button" className="btn ghost" onClick={() => run('cancel-install')}>{t('Cancel download')}</button>
                    </div>
                  )}
                  {progress.error && <p role="alert">{progress.error}</p>}
                  {progress.phase === 'failed' && <button type="button" className="btn ghost"
                    disabled={busy} onClick={() => run('discard-install')}>{t('Clear download')}</button>}
                </div>
              )}
            </div>
          ))}
        </>
      )}
      {provider === 'apple' && (
        <>
          <p>{status.apple === 'available' ? t('Available on this Mac. Inference stays on-device.') : t(status.apple)}</p>
          <p>{t('Manage Apple Intelligence and its system model in macOS System Settings.')}</p>
          <div className="nm-ai-actions">
            <button type="button" className="btn ghost" disabled={busy} onClick={() => run('apple-status')}>{t('Check availability')}</button>
            <button type="button" className="btn" disabled={busy || status.apple !== 'available'}
              onClick={() => run('select', { provider })}>{t('Use Apple Foundation Models')}</button>
          </div>
        </>
      )}
      {provider !== 'off' && provider !== 'local' && provider !== 'apple' &&
        <RemoteForm key={provider} provider={provider} status={status} run={run} busy={busy} />}
      {confirmation && (
        <div className="nm-ai-confirm" role="alert">
          <p>{t('Remove {{name}} from this Mac and free {{size}}?', { name: confirmation.remove.name, size: size(confirmation.remove.bytes) })}
            {confirmation.next ? ' ' + t('Numenor will then download {{name}}.', { name: confirmation.next.name }) : ''}</p>
          <div className="nm-ai-actions">
            <button type="button" className="btn ghost" onClick={() => setConfirmation(undefined)}>{t('Keep model')}</button>
            <button type="button" className="btn" disabled={busy} onClick={async () => {
              if (await run('remove', { id: confirmation.remove.id })) {
                setConfirmation(undefined);
                if (confirmation.next) await run('install', { id: confirmation.next.id });
              }
            }}>{confirmation.next ? t('Remove and download') : t('Confirm removal')}</button>
          </div>
        </div>
      )}
      {(message || status.lastError) && <p role="alert">{message || status.lastError}</p>}
    </fieldset>
  );
}
