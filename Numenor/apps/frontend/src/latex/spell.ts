// Maziar: LaTeX-aware spelling and grammar checking for the CodeMirror editor.
//
// The document is "masked" before checking: commands, math, comments, citation keys, labels, file paths,
// verbatim/code environments and the like are blanked out with spaces (newlines kept), so only the prose
// is checked and every offset in the result still lines up with the editor text. Checking itself is done
// by macOS's spelling and grammar checker through the backend (`/api/spell/check`), on this Mac only.
import { StateEffect, StateField, type Extension } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, hoverTooltip, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { addSpellWord, getSpellVocabulary, removeSpellWord, spellCheck, type SpellIssue } from '../api/client';

// Commands whose brace arguments are not prose (number = how many leading {…} arguments to blank).
const NON_PROSE_ARGS: Record<string, number> = {
  cite: 1, citep: 1, citet: 1, citealp: 1, citeauthor: 1, citeyear: 1, nocite: 1, parencite: 1, textcite: 1, autocite: 1, footcite: 1,
  ref: 1, eqref: 1, autoref: 1, pageref: 1, cref: 1, Cref: 1, nameref: 1, vref: 1, label: 1,
  includegraphics: 1, input: 1, include: 1, includeonly: 1, includepdf: 1, graphicspath: 1, lstinputlisting: 1, inputminted: 2,
  usepackage: 1, RequirePackage: 1, documentclass: 1, bibliography: 1, bibliographystyle: 1, addbibresource: 1,
  url: 1, href: 1, path: 1, email: 1,
  begin: 1, end: 1, newcommand: 2, renewcommand: 2, providecommand: 2, newenvironment: 3, renewenvironment: 3, def: 0,
  DeclareMathOperator: 2, newtheorem: 2, setlength: 2, addtolength: 2, setcounter: 2, addtocounter: 2,
  hspace: 1, vspace: 1, hskip: 0, vskip: 0, color: 1, textcolor: 1, colorbox: 1, definecolor: 3, pagecolor: 1,
  hypersetup: 1, geometry: 1, pagestyle: 1, thispagestyle: 1, pagenumbering: 1, newpage: 0, linewidth: 0,
  multicolumn: 2, multirow: 2, cline: 1, cmidrule: 1, rule: 2, resizebox: 2, scalebox: 1, rotatebox: 1,
  fontsize: 2, selectfont: 0, usetikzlibrary: 1, tikz: 1, SI: 2, si: 1, num: 1, ang: 1, qty: 2, unit: 1,
  acrshort: 1, acrlong: 1, acrfull: 1, gls: 1, Gls: 1, glspl: 1, newacronym: 3, verb: 0, lstset: 1, captionsetup: 1,
  setmainfont: 1, setsansfont: 1, setmonofont: 1, author: 0, affiliation: 0, keywords: 0,
  // Code and file names set in monospace
  texttt: 1, code: 1, lstinline: 1, mintinline: 2, file: 1, filename: 1, cmd: 1, command: 1, package: 1, pkg: 1, cls: 1, env: 1
};

// Things in running text that look like file paths, URLs, e-mail addresses or identifiers.
const NON_PROSE_TOKENS = [
  /\b(?:https?:\/\/|www\.)\S+/g,
  /\b[\w.+-]+@[\w-]+\.[\w.]+\b/g,
  /(?:^|(?<=\s))[^\s]*[\/\\][^\s]*/g,
  /\b[\w-]+\.(?:tex|bib|bst|sty|cls|png|jpe?g|gif|pdf|eps|svg|tikz|py|m|r|js|ts|cpp|h|c|java|txt|csv|json|ya?ml|md|log|zip)\b/gi,
  /\b\w+_\w+\b/g
];

// Environments whose whole body is skipped (math, code, drawings).
const SKIP_ENVS = new Set([
  'equation', 'equation*', 'align', 'align*', 'alignat', 'alignat*', 'flalign', 'flalign*', 'gather', 'gather*',
  'multline', 'multline*', 'eqnarray', 'eqnarray*', 'displaymath', 'math', 'split', 'dmath', 'dmath*',
  'verbatim', 'verbatim*', 'Verbatim', 'lstlisting', 'minted', 'comment', 'alltt', 'tikzpicture', 'pgfpicture',
  'axis', 'algorithmic', 'algorithm2e', 'filecontents', 'filecontents*', 'thebibliography'
]);

function blank(chars: string[], from: number, to: number) {
  for (let i = from; i < to && i < chars.length; i += 1) if (chars[i] !== '\n') chars[i] = ' ';
}

/** Skips a balanced {…} or […] group starting at `i` (which must be the opening bracket); returns the index after it. */
function skipGroup(text: string, i: number, open: string, close: string) {
  let depth = 0;
  for (let j = i; j < text.length; j += 1) {
    const ch = text[j];
    if (ch === '\\') {
      j += 1;
      continue;
    }
    if (ch === open) depth += 1;
    else if (ch === close) {
      depth -= 1;
      if (depth === 0) return j + 1;
    }
  }
  return text.length;
}

function skipSpaces(text: string, i: number) {
  while (i < text.length && (text[i] === ' ' || text[i] === '\t')) i += 1;
  return i;
}

/** Returns `text` with everything that isn't natural-language prose replaced by spaces. */
export function maskLatex(text: string): string {
  const chars = text.split('');
  let i = 0;
  const n = text.length;
  while (i < n) {
    const ch = text[i];

    if (ch === '%') {
      const end = text.indexOf('\n', i);
      const stop = end === -1 ? n : end;
      blank(chars, i, stop);
      i = stop;
      continue;
    }

    if (ch === '$') {
      const display = text[i + 1] === '$';
      const closer = display ? '$$' : '$';
      let j = i + closer.length;
      while (j < n) {
        if (text[j] === '\\') {
          j += 2;
          continue;
        }
        if (text.startsWith(closer, j)) break;
        j += 1;
      }
      const stop = Math.min(n, j + closer.length);
      blank(chars, i, stop);
      i = stop;
      continue;
    }

    if (ch === '\\') {
      const next = text[i + 1];
      if (next === '(' || next === '[') {
        const closer = next === '(' ? '\\)' : '\\]';
        const end = text.indexOf(closer, i + 2);
        const stop = end === -1 ? n : end + 2;
        blank(chars, i, stop);
        i = stop;
        continue;
      }
      const nameMatch = /^[A-Za-z@]+\*?/.exec(text.slice(i + 1, i + 40));
      if (!nameMatch) {
        // Control symbol like \% \& \\ \, — blank the backslash and the symbol.
        blank(chars, i, Math.min(n, i + 2));
        i += 2;
        continue;
      }
      const name = nameMatch[0];
      const bare = name.replace(/\*$/, '');
      let j = i + 1 + name.length;

      if (bare === 'verb' || (bare === 'lstinline' && text[j] !== '{' && text[j] !== '[')) {
        const delim = text[j];
        const end = delim ? text.indexOf(delim, j + 1) : -1;
        const stop = end === -1 ? n : end + 1;
        blank(chars, i, stop);
        i = stop;
        continue;
      }

      if (bare === 'begin') {
        const k = skipSpaces(text, j);
        if (text[k] === '{') {
          const close = skipGroup(text, k, '{', '}');
          const env = text.slice(k + 1, close - 1).trim();
          if (SKIP_ENVS.has(env)) {
            const endTag = `\\end{${env}}`;
            const end = text.indexOf(endTag, close);
            const stop = end === -1 ? n : end + endTag.length;
            blank(chars, i, stop);
            i = stop;
            continue;
          }
          blank(chars, i, close);
          j = close;
          // Environment options / column specs: \begin{tabular}{lcr}, \begin{figure}[h]
          let p = skipSpaces(text, j);
          while (text[p] === '[' || (text[p] === '{' && /^(tabular|tabularx|array|minipage|wrapfigure|subfigure|multicols|tabu|longtable)\*?$/.test(env))) {
            const stop = text[p] === '[' ? skipGroup(text, p, '[', ']') : skipGroup(text, p, '{', '}');
            blank(chars, p, stop);
            j = stop;
            p = skipSpaces(text, j);
            if (text[p] === '{' && !/^(tabularx|minipage|wrapfigure|subfigure)$/.test(env)) break;
          }
          i = j;
          continue;
        }
      }

      blank(chars, i, j);
      const argCount = NON_PROSE_ARGS[bare];
      // Optional [..] arguments are never prose worth checking (placement, widths, keys).
      let p = skipSpaces(text, j);
      while (text[p] === '[') {
        const stop = skipGroup(text, p, '[', ']');
        blank(chars, p, stop);
        p = skipSpaces(text, stop);
        j = stop;
      }
      if (argCount) {
        let remaining = argCount;
        while (remaining > 0) {
          p = skipSpaces(text, j);
          if (text[p] !== '{') break;
          const stop = skipGroup(text, p, '{', '}');
          blank(chars, p, stop);
          j = stop;
          remaining -= 1;
          p = skipSpaces(text, j);
          while (text[p] === '[') {
            const s2 = skipGroup(text, p, '[', ']');
            blank(chars, p, s2);
            j = s2;
            p = skipSpaces(text, j);
          }
        }
      }
      i = j;
      continue;
    }

    if (ch === '{' || ch === '}' || ch === '~' || ch === '&' || ch === '^' || ch === '_' || ch === '#') {
      chars[i] = ' ';
    }
    i += 1;
  }
  let masked = chars.join('');
  for (const re of NON_PROSE_TOKENS) {
    masked = masked.replace(re, (m) => m.replace(/[^\n]/g, ' '));
  }
  return masked;
}

// ---------- ignore list and personal dictionary (kept in this browser) ----------

const IGNORE_KEY = 'maziar.spell.ignored';
const DICT_KEY = 'maziar.spell.dictionary';

function loadSet(key: string) {
  try {
    return new Set<string>(JSON.parse(localStorage.getItem(key) || '[]'));
  } catch {
    return new Set<string>();
  }
}

function saveSet(key: string, set: Set<string>) {
  try {
    localStorage.setItem(key, JSON.stringify([...set]));
  } catch {
    /* ignore */
  }
}

// ---------- spelling vocabulary (kept on the computer running Numenor; invited people's in their browser) ----------

let vocabulary = new Set<string>();
let vocabularyWords: string[] = [];
let vocabularyLoaded: Promise<void> | null = null;
const vocabularyListeners = new Set<() => void>();

function setVocabulary(words: string[]) {
  vocabularyWords = words;
  vocabulary = new Set(words.map((w) => w.toLowerCase()));
  vocabularyListeners.forEach((fn) => fn());
}

function ensureVocabulary() {
  if (!vocabularyLoaded) {
    vocabularyLoaded = getSpellVocabulary()
      .then((res) => setVocabulary(res.words))
      .catch(() => {});
  }
  return vocabularyLoaded;
}

/** Every word in the spelling vocabulary (this computer's list plus any kept in this browser). */
export function listVocabulary(): string[] {
  const local = [...loadSet(DICT_KEY)];
  const all = new Map<string, string>();
  [...vocabularyWords, ...local].forEach((w) => all.set(w.toLowerCase(), w));
  return [...all.values()].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
}

/** Calls `fn` whenever the vocabulary changes; returns an unsubscribe function. */
export function onVocabularyChange(fn: () => void) {
  vocabularyListeners.add(fn);
  ensureVocabulary();
  return () => {
    vocabularyListeners.delete(fn);
  };
}

/** Marks `word` as correct from now on, in every open file. */
export async function addToVocabulary(word: string) {
  try {
    const res = await addSpellWord(word);
    setVocabulary(res.words);
  } catch {
    // Invited people (or no server): keep it in this browser.
    const set = loadSet(DICT_KEY);
    set.add(word.toLowerCase());
    saveSet(DICT_KEY, set);
    vocabularyListeners.forEach((fn) => fn());
  }
}

export async function removeFromVocabulary(word: string) {
  const set = loadSet(DICT_KEY);
  if (set.delete(word.toLowerCase())) saveSet(DICT_KEY, set);
  try {
    const res = await removeSpellWord(word);
    setVocabulary(res.words);
  } catch {
    vocabularyListeners.forEach((fn) => fn());
  }
}

const ignoreKey = (issue: SpellIssue) => `${issue.kind}:${issue.kind === 'spelling' ? issue.word.toLowerCase() : `${issue.message}|${issue.word}`}`;

// ---------- CodeMirror extension ----------

export type SpellStatus = { checking: boolean; count: number; error?: string; issues?: SpellIssue[] };

type Options = {
  language: string;
  grammar: boolean;
  onStatus?: (status: SpellStatus) => void;
};

const setIssues = StateEffect.define<SpellIssue[]>();

const issueField = StateField.define<{ issues: SpellIssue[]; decorations: DecorationSet }>({
  create: () => ({ issues: [], decorations: Decoration.none }),
  update(value, tr) {
    let { issues, decorations } = value;
    if (tr.docChanged) {
      decorations = decorations.map(tr.changes);
      issues = issues
        .map((issue) => ({ ...issue, from: tr.changes.mapPos(issue.from, 1), to: tr.changes.mapPos(issue.to, -1) }))
        .filter((issue) => issue.to > issue.from);
    }
    for (const effect of tr.effects) {
      if (effect.is(setIssues)) {
        issues = effect.value;
        decorations = Decoration.set(
          issues
            .filter((issue) => issue.to <= tr.state.doc.length)
            .map((issue) => Decoration.mark({ class: `cm-maziar-${issue.kind}` }).range(issue.from, issue.to)),
          true
        );
      }
    }
    return { issues, decorations };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations)
});

function visibleIssues(issues: SpellIssue[]) {
  const ignored = loadSet(IGNORE_KEY);
  const dictionary = loadSet(DICT_KEY);
  return issues.filter((issue) => {
    if (ignored.has(ignoreKey(issue))) return false;
    if (issue.kind !== 'spelling') return true;
    const word = issue.word.toLowerCase();
    return !dictionary.has(word) && !vocabulary.has(word);
  });
}

export function spellExtension(options: Options): Extension {
  const checker = ViewPlugin.fromClass(
    class {
      timer: number | null = null;
      seq = 0;
      destroyed = false;
      unsubscribe: () => void;
      constructor(readonly view: EditorView) {
        this.schedule(300);
        // A word added to (or removed from) the vocabulary: hide it at once, then check again.
        this.unsubscribe = onVocabularyChange(() => {
          if (this.destroyed) return;
          refilter(this.view);
          this.schedule(400);
        });
      }
      update(update: ViewUpdate) {
        if (update.docChanged) this.schedule(900);
      }
      schedule(delay: number) {
        if (this.timer) window.clearTimeout(this.timer);
        this.timer = window.setTimeout(() => this.run(), delay);
      }
      async run() {
        this.timer = null;
        const seq = ++this.seq;
        const doc = this.view.state.doc.toString();
        if (doc.length > 400_000) {
          options.onStatus?.({ checking: false, count: 0, error: 'File too large to check.' });
          return;
        }
        options.onStatus?.({ checking: true, count: 0 });
        try {
          const { issues } = await spellCheck(maskLatex(doc), options.language, options.grammar);
          if (this.destroyed || seq !== this.seq || this.view.state.doc.toString() !== doc) return;
          const shown = visibleIssues(issues);
          this.view.dispatch({ effects: setIssues.of(shown) });
          options.onStatus?.({ checking: false, count: shown.length, issues: shown });
        } catch (err) {
          if (this.destroyed || seq !== this.seq) return;
          options.onStatus?.({ checking: false, count: 0, error: (err as Error).message });
        }
      }
      destroy() {
        this.destroyed = true;
        this.unsubscribe();
        if (this.timer) window.clearTimeout(this.timer);
        // Clear the underlines when checking is switched off or the language changes.
        const view = this.view;
        window.setTimeout(() => {
          try {
            view.dispatch({ effects: setIssues.of([]) });
          } catch {
            /* view destroyed */
          }
        }, 0);
      }
    }
  );

  const refilter = (view: EditorView) => {
    const current = view.state.field(issueField).issues;
    const shown = visibleIssues(current);
    view.dispatch({ effects: setIssues.of(shown) });
    options.onStatus?.({ checking: false, count: shown.length, issues: shown });
  };

  const tooltip = hoverTooltip((view, pos) => {
    const issue = view.state.field(issueField).issues.find((item) => pos >= item.from && pos <= item.to);
    if (!issue) return null;
    return {
      pos: issue.from,
      end: issue.to,
      above: true,
      create: () => {
        const dom = document.createElement('div');
        dom.className = `cm-maziar-spell-tip ${issue.kind}`;
        const title = document.createElement('div');
        title.className = 'tip-title';
        title.textContent = issue.kind === 'spelling' ? 'Spelling' : 'Grammar';
        const message = document.createElement('div');
        message.className = 'tip-message';
        message.textContent = issue.message;
        dom.append(title, message);
        if (issue.suggestions.length) {
          const list = document.createElement('div');
          list.className = 'tip-suggestions';
          issue.suggestions.forEach((suggestion) => {
            const button = document.createElement('button');
            button.textContent = suggestion;
            button.onmousedown = (event) => {
              event.preventDefault();
              const live = view.state.field(issueField).issues.find((item) => item.from === issue.from && item.word === issue.word) || issue;
              view.dispatch({ changes: { from: live.from, to: live.to, insert: suggestion } });
              view.dispatch({ effects: setIssues.of(view.state.field(issueField).issues.filter((item) => item !== live && !(item.from === live.from && item.word === live.word))) });
            };
            list.appendChild(button);
          });
          dom.appendChild(list);
        } else {
          const none = document.createElement('div');
          none.className = 'tip-none';
          none.textContent = 'No suggestions';
          dom.appendChild(none);
        }
        const actions = document.createElement('div');
        actions.className = 'tip-actions';
        const ignore = document.createElement('button');
        ignore.textContent = 'Ignore';
        ignore.title = 'Hide this suggestion from now on';
        ignore.onmousedown = (event) => {
          event.preventDefault();
          const set = loadSet(IGNORE_KEY);
          set.add(ignoreKey(issue));
          saveSet(IGNORE_KEY, set);
          refilter(view);
        };
        actions.appendChild(ignore);
        if (issue.kind === 'spelling') {
          const learn = document.createElement('button');
          learn.textContent = 'Add to vocabulary';
          learn.title = 'Treat this word as correct from now on';
          learn.onmousedown = (event) => {
            event.preventDefault();
            addToVocabulary(issue.word);
          };
          actions.appendChild(learn);
        }
        dom.appendChild(actions);
        return { dom };
      }
    };
  }, { hoverTime: 250 });

  // Right-click on an underlined word: suggestions, "Add to spelling vocabulary", "Ignore".
  const contextMenu = EditorView.domEventHandlers({
    contextmenu(event, view) {
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos == null) return false;
      const issue = view.state.field(issueField).issues.find((item) => pos >= item.from && pos <= item.to);
      if (!issue) return false;
      event.preventDefault();
      showIssueMenu(view, issue, event.clientX, event.clientY, () => refilter(view));
      return true;
    }
  });

  return [issueField, checker, tooltip, contextMenu];
}

function closeIssueMenu() {
  document.querySelectorAll('.cm-maziar-spell-menu').forEach((el) => el.remove());
}

function showIssueMenu(view: EditorView, issue: SpellIssue, x: number, y: number, refilterView: () => void) {
  closeIssueMenu();
  const menu = document.createElement('div');
  menu.className = 'cm-maziar-spell-menu';
  menu.setAttribute('role', 'menu');
  const add = (label: string, onPick: () => void, cls = '') => {
    const button = document.createElement('button');
    button.className = `cm-maziar-spell-menu-item ${cls}`;
    button.textContent = label;
    button.onmousedown = (event) => {
      event.preventDefault();
      close();
      onPick();
    };
    menu.appendChild(button);
  };
  const sep = () => {
    const line = document.createElement('div');
    line.className = 'cm-maziar-spell-menu-sep';
    menu.appendChild(line);
  };
  const head = document.createElement('div');
  head.className = 'cm-maziar-spell-menu-head';
  head.textContent = issue.kind === 'spelling' ? `“${issue.word}”` : issue.message;
  menu.appendChild(head);
  issue.suggestions.slice(0, 6).forEach((suggestion) =>
    add(suggestion, () => {
      const live = view.state.field(issueField).issues.find((item) => item.from === issue.from && item.word === issue.word) || issue;
      view.dispatch({ changes: { from: live.from, to: live.to, insert: suggestion } });
      view.focus();
    }, 'suggestion')
  );
  if (!issue.suggestions.length) {
    const none = document.createElement('div');
    none.className = 'cm-maziar-spell-menu-none';
    none.textContent = 'No suggestions';
    menu.appendChild(none);
  }
  sep();
  if (issue.kind === 'spelling') add('Add to spelling vocabulary', () => addToVocabulary(issue.word));
  add('Ignore', () => {
    const set = loadSet(IGNORE_KEY);
    set.add(ignoreKey(issue));
    saveSet(IGNORE_KEY, set);
    refilterView();
  });
  document.body.appendChild(menu);
  const rect = menu.getBoundingClientRect();
  menu.style.left = `${Math.max(6, Math.min(x, window.innerWidth - rect.width - 6))}px`;
  menu.style.top = `${Math.max(6, Math.min(y, window.innerHeight - rect.height - 6))}px`;

  const onDown = (event: MouseEvent) => {
    if (!menu.contains(event.target as Node)) close();
  };
  const onKey = (event: KeyboardEvent) => event.key === 'Escape' && close();
  function close() {
    menu.remove();
    window.removeEventListener('mousedown', onDown, true);
    window.removeEventListener('keydown', onKey, true);
    window.removeEventListener('blur', close);
  }
  window.setTimeout(() => {
    window.addEventListener('mousedown', onDown, true);
    window.addEventListener('keydown', onKey, true);
    window.addEventListener('blur', close);
  }, 0);
}

/** Forget all ignored suggestions (the dictionary is kept). */
export function resetIgnoredSuggestions() {
  saveSet(IGNORE_KEY, new Set());
}
