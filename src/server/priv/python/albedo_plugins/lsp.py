"""Local LSP binding and deferred diagnostics for successful files edits."""

import os

from albedo_api import PythonApi
from albedo_lsp import Lsp


_manager: Lsp | None = None


def record(path) -> None:
    if _manager is not None:
        _manager.record(path)


async def finish() -> dict:
    if _manager is None:
        return {"ok": True, "error": "", "feedback": ""}
    return await _manager.finish()


async def setup(api: PythonApi) -> dict[str, object]:
    if os.environ.get("ALBEDO_REMOTE_TARGET"):
        return {}
    config = await api.host("lsp.config", {})
    if not isinstance(config, dict):
        raise ValueError("lsp.config must return an object")
    global _manager
    manager = _manager = Lsp(config)

    async def shutdown():
        global _manager
        if _manager is manager:
            _manager = None
        await manager.close()

    api.on_shutdown(shutdown)
    return {"lsp": manager}
