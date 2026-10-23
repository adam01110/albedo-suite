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

Select **OpenCode Go** in the first-startup or `/login` provider chooser to
enter an API key, or use `/login opencode-go` for native OpenCode Console device
OAuth. The default base URL is `https://opencode.ai/inference/go/v1`, not the
pay-as-you-go Zen URL. Existing `https://opencode.ai/zen/go/v1` profiles remain
supported. `OPENCODE_GO_API_KEY` and `OPENCODE_API_KEY` are also supported when
the profile has no saved key.

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

Use bare API model IDs, not OpenCode's `opencode-go/` prefix. The saved protocol
is a compatibility field; the server selects the wire format per model:
Chat Completions for GLM/Kimi/MiMo/DeepSeek/Qwen, Messages for MiniMax M2.7/Claude,
Responses for GPT/Grok/Muse Spark, and Gemini for Gemini models. Cached
models.dev per-model
SDK metadata takes precedence over the documented routing defaults. `/model`
can switch between these formats within one profile; native portable Chat
Completions replay keeps history compatible across routes.

The picker discovers IDs from Go's `/models` endpoint and uses models.dev for
limits and modalities. Discovery caches are endpoint-specific, refresh after an
hour, and survive failed fetches. `/reload models` forces discovery refresh and
reports failures. Authentication stays in runtime credentials, not Nix.
Claude-only beta headers and context-management fields are not sent to Go's
Messages endpoint; its non-Claude models do not receive Claude adaptive-effort
settings. Native account/key rotation tries sibling Go credentials on limits, without
rotating to paid Zen. OAuth organization headers and refresh remain native.

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
| `extraSettings` | `{}` | Additional upstream server fields |

**Secret paths must be strings, not Nix paths.** Never use `builtins.readFile`
on a credential or copy one into `/nix/store`. The launcher reads these files
only when the server starts. Secret variables override public environment
values.

Lazy mode defaults to true. [Lazy MCP](lazy-mcp.md) explains how to discover,
load and unload servers.

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
library Python and remote edits explicitly. [Deferred formatting](formatter.md)
explains file staging, retries and cancellation.

## LSP

Set `programs.albedo.lsp.enable = true` and declare servers under
`programs.albedo.lsp.settings`. The module merges these into the existing
extension settings document. [Local LSP](lsp.md) describes the temporary
compatibility layer, server fields and explicit diagnostics/navigation tools.
It neither starts servers at session setup nor adds a final-reply gate.

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
restrictions there. Enable MCP and formatting through `mcp.enable` and
`formatter.enable`, rather than conflicting `settings.enabled` values.

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

Skills can be enabled or disabled through global choices in `capabilities.json`.
These are separate from extension settings. A personal skill with the same name
replaces a bundled skill after activation and `/reload session`.

For custom activation entries, `albedo-configure HOME DEFAULTS capabilities.json`
merges this document under the same daemon lock as the other settings. Defaults
use this shape:

```json
{"global": {"skills": {"research": false, "customize-albedo": true}}}
```

The helper preserves other choices and refuses invalid capability groups.
Session-specific overrides still take precedence over global choices.

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
use base01; signs retain the red/green state colors. Ordinary text and the canvas
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
