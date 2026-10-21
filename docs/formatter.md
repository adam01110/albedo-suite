# Deferred formatting

This is a temporary compatibility layer. Keep it optional and remove it when
upstream provides a suitable tracked-file formatting lifecycle. See the
[retirement notes](development.md#temporary-compatibility-layers).

Enable formatting with `programs.albedo.formatter.enable` and supply commands
through `programs.albedo.formatter.settings`. The suite supplies no formatter
commands by default.

## Before the final reply

After a successful local `files.write` or `files.edit` call, the formatter records
a hash and file identity. It does not run a command yet.

When the model returns a response without tool calls, Albedo holds the assistant
text and calls the loaded extensions' `Managed.before_final` hooks. Reasoning
and tool progress still stream. The assistant text is committed only after the
hooks accept it. Sessions without a loaded acceptance hook stream as before.

The formatter uses project treefmt configuration first, then a configured
`nix fmt` command, then suffix chains. Project targets use one temporary shadow
workspace per gate, with tracked files at their original relative paths.
Directories along tracked paths are real staging directories; other entries are
read-through symlinks to the original project context. This preserves sibling
config imports without traversing dependency trees or copying the whole workspace.
Direct treefmt receives the shadow workspace as its explicit tree root, preserving
exact includes/excludes without interpreting its glob syntax here. Nix evaluates
the flake from the original project directory; its formatter receives the shadow
target and a subprocess-only `TREEFMT_WORKING_DIR` pointing to the shadow root.
This also supports treefmt-nix wrappers using `--tree-root-file=flake.nix` without
conflicting root options. Wrappers hardcoding an absolute original tree root or
ignoring supplied file paths are incompatible with staged project formatting.
Suffix chains retain
temporary sibling staging. Commands receive only explicit tracked paths; only
those files can be published, not every dirty file in version control. Successful
exclusions and already formatted files are valid no-ops.

Before replacing an original, the formatter checks its contents and identity
again. Replacement is atomic and preserves file mode. Commands must respect
the supplied file paths. This mechanism does not sandbox project commands.

A failed command returns a bounded diagnostic to the model for repair. If a
command changes a file, Albedo also discards the attempted final reply. The
model must review the changed file and write a new reply. Three rejected replies
end the turn with an explicit failure.

## Limits

- Only local `files.write` and `files.edit` calls are tracked. Format shell,
  standard library Python, remote and outside-workspace edits explicitly.
- Reports made while background cells or jobs run defer the check until later.
- Without a project formatter, file types with no configured chain are ignored.
- The tracker holds at most 1024 pending paths. Files must be at most 16 MiB.
  Exceeding the path limit fails the check rather than dropping entries.
- The formatter refuses concurrent changes and symlink escapes. It leaves
  unrelated dirty files alone.
- Shadow context is bounded to 20,000 immediate entries along tracked paths;
  exceeding that limit fails the gate explicitly. Sibling directory trees such
  as `.direnv` and `node_modules` are linked, never traversed. Context is not a
  sandbox: commands can read original configuration and must respect explicit
  staged target paths, not rewrite other project files through context links.
  Tracked targets themselves are regular staged copies and symlink replacements
  are rejected before publishing.
- Commands share a 45-second budget. Output is bounded. Cancellation kills and
  reaps the process group before removing the staged files.
- Tracking lives in the Python process and does not survive a kernel or daemon
  restart. Finish formatting before deliberately restarting with pending edits.

## Tests

`test/formatter_python_test.py` checks staging, command arguments, limits,
timeouts, cancellation and concurrent edits with child processes.
`test/formatter_e2e_test.py` checks live events, rejected replies, repair,
retry limits, both provider protocols and streaming with formatting disabled.

For unit tests, set `ALBEDO_FORMATTER_SOURCE` to the integrated `priv/python`
directory. `scripts/test-e2e.py` copies the daemon cases and fixture files into
a writable pinned-source tree. The tests do not use your Albedo home, live
providers or MCP credentials.
