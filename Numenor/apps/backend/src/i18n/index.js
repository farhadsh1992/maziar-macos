const DICT = {
  'zh-CN': {
    llm_error: 'LLM 未配置或调用失败：{{error}}。请检查设置中的 AI 和模型。',
    missing_project_id_tools: '缺少 projectId，无法使用工具模式。',
    zip_extract_failed: 'Zip 解压失败: {{error}}',
    arxiv_download_failed: 'arXiv 下载失败: {{error}}'
  },
  'pt-PT': {
    llm_error: 'Não foi possível usar o modelo de IA: {{error}}. Consulte Definições → IA e modelos.',
    missing_project_id_tools: 'Selecione um projeto para usar as ferramentas do agente.',
    zip_extract_failed: 'Não foi possível extrair o ZIP: {{error}}',
    arxiv_download_failed: 'Não foi possível transferir o artigo do arXiv: {{error}}'
  },
  'en-US': {
    llm_error: 'LLM is not configured or the call failed: {{error}}. Check Settings → AI & Models.',
    missing_project_id_tools: 'Missing projectId; tools mode is unavailable.',
    zip_extract_failed: 'Zip extraction failed: {{error}}',
    arxiv_download_failed: 'arXiv download failed: {{error}}'
  }
};

export function getLang(req) {
  const header = req?.headers?.['x-lang'] || req?.headers?.['accept-language'] || '';
  const raw = Array.isArray(header) ? header[0] : header;
  if (typeof raw === 'string' && /^pt(?:[-,;]|$)/i.test(raw)) return 'pt-PT';
  if (typeof raw === 'string' && raw.toLowerCase().includes('en')) {
    return 'en-US';
  }
  return 'zh-CN';
}

export function t(lang, key, params = {}) {
  const bucket = DICT[lang] || DICT['zh-CN'];
  const template = bucket[key] || DICT['zh-CN'][key] || key;
  return template.replace(/\{\{(\w+)\}\}/g, (_, token) => {
    const value = params[token];
    return value === undefined || value === null ? '' : String(value);
  });
}
