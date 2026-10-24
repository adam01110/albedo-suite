# Vim composer editing

## Scope

Albedo implements a **Vim-style composer subset**, not an embedded Vim or Neovim.
It covers Normal/Insert modes, basic motions, delete/change/yank operators,
selected text objects, character finds, replacement, paste and undo/redo.
Visual mode, dot-repeat, macros, buffer search and Ex commands are absent.
There is no meaningful percentage of "full Vim" implemented; the tables below
list the supported surface rather than implying full compatibility.

This describes the suite source, including the latest Normal-mode startup and
literal-argument changes. An installed client needs those changes deployed before
it has that behavior; editing this repository does not update a running client.
Both suite packages include the same Vim support.

## Modes and application keys

New chat models start in `NORMAL`; press `i` to type. The footer shows `sessions`,
the current mode, then `commands`. The mode label is bold: `NORMAL` uses the
theme's cyan and `INSERT` its green (Base16 base0C/base0B when configured).
This edits only the unsent composer, never the transcript or already-submitted
messages.

| Key | Behavior |
| --- | --- |
| `Esc` in Insert mode | Enter Normal mode, including while an agent runs. An open command menu or transcript selection is dismissed first. |
| `Esc` in Normal mode | Cancel an unfinished count, operator or literal argument first. Otherwise interrupt a running/queued turn and restore cancelled queued input to the composer. |
| `i` / `a` | Insert at / after the cursor, including while an agent runs. |
| `I` / `A` | Insert at the first nonblank / end of the logical line. |
| `o` / `O` | Open one line below / above and enter Insert mode. |
| `/` in Normal mode | Enter Insert mode and insert `/` at the start of the draft for Albedo commands; **not** Vim search. |
| `Enter` | Submit using the existing composer rules, in either mode. |
| `Shift+Enter` | Insert a newline, in either mode. |

Arrows, transcript paging, control/Alt shortcuts, menus and external-editor
integration retain their application behavior. `Ctrl+r` in Normal mode is the
exception: it performs Vim-style redo. Unsupported unmodified Normal-mode keys
are generally consumed without inserting text; they do not invoke Vim features.

When interruption cancels queued messages, their text, images and collapsed pastes
return to an editable Insert-mode composer. Existing draft text stays first;
multiple cancelled messages follow in queue order, separated by newlines. Inputs
already delivered to the agent and newer uncancelled inputs are not restored.

## Navigation outside the composer

`j`/`k` also move through non-search pickers, page action menus and the folder
browser's session pane. In that pane, `h` returns to the folder query. Choice
menus and the effort selector accept `h`/`k` for previous and `l`/`j` for next.
The context detail reader uses `j`/`k` to scroll and `h`/`l` to change pages.
On the MCP transport row, `h`/`l` change transport and `j`/`k` move focus.

Live search and text-entry fields keep these letters as text, including session,
model and folder searches. Arrow keys remain available there.

## Motions

All the motions below work alone and with `d`, `c` or `y`, except where noted.

| Keys | Behavior |
| --- | --- |
| `h` / `l` | Move left / right within the logical line. |
| `j` / `k` | Move down / up by logical lines, not wrapped display rows. Operators use linewise ranges. |
| `w` / `b` / `e` | Next word start / previous word start / word end. |
| `0` / `^` / `$` | Line start / first nonblank / line end. |
| `gg` / `G` | First / last line; an explicit count selects a 1-based line number. Operators use linewise ranges. |
| `f{char}` / `F{char}` | Find the counted occurrence forward / backward on the current line. |
| `t{char}` / `T{char}` | Move just before / after a forward / backward character match. |
| `;` / `,` | Repeat the last successful character find in its original / opposite direction. |

Words distinguish whitespace, letters/digits/underscore and punctuation.
Uppercase `W`, `B` and `E` motions are **not** implemented, although `iW`/`aW`
text objects are. Character finds do not cross newlines or wrap around.

## Editing, registers and history

| Keys | Behavior |
| --- | --- |
| `d{motion}` / `c{motion}` / `y{motion}` | Delete / change / yank the motion's range. Change enters Insert mode. |
| `dd` / `cc` / `yy` | Delete / change / yank logical lines. |
| `D` / `C` | Delete / change from the cursor through the counted line end. |
| `x` / `X` | Delete characters at / before the cursor, within the line. |
| `r{char}` | Replace the counted characters without entering Insert mode; no change if too few remain on the line. |
| `p` / `P` | Paste after / before the cursor; linewise registers paste below / above. |
| `u` / `Ctrl+r` | Undo / redo composer changes, with counts. |

There is one composer-local register, populated by yank and deletion. It is not
Vim's named/numbered register system and is not the system clipboard. Application
clipboard shortcuts remain separate.

Undo stores up to 100 snapshots. An insertion or change and its following typed
text undo together after returning to Normal mode. Paste, external-editor results
and attachment edits also participate in composer history. Submission clears undo,
redo, pending input and the local register; none of these commands undo submission.
Deletion overlapping an attachment marker removes the entire marker to keep its
payload atomic.

## Text objects

Use `d`, `c` or `y`, followed by `i` (inner) or `a` (around), then an object key.
For example: `diw`, `ci"`, `ya(` and `d2iW`.

| Object keys | Inner / around range |
| --- | --- |
| `w` | Word / word with adjacent whitespace. |
| `W` | Whitespace-delimited WORD / WORD with adjacent whitespace. |
| `(`, `)`, `b` | Inside / including parentheses. |
| `[`, `]` | Inside / including square brackets. |
| `{`, `}`, `B` | Inside / including braces. |
| `<`, `>` | Inside / including angle brackets; not HTML/XML tag parsing. |
| Single quote, double quote, backtick | Inside / including a quoted pair on the current logical line. |

Word objects accept counts. Paired delimiters support nesting: a count selects
an enclosing outer pair, such as `d2a(`. Quote objects accept only a single pair;
counts greater than one do nothing. Delimiter matching is textual, not
language-aware, and does not provide all Vim text-object edge-case semantics.

## Counts and compatibility limits

- Counts work for motions, `d/c/y` operators, character deletion/replacement,
  register paste and undo/redo. Examples: `3w`, `2dd`, `d2w`, `2d3w`, `3fx`, `2p`.
  Operator and motion counts multiply; counts are capped at 999.
- `2G` and `2gg` select line 2. `2$` selects the next line's end. `0` without a
  preceding count is the line-start motion.
- Counts do **not** repeat inserted text or opened lines: `3i` is not Vim's
  repeated insertion, and `3o` still opens only one line.
- Cursor/range calculations use Unicode code points, not full grapheme-cluster
  semantics. Do not assume identical Vim behavior for combining characters.
- Normal-mode startup does not force a return to Normal after every submission;
  the current mode is retained.

## Not implemented

| Area | Examples of missing Vim features |
| --- | --- |
| Modes | Characterwise, linewise and blockwise Visual mode (`v`, `V`, `Ctrl+v`); Replace mode (`R`). |
| Repetition and automation | Dot-repeat (`.`), macro recording/playback (`q`, `@`), mappings and vimrc configuration. |
| Search | Buffer search (`/`, `?`, `n`, `N`, `*`, `#`), regular expressions and substitution. `/` is reserved for Albedo commands. |
| Other motions | `W/B/E`, `%`, `ge/gE`, paragraph/sentence motions, marks, jumps and Vim window/screen motions. |
| Other edits | `s/S`, `Y`, `J/gJ`, indentation (`>/<`), case operators (`~/gu/gU`), formatting and numeric increment/decrement. |
| Other text objects | Sentences, paragraphs, tags, Visual-mode objects and plugin-defined objects. |
| Registers | Named/numbered registers, black-hole register, register selection (`"a`), clipboard registers and register insertion. |
| Ex/editor features | `:` commands, file/buffer/window/tab management, folds, plugins and persistent Vim undo history. |

## Implementation and verification

- [Mode and prefix adapter](../src/client/cli/internal/tui/vim.go).
- [Pure motions and operator ranges](../src/client/cli/internal/tui/vim_motions.go).
- [Literal arguments and text objects](../src/client/cli/internal/tui/vim_arguments.go).
- [Editor actions](../src/client/cli/internal/tui/vim_commands.go).

The `TestVim*` regressions cover parser counts/cancellation, motions and operators,
literal arguments, text objects, undo/redo, attachment/input lifecycle and footer
rendering. Both client package check phases run
`go test ./internal/tui -run '^TestVim' -count=1 -v` against the overlaid pinned
upstream source. Tests establish the supported subset, not complete Vim parity.
