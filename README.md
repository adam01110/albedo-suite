<!-- rumdl-disable MD033 MD041 -->

<div align="center">

# albedo-suite

Extensions and Nix integration for [Albedo](https://tangled.org/okami.mom/albedo).

[![Nix](https://img.shields.io/badge/Nix-flake-fe8019?style=flat-square&labelColor=504945&logo=nixos&logoColor=ebdbb2)](https://nixos.org)

[What it changes](#what-it-changes) · [Usage](#usage) · [Development](#development)

</div>

This repo holds the Albedo code used by my Nix configuration. Personal settings,
providers, skills and SOPS declarations stay in Infra.

> [!WARNING]
> This repository is almost entirely AI-generated, and I rarely review it. It
> exists as glue for my own Albedo setup, not as a standalone project. I do not
> provide support for it or accept responsibility for its use.

## What it changes

| Component | Behavior |
| --- | --- |
| [Lazy MCP](docs/lazy-mcp.md) | Connect to a server when explicitly requested, rather than at session startup. |
| [Explicit file checks](docs/formatter.md) | Format tracked files and collect diagnostics in one `files.check()` call. |
| [Local LSP](docs/lsp.md) | Start a language server on an explicit diagnostics or navigation call. |
| [User questions](docs/questions.md) | Answer durable questions inline or through `/questions` and resume the asking session. |
| [Monitor snapshots](docs/monitor.md) | Export running-agent status and cached connected-account quotas without starting the daemon. |
| [RTK and FFF](docs/tool-parity.md) | Filter supported commands through RTK and replace file search with FFF. |
| [Zed provider](docs/zed.md) | Native hosted-model streaming with tool choice, thinking, effort and usage. |
| [Provider availability](docs/provider-availability.md) | Disable or re-enable saved profiles with Ctrl+T in `/login`. |
| CLI resume | `albedo resume` without an ID reopens the newest non-archived session in the current directory. |
| [Vim editing](docs/vim.md) | Modal composer motions and edits, with the current mode in the footer. |
| [TUI activity](docs/activity-sidebar.md) | Show passive current and recent tool activity below background jobs. |
| [Image previews](docs/tool-images.md) | Display attachments and tool-returned images in supported terminals. |
| [Prompt context](docs/prompt-context.md) | Keep startup references compact and retrieve full API docs explicitly. |
| CLI diffs | Show diffs by default when enabled. The existing toggle still works. |
| Home Manager | Install Albedo and merge settings while preserving runtime authentication. |

MCP, formatting and LSP are disabled until configured. The suite supplies no personal
provider profiles or server list.

Formatting and LSP are temporary compatibility layers, not a long-term fork
API. Keep them isolated and remove them when upstream covers the needed behavior.
[Retiring these layers](docs/development.md#temporary-compatibility-layers) lists
what to remove.

## Usage

Add the flake input using a local checkout:

```nix
inputs.albedo-suite = {
  url = "git+file:///absolute/path/to/albedo-suite?ref=main";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import the module into Home Manager:

```nix
{inputs, ...}: {
  imports = [inputs.albedo-suite.homeManagerModules.default];

  programs.albedo = {
    enable = true;
    showDiffs = true;
  };
}
```

The runtime directory defaults to `~/.local/share/albedo`. The module does not
move existing data. Stop the daemon before activation. The settings helper
refuses to write while it is running.

[Configuration](docs/configuration.md) covers providers, MCP credentials,
formatter commands and other options. The helper merges settings into the
existing documents. Removing an entry from Nix does not delete its runtime copy.

## Development

```console
nix build .#albedo-defaults
nix flake check
nix fmt
```

`albedo-defaults` shows diffs by default. `albedo-patched` keeps upstream's diff
default. Home Manager selects the package through `showDiffs`, which defaults
to false. Both packages include the server changes.

Edit the files under `src/` directly. There are no patch files. NUR supplies the
pinned upstream build, and checksum checks reject changed upstream files before
the suite copies its replacements into that build.

[Development details](docs/development.md) cover checks, daemon tests and the
upstream updater. Read the [maintenance guide](docs/agent-maintenance.md) before
changing suite behavior or updating upstream.

## License

This repository is licensed under the [GNU Affero General Public License v3.0
only with the Classpath exception](LICENSE), matching upstream Albedo. The
exception permits linking independent modules under their own licenses.
[The source notices](THIRD_PARTY_NOTICES.md) and `LICENSES/` retain upstream
attribution, historical MPL obligations and separately licensed components.
[Source instructions](docs/package-sources.md) cover distribution and remote
network source obligations.
