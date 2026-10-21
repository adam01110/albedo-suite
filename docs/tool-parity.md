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
selectors, machine-readable output and unsupported flags remain unfiltered.
Internal protocol jobs bypass RTK so JSON and transport streams are not
compressed.

The job records both requested and executed arguments. Job previews, pagination
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
rank fuzzy filename matches; wildcard patterns and `glob=` retain exact glob
filtering. No additional public search tool is added. The compatibility layer
preserves bounded rows, matching-line objects,
context and exact glob searches. The worker is daemon-owned and shared per host;
Python sessions call `files.fff` RPC, and the daemon uses the worker's private
stdin/stdout JSON protocol (`--stdio`). There is no Unix-socket fallback or
per-kernel worker. Each worker caches at most four root indexes. Search refreshes
the index before returning results; the worker does not trust watcher updates
alone.

FFF cannot include hidden or ignored files in its index. `hidden=True` and
`ignored=True` are explicit errors, not quiet empty results. Unsupported search
semantics likewise fail visibly. Remote search requires the FFF worker on the
remote execution host; a missing dependency does not fall back to native search.
IPC uses a versioned protocol so incompatible remote workers fail explicitly.
Search limits are
1-10000 matches, up to 50 context lines, with explicit response-size budgets.

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

The motivating benchmark found RTK retained three failure messages in 728 bytes,
where a 924-byte native tail retained two. FFF exact/content searches were faster
on a warm 1500-file synthetic corpus, but excluded bridge and refresh overhead.
Those results establish different capabilities, not production-wide speedups.

A packaged Python-adapter check on the same 1500-file corpus included IPC and
refresh overhead (11 requests, median of the last 10, 100-result cap): exact
search 3.0 ms versus native 8.6 ms; content search 2.3 ms versus native 10.7 ms.
The first exact search took 68 ms. Unfiltered paths took 54 ms versus native
9.4 ms; fuzzy search took 57 ms with no equivalent native operation. Broad
listings still materialize 1000 native metadata records: smaller pages change
FFF tie ordering, so the suite retains the fixed page size for stable prefixes.
