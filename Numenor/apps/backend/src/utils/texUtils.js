import path from 'path';

const TEXT_EXTENSIONS = new Set([
  '.tex',
  '.bib',
  '.cls',
  '.sty',
  '.bst',
  '.txt',
  '.md',
  '.json',
  '.yaml',
  '.yml',
  '.csv',
  '.tsv'
]);

export function isTextFile(filePath) {
  return TEXT_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

export function extractDocumentBody(tex) {
  const startMarker = '\\begin{document}';
  const endMarker = '\\end{document}';
  const start = tex.indexOf(startMarker);
  const end = tex.lastIndexOf(endMarker);
  if (start === -1 || end === -1 || end <= start) return '';
  const bodyStart = start + startMarker.length;
  return tex.slice(bodyStart, end).trim();
}

export function mergeTemplateBody(template, body) {
  const startMarker = '\\begin{document}';
  const endMarker = '\\end{document}';
  const start = template.indexOf(startMarker);
  const end = template.lastIndexOf(endMarker);
  if (start === -1 || end === -1 || end <= start) return template;
  const before = template.slice(0, start + startMarker.length);
  const after = template.slice(end);
  const nextBody = body ? `\n${body}\n` : '\n';
  return `${before}${nextBody}${after}`;
}
