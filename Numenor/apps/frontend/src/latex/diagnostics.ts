// Maziar: LaTeX log parsing and editor markers for compile errors and warnings.
//
// The backend compiles with `-file-line-error` and an unwrapped log (max_print_line), so errors read
// `./chapters/results.tex:4: Undefined control sequence.`. Warnings don't carry a file name, so the parser
// follows TeX's "(file … )" nesting to know which file was being read when a warning was printed.
import { RangeSetBuilder, StateEffect, StateField, type Extension } from '@codemirror/state';
import { Decoration, EditorView, type DecorationSet } from '@codemirror/view';

export type LatexDiagnostic = {
  severity: 'error' | 'warning' | 'badbox';
  message: string;
  /** Project-relative path when the file belongs to the project, else the name TeX printed. */
  file?: string;
  line?: number;
  /** Extra context lines (e.g. the `l.4 \undefinedcommand` excerpt). */
  detail?: string;
};

const FILE_OPEN = /^\(([^\s()]+?\.(?:tex|ltx|sty|cls|clo|cfg|def|fd|aux|toc|lof|lot|bbl|out|ldf|dict|code\.tex|bib|nav|snm|vrb|ins|dtx))(?=[\s()]|$)/;

function normalizeFile(raw: string) {
  let name = raw.trim();
  while (name.startsWith('./')) name = name.slice(2);
  return name;
}

/** The output of the final TeX run only — earlier passes report references that later passes resolve. */
function lastPass(log: string) {
  const re = /^This is (?:pdfTeX|XeTeX|LuaTeX|LuaHBTeX|e-TeX|TeX|Tectonic)/gm;
  let start = 0;
  let match: RegExpExecArray | null;
  while ((match = re.exec(log))) start = match.index;
  return log.slice(start);
}

export function parseLatexLog(log: string, projectFiles: Set<string> = new Set()): LatexDiagnostic[] {
  if (!log) return [];
  const lines = lastPass(log).split('\n');
  const out: LatexDiagnostic[] = [];
  const seen = new Set<string>();
  const stack: (string | null)[] = [];
  const currentFile = () => {
    for (let i = stack.length - 1; i >= 0; i -= 1) if (stack[i]) return stack[i] as string;
    return undefined;
  };
  const resolve = (name?: string) => {
    if (!name) return undefined;
    const n = normalizeFile(name);
    if (projectFiles.size === 0 || projectFiles.has(n)) return n;
    // Absolute path inside the project?
    for (const f of projectFiles) if (n.endsWith(`/${f}`)) return f;
    return n;
  };
  const push = (d: LatexDiagnostic) => {
    const key = `${d.severity}|${d.file || ''}|${d.line || ''}|${d.message}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push(d);
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];

    // file:line: message  (from -file-line-error)
    const fle = line.match(/^(.+?\.(?:tex|ltx|sty|cls|bib|bbl)):(\d+): (.*)$/);
    if (fle) {
      const detail: string[] = [];
      let message = fle[3].trim();
      for (let j = i + 1; j < Math.min(i + 8, lines.length); j += 1) {
        const next = lines[j];
        if (!next.trim()) break;
        detail.push(next);
        if (/^l\.\d+/.test(next)) {
          if (lines[j + 1]?.trim()) detail.push(lines[j + 1]);
          break;
        }
      }
      if (message.startsWith('LaTeX Error: ')) message = message.slice('LaTeX Error: '.length);
      push({ severity: 'error', message, file: resolve(fle[1]), line: Number(fle[2]), detail: detail.join('\n') || undefined });
      continue;
    }

    // "! Message" errors (engines without -file-line-error, e.g. tectonic)
    if (line.startsWith('! ')) {
      let lineNo: number | undefined;
      const detail: string[] = [];
      for (let j = i + 1; j < Math.min(i + 8, lines.length); j += 1) {
        const m = lines[j].match(/^l\.(\d+)/);
        detail.push(lines[j]);
        if (m) {
          lineNo = Number(m[1]);
          break;
        }
      }
      push({ severity: 'error', message: line.slice(2).replace(/^LaTeX Error: /, '').trim(), file: resolve(currentFile()), line: lineNo, detail: detail.join('\n') || undefined });
      continue;
    }

    // Warnings (LaTeX, packages, classes), possibly continued on "(pkg)   …" lines
    const warn = line.match(/^(?:LaTeX|LaTeX Font|(?:Package|Class) (\S+)) Warning: (.*)$/);
    if (warn) {
      let message = warn[2];
      const pkg = warn[1];
      // Package/class warnings continue on lines prefixed with "(pkgname)".
      const contRe = pkg ? new RegExp(`^\\(${pkg.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\)\\s+(.*)$`) : null;
      for (let j = i + 1; contRe && j < lines.length; j += 1) {
        const cont = lines[j].match(contRe);
        if (!cont) break;
        message += ` ${cont[1]}`;
        i = j;
      }
      const lineMatch = message.match(/on input line (\d+)/);
      if (/Font shape|Some font shapes were not available/.test(message)) continue;
      push({
        severity: 'warning',
        message: (pkg ? `${pkg}: ` : '') + message.replace(/\s+/g, ' ').trim(),
        file: resolve(currentFile()),
        line: lineMatch ? Number(lineMatch[1]) : undefined
      });
      continue;
    }

    const box = line.match(/^((?:Over|Under)full \\[hv]box .*?)(?: (?:in paragraph|in alignment|detected) at lines? (\d+)(?:--\d+)?)?$/);
    if (box) {
      push({ severity: 'badbox', message: box[1].trim(), file: resolve(currentFile()), line: box[2] ? Number(box[2]) : undefined });
      continue;
    }

    // Track "(file" opens and ")" closes to know the current file.
    for (let k = 0; k < line.length; k += 1) {
      const ch = line[k];
      if (ch === '(') {
        const m = line.slice(k).match(FILE_OPEN);
        if (m) {
          stack.push(m[1]);
          k += m[0].length - 1;
        } else {
          stack.push(null);
        }
      } else if (ch === ')') {
        stack.pop();
      }
    }
  }
  const rank = { error: 0, warning: 1, badbox: 2 } as const;
  return out.sort((a, b) => rank[a.severity] - rank[b.severity]);
}

// ---------- editor markers ----------

const setMarks = StateEffect.define<{ line: number; severity: LatexDiagnostic['severity']; message: string }[]>();
const flashLine = StateEffect.define<number | null>();

const markField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    let next = value.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(setMarks)) {
        const builder = new RangeSetBuilder<Decoration>();
        const byLine = new Map<number, { severity: LatexDiagnostic['severity']; messages: string[] }>();
        for (const mark of effect.value) {
          if (mark.line < 1 || mark.line > tr.state.doc.lines) continue;
          const entry = byLine.get(mark.line);
          if (entry) {
            entry.messages.push(mark.message);
            if (mark.severity === 'error') entry.severity = 'error';
          } else {
            byLine.set(mark.line, { severity: mark.severity, messages: [mark.message] });
          }
        }
        [...byLine.keys()].sort((a, b) => a - b).forEach((lineNo) => {
          const entry = byLine.get(lineNo)!;
          const line = tr.state.doc.line(lineNo);
          builder.add(line.from, line.from, Decoration.line({
            class: `cm-maziar-diag cm-maziar-diag-${entry.severity}`,
            attributes: { title: entry.messages.join('\n') }
          }));
        });
        next = builder.finish();
      }
    }
    return next;
  },
  provide: (field) => EditorView.decorations.from(field)
});

const flashField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    let next = value.map(tr.changes);
    for (const effect of tr.effects) {
      if (effect.is(flashLine)) {
        if (effect.value == null || effect.value < 1 || effect.value > tr.state.doc.lines) {
          next = Decoration.none;
        } else {
          const line = tr.state.doc.line(effect.value);
          next = Decoration.set([Decoration.line({ class: 'cm-maziar-flash' }).range(line.from)]);
        }
      }
    }
    return next;
  },
  provide: (field) => EditorView.decorations.from(field)
});

export function diagnosticsExtension(): Extension {
  return [markField, flashField];
}

/** Marks the lines of `file` that have diagnostics (call again whenever the open file or the log changes). */
export function showDiagnostics(view: EditorView, diagnostics: LatexDiagnostic[], file: string) {
  const marks = diagnostics
    .filter((d) => d.file === file && d.line)
    .map((d) => ({ line: d.line as number, severity: d.severity, message: d.message }));
  view.dispatch({ effects: setMarks.of(marks) });
}

/** Moves the cursor to `line` (1-based), scrolls it to the middle and highlights it briefly. */
export function revealLine(view: EditorView, line: number, column = 0) {
  const doc = view.state.doc;
  const target = doc.line(Math.min(Math.max(1, line), doc.lines));
  const pos = Math.min(target.to, target.from + Math.max(0, column));
  view.dispatch({
    selection: { anchor: pos },
    effects: [flashLine.of(target.number), EditorView.scrollIntoView(pos, { y: 'center' })]
  });
  view.focus();
  window.setTimeout(() => {
    if (view.state.field(flashField, false) !== undefined) view.dispatch({ effects: flashLine.of(null) });
  }, 1800);
}
