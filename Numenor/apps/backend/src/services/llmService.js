export function normalizeChatEndpoint(endpoint) {
  if (!endpoint) return 'https://api.openai.com/v1/chat/completions';
  let url = endpoint.trim();
  if (!url) return 'https://api.openai.com/v1/chat/completions';
  url = url.replace(/\/+$/, '');
  if (/\/chat\/completions$/i.test(url)) return url;
  if (/\/v1$/i.test(url)) return `${url}/chat/completions`;
  if (/\/v1\//i.test(url)) return url;
  return `${url}/v1/chat/completions`;
}

export function normalizeBaseURL(endpoint) {
  if (!endpoint) return undefined;
  const trimmed = endpoint.replace(/\/+$/, '');
  return trimmed.replace(/\/chat\/completions$/i, '');
}

export function resolveLLMConfig(llmConfig) {
  // NUMENOR_LLM_LOCKED=1: use only the server's NUMENOR_LLM_* settings and ignore any endpoint, key or
  // model sent from the browser (Maziar sets this so its own AI settings are the single source).
  if (process.env.NUMENOR_LLM_LOCKED === '1') llmConfig = null;
  return {
    endpoint: (llmConfig?.endpoint || process.env.NUMENOR_LLM_ENDPOINT || 'https://api.openai.com/v1/chat/completions').trim(),
    apiKey: (llmConfig?.apiKey || process.env.NUMENOR_LLM_API_KEY || '').trim(),
    model: (llmConfig?.model || process.env.NUMENOR_LLM_MODEL || 'gpt-4o-mini').trim()
  };
}

export async function callOpenAICompatible({ messages, model, endpoint, apiKey }) {
  if (process.env.NUMENOR_LLM_LOCKED === '1') { model = undefined; endpoint = undefined; apiKey = undefined; }
  const finalEndpoint = normalizeChatEndpoint(endpoint || process.env.NUMENOR_LLM_ENDPOINT);
  const finalApiKey = (apiKey || process.env.NUMENOR_LLM_API_KEY || '').trim();
  const finalModel = (model || process.env.NUMENOR_LLM_MODEL || 'gpt-4o-mini').trim();

  if (!finalApiKey) {
    return { ok: false, error: 'NUMENOR_LLM_API_KEY not set' };
  }

  const res = await fetch(finalEndpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${finalApiKey}`
    },
    body: JSON.stringify({
      model: finalModel,
      messages,
      temperature: 0.2
    })
  });

  const text = await res.text();
  if (!res.ok) {
    return { ok: false, error: text || `Request failed with ${res.status}` };
  }
  const contentType = res.headers.get('content-type') || '';
  if (!contentType.includes('application/json')) {
    return { ok: false, error: text || 'Non-JSON response from provider.' };
  }
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    return { ok: false, error: 'Response JSON parse failed.' };
  }
  const content = data?.choices?.[0]?.message?.content || '';
  return { ok: true, content };
}
