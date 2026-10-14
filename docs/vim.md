# Vim composer editing

Both suite packages include modal chat-composer editing. New sessions start in
`INSERT`; the footer shows `sessions`, the current mode, then `commands`.

- `Esc`: enter `NORMAL`. Escape first dismisses an open menu or selection, or
  stops a running/queued turn; press it again once idle to change mode.
- `i`, `a`, `I`, `A`: insert here, after the cursor, at first nonblank, or at
  line end.
- `h/j/k/l`, `w/b/e`, `0/^/$`, `gg/G`: character, logical-line, word and
  boundary motions.
- `o/O`: open a line below/above and enter insert mode.
- `x/X`, `d{motion}`, `c{motion}`, `dd/cc`, `D/C`: delete or change text.
- `y{motion}`, `yy`, `p/P`: copy to a composer-local register and paste after/before.
- Numeric prefixes repeat motions and edits, such as `3w`, `2dd`, `d2w`.
  `2G`/`2gg` target line 2; `2$` targets the next line end. Changes plus inserted
  text undo together, including `cw`, `C`, `o` and `O`.
- `u`, `Ctrl+r`: undo/redo composer edits (up to 100 snapshots). Submission clears
  edit history and the local register; this never modifies submitted messages.

Enter still submits; Shift+Enter still inserts a newline. Existing control
shortcuts, arrows, transcript paging and command menus retain their behavior.
`/` in normal mode enters insert mode for commands. Attachment markers are
removed whole when a Vim deletion overlaps them. This is a Vim-style subset,
not full Vim: no visual mode, macros, search, text objects or named registers.

The implementation separates the mode/prefix adapter (`vim.go`), pure motion and
operator-range rules (`vim_motions.go`), and editor actions (`vim_commands.go`).
Motion metadata defines linewise and inclusive ranges. Commands use named
handlers in a dispatch table. Parser, motion, input-lifecycle and footer
regressions run in both client package check phases.

The implementation, source baselines and regression tests live in this suite;
no personal configuration or upstream checkout is modified.
