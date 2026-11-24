import { readGroup, type LatexBlock } from './structure';

export function tableSnippet(rows: number, columns: number, header: boolean) {
  const row = (label: string) =>
    Array.from({ length: columns }, (_, col) => `${label} ${col + 1}`).join(' & ') + ' \\\\';
  return [
    '\\begin{table}[t]', '\\centering', `\\begin{tabular}{${'l'.repeat(columns)}}`,
    ...(header ? [row('Header'), '\\hline'] : []),
    ...Array.from({ length: rows }, (_, index) => row(`Row ${index + 1}, column`)),
    '\\end{tabular}', '\\caption{Table caption.}', '\\end{table}'
  ].join('\n');
}

export function parseTable(source: string, block: LatexBlock) {
  if (block.caption?.includes('\\')) return;
  const env = block.tabular ?? block;
  const wrapperStart = env !== block ? readGroup(source, block.bodyFrom, '[')?.end ?? block.bodyFrom : block.bodyFrom;
  const wrapper = env !== block
    ? source.slice(wrapperStart, env.from) + source.slice(env.to, block.bodyTo)
    : '';
  const body = source.slice(env.bodyFrom, env.bodyTo);
  const optional = readGroup(body, 0, '[');
  const sized = env.name === 'tabular*' || env.name === 'tabularx';
  const width = sized ? readGroup(body, optional?.end ?? 0) : undefined;
  if (sized && !width) return;
  const position = sized ? readGroup(body, width!.end, '[') : optional;
  const spec = readGroup(body, position?.end ?? width?.end ?? 0);
  if (!spec || !/^[lcrX|\s]+$/.test(spec.text)) return;
  const alignment = [...spec.text].filter((char) => 'lcrX'.includes(char));
  if (!alignment.length) return;

  // Metadata is allowed outside the grid. Unrecognized wrapper content requires the PDF.
  const metadata = stripMetadata(wrapper);
  if (metadata === undefined || metadata.trim()) return;
  const grid = stripMetadata(body.slice(spec.end), env.name === 'longtable');
  if (grid === undefined) return;

  const rows: string[][] = [];
  let header = false;
  let cells: string[] = [];
  let cell = '';
  const finishRow = () => {
    cells.push(cell.replace(/\s+/g, ' ').trim());
    rows.push(cells);
    cells = [];
    cell = '';
  };
  const tokens = /\\(?:[a-zA-Z@]+|[^\r\n])|[&{}~$^_]|[^\\&{}~$^_]+/g;
  const escaped = ['&', '%', '#', '_', '{', '}', '$', ' '];
  for (let token; (token = tokens.exec(grid));) {
    const value = token[0];
    if (value === '&') {
      cells.push(cell.replace(/\s+/g, ' ').trim());
      cell = '';
    } else if (value === '\\\\') {
      finishRow();
    } else if (['\\hline', '\\toprule', '\\midrule', '\\bottomrule'].includes(value)) {
      if (cells.length || cell.trim()) return;
      if (rows.length === 1 && (value === '\\midrule' || value === '\\hline')) header = true;
    } else if (value.length === 2 && value.startsWith('\\') && escaped.includes(value[1])) {
      cell += value[1];
    } else if (value === '~') {
      cell += ' ';
    } else if (value.startsWith('\\') || /^[{}$^_]$/.test(value)) {
      return;
    } else {
      cell += value;
    }
  }
  if (cells.length || cell.trim()) finishRow();
  if (!rows.length || rows.some((row) => row.length !== alignment.length)) return;
  return { rows, header, alignment };
}

function stripMetadata(text: string, longtable = false) {
  const commands = /\\(?:[a-zA-Z@]+|[^\r\n])/g;
  let result = '';
  let from = 0;
  for (let match; (match = commands.exec(text));) {
    if (!['\\caption', '\\label', '\\centering'].includes(match[0])) continue;
    result += text.slice(from, match.index);
    if (match[0] !== '\\centering') {
      const short = match[0] === '\\caption' ? readGroup(text, commands.lastIndex, '[') : undefined;
      const group = readGroup(text, short?.end ?? commands.lastIndex);
      if (!group) return;
      commands.lastIndex = group.end;
      if (longtable && match[0] === '\\caption') {
        const end = /^\s*(?:\\label\s*\{[^{}]*\}\s*)?\\\\/.exec(text.slice(group.end));
        if (end) commands.lastIndex += end[0].length;
      }
    }
    from = commands.lastIndex;
  }
  return result + text.slice(from);
}
