# Property-test discovery suites

These suites search for correctness bugs with generated inputs. `nix flake
check` runs all of them at small case counts, each printing the seed it used:
the server build's check phase runs every `*_prop` module beside the suite
tests (`PROPTEST_COUNT=20`), the client build runs every `TestProp*` test, and
the `python-properties` check runs the hypothesis files at their own defaults.
Run them longer with the commands below. Each confirmed bug has its own fix
change with a deterministic regression test, so the suites pass; opt-in checks
for open questions are listed under "Opt-in properties".

Only suite-owned behaviour is covered: upstream Albedo code, including upstream
lines inside files the suite replaces, is out of scope for these suites.

## Gleam and Erlang (server)

Build an overlay tree once. This is a heavy step:

```console
bash scripts/overlay-tree.sh server /tmp/albedo-overlay-server-<name>
```

Then run every `*_prop` module, or name the ones you want:

```console
PROPTEST_COUNT=200 [PROPTEST_SEED=n] scripts/proptest-server.sh /tmp/albedo-overlay-server-<name> [module...]
```

The script fetches qcheck and its dependencies from Hex at the sha256
checksums in `hex-packages.txt`, which the server check fetches too. It copies
them, together with `test/proptest/*`, into the tree's `test/` directory, so no
manifest changes. The Zed state machines run with
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
python3 test/proptest/calibrate.py           # planted-mutation calibration; not in the checks
python3 test/proptest_tooling_test.py        # updater and overlay models
python3 test/glob_translation_property_test.py
python3 -m unittest discover -s test -p escaping_sweep_test.py
python3 -m unittest discover -s test -p api_docs_property_test.py
PROPTEST_FIND_READ_LINES=1 python3 test/files_line_number_prop_test.py  # needs the FFF env from its docstring
```

The `python-properties` check in `nix/modules/checks.nix` sets the environment
these files need, and also runs the FFF, LSP, monitor, E2E runner and `files.check`
property files there. `glob_translation_property_test.py` needs Python 3.13 or
newer for its `pathlib` cross-check. Most files take their example counts from
their own `settings`; `PROPTEST_COUNT`, `PROPTEST_EXAMPLES`,
`GLOB_PROPERTY_EXAMPLES` and `ALBEDO_FFF_SCOPE_EXAMPLES` raise them where the
file reads one.

## Known upstream limitations

- Upstream's textarea `CursorUp` stalls on a soft-wrapped row that follows a
  wide rune, and upstream's `ChatModel.promptLines` walks the cursor up on every
  key, so such a composer stops answering. `TestPropVimHistories` therefore
  puts wide runes only in composers too wide to wrap.

## Opt-in properties

These checks stay off by default because they encode open questions, not
confirmed bugs:

- `PROPTEST_NEGATIVE_SHARE=1` for `TestPropZeroUsageShare` feeds negative
  counts, which the usage detail pane prints as a negative share.
- `PROPTEST_LIST_TOOL_CALLS=1` for `TestPropSummaryAndSessionAgree` expects
  list rows to carry `session_tool_calls`, which the server omits and the client
  drops.
