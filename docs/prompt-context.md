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

Skill descriptions appear once in the skills catalog. The command catalog keeps
their slash names, usage and exact typed-method mapping. Full catalog metadata,
activation, arguments and resource paging are unchanged. Printed skill pages
show readable content and source/encoding, plus continuation information when
truncated; dictionary fields and JSON serialization remain unchanged.

The memory startup block is an explicitly incomplete topic index: up to 12
recent paragraphs per workspace, using at most 120 characters of each first
line, within a shared 1600-character topic budget. Workspace headings identify
linked sources. `memory.search()` and `memory.grep()` still search full notes
and journals across linked workspaces; `memory.read(max_chars=...)` reads the
current workspace's notes. No memory is deleted or rewritten by indexing.
Required instructions still belong in instruction files, never in memory.

Memory writes do not regenerate a running session's startup block. Explicit
reloads, capability changes, compaction and normal upstream cache expiration
retain their existing behavior. Adopting changed startup instructions can
require a new cache fill; this change does not reload existing sessions or
activate a package automatically.

## MCP discovery

Lazy MCP startup context includes only eligible server names and user-configured
`description` metadata. No connection, credential lookup or remote tool-catalog
fetch is needed to choose a server. Loading and unloading keep this context
snapshot unchanged; schemas remain explicit tool results. See [lazy MCP](lazy-mcp.md)
for configuration and reload behavior.

## Context reader

The CLI `/context` reader opens sections in a formatted view: Markdown headings,
lists and code blocks use the chat renderer; complete JSON objects and arrays
are indented; extension wrapper tags stay visible. Long generated instruction
lines have paragraph spacing, and formatted text wraps at at most 100 columns.

Press `r` to toggle between formatted and raw views. Raw view shows the original
page text with terminal-width wrapping, not Markdown rendering or JSON changes.
The header identifies the current view. Switching views resets the scroll to the
start of the current page; arrow/hjkl navigation and page jumps are unchanged.
Formatting is local to the CLI and never changes the prepared request, its byte
counts or the model's context. Pages remain bounded; incomplete JSON at a page
boundary stays literal rather than being reconstructed.

## Verification boundary

Regression tests compare successive fake-provider requests byte-for-byte for
instructions and tool schemas and verify that earlier input items remain an
unchanged prefix after documentation reads and memory writes. They also test
full reference retrieval, remote access, omitted-memory recall, skill paging
and activation, and capability-collision fallback. These checks establish
prefix stability and API behavior, not a measured provider cache hit rate,
billing reduction or model task-success benchmark.
