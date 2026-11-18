"""Private formatter setup; it exports no model namespace bindings."""

import os

from albedo_api import PythonApi
import albedo_formatter


async def setup(api: PythonApi) -> dict[str, object]:
    if os.environ.get("ALBEDO_REMOTE_TARGET"):
        return {}
    config = await api.host("formatter.config", {})
    if not isinstance(config, dict):
        raise ValueError("formatter.config must return an object")
    albedo_formatter.configure(config)
    return {}
