# Turn notifications

When a turn ends while the terminal is unfocused, the TUI writes an OSC 777
desktop notification followed by a bell. The terminal turns the sequence into
a notification through the desktop's notification server, and the bell lets
the window manager mark the window urgent. Because the sequence travels over
the TTY, a TUI attached over SSH still notifies the local desktop. Terminals
without OSC 777 support ignore it.

```text
title: albedo · fix flaky upload tests
body:  Done in 4m 12s · 18 tools — Root cause was the retry timer racing close
```

| Outcome | Body |
| --- | --- |
| Completed | `Done in <elapsed> · <n> tools — <first line of the final reply>` |
| Failed | `Failed after <elapsed> — <error>` |
| Interrupted | `Interrupted after <elapsed>` |

The title is the session name. The body is one line, because terminals drop
control characters inside an OSC string. The reply preview is the first
nonblank line without leading Markdown block marks (`#`, `>`, `*`, `-`, `+`) and
with `**`, `__` and backticks removed, cut to 100 cells.

A notification is sent only when:

- the terminal reports focus and is currently unfocused (a terminal that never
  reports focus never notifies);
- the turn ended live, through a completed, error or interrupted event or a
  status read that finds the session idle, not in replayed history or when
  your next message closes an unfinished turn;
- the turn took at least 10 seconds.

Set `ALBEDO_NOTIFY` before starting the client to change this:

| Value | Effect |
| --- | --- |
| unset, `on` | Notify with the reply preview. |
| `brief` | Notify without reply text; a failed turn still shows its error. |
| `off`, `0`, `false`, `no` | Never notify. |

Session names, replies and errors are untrusted: escape sequences and control
characters are removed, `;` (the OSC field separator) becomes `,`, and `&`, `<`
and `>` become the lookalikes `＆`, `‹` and `›`. Each text stays one field with
no markup characters. Entities are not an option: every entity ends in `;`,
which would split the field, and servers treat an unterminated `&lt`
differently (Plasma rewrites it, GNOME shows it literally, mako and dunst
reject the markup).

Inside tmux the OSC is wrapped for passthrough, which needs
`set -g allow-passthrough on`; the bell stays outside the wrapper for tmux's own
bell handling. Other multiplexers may swallow the sequence.

The icon and application name come from the terminal. The sequence carries no
urgency, actions or replacement ID, so each turn is a separate notification.

Regression tests cover the sequence format, outcomes, focus, duration, replay,
mode and sanitization rules, the status-read path and tmux wrapping. Both
package variants run them in the client check's single `go test` over
`internal/terminal` and `internal/tui`.
