const equationEnvironments = new Set(['equation', 'equation*', 'align', 'align*', 'gather', 'gather*']);
const tableWrappers = new Set(['table', 'table*']);
const tabularEnvironments = new Set(['tabular', 'tabular*', 'tabularx', 'longtable']);
const literalEnvironments = new Set([
  'verbatim', 'verbatim*', 'Verbatim', 'BVerbatim', 'LVerbatim', 'SaveVerbatim',
  'lstlisting', 'minted', 'alltt', 'listing', 'comment', 'filecontents', 'filecontents*'
]);
const headingLevels: Record<string, number> = { section: 1, subsection: 2, subsubsection: 3 };

export type LatexHeading = {
  title: string; level: number; command: string; pos: number; line: number;
  titleFrom: number; titleTo: number;
};
type LatexNote = { from: number; to: number; level: string; color: string };
type Environment = { name: string; from: number; bodyFrom: number; bodyTo: number; to: number };
export type LatexBlock = Environment & {
  kind: 'equation' | 'table';
  label?: string;
  caption?: string;
  tabular?: Environment;
};
export type LatexStructure = {
  source: string; headings: LatexHeading[]; notes: LatexNote[]; blocks: LatexBlock[]; figures: Environment[];
};

export function blockKind(name: string): LatexBlock['kind'] | undefined {
  if (equationEnvironments.has(name) || name === '\\[' || name === '$$') return 'equation';
  if (tableWrappers.has(name) || tabularEnvironments.has(name)) return 'table';
}

const blank = (text: string) => text.replace(/[^\r\n]/g, ' ');

// Keep offsets identical to the CodeMirror document, including UTF-16 code units.
function tokenize(text: string) {
  const tokens = /\\(?:begin|end)\s*\{\s*[\w*@-]+\s*\}|\\verb(?:\*[^\r\n]|[^a-zA-Z*@\r\n])|\\(?:[a-zA-Z@]+|[^\r\n])|\$\$|%[^\r\n]*/g;
  const notes: LatexNote[] = [];
  const chunks: string[] = [];
  let copiedTo = 0;
  let literal = '';
  for (let token; (token = tokens.exec(text));) {
    const [value] = token;
    const environment = value.match(/^\\(begin|end)\s*\{\s*([^}\s]+)\s*\}$/);
    let end = tokens.lastIndex;
    if (literal) {
      if (environment?.[1] !== 'end' || environment[2] !== literal) continue;
      literal = '';
    } else if (environment?.[1] === 'begin' && literalEnvironments.has(environment[2])) {
      chunks.push(text.slice(copiedTo, token.index));
      copiedTo = token.index;
      literal = environment[2];
      continue;
    } else if (value.startsWith('%')) {
      const marker = value.match(/^%%h([1-5])\/([grbpo]?)>[ \t]*(?=\S)/);
      const lineStart = text.lastIndexOf('\n', token.index - 1) + 1;
      if (marker && !text.slice(lineStart, token.index).trim()) {
        notes.push({ from: token.index + marker[0].length, to: end, level: marker[1], color: marker[2] || 'default' });
      }
      chunks.push(text.slice(copiedTo, token.index));
      copiedTo = token.index;
    } else if (/^\\verb(?:\*[^\r\n]|[^a-zA-Z*@\r\n])$/.test(value)) {
      const delimiter = value[value.length - 1];
      const close = text.indexOf(delimiter, end);
      const newline = text.indexOf('\n', end);
      const lineEnd = newline < 0 ? text.length : newline;
      end = close >= 0 && close < lineEnd ? close + 1 : lineEnd;
      tokens.lastIndex = end;
      chunks.push(text.slice(copiedTo, token.index));
      copiedTo = token.index;
    } else {
      continue;
    }
    chunks.push(blank(text.slice(copiedTo, end)));
    copiedTo = end;
  }
  const tail = text.slice(copiedTo);
  chunks.push(literal ? blank(tail) : tail);
  return { source: chunks.join(''), notes };
}

export function skipSpace(text: string, from: number) {
  while (from < text.length && /\s/.test(text[from])) from++;
  return from;
}

export function readGroup(text: string, from: number, opening = '{') {
  const start = skipSpace(text, from);
  if (text[start] !== opening) return;
  const stack = [opening === '[' ? ']' : '}'];
  for (let pos = start + 1; pos < text.length; pos++) {
    const char = text[pos];
    if (char === '\\') {
      pos++;
    } else if (char === '{' || (char === '[' && stack[stack.length - 1] === ']')) {
      stack.push(char === '{' ? '}' : ']');
    } else if (char === stack[stack.length - 1]) {
      stack.pop();
      if (!stack.length) return { from: start + 1, to: pos, end: pos + 1, text: text.slice(start + 1, pos) };
    }
  }
}

function titleText(text: string) {
  return text.replace(/\\(?:textbf|textit|emph|texttt|textrm)\s*\{/g, '{')
    .replace(/(\\[{}%&#_$])|[{}]/g, (_, escaped) => escaped ? escaped[1] : '')
    .replace(/\s+/g, ' ').trim();
}

function metadata(source: string, env: Environment) {
  const fields: { label?: string; caption?: string } = {};
  const commands = /\\(?:[a-zA-Z@]+|[^\r\n])/g;
  commands.lastIndex = env.bodyFrom;
  for (let match; (match = commands.exec(source)) && match.index < env.bodyTo;) {
    const name = match[0];
    if (name !== '\\label' && name !== '\\caption') continue;
    const optional = name === '\\caption' ? readGroup(source, commands.lastIndex, '[') : undefined;
    const group = readGroup(source, optional?.end ?? commands.lastIndex);
    if (!group || group.end > env.bodyTo) continue;
    commands.lastIndex = group.end;
    if (name === '\\label') fields.label ??= group.text.trim();
    else fields.caption ??= titleText(group.text);
  }
  return fields;
}

export function parseLatexStructure(text: string): LatexStructure {
  const { source, notes } = tokenize(text);
  const headings: LatexHeading[] = [];
  const blocks: LatexBlock[] = [];
  const figures: Environment[] = [];
  const environments: { name: string; from: number; bodyFrom: number; tabular?: Environment }[] = [];
  const commands = /\\(?:[a-zA-Z@]+|[^\r\n])|\$\$/g;
  let line = 1;
  let newline = source.indexOf('\n');
  for (let match; (match = commands.exec(source));) {
    const [command] = match;
    const from = match.index;
    const heading = Object.prototype.hasOwnProperty.call(headingLevels, command.slice(1)) ? headingLevels[command.slice(1)] : 0;
    if (heading) {
      const commandEnd = skipSpace(source, commands.lastIndex);
      const after = source[commandEnd] === '*' ? commandEnd + 1 : commandEnd;
      const short = readGroup(source, after, '[');
      const title = readGroup(source, short?.end ?? after);
      if (title) {
        while (newline >= 0 && newline < from) {
          line++;
          newline = source.indexOf('\n', newline + 1);
        }
        headings.push({
          title: titleText(title.text) || '(untitled)', level: heading, command: command.slice(1),
          pos: from, line, titleFrom: title.from, titleTo: title.to
        });
        commands.lastIndex = title.end;
      }
      continue;
    }

    let name = command;
    let opening = command === '\\[' || (command === '$$' && environments[environments.length - 1]?.name !== '$$');
    if (command === '\\begin' || command === '\\end') {
      const group = readGroup(source, commands.lastIndex);
      if (!group || !/^[\w*@-]+$/.test(group.text.trim())) continue;
      name = group.text.trim();
      opening = command === '\\begin';
      commands.lastIndex = group.end;
    } else if (command === '\\]') {
      name = '\\[';
    } else if (command !== '\\[' && command !== '$$') {
      continue;
    }

    if (opening) {
      environments.push({ name, from, bodyFrom: commands.lastIndex });
      continue;
    }
    // Allow recovery after an unmatched block, while requiring an actual matching closer.
    let index = environments.length - 1;
    while (index >= 0 && environments[index].name !== name) index--;
    if (index < 0) continue;
    const start = environments[index];
    environments.length = index;
    const env = { ...start, to: commands.lastIndex, bodyTo: from };
    if (name === 'figure' || name === 'figure*') figures.push(env);
    const kind = blockKind(name);
    if (!kind) continue;
    if (tabularEnvironments.has(name)) {
      const wrapper = environments[environments.length - 1];
      if (wrapper && tableWrappers.has(wrapper.name)) wrapper.tabular ??= env;
    }
    blocks.push({ ...env, kind, ...metadata(source, env) });
  }
  blocks.sort((a, b) => a.from - b.from);
  const grouped: LatexBlock[] = [];
  let wrapperEnd = -1;
  for (const block of blocks) {
    if (block.to <= wrapperEnd && block.kind === 'table') continue;
    grouped.push(block);
    if (tableWrappers.has(block.name)) wrapperEnd = block.to;
  }
  return { source, notes, headings, blocks: grouped, figures };
}
