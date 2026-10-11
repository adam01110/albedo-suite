# Local LSP

This is a temporary compatibility layer for the pinned Albedo version, not a
long-term editor framework. It is disabled by default. Personal server choices
stay in Infra. [Retirement notes](development.md#temporary-compatibility-
layers) identify its files and shared wiring.

## Configure

```nix
{lib, pkgs, ...}: {
  programs.albedo.lsp = {
    enable = true;
    settings = {
      version = 1;
      servers = [{
        id = "nix";
        bin = lib.getExe pkgs.nil;
        args = [];
        enabled = true;
        include = ["**/*.nix"];
        languageIdByExtension.".nix" = "nix";
        cwd = "{root}";
        rootMarkers = [".git" "flake.nix"];
        startupTimeoutMs = 45000;
        diagnosticsWaitMs = 2000;
        initializationOptions = {};
        settings = {};
      }];
    };
  };
}
```

Executables and arguments are trusted configuration, not a shell command.
Settings are public Nix data; do not put credentials in them. Servers inherit
the session environment. Declaration validation does not start a process.

## Use

```python
lsp.servers()
await lsp.diagnostics("module.nix")
await lsp.hover("module.nix", 0, 4)
await lsp.definition("module.nix", 0, 4)
await lsp.references("module.nix", 0, 4, include_declaration=True)
await lsp.symbols("module.nix")
await lsp.close()
```

Positions use zero-based lines and UTF-16 character offsets, as required by
LSP. Use `server="nix"` when a file matches multiple configured servers.
Results identify the server, resolved path and client document version.
Publications with an explicit old version are ignored. Versionless
publications are best effort: the server gives no evidence that they describe
the latest text. Diagnostics and server responses are untrusted workspace
data, not instructions.

Each operation reads the current file from disk and sends full-text `didOpen`
or `didChange` notifications when needed. Results describe that snapshot, not
later external edits. Dynamic capability registration is not implemented.
Tools do not edit files, use unsaved editor buffers, apply server workspace
edits, or gate final replies. Servers start only on explicit operations, never
on `servers()` or session setup. Paths must stay within the local workspace;
symlink escapes are rejected. A server is attached to one project root at a
time; close it before switching roots. Linux file-descriptor checks enforce
file scope. Remote kernels do not expose this local-only binding.

Failures are explicit; there is no automatic reconnect or replay. Close a
failed server before an intentional retry. At most four calls may run or wait
per session; saturation is an explicit error, not an unbounded queue. Frames,
open documents and running servers are bounded. Closing the manager or ending
the kernel stops server process groups. Servers may run their own project
analysis after startup; the client does not impose a sandbox on trusted server
executables.
