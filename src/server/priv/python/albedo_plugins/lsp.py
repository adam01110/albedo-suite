"""Temporary local LSP binding; no hooks or automatic startup."""

import os

from albedo_api import PythonApi
from albedo_lsp import Lsp


async def setup(api: PythonApi) -> dict[str, object]:
    if os.environ.get("ALBEDO_REMOTE_TARGET"):
        return {}
    config = await api.host("lsp.config", {})
    if not isinstance(config, dict):
        raise ValueError("lsp.config must return an object")
    manager = Lsp(config)
    api.on_shutdown(manager.close)
    return {"lsp": manager}
