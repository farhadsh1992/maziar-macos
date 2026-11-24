import { RangeSet, StateEffect, StateField, type Extension, type Text } from '@codemirror/state';
import { foldedRanges, unfoldEffect } from '@codemirror/language';
import { Decoration, EditorView, gutter, GutterMarker } from '@codemirror/view';
import type { SourceComment } from '../api/client';

export function resolveComment(doc: Text, comment: SourceComment, source = doc.toString()) {
  const { quote } = comment;
  if (quote && source.startsWith(quote, comment.from)) return { from: comment.from, to: comment.from + quote.length };
  let nearest = -1;
  let distance = Infinity;
  let tied = false;
  for (let from = quote ? source.indexOf(quote) : -1; from >= 0; from = source.indexOf(quote, from + 1)) {
    const gap = Math.abs(comment.from - from);
    if (gap < distance) { nearest = from; distance = gap; tied = false; }
    else if (gap === distance) tied = true;
    if (from > comment.from && gap > distance) break;
  }
  if (nearest >= 0 && !tied) return { from: nearest, to: nearest + quote.length };
  const line = doc.line(Math.max(1, Math.min(comment.line, doc.lines)));
  return { from: line.from, to: line.from };
}

class CommentMarker extends GutterMarker {
  constructor(readonly ids: string[]) { super(); }
  eq(other: CommentMarker) { return this.ids.join(',') === other.ids.join(','); }
  toDOM(view: EditorView) {
    const button = view.dom.ownerDocument.createElement('button');
    button.className = 'nm-comment-gutter-button';
    button.type = 'button';
    button.dataset.comments = this.ids.join(',');
    button.title = view.state.phrase('Comments');
    button.setAttribute('aria-label', view.state.phrase('Comments'));
    button.innerHTML = '<svg aria-hidden="true" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 11a7 7 0 0 1-7 7H8l-4 3v-7a7 7 0 0 1 7-10h2a7 7 0 0 1 7 7Z"/></svg>';
    return button;
  }
}

const annotate = StateEffect.define<{ comments: readonly SourceComment[]; selected?: string }>();
function decorations(doc: Text, comments: readonly SourceComment[], selected?: string) {
  const groups = new Map<number, string[]>();
  const source = comments.length ? doc.toString() : '';
  const ranges = comments.flatMap((comment) => {
    const { from, to } = resolveComment(doc, comment, source);
    const line = doc.lineAt(from).from;
    const ids = groups.get(line) ?? [];
    ids.push(comment.id);
    groups.set(line, ids);
    return from < to ? [Decoration.mark({
      class: comment.id === selected ? 'nm-comment-range nm-comment-selected' : 'nm-comment-range'
    }).range(from, to)] : [];
  });
  return {
    comments, selected, ranges: Decoration.set(ranges, true),
    markers: RangeSet.of([...groups].map(([position, ids]) => new CommentMarker(ids).range(position)), true)
  };
}
const commentField = StateField.define<ReturnType<typeof decorations>>({
  create: (state) => decorations(state.doc, []),
  update(value, transaction) {
    const next = transaction.effects.find((effect) => effect.is(annotate));
    if (next?.is(annotate)) return decorations(transaction.newDoc, next.value.comments, next.value.selected);
    return transaction.docChanged ? decorations(transaction.newDoc, value.comments, value.selected) : value;
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.ranges)
});

export function displayComments(view: EditorView, comments: readonly SourceComment[], selected?: string) {
  view.dispatch({ effects: annotate.of({ comments, selected }) });
}

export function jumpToComment(view: EditorView, comment: SourceComment) {
  const range = resolveComment(view.state.doc, comment);
  const effects: StateEffect<unknown>[] = [EditorView.scrollIntoView(range.from, { y: 'center' })];
  foldedRanges(view.state).between(range.from, range.to, (from, to) => {
    effects.push(unfoldEffect.of({ from, to }));
  });
  view.dispatch({ effects });
}

export function sourceCommentsExtension(select: (ids: string[]) => void): Extension {
  return [commentField, gutter({
    class: 'nm-comment-gutter',
    markers: (view) => view.state.field(commentField).markers,
    initialSpacer: () => new CommentMarker([]),
    domEventHandlers: {
      click(_view, _line, event) {
        const button = (event.target as Element).closest<HTMLElement>('[data-comments]');
        if (!button?.dataset.comments) return false;
        select(button.dataset.comments.split(','));
        return true;
      }
    }
  })];
}
