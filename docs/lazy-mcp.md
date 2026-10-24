# Lazy MCP

Set `programs.albedo.mcp.lazy = true` to defer connections until requested.
The Home Manager option defaults to true. Without Home Manager, Albedo keeps
upstream eager discovery when `mcp.lazy` is absent or false in `extensions.json`.

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
snapshot; loading and unloading do not rewrite it. Use a session reload or new
session to pick up changed settings. Metadata is discovery data, not instructions
or permission to execute tools.

Use the Python API to discover and load servers:

```python
# Names, descriptions and state; no connections.
await mcp.servers()
await mcp.tools()                           # List already-loaded operations.
await mcp.tools("docs")                     # Load docs and return tool summaries.
await mcp.load("docs")                      # Load docs and return full definitions.
await mcp.describe("docs/search")           # Load if needed and return one schema.
await mcp.call("docs/search", query="Nix")   # Load if needed and call once.
await mcp.unload("docs")                    # Stop docs and discard its catalogue.
```

Loading a server does not add its tool definitions to subsequent model requests.
The model receives descriptions and schemas only as results of the Python
operations it requests. Existing tool filters, credential handling, transport
restrictions and timeouts still apply. Disabled servers and servers excluded by
capability selection cannot load.

## Connections and failures

Home Manager defaults `programs.albedo.mcp.idleTimeoutMs` to 60000 (60 seconds).
In lazy mode, idle transports close automatically while their schemas remain
loaded. `mcp.servers()` reports `loaded` and `connected` separately. Reading
catalogues does not keep a connection alive. Explicit load or call reconnects
an idle transport before use, without replaying the operation. If rediscovery
changes the catalogue, that first use is refused before dispatch; read the new
schemas explicitly before calling again. Unexpected transport death reports
`connected = false` and requires unload/load, rather than hidden reconnection.

Set the timeout to zero to disable cleanup. Without Home Manager, configure
`mcp.idleTimeoutMs` in `extensions.json`; it defaults to zero. The timeout is
lazy-mode-only and accepts integer milliseconds from zero to 3600000.
Unload discards both connection and catalogue. A session reload starts empty.

Lazy mode does not probe or reconnect servers in the background. Retry a failed
load explicitly. If a connection drops unexpectedly (rather than idle cleanup),
unload and load it again.
Albedo never replays failed or interrupted calls. Check their effects before
retrying.

One manager runs load, call and unload operations sequentially within a session.
Concurrent first loads start one client. Unload cannot interrupt a dispatched
call, but MCP calls in that session do not run in parallel. The limit is 512
loaded operations across servers.

Queued requests belong to their requesting Erlang process. If it dies before
execution, the manager discards the request without loading, calling or unloading
a server. Calls also check ownership immediately before transport dispatch, so
caller death during an idle reconnect prevents the pending operation. Reconnection
already in progress may finish and retain its catalogue. Closing the session is
cleanup and still runs if its requester dies. Once dispatched, caller death does
not undo or replay an operation; its effects may be unknown. Inspect effects
before retrying.

## Tests and configuration validation

`test/lazy_mcp_python_test.py` checks the Python API with a fake host.
`test/fixtures/native/lazy_mcp_native_tests.erl` checks native state and lifecycle
with stub modules. `test/lazy_mcp_test.py` uses the packaged daemon and local
stdio fixtures.

`scripts/test-e2e.py` prepares the cases and fixtures and runs them with the
supplied binaries. It also runs upstream's eager compatibility cases. All
fixtures use temporary homes.

The `/mcp` save form still validates connections eagerly. Use Nix definitions,
or the settings API with `validate_connection: false`, if saving configuration
must not start a server. Lazy mode does not alter this explicit validation.
