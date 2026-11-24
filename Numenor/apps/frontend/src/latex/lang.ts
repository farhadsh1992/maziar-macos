import { StreamLanguage } from '@codemirror/language';
import { Decoration, EditorView, MatchDecorator, ViewPlugin, type DecorationSet, type ViewUpdate } from '@codemirror/view';

// Simple LaTeX mode for CodeMirror 6
const latexMode = {
  startState: () => ({ inlineCloser: '' }),
  blankLine(state: { inlineCloser: string }) {
    state.inlineCloser = '';
  },
  token(stream: any, state: { inlineCloser: string }) {
    if (stream.sol()) state.inlineCloser = '';
    if (stream.match(/^%.*$/)) return 'comment';

    // Display delimiters are handled by the structural tokenizer. Keep an
    // unclosed math delimiter from changing the color of following lines.
    if (stream.match(/^\$\$|^\\[\[\]]/)) {
      state.inlineCloser = '';
      return 'keyword';
    }
    if (stream.match(/^\\\(|^\\\)|^\$/)) {
      const delimiter = stream.current();
      state.inlineCloser = delimiter === state.inlineCloser ? '' : delimiter === '\\(' ? '\\)' : delimiter === '$' ? '$' : '';
      return 'keyword';
    }
    if (stream.match(/^\\[^a-zA-Z@]/)) return state.inlineCloser ? 'number' : 'keyword';

    // Commands
    if (stream.match(/^\\[a-zA-Z@]+/)) {
      return 'keyword';
    }

    // Special characters
    if (stream.match(/^[{}[\]]/)) {
      return 'bracket';
    }

    // Math mode content
    if (state.inlineCloser) {
      stream.next();
      return 'number';
    }

    stream.next();
    return null;
  }
};

export function latex() {
  // Maziar: language data belongs inside the parser spec — `define` takes only one argument, so passing it
  // as a second one was silently ignored and Cmd/Ctrl+/ (toggleComment) found no comment syntax.
  return StreamLanguage.define({
    ...latexMode,
    languageData: {
      commentTokens: { line: '%' }
    }
  });
}

// Maziar: "%%%" comments are notes meant to stand out — shown bold green from the %%% to the end of the
// line. An escaped "\\%" is a literal percent sign, not a comment, so it doesn't count.
const strongCommentMark = Decoration.mark({ class: 'cm-maziar-strong-comment' });
const strongCommentMatcher = new MatchDecorator({
  regexp: /(?<!\\)%%%.*$/gm,
  decoration: () => strongCommentMark
});

export function strongComments() {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = strongCommentMatcher.createDeco(view);
      }
      update(update: ViewUpdate) {
        this.decorations = strongCommentMatcher.updateDeco(update, this.decorations);
      }
    },
    { decorations: (plugin) => plugin.decorations }
  );
}
