# Vim-first terminal interface

The workspace uses one navigation language, explicit input modes, and a visible
focus indicator. Conversation content stays primary; a single accent marks the
selected row. Existing list frames and terminal colors are reused instead of
adding a second widget system. Navigation changes focus or reveals content;
forms and destructive operations keep their existing validation and confirmation.

## Workspace and help

From chat or sessions, **F2** opens a searchable destination list. **Space** in
NORMAL does the same. **F1** opens the keyboard reference from any screen.
Closing either surface preserves the underlying screen, draft, attachments and
undo history. Streaming continues while it is open.

The workspace includes conversations, sessions, folders, providers, models,
agents, history, context, questions, settings and quota. Session commands that
advertise a page join the list. Choosing a destination opens its existing screen;
it does not bypass that screen's confirmation or form flow.

In composer NORMAL, `/` opens this independent launcher rather than inserting a
slash into an existing draft. In INSERT, slash commands and their existing
argument completion remain available.

## Lists

- NORMAL: `j`/`k` move, optionally preceded by a count (up to 999).
- `gg`/`G` go to the first/last row; `ctrl+u`/`ctrl+d` move half a page.
- `l` or Enter opens; `h`, `q` or Escape goes back. Model pickers use `h`/`l`
  for effort; folder pickers use them for parent/child folders.
- `/` explicitly enters SEARCH. All printable keys, including motions and
  digits, are literal there. Escape retains the filter and returns to NORMAL.
  Enter opens the highlighted search result. Paste enters SEARCH explicitly.
- Escape cancels an incomplete count or `g` chord before leaving the screen.

Session actions in NORMAL are `n` new, `r` rename, `p` pin, `a` archive/restore,
and `f` folders. In the archive, `x` (or `ctrl+x`) requests deletion and still
requires confirmation. `ctrl+d` is paging, not deletion.

On document pages, `a` opens the actions menu and `r` refreshes. Enter also opens
the menu, except on questions where it opens the answer flow. Use `j`/`k` and
`l`/Enter in the menu; `h`/Escape cancels. Existing non-conflicting control-key
action shortcuts remain available. Actions previously bound to `ctrl+d` or
`ctrl+u` remain in the menu; those chords now page through rows.

## Conversation focus

`ctrl+s` opens sessions directly from either focus, including INSERT, while
retaining the draft. The lowercase `compose` label sits on the separator above
the input; the footer keeps the editing mode instead of repeating that label.

The composer retains its existing Vim editing: insert commands, counted motions,
operators, text objects, find/till, yank/paste and undo/redo. Yanks also write to
the system clipboard through the existing local clipboard/OSC 52 transport;
linewise yanks include a final newline. The internal register remains available
for `p`/`P`. NORMAL motions act
on the composer regardless of whether its draft is empty.

**Tab in NORMAL** moves focus between composer and transcript without changing
the draft. The footer names both mode and focus, dropping secondary hints first
when space is limited. A rail cursor marks the selected transcript row.

In transcript focus:

- `j`/`k`, counts, `gg`/`G`, and `ctrl+u`/`ctrl+d` navigate rows. `G` resumes
  following the live response; ordinary navigation pauses following.
- `]`/`[` select the next/previous actionable row. Enter or `l` uses the same
  action as a click: reveal a fold, expand tool activity, copy a reply or open
  an artifact. Action selection follows its stable key across reflow.
- `y` copies the selected row; `o` opens its first file reference in the editor.
- `/` opens transcript FIND; Enter searches, `n`/`N` repeat in either direction.
  Escape closes FIND without changing the composer. Paste in FIND edits only
  its query; paste while browsing is ignored.
- `i`/`a`/`I`/`A` return to composer INSERT. Tab returns to composer NORMAL.
- `h` or `q` returns to sessions. Bare Escape retains the existing stop-response
  behavior; an incomplete motion/count consumes Escape locally first.

Shell cancellation is not activated by a generic transcript Enter. It retains
its explicit `ctrl+shift+x` chord. Mouse interactions remain supported.

## Agents and forms

Agents keep navigation separate from composing: `i` writes, Escape returns to
NORMAL while retaining the draft, and NORMAL Enter opens the selected agent
rather than sending retained text. INSERT Enter sends. The footer names the
mode and the current Enter action.

Text forms remain literal. Choice fields use `j`/`k` (and horizontal motions
where the choices are horizontal), Enter applies, and Escape cancels. Form
validation, revision guards, and destructive confirmations are unchanged.

## Verification

`vim_workspace_test.go` covers counted and nested list navigation, strict search,
draft/undo preservation, transcript action targeting and search, modal key
priority, owned launcher cancellation, archive deletion safety, terminal sizes,
and footer mode retention after shell activity. Existing Vim, question, context,
quota and input-layout tests run with it in the client checks.
