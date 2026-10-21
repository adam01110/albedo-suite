"""Local LSP binding and deferred diagnostics for successful files edits."""

import os

from albedo_api import PythonApi
from albedo_lsp import Lsp


_manager: Lsp | None = None


def record(path) -> None:
    if _manager is not None:
        _manager.record(path)


def workspace():
    return None if _manager is None else _manager.cwd


def pending_paths():
    return () if _manager is None else tuple(_manager.pending)


def pending_versions():
    return {} if _manager is None else dict(_manager.pending)


async def finish(paths=None, *, details=False) -> dict:
    if _manager is None:
        return {"ok": True, "error": "", "feedback": ""}
    return await _manager.finish(paths, details=details)


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
