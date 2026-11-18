# Lazy MCP

Set `programs.albedo.mcp.lazy = true` to defer connections until requested.
The Home Manager option defaults to true. Without Home Manager, Albedo keeps
upstream eager discovery when `mcp.lazy` is absent or false in `extensions.json`.
Upstream now exposes MCP operations only through Python in either mode; eager
startup context lists operation names, not remote schemas or descriptions.

## Discovering and using servers

In lazy mode, session preparation checks configuration and capabilities. It does
not read server credentials, consult cached catalogues or contact servers.
Initial model context lists eligible server names and locally configured
`description` strings, like the skills catalog. Use the description to state
what the server does and when it should load. Descriptions are optional
(default empty), limited to 1024 UTF-8 bytes, and public: never put secrets in
them. Disabled and capability-excluded servers are omitted. Remote tool schemas,
resources and prompts are not fetched or injected.

Home Manager:

```nix
programs.albedo.mcp.servers.docs = {
  command = "/path/to/docs-mcp";
  description = "Retrieve API docs. Load for version-specific coding questions.";
};
```

Without Home Manager, set `mcp.servers.<name>.description` in `extensions.json`
for either stdio or HTTP servers. The lazy context catalog is a preparation-time
snapshot; loading and idle cleanup do not rewrite it. Use a session reload or new
session to pick up changed settings. Metadata is discovery data, not instructions
or permission to execute tools.

Use the Python API to discover and load servers:

```python
# Names, descriptions and state; no connections.
await mcp.servers()
await mcp.tools()                           # List already-loaded operations.
await mcp.search("API docs", limit=5)        # Rank loaded operations without connecting.
await mcp.tools("docs")                     # Load docs and return tool summaries.
await mcp.load("docs")                      # Load docs and return full definitions.
await mcp.describe("docs/search")           # Load if needed and return one schema.
await mcp.call("docs/search", query="Nix")   # Load if needed and call once.
```

There is no `unload`: servers close through their idle timeout, and a session
reload or close stops every server.

ACP editor servers share the native `mcp` Python binding through separate
`editor_mcp` routes. Listing, searching, describing and calling editor operations
does not load a configured server. Their lifecycle remains owned by the editor;
`servers()` and `load()` manage configured servers only.

Loading a server does not add its tool definitions to subsequent model requests.
The model receives descriptions and schemas only as results of the Python
operations it requests. Existing tool filters, credential handling, transport
restrictions and timeouts still apply. Disabled servers and servers excluded by
capability selection cannot load.

## Connections and failures

Home Manager defaults `programs.albedo.mcp.idleTimeoutMs` to 60000 (60 seconds).
Each server may set its own `idleTimeoutMs`, which overrides the default; use
`0` for servers that hold state in their process, such as an open document, so
they stay connected until the session closes or reloads:

```nix
programs.albedo.mcp.servers.slides = {
  command = "/path/to/slides-mcp";
  idleTimeoutMs = 0;
};
```

In lazy mode, idle transports close automatically while their schemas remain
loaded. Closing a transport stops the server process, so anything it held in
memory is lost. `mcp.servers()` reports `loaded` and `connected` separately.
Reading catalogues does not keep a connection alive, and `describe()` or `call()`
on an already-loaded operation does not reload its server. A call reconnects an
idle transport before use, without replaying the operation. If rediscovery
changes the catalogue, that first use is refused before dispatch; read the new
schemas explicitly before calling again. Unexpected transport death reports
`connected = false`; calls are refused until an explicit `mcp.load(server)`
reconnects it, so no call silently reaches a fresh server.

The chat sidebar lists the session's MCP servers in a `mcp` glance under
`skills`, in the order they were first loaded: loaded servers are active, and
servers loaded before a session reload stay listed as unloaded. Rows persist
with the session (table `mcp_loads`) and move with it. Eager mode records
nothing.

Set a timeout to zero to disable cleanup. Without Home Manager, configure
`mcp.idleTimeoutMs` and `mcp.servers.<name>.idleTimeoutMs` in
`extensions.json`; the default is zero. Timeouts are lazy-mode-only and accept
integer milliseconds from zero to 3600000. A session reload starts empty.

Lazy mode does not probe or reconnect servers in the background. Retry a failed
load explicitly. If a connection drops unexpectedly (rather than idle cleanup),
load it again.
Albedo never replays failed or interrupted calls. Check their effects before
retrying.

One manager runs load and call operations sequentially within a session.
Concurrent first loads start one client. Idle cleanup cannot interrupt a
dispatched call, and MCP calls in that session do not run in parallel. The limit is 512
loaded operations across servers.

Queued requests belong to their requesting Erlang process. If it dies before
execution, the manager discards the request without loading or calling a
server. Calls also check ownership immediately before transport dispatch, so
caller death during an idle reconnect prevents the pending operation. Reconnection
already in progress may finish and retain its catalogue. Closing the session is
cleanup and still runs if its requester dies. Once dispatched, caller death does
not undo or replay an operation; its effects may be unknown. Inspect effects
before retrying.

## Tests and configuration validation

`test/lazy_mcp_python_test.py` checks the Python API with a fake host.
`test/suite_lazy_mcp_test.gleam` checks the manager's state and lifecycle
(`src/server/extensions/mcp/src/albedo_ext_mcp/lazy.gleam`) against upstream's
fake stdio server. `test/lazy_mcp_test.py` uses the packaged daemon and local
stdio fixtures.

`scripts/test-e2e.py` prepares the cases and fixtures and runs them with the
supplied binaries. It also runs upstream's eager compatibility cases. All
fixtures use temporary homes.

The `/mcp` save form still validates connections eagerly. Use Nix definitions,
or the settings API with `validate_connection: false`, if saving configuration
must not start a server. Lazy mode does not alter this explicit validation.
