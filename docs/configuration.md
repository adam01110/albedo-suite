# Configuration

All options are under `programs.albedo`. Import
`albedo-suite.homeManagerModules.default`. You do not need an overlay.

## Providers

```nix
programs.albedo = {
  activeProvider = "main";
  providers.main = {
    extension = "codex";
    protocol = "responses";
    model = "YOUR_MODEL";
  };
};
```

Replace `YOUR_MODEL` with a model your provider supports. Albedo manages
authentication at runtime. Do not put tokens in these profiles.

The module leaves `config.json` untouched when no profiles are declared. When
you declare profiles, `activeProvider` must name one of them.

### OpenCode Go

A Home Manager profile for the upstream OpenCode Go provider:

```nix
programs.albedo = {
  activeProvider = "go";
  providers.go = {
    extension = "opencode-go";
    baseUrl = "https://opencode.ai/inference/go/v1";
    protocol = "chat_completions";
    model = "glm-5.2";
  };
};
```

The suite changes its protocol routing and Messages requests. Cached models.dev
per-model SDK metadata chooses the wire format before upstream's model-family
defaults, and Go's non-Claude Messages models do not receive Claude
adaptive-effort settings. Authentication stays in runtime credentials, not Nix.

## MCP servers

```nix
{lib, pkgs, ...}: {
  programs.albedo.mcp = {
    enable = true;
    lazy = true;
    servers.docs = {
      command = lib.getExe pkgs.context7-mcp;
      secretFiles.CONTEXT7_API_KEY = "/run/user/1000/secrets/context7";
    };
  };
}
```

Use your actual runtime secret path. `command` is an executable, not a shell
expression. Each server also accepts:

| Option | Default | Purpose |
| --- | --- | --- |
| `args` | `[]` | Argument array; no shell expansion |
| `environment` | `{}` | Public environment variables |
| `secretFiles` | `{}` | Environment variable names mapped to runtime secret paths |
| `runtimeInputs` | `[]` | Packages added to the server's PATH |
| `idleTimeoutMs` | `null` | Lazy idle timeout for this server; `null` uses `mcp.idleTimeoutMs`, `0` never closes it |
| `extraSettings` | `{}` | Additional upstream server fields |

**Secret paths must be strings, not Nix paths.** Never use `builtins.readFile`
on a credential or copy one into `/nix/store`. The launcher reads these files
only when the server starts. Secret variables override public environment
values.

Lazy mode defaults to true. [Lazy MCP](lazy-mcp.md) explains how to discover
and load servers and when they close.

## Formatting

```nix
{lib, pkgs, ...}: {
  programs.albedo.formatter = {
    enable = true;
    settings = {
      timeoutMs = 45000;
      treefmt = [(lib.getExe pkgs.treefmt)];
      nix = [(lib.getExe pkgs.nix)];
      formatters.alejandra.command = [(lib.getExe pkgs.alejandra)];
      chains.".nix" = ["alejandra"];
    };
  };
}
```

Configure the commands and file suffixes you need. The formatter uses project
treefmt configuration first, then `nix fmt`, then the suffix chains.

It tracks local `files.write` and `files.edit` calls. Format shell, standard
library Python and remote edits explicitly. [Explicit file checks](formatter.md)
explains file staging, retries and cancellation.

## LSP

Set `programs.albedo.lsp.enable = true` and declare servers under
`programs.albedo.lsp.settings`. The module merges these into the existing
extension settings document. [Local LSP](lsp.md) describes the temporary
compatibility layer, server fields and explicit diagnostics/navigation tools.
It neither starts servers at session setup nor adds a final-reply gate.

## Linters

Set `programs.albedo.linter.enable = true` and declare commands, output parsers
and file chains under `programs.albedo.linter.settings`. [Linters](linter.md)
describes the fields. Linting runs only inside `files.check()`, after
formatting.

## Other options

| Option | Default | Purpose |
| --- | --- | --- |
| `package` | Selected by `showDiffs` | Custom Albedo package |
| `finalPackage` | Wrapped `package` | Read-only package for launchers; includes `home` and `environment` |
| `showDiffs` | `false` | Select the package with diffs shown by default |
| `home` | `${config.xdg.dataHome}/albedo` | Absolute runtime directory |
| `environment` | `{}` | Public CLI variables, such as GNUPGHOME or JJ_CONFIG paths |
| `appendInstructions` | `null` | Source file installed as `~/.agents/APPEND_SYSTEM.md` |
| `settings` | `{}` | Raw extension JSON escape hatch |

Providers, settings, environment and instructions are visible in the Nix store.
Keep private values in runtime authentication or `secretFiles`, not these fields.
Raw `settings` bypasses the typed server checks. Apply the same secret
restrictions there. Enable MCP, formatting, linting and LSP through
`mcp.enable`, `formatter.enable`, `linter.enable` and `lsp.enable`, rather than
conflicting `settings.enabled` values.

## Applying changes

The activation helper acquires Albedo's daemon lock and validates the existing
JSON. It replaces each changed document atomically with permissions 0600.
Undeclared settings, profiles and authentication remain in the document.

The helper refuses to write while a daemon is running or settings recovery is
pending. It also refuses malformed JSON and legacy provider settings that
Albedo has not migrated.

The helper merges nested settings and keeps undeclared entries. Remove obsolete
servers or profiles from the runtime document explicitly. Disabling MCP or
formatting updates its enable bit.

Each document is atomic on its own. The extensions and provider documents do
not share a transaction. The module does not move or delete existing runtime
data.

## Skill preferences

For custom activation entries, `albedo-configure HOME DEFAULTS capabilities.json`
merges this document under the same daemon lock as the other settings. Defaults
use this shape:

```json
{"global": {"skills": {"research": false, "customize-albedo": true}}}
```

The helper preserves other choices and refuses invalid capability groups.

## Terminal colors

The CLI reads `$XDG_CONFIG_HOME/albedo/theme.json` (normally
`~/.config/albedo/theme.json`) before querying terminal colors. Set
`ALBEDO_THEME_FILE` to select another file. The JSON object must contain exactly
`base00` through `base0F`, with uppercase slot suffixes and `#RRGGBB` values.
Invalid files and missing explicitly selected files produce a startup error;
a missing default file preserves terminal autodetection.

With a file, colors use the Base16 palette directly rather than contrast-mixing
terminal replies. This covers transcript accents, effort indicators, pickers,
language/host labels, orchestrator identities and code highlighting. Diff panels
use base01; signs retain the red/green state colors. Footer key hints keep keys
in base05 rather than upstream's bold accent. Ordinary text and the canvas
still inherit the terminal foreground/background; configure the terminal with the
same theme. Truecolor support is required for exact RGB output. This setting does
not change the web UI. Restart the CLI to read a changed file; no daemon restart
is needed.

For Stylix, generate the JSON from `config.lib.stylix.colors.withHashtag` using
Home Manager's `xdg.configFile."albedo/theme.json".text`. The Infra integration
lives in `modules/programs/tui/albedo/theme.nix`. It sets
`programs.albedo.environment.ALBEDO_THEME_FILE` to the generated path. That module
requires a suite package containing this feature; the configuration alone does
not patch an older CLI.

## Terminal icons

The CLI reads `$XDG_CONFIG_HOME/albedo/icons.json` (normally
`~/.config/albedo/icons.json`) at startup. Set `ALBEDO_ICONS_FILE` to select
another file. The JSON object overrides any subset of the names below; omitted
names keep upstream's icon. Each value must be exactly one terminal cell wide,
because the layouts around it count one cell, so wide emoji, multi-character
strings, control characters and escape sequences are refused. Nerd Font glyphs
are one cell wide. Unknown names, invalid files and a missing explicitly
selected file produce a startup error; a missing default file keeps the
defaults. Restart the CLI to read a changed file.

| Name | Default | Where |
| --- | --- | --- |
| `brand` | `✦` | Screen titles and the chat header |
| `prompt` | `›` | Input prompt |
| `selection` | `▌` | Bar beside the selected row |
| `newSession`, `settings`, `archive`, `accounts` | `✦`, `◇`, `▤`, `◇` | Session list actions |
| `item`, `itemSelected`, `itemActive` | `·`, `◆`, `●` | Session and folder rows: idle, selected, recent or current |
| `itemEditing`, `itemPinned`, `itemMoved` | `✎`, `★`, `↗` | Session rows being renamed, pinned or moved |
| `callSucceeded`, `callFailed`, `callPending` | `✓`, `✗`, `·` | Tool call outcomes in tool cards |
| `hostConnected`, `hostConnecting`, `hostLost` | `●`, `◌`, `○` | Kernel host in the chat header |
| `bookmark`, `branch` | `⚑`, `⎇` | Folder picker jj bookmarks and Git branches |
| `agentYou`, `agentRunning`, `agentPulse` | `◆`, `●`, `◉` | `/agents` graph: you, a running agent and its pulse |
| `agentDone`, `agentIdle`, `agentPeer` | `✓`, `○`, `◇` | `/agents` graph: closed, idle and peer agents |

```json
{"brand": "\uf135", "branch": "\ue725", "callFailed": "\uf00d"}
```

Box drawing, rules, key-hint arrows, gauges and ellipses are structure rather
than icons and stay fixed. This setting does not change the web UI.

With Home Manager, set `programs.albedo.icons`. The module writes the JSON to
the Nix store and sets `programs.albedo.environment.ALBEDO_ICONS_FILE` to it:

```nix
programs.albedo.icons = {
  brand = "*";
  callFailed = "x";
};
```

The option checks only that values are strings; the CLI checks names and widths
at startup, so a bad entry fails when the CLI starts, not at build time.
