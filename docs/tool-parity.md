# RTK and FFF

The suite replaces relevant command output handling with RTK and file search
with FFF. These are required runtime dependencies, not optional extensions.
Reads, exact edits, directory listings, job supervision, cancellation and output
storage remain Albedo APIs.

## Command execution

Supported terminal `run()` commands (verified Cargo, Go, Git, pytest, ls, rg
and wc invocations) execute through RTK's argument-vector CLI,
without evaluating a shell string. Unsupported invocations retain ordinary
execution. Explicit executable paths preserve their identity rather than being
replaced by a different executable that RTK resolves by name. Toolchain/global
selectors, unsupported flags and machine-readable output flags (`--json`,
`--null`, `-0`, `-z`, `--null-data`, `--message-format*`, `--porcelain*`)
remain unfiltered; other structured modes such as `go test -json` are routed.
Supplied `stdin` keeps a command unrouted, except `rg`, which RTK reads stdin for.
`src/server/python/albedo_rtk.py` holds the supported subcommand grammar.
Internal protocol jobs bypass RTK so JSON and transport streams are not
compressed.

Public job arguments, command labels, traces and completion notices identify the
requested command; routing stays private and is not part of agent instructions.
The job retains executed arguments internally. Job previews, pagination
and saved output retain the **RTK-filtered stream**, not the original child's
stdout. RTK may change child verbosity and omit details; its recall mechanism
is command-specific and is not a substitute for guaranteed native raw capture.
Exit status, timeout and process-group cleanup remain supervised.

Pipeline producers run without semantic filtering so downstream commands receive
original data. Attach a pipe before launch; attaching one after an RTK-routed
producer starts fails rather than rerunning the command. Supported invocations
require RTK on the execution host and fail visibly when it is missing.
Degraded SSH mode refuses supported commands because it cannot verify remote
RTK resolution; normal remote Python kernels use their own runtime dependencies.

## File search

`files.find()` and `files.paths()` use the pinned `@ff-labs/fff-node` engine,
not ripgrep or a Python scan fallback. Ordinary `files.paths(query)` searches
rank fuzzy filename matches; wildcard patterns and `glob=` retain exact,
case-sensitive glob filtering. No additional public search tool is added. The compatibility layer
preserves bounded rows, matching-line objects,
context and exact glob searches. The worker is daemon-owned and shared per host;
Python sessions call `files.fff` RPC, and the daemon uses the worker's private
stdin/stdout JSON protocol (`--stdio`). There is no Unix-socket fallback or
per-kernel worker. Each worker caches at most four root indexes. Search refreshes
the index before returning results; the worker does not trust watcher updates
alone. Workers start on demand and exit after 60 seconds without a search.
Requests, including queue time, have a 30-second worker deadline. Tests shorten
both with `ALBEDO_FFF_IDLE_MS` and `ALBEDO_FFF_CALL_DEADLINE_MS`, from 100 ms up
to the default, and the registry's `albedo_fff:search/5` takes an explicit
timeout; production keeps the defaults. Closing one session does not stop
another session's worker; workers are not session background jobs.

FFF cannot include hidden or ignored files in its index. `hidden=True` and
`ignored=True` are explicit errors, not quiet empty results. Unsupported search
semantics likewise fail visibly. Remote search requires the FFF worker on the
remote execution host; a missing dependency does not fall back to native search.
IPC uses a versioned protocol so incompatible remote workers fail explicitly.
Search limits are
1-10000 matches, up to 50 context lines, with explicit response-size budgets.

`files.find()` reports lines in `files.read()` numbering: every row's line
number and text are the ones `read(path, start_line=N, end_line=N)` shows, and
`context=N` counts read lines. FFF splits files on `\n` alone, while `read`
also ends lines at `\r`, `\v`, `\f`, `\x1c`-`\x1e`, `\x85`, U+2028 and
U+2029 (CRLF is one boundary). FFF still finds the matching files and lines;
the plugin then rescans each file with a hit once, stopping after the last
hit's context and counting past regions far from any hit without splitting
them. A hit FFF line that holds several read lines reports each read line the
match is in: literal patterns compare exactly (ASCII case folding for
`case_sensitive=False`), regular expressions use Python's `re` as an
approximation of FFF's engine, and when neither identifies a line, the first
read line of the FFF line is reported. The comparison sees at most 1 MiB of
each read line. A file that cannot be reopened keeps FFF's own numbering.

## Packaging and updates

`albedo-defaults` and `albedo-patched` put RTK and `albedo-fff` on the daemon's
PATH. `albedo-fff` packages FFF 0.11.0, ffi-rs 1.3.7, Node and the platform-native
libraries with fixed artifact hashes. It supports x86_64-linux and aarch64-linux;
the nixpkgs `fff` terminal file manager is unrelated.

RTK support is deliberately an explicit verified argument grammar, not blind
`rtk rewrite` shell-text evaluation. Update that grammar and integration tests
when changing RTK. The upstream checksum gate also covers replaced run/files
modules and their tool instructions. An Albedo update must merge upstream
changes before refreshing those checksums.

Broad path listings materialize 1000 native metadata records before applying
the requested result cap. Smaller native pages change FFF tie ordering; the
fixed page size preserves stable prefixes.
