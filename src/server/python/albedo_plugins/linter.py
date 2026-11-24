"""Private linter setup; it exports no model namespace bindings."""

import os

from albedo_api import PythonApi
import albedo_linter


async def setup(api: PythonApi) -> dict[str, object]:
    if os.environ.get("ALBEDO_REMOTE_TARGET"):
        return {}
    config = await api.host("linter.config", {})
    if not isinstance(config, dict):
        raise ValueError("linter.config must return an object")
    albedo_linter.configure(config)
    return {}
