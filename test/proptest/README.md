# Property-test discovery suites

These suites search for correctness bugs with generated inputs. They are not
wired into the package checks, except the Zed Erlang suite, which is fast. Each
confirmed bug has its own fix change based on `main`, with a deterministic
regression test. This stack merges those fixes, so the suites should pass. The
exceptions are listed under "Known red properties".

Only suite-owned behaviour is covered: upstream Albedo code, including upstream
lines inside files the suite replaces, is out of scope for these suites.

## Gleam and Erlang (server)

Build an overlay tree once. This is a heavy step, so hold the shared CPU lock:

```console
flock /home/adam0/Projects/albedo-suite/.workspaces/loops/cpu.lock \
  bash scripts/overlay-tree.sh server /tmp/albedo-overlay-server-<name>
```

Then run every `*_prop` module, or name the ones you want:

```console
PROPTEST_COUNT=200 [PROPTEST_SEED=n] scripts/proptest-server.sh /tmp/albedo-overlay-server-<name> [module...]
```

The script fetches qcheck and its dependencies from Hex at pinned sha256
checksums. It copies them, together with `test/proptest/*`, into the tree's
`test/` directory, so no manifest changes. The Zed state machines run with
`<tree>/shell gleam run -m suite_zed_prop_test`, from
`<tree>/source/apps/albedo` after copying `test/albedo_zed_prop.erl` and
`test/suite_zed_prop_test.gleam` there.

## Go (client)

```console
bash scripts/overlay-tree.sh sync client /tmp/albedo-overlay-client-<name>
<tree>/shell go -C cli test ./internal/tui ./internal/daemon ./internal/terminal \
  ./internal/config ./internal/app ./internal/cli -run '^TestProp' -count=1
```

Environment knobs: `VIM_PROP_CASES`, `VIM_PROP_SEED`, `VIM_PARITY=1`,
`BH_PROP_CASES` and `USAGE_PROP_CASES`. The client renderer is built from
`cli/vendor/charm.land/bubbletea/v2/cursed_renderer.go`, and `sync` does not
refresh that file. Mutate it there when calibrating. `sync` also leaves test
files from earlier changes in the tree, so delete them when you switch changes.

## Python

Run these with a Python that has hypothesis, for example
`nix build --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [p.hypothesis])'`.
Set `PYTHONPATH` and `ALBEDO_PYTHON_SOURCE` to a writable copy of upstream
`python/` with `src/server/python` copied over it:

```console
python3 test/proptest_scripts_test.py        # also set ALBEDO_UPDATER, ALBEDO_MONITOR_SOURCE, ALBEDO_E2E_RUNNER as checks.nix does
python3 test/proptest/py_lsp_formatter_rtk.py
python3 test/proptest/calibrate.py           # planted-mutation calibration
python3 test/proptest_tooling_test.py        # updater and overlay models
python3 test/glob_translation_property_test.py
python3 -m unittest discover -s test -p escaping_sweep_test.py
python3 -m unittest test/api_docs_property_test.py
PROPTEST_FIND_READ_LINES=1 python3 test/files_line_number_prop_test.py  # needs the FFF env from its docstring
```

## Known red properties

These are open questions, not confirmed bugs:

- `lazy_mcp_prop` can fail when two servers first load in the same second.
  `loads.list` then orders them by name, while its docstring says load order.
- `PROPTEST_NEGATIVE_SHARE=1` for `TestPropZeroUsageShare` feeds negative
  counts, which the usage detail pane prints as a negative share.
- `PROPTEST_LIST_TOOL_CALLS=1` for `TestPropSummaryAndSessionAgree` expects
  list rows to carry `session_tool_calls`, which the server omits and the client
  drops.
