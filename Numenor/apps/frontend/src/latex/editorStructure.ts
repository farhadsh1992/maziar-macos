import { EditorState, Facet, RangeSet, StateEffect, StateField, type Range } from '@codemirror/state';
import { codeFolding, foldedRanges, unfoldEffect } from '@codemirror/language';
import { Decoration, EditorView, GutterMarker, gutterLineClass, WidgetType } from '@codemirror/view';
import 'katex/dist/katex.min.css';
import { blockKind, parseLatexStructure, skipSpace, type LatexBlock, type LatexStructure } from './structure';
import { parseTable } from './table';

export const latexOptions = {
  headings: 'Highlight section headings',
  equations: 'Highlight equations',
  foldEquations: 'Enable equation folding',
  previewEquations: 'Enable equation preview',
  tables: 'Highlight tables',
  foldTables: 'Enable table folding',
  previewTables: 'Enable table preview',
  notes: 'Style comment headings',
  outline: 'Show LaTeX Outline'
} as const;
export type LatexOptions = Record<keyof typeof latexOptions, boolean>;
export const defaultLatexOptions: LatexOptions = {
  headings: true, equations: true, foldEquations: true, previewEquations: true,
  tables: true, foldTables: true, previewTables: true, notes: true, outline: true
};

type Configuration = {
  enabled: boolean;
  options: LatexOptions;
  translate: (text: string, values?: { count: number }) => string;
  showPdf: (line: number) => void;
};

export const latexConfiguration = Facet.define<Configuration, Configuration>({
  combine: (values) => values[0] ?? {
    enabled: false, options: defaultLatexOptions, translate: (text) => text, showPdf: () => {}
  }
});
export const latexStructure = StateField.define<LatexStructure | null>({
  create: (state) => state.facet(latexConfiguration).enabled ? parseLatexStructure(state.doc.toString()) : null,
  update(previous, transaction) {
    if (!transaction.state.facet(latexConfiguration).enabled) return null;
    return transaction.docChanged || !previous ? parseLatexStructure(transaction.newDoc.toString()) : previous;
  }
});

const setPreview = StateEffect.define<{ from: number; kind: LatexBlock['kind'] } | null>();
const previewAllowed = (options: LatexOptions, kind: LatexBlock['kind']) =>
  kind === 'equation' ? options.previewEquations : options.previewTables;
const foldAllowed = (options: LatexOptions, kind: LatexBlock['kind']) =>
  kind === 'equation' ? options.foldEquations : options.foldTables;

function foldRange(state: EditorState, block: LatexBlock) {
  const firstLine = state.doc.lineAt(block.from);
  const lastLine = state.doc.lineAt(block.to - 1);
  if (firstLine.number < lastLine.number) return { from: firstLine.to, to: block.to };
}

// Undefined delegates to the previous folding rules. Null reserves this line for a
// recognized block that is disabled, single-line, or still missing its closer.
export function structuredFold(state: EditorState, lineStart: number, lineEnd: number) {
  const structure = state.field(latexStructure);
  if (!structure) return undefined;
  const { options } = state.facet(latexConfiguration);
  const blocks = structure.blocks;
  let lo = 0, hi = blocks.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (blocks[mid].from < lineStart) lo = mid + 1;
    else hi = mid;
  }
  const block = blocks[lo];
  if (block && block.from < lineEnd) {
    return foldAllowed(options, block.kind) ? foldRange(state, block) ?? null : null;
  }
  const source = structure.source.slice(lineStart, lineEnd);
  const opening = source.match(/\\begin\s*\{([^}]+)\}|\\\[|\$\$/);
  return opening && blockKind(opening[1] ?? opening[0]) ? null : undefined;
}

export function unfoldLatexBlocks(state: EditorState, options?: LatexOptions) {
  const effects: StateEffect<unknown>[] = [];
  const starts = new Set(state.field(latexStructure)?.blocks.flatMap((block) =>
    options && foldAllowed(options, block.kind) ? [] : [state.doc.lineAt(block.from).to]) ?? []);
  foldedRanges(state).between(0, state.doc.length, (from, to) => {
    if (!options || starts.has(from)) effects.push(unfoldEffect.of({ from, to }));
  });
  if (!options) effects.push(setPreview.of(null));
  return effects;
}

export function previewTarget(state: EditorState, position: number) {
  const { options } = state.facet(latexConfiguration);
  return state.field(latexStructure)?.blocks.find((item) =>
    position >= item.from && position < item.to && previewAllowed(options, item.kind));
}

export function openLatexPreview(view: EditorView, position: number) {
  const block = previewTarget(view.state, position);
  if (!block) return;
  const effects: StateEffect<unknown>[] = [setPreview.of({ from: block.from, kind: block.kind })];
  foldedRanges(view.state).between(block.from, block.to, (from, to) => {
    effects.push(unfoldEffect.of({ from, to }));
  });
  view.dispatch({ effects });
}

async function previewEquation(source: string, block: LatexBlock, container: HTMLElement) {
  const { default: katex } = await import('katex');
  let body = source.slice(block.bodyFrom, block.bodyTo)
    .replace(/\\(?:label|tag)\*?\s*\{[^{}]*\}|\\(?:notag|nonumber)\b/g, '');
  const name = block.name.replace(/\*$/, '');
  if (name === 'align') body = `\\begin{aligned}${body}\\end{aligned}`;
  if (name === 'gather') body = `\\begin{gathered}${body}\\end{gathered}`;
  katex.render(body, container, { displayMode: true, throwOnError: true, trust: false, maxExpand: 100, maxSize: 10 });
}

class PreviewWidget extends WidgetType {
  constructor(
    readonly block: LatexBlock,
    readonly source: string,
    readonly configuration: Configuration
  ) { super(); }

  eq(other: PreviewWidget) {
    return this.block.from === other.block.from && this.block.to === other.block.to
      && this.configuration === other.configuration
      && this.source.slice(this.block.from, this.block.to) === other.source.slice(other.block.from, other.block.to);
  }

  toDOM(view: EditorView) {
    const doc = view.dom.ownerDocument;
    const { block, configuration } = this;
    const { translate } = configuration;
    const strip = doc.createElement('div');
    strip.className = `cm-nm-preview cm-nm-preview-${block.kind}`;
    strip.setAttribute('role', 'group');
    strip.setAttribute('aria-label', translate(block.kind === 'equation' ? 'Equation preview' : 'Table preview'));
    const button = (label: string, action: () => void) => {
      const node = doc.createElement('button');
      node.type = 'button';
      node.textContent = label;
      node.onclick = action;
      return node;
    };
    const close = button('×', () => {
      view.dispatch({ effects: setPreview.of(null) });
      view.focus();
    });
    close.className = 'cm-nm-preview-close';
    close.setAttribute('aria-label', translate('Close preview'));
    strip.append(close);
    const content = doc.createElement('div');
    content.className = 'cm-nm-preview-content';
    strip.append(content);
    const fallback = () => {
      content.replaceChildren(
        doc.createTextNode(translate('This source needs the LaTeX compiler.')),
        button(translate('View in PDF'), () => {
          const position = Math.min(block.bodyTo, skipSpace(this.source, block.bodyFrom));
          configuration.showPdf(view.state.doc.lineAt(position).number);
        })
      );
    };
    if (block.kind === 'equation') {
      previewEquation(this.source, block, content)
        .catch(fallback)
        .finally(() => { if (strip.isConnected) view.requestMeasure(); });
      return strip;
    }

    const grid = parseTable(this.source, block);
    if (!grid) {
      fallback();
      return strip;
    }
    const table = doc.createElement('table');
    if (block.caption) table.createCaption().textContent = block.caption;
    const body = table.createTBody();
    grid.rows.forEach((row, index) => {
      const isHeader = grid.header && index === 0;
      const tr = isHeader ? table.createTHead().insertRow() : body.insertRow();
      row.forEach((value, column) => {
        const cell = doc.createElement(isHeader ? 'th' : 'td');
        if (isHeader) cell.setAttribute('scope', 'col');
        cell.textContent = value;
        cell.style.textAlign = grid.alignment[column] === 'r' ? 'right'
          : grid.alignment[column] === 'c' ? 'center' : 'left';
        tr.append(cell);
      });
    });
    content.append(table);
    return strip;
  }
}

class HeadingGutterMarker extends GutterMarker {
  constructor(readonly level: number) { super(); }
  elementClass = `cm-nm-heading-gutter-${this.level}`;
  eq(other: HeadingGutterMarker) { return this.level === other.level; }
}

type Presentation = {
  preview: LatexBlock | null;
  decorations: ReturnType<typeof Decoration.set>;
  gutters: RangeSet<GutterMarker>;
};

function decorate(state: EditorState, preview: LatexBlock | null): Presentation {
  const structure = state.field(latexStructure);
  const configuration = state.facet(latexConfiguration);
  const { options } = configuration;
  if (!structure) return { preview: null, decorations: Decoration.none, gutters: RangeSet.empty };
  const decorations: Range<Decoration>[] = [];
  const gutters: Range<GutterMarker>[] = [];
  const doc = state.doc;
  if (options.headings) {
    for (const item of structure.headings) {
      if (item.titleFrom < item.titleTo) {
        decorations.push(Decoration.mark({ class: `cm-nm-heading-title-${item.level}` })
          .range(item.titleFrom, item.titleTo));
      }
      const firstLine = doc.lineAt(item.pos);
      const lastLine = doc.lineAt(item.titleTo).number;
      gutters.push(new HeadingGutterMarker(item.level).range(firstLine.from));
      for (let number = firstLine.number; number <= lastLine; number++) {
        const classes = ['cm-nm-heading', `cm-nm-heading-${item.level}`];
        if (number === firstLine.number) classes.push('cm-nm-heading-start');
        if (number === lastLine) classes.push('cm-nm-heading-end');
        decorations.push(Decoration.line({ class: classes.join(' ') }).range(doc.line(number).from));
      }
    }
  }
  for (const block of structure.blocks) {
    if (!(block.kind === 'equation' ? options.equations : options.tables)) continue;
    const lastLine = doc.lineAt(block.to - 1).number;
    for (let line = doc.lineAt(block.from).number; line <= lastLine; line++) {
      decorations.push(Decoration.line({ class: `cm-nm-${block.kind}` }).range(doc.line(line).from));
    }
  }
  if (options.notes) {
    for (const note of structure.notes) {
      decorations.push(Decoration.mark({ class: `cm-nm-note cm-nm-note-${note.level} cm-nm-note-${note.color}` })
        .range(note.from, note.to));
    }
  }
  if (preview) {
    const widget = new PreviewWidget(preview, structure.source, configuration);
    decorations.push(Decoration.widget({ widget, side: 1, block: true }).range(doc.lineAt(preview.to - 1).to));
  }
  return { preview, decorations: Decoration.set(decorations, true), gutters: RangeSet.of(gutters, true) };
}

const presentation = StateField.define<Presentation>({
  create: (state) => decorate(state, null),
  update(previous, transaction) {
    let target = previous.preview && { from: previous.preview.from, kind: previous.preview.kind };
    if (target && transaction.docChanged) target.from = transaction.changes.mapPos(target.from, 1);
    let requested = false;
    for (const effect of transaction.effects) {
      if (effect.is(setPreview)) {
        target = effect.value;
        requested = true;
      }
    }
    const config = transaction.state.facet(latexConfiguration);
    if (!requested && !transaction.docChanged && config === transaction.startState.facet(latexConfiguration)) {
      return previous;
    }
    const preview = target && previewAllowed(config.options, target.kind)
      ? transaction.state.field(latexStructure)?.blocks.find(
        (block) => block.from === target!.from && block.kind === target!.kind
      ) ?? null : null;
    return decorate(transaction.state, preview);
  },
  provide: (field) => [
    EditorView.decorations.from(field, (value) => value.decorations),
    gutterLineClass.from(field, (value) => value.gutters)
  ]
});

export const structuredLatexEditor = [
  latexStructure,
  presentation,
  EditorState.transactionExtender.of((transaction) => {
    if (!transaction.docChanged) return null;
    const { startState, changes } = transaction;
    const structure = startState.field(latexStructure);
    const folded = foldedRanges(startState);
    if (!structure?.blocks.length || !folded.size) return null;
    const effects: StateEffect<unknown>[] = [];
    for (const block of structure.blocks) {
      const range = foldRange(startState, block);
      if (!range || !changes.touchesRange(block.from, block.to)) continue;
      folded.between(range.from, range.to, (from, to) => {
        if (from === range.from && to === range.to) {
          effects.push(unfoldEffect.of({ from: changes.mapPos(from, 1), to: changes.mapPos(to, -1) }));
        }
      });
    }
    return effects.length ? { effects } : null;
  }),
  codeFolding({
    preparePlaceholder(state, range) {
      const block = state.field(latexStructure)?.blocks.find((item) => {
        const candidate = foldRange(state, item);
        return candidate?.from === range.from && candidate.to === range.to;
      });
      if (!block) return '…';
      const translate = state.facet(latexConfiguration).translate;
      const count = state.doc.lineAt(block.to - 1).number - state.doc.lineAt(block.from).number + 1;
      const name = translate(block.kind === 'equation' ? 'Equation' : 'Table');
      const details = [block.caption, block.label].filter(Boolean).join(' · ');
      return `${name} · ${details || translate('{{count}} lines', { count })}`;
    },
    placeholderDOM(view, unfold, label: string) {
      const button = view.dom.ownerDocument.createElement('button');
      button.type = 'button';
      button.className = 'cm-foldPlaceholder cm-nm-fold-placeholder';
      button.textContent = label;
      button.title = view.state.phrase('unfold');
      button.onclick = unfold;
      return button;
    }
  })
];
