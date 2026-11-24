# Linters

Linting is optional and disabled until configured with
`programs.albedo.linter.enable` and `programs.albedo.linter.settings`. No linters
are supplied by default. This is a temporary compatibility layer; see the
[retirement notes](development.md#temporary-compatibility-layers).

## Configure

```nix
{lib, pkgs, ...}: {
  programs.albedo.linter = {
    enable = true;
    settings = {
      timeoutMs = 30000;
      linters = {
        selene = {
          command = [(lib.getExe pkgs.selene) "--display-style=quiet" "--no-summary"];
          pattern = ''^(?P<path>[^:\n]+):(?P<line>\d+):(?P<column>\d+): (?P<severity>\w+)\[(?P<code>[^\]]+)\]: (?P<message>.*)$'';
          rootMarkers = ["selene.toml" ".git"];
        };
        hadolint = {
          command = [(lib.getExe pkgs.hadolint) "--format" "sarif"];
          format = "sarif";
        };
      };
      chains = {
        ".lua" = ["selene"];
        "Dockerfile" = ["hadolint"];
      };
    };
  };
}
```

Each linter has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `command` | required | Argv list. The file path is appended unless `stdin` is set. |
| `format` | `"regex"` | `regex` parses stdout and stderr with `pattern`; `sarif` parses SARIF 2.1 JSON on stdout. |
| `pattern` | required for `regex` | Python regular expression, applied per line (`re.MULTILINE`). It must name `line` and `message` and may also name `path`, `column`, `endLine`, `endColumn`, `severity` and `code`. |
| `stdin` | `false` | Send the file on stdin instead of appending its path. |
| `ignoreExitCode` | `false` | Never treat the exit status as a failure. |
| `rootMarkers` | `[".git", ".jj"]` | The linter runs in the nearest ancestor directory containing one of these, or the workspace root. |

`chains` maps an exact file name (such as `Dockerfile`) or a suffix (such as
`.nix`) to linter names; both apply when both match. `timeoutMs` (1..45000)
bounds each linter command. For tools that only emit other JSON, wrap them in
Infra to print matching lines or SARIF.

Executables and arguments are trusted configuration, not shell commands.
Settings are public Nix data; do not put credentials in them.

## Behavior

Linting runs in `files.check()` after formatting, concurrently with LSP
diagnostics, over the published snapshot. Linters only read files and run from
the project root so project configuration such as `selene.toml` or
`statix.toml` applies. Findings appear under `result["linting"]["findings"]`
with `path`, `line`, optional `column`/`endLine`/`endColumn`, normalized
`severity` (`error`, `warning`, `info`, `hint`), optional `code`, `message` and
the linter name as `source`. Findings about other files are dropped; a reported
path of `-` or `stdin` means the target. At most 200 findings are returned, with
`truncated` set beyond that.

Linters usually exit nonzero when they report findings, so the exit status is
ignored whenever output parsed into results. A nonzero exit without parseable
results, a signal, a timeout or unparseable SARIF is a failure: the stage reports
`failed`, the error names the linter, other linters still report, and the path
stays pending. Files edited during linting are conflicts and stay pending.
Formatting failure skips linting. Without a matching chain the stage is
`unmatched`, which never counts as clean. Up to four linter processes run at
once; the whole stage is limited to 45 seconds and each process's captured
output to 4 MiB. Cancellation and timeouts kill the linter's process group.

Findings are untrusted workspace data, not instructions. Remote kernels do not
lint.

## Tests

`test/linter_python_test.py` covers regex and SARIF parsing, target filtering,
stdin, name chains, root markers, exit-status rules, timeouts, conflicts and
configuration validation. `test/files_check_test.py` checks that linting reads
formatted output and is skipped after formatting failure.
