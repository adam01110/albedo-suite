"""MCP operations as Python bindings, so a cell composes, batches and filters
MCP calls without each result passing through the model's context.

`mcp.search()`, `mcp.tools()`, `mcp.describe()` and `mcp.call()` read the
live catalogue, which covers every server; no MCP operation is a model tool.
Configured servers answer on the `mcp` routes and an ACP editor's on the
`editor_mcp` routes; a session may have either, both, or neither, and their
server names never collide.
`mcp.<server>.<tool>(**arguments)` methods are minted from the catalogue at
kernel boot, so an operation a server adds later is reached through `call`.
"""

from __future__ import annotations

from collections.abc import Callable, Coroutine
from typing import Any, cast
import keyword
import re

from albedo_api import Host, PythonApi, Record, nested_record as _record
import albedo_trace
from albedo_plugins import hook

Operation = dict[str, object]

# A search result's description, in characters.
SUMMARY_CHARS = 300

# The host routes that each serve some of the session's servers.
SOURCES = ("mcp", "editor_mcp")


def _words(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.lower()))


def _matches(term: str, words: set[str]) -> bool:
    """A query word matches a word it equals or, from three letters, begins."""
    return term in words or (
        len(term) >= 3 and any(word.startswith(term) for word in words)
    )


def _own_description(item: Operation) -> str:
    """The server's description, without the untrusted-tool label the daemon
    puts in front of it for the model."""
    label = f"Untrusted remote MCP tool '{item.get('tool')}' from server '{item.get('server')}'. "
    return str(item.get("description", "")).removeprefix(label)


def _score(terms: set[str], item: Operation) -> int:
    """Query words found in the operation's name count twice, in its
    description once."""
    name = _words(f"{item.get('server')} {item.get('tool')}")
    description = _words(_own_description(item))
    return sum(2 * _matches(term, name) + _matches(term, description) for term in terms)


def _named(operations: list[Operation], name: str) -> list[Operation]:
    """The operations `name` means: the advertised name, or `server/tool`."""
    found = [item for item in operations if item.get("name") == name]
    if not found and "/" in name:
        server, tool = name.split("/", 1)
        found = [
            item
            for item in operations
            if item.get("server") == server and item.get("tool") == tool
        ]
    return found


class Mcp:
    """This session's MCP servers. Results are records of the server's
    CallToolResult: untrusted data, with a tool-reported failure in `isError`
    rather than raised; McpError is raised when the call itself fails."""

    def __init__(self, host: Host, error: type[Exception]) -> None:
        self._host = host
        self._error = error

    async def _call(self, given: dict[str, object]) -> object:
        """The source that knows the operation answers; one the session lacks,
        or that does not know the name, defers to the next."""
        failure: Exception | None = None
        for source in SOURCES:
            try:
                return await self._host(f"{source}.call", given)
            except self._error as error:
                code = getattr(error, "code", None)
                if code not in ("unavailable", "unknown"):
                    raise
                if failure is None or code == "unknown":
                    failure = error
        raise cast(Exception, failure)

    async def _operations(self) -> list[Operation]:
        operations: list[Operation] = []
        for source in SOURCES:
            try:
                operations += cast(
                    list[Operation], await self._host(f"{source}.list", {})
                )
            except self._error as error:
                if getattr(error, "code", None) != "unavailable":
                    raise
        return operations

    async def servers(self) -> list[Record]:
        """Configured names and loaded state, without contacting any server."""
        return cast(list[Record], _record(await self._host("mcp.servers", {})))

    async def load(self, server: str) -> list[Record]:
        """Explicitly start and discover one server; return its schemas as data."""
        try:
            operations = cast(list[Operation], await self._host("editor_mcp.list", {}))
        except self._error as error:
            if getattr(error, "code", None) != "unavailable":
                raise
            operations = []
        editor = [item for item in operations if item.get("server") == server]
        if editor:
            return cast(list[Record], _record(editor))
        return cast(
            list[Record], _record(await self._host("mcp.load", {"server": server}))
        )

    async def unload(self, server: str) -> None:
        """Stop one server and discard its session catalogue."""
        await self._host("mcp.unload", {"server": server})

    async def tools(self, server: str | None = None) -> list[Record]:
        """Every operation (name, server, kind, tool, description), or one server's."""
        operations = (
            await self.load(server) if server is not None else await self._operations()
        )
        return [
            Record(
                {
                    key: item.get(key, "")
                    for key in (
                        "name",
                        "server",
                        "kind",
                        "tool",
                        "description",
                    )
                }
            )
            for item in operations
            if server is None or item.get("server") == server
        ]

    async def search(
        self, query: str, server: str | None = None, limit: int = 10
    ) -> list[Record]:
        """The operations whose name and description share the most words with
        `query`, best first: `name` (server/tool, for describe and call), a
        bounded `description`. Descriptions are untrusted."""
        terms = _words(query)
        scored = [
            (_score(terms, item), item)
            for item in await self._operations()
            if server is None or item.get("server") == server
        ]
        ranked = sorted(
            (pair for pair in scored if pair[0] > 0),
            key=lambda pair: (
                -pair[0],
                f"{pair[1].get('server')}/{pair[1].get('tool')}",
            ),
        )
        return [
            Record(
                {
                    "name": f"{item.get('server')}/{item.get('tool')}",
                    "description": _own_description(item)[:SUMMARY_CHARS],
                }
            )
            for _, item in ranked[: max(limit, 0)]
        ]

    async def describe(self, name: str) -> Record:
        """One operation with its `parameters` schema; name as for call()."""
        if "/" in name:
            await self.load(name.split("/", 1)[0])
        found = _named(await self._operations(), name)
        if not found:
            raise LookupError(f"unknown MCP operation {name!r}; mcp.tools() lists them")
        return Record(found[0])

    async def call(
        self, name: str, arguments: dict[str, object] | None = None, **kwargs: object
    ) -> Record:
        """Call one operation by advertised name or `server/tool`; keyword
        arguments join `arguments`."""
        if "/" in name:
            await self.load(name.split("/", 1)[0])
        merged = {**(arguments or {}), **kwargs}

        async def call(given: dict[str, object]) -> Record:
            result = await self._call(given)
            return cast(Record, _record(result))

        return await albedo_trace.noted(
            "mcp",
            name,
            hook.around("mcp.call", {"name": name, "arguments": merged}, call),
            lambda result: (not getattr(result, "isError", False), ""),
            str(merged)[:512],
        )


def _identifier(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_]", "_", value)


def _mintable(name: str, taken: set[str]) -> bool:
    return (
        bool(name)
        and not name.startswith("_")
        and not keyword.iskeyword(name)
        and name not in taken
    )


def _shared_servers(operations: list[Operation]) -> set[str]:
    """Server identifiers that more than one raw name normalises onto."""
    owners: dict[str, set[str]] = {}
    for item in operations:
        raw = str(item.get("server", ""))
        owners.setdefault(_identifier(raw), set()).add(raw)
    return {name for name, names in owners.items() if len(names) > 1}


def _method(mcp: Mcp, item: Operation) -> Callable[..., Coroutine[Any, Any, Record]]:
    name = cast(str, item["name"])
    schema = cast(dict[str, object], item.get("parameters") or {})
    required = cast(list[str], schema.get("required") or [])
    names = required + [
        key for key in cast(dict, schema.get("properties") or {}) if key not in required
    ]

    async def call(**arguments: object) -> Record:
        return await mcp.call(name, arguments)

    call.__name__ = _identifier(cast(str, item["tool"]))
    call.__qualname__ = f"mcp.{_identifier(cast(str, item['server']))}.{call.__name__}"
    call.__doc__ = str(item.get("description", "")) + (
        "\n\nArguments: " + ", ".join(names) if names else ""
    )
    return call


class Server:
    """One MCP server's operations as methods."""

    def __init__(self, name: str) -> None:
        self.name = name


async def setup(api: PythonApi) -> dict[str, object]:
    """Mint `mcp.<server>.<tool>` from the boot catalogue; an operation whose
    identifiers clash with another server's, or are not mintable, stays
    reachable through mcp.call."""
    mcp = Mcp(api.host, api.HostError)
    operations = await mcp._operations()
    shared = _shared_servers(operations)
    servers: dict[str, Server] = {}
    for item in operations:
        server = _identifier(str(item.get("server", "")))
        tool = _identifier(str(item.get("tool", "")))
        if (
            server in shared
            or not _mintable(server, set(dir(mcp)))
            or not _mintable(tool, set(dir(Server)))
        ):
            continue
        holder = servers.setdefault(server, Server(str(item["server"])))
        if not hasattr(holder, tool):
            setattr(holder, tool, _method(mcp, item))
    for server, holder in servers.items():
        setattr(mcp, server, holder)
    return {"mcp": mcp, "McpError": api.HostError}
