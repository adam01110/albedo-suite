# Smaller, cache-stable agent context

The suite reduces startup reference prose without changing provider cache keys,
request history, tool schemas, compaction policy or executable capabilities.
The selected instructions and tool schemas stay fixed during ordinary turns.
Reading documentation adds an ordinary tool result to the end of history; it
never expands or replaces an earlier system-prompt block.

## API references

The startup prompt keeps short discovery and lifecycle guidance for agents,
remote execution, browser automation, mail, scheduling and paperclips. Complete
original extension instructions are available through:

```python
print(await api_docs.catalog())
print(await api_docs.read("remote"))
```

Read the reference before first use or when uncertain. Retrieval returns the
complete text, not a model-generated summary. Only active contributions appear;
a disabled or failed extension is not enabled by reading documentation. The
same binding works from a remote Python kernel. Core execution, files,
verification and other extension instructions remain inline. Unknown/custom
extensions retain their instructions unchanged.

If the documentation module or route would collide with an existing capability,
the suite falls back to the original inline instructions rather than breaking
that capability or advertising an unavailable retrieval API.

## Skills and memory

Skill descriptions appear once in the skills catalog. Printed skill pages
show readable content and source/encoding, plus continuation information when
truncated; dictionary fields and JSON serialization remain unchanged.

The memory startup block is an explicitly incomplete topic index: up to 12
recent paragraphs per workspace, using at most 120 characters of each first
line, within a shared 1600-character topic budget. Each workspace has a heading,
the current workspace first, then linked sources. Searches still cover full
notes; no memory is deleted or rewritten by indexing.

## MCP discovery

Lazy MCP startup context includes only eligible server names and user-configured
`description` metadata. No connection, credential lookup or remote tool-catalog
fetch is needed to choose a server. Loading and idle cleanup keep this context
snapshot unchanged; schemas remain explicit tool results. See [lazy MCP](lazy-mcp.md)
for configuration and reload behavior.

## Context reader

The CLI `/context` reader opens sections in a formatted view: Markdown headings,
lists and code blocks use the chat renderer; complete JSON objects and arrays
are indented; extension wrapper tags stay visible. Long generated instruction
lines have paragraph spacing, and formatted text wraps at at most 100 columns.

A section reads as one document. The daemon still serves bounded pages; the
reader shows the first as soon as it arrives and appends the rest as they
stream in, so a page boundary no longer splits the view. Formatting a long
section whole takes seconds, so it is formatted in chunks cut at blank lines
outside code fences, only as far as you have scrolled; `end` formats the rest.
Arrows scroll, `pgup`/`pgdn` and space jump a screen, and `home`/`end` (or
`g`/`G`) go to either end. The header shows the source, byte count, view and
how far down the section you are.

Press `r` to toggle between formatted and raw views. Raw view shows the original
text with terminal-width wrapping, not Markdown rendering or JSON changes.
Switching views resets the scroll to the start. Formatting is local to the CLI
and never changes the prepared request, its byte counts or the model's context.

Above the section list, a bar shows how the request fills its window:
instructions, tools and conversation in their own colors, free space in grey,
and the reserve past the compaction trigger in a muted yellow. The legend
under it gives each part's tokens and share. The total is the request's
measured or estimated size; parts are split from it by section bytes, so their
counts are approximate.

The daemon keeps a running turn's snapshot when the turn's idle kernel is
released while it waits on the model, so `/context` stays ready mid-turn. A
resting session without a composition, as after a daemon restart, prepares one
without a kernel to rebuild its last request; the inspector reads a pending
snapshot again every second until it is ready. A session that has sent nothing
yet shows a preview of its first request: the instructions and tools that will
be sent, without the conversation.

## Verification boundary

Regression tests compare successive fake-provider requests byte-for-byte for
instructions and tool schemas and verify that earlier input items remain an
unchanged prefix after documentation reads and memory writes. They also test
full reference retrieval, remote access, omitted-memory recall, skill paging
and activation, and capability-collision fallback. These checks establish
prefix stability and API behavior, not a measured provider cache hit rate,
billing reduction or model task-success benchmark.
