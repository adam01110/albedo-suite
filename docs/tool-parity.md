# Pi tool parity

RTK and FFF are intentionally not added to the Albedo suite.

Albedo retains raw command output outside model context and exposes bounded
`job.head()` / `job.tail()` previews plus paginated `output.read()` access. Its
file helpers return bounded ripgrep results with explicit truncation. This
already addresses excessive tool output without changing the executed command,
exit status or retained diagnostics. RTK adds command-specific semantic
compression, but Pi's shell-command rewrite hook does not fit Albedo's exact
argument-vector execution. No automatic RTK rewrite is needed here.

FFF adds fuzzy/frecency ranking and a persistent watched file index. Albedo
already offers ignore-aware content and path searches through `files.find()`
and `files.paths()`, including remote targets. There is no demonstrated need
for ranked fuzzy navigation that justifies an additional native index and
Python/Node bridge. The `fff` package in nixpkgs is an unrelated terminal file
manager, not the `@ff-labs/fff-node` search engine used by Pi's FFF extension.

These are not claims that bounded previews implement RTK's semantic filters,
or that ripgrep implements FFF's ranking. They are overlapping use cases with
no current reason to add the extra integrations.
