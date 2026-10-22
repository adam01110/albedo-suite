"""Full, session-scoped extension instructions without startup prompt duplication."""

from typing import cast

from albedo_api import Host, PythonApi, Text


class ApiDocs:
    def __init__(self, host: Host):
        self._host = host

    async def catalog(self) -> list[str]:
        """List active documentation topics without enabling any capability."""
        return cast(list[str], await self._host("api_docs.catalog", {}))

    async def read(self, topic: str) -> Text:
        """Return complete original instructions for an active extension."""
        return Text(cast(str, await self._host("api_docs.read", {"topic": topic})))


def setup(api: PythonApi) -> dict[str, object]:
    return {"api_docs": ApiDocs(api.host), "ApiDocsError": api.HostError}
