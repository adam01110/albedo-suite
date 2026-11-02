"""Provider model lists: each provider's own list reaches the picker and reloads.

The host caches every provider's fetched list: a saved list answers at once,
also after a restart, while a fresh one is fetched behind it. `/reload models`
refetches the list of every saved profile and the models.dev catalog; a list
that cannot be fetched keeps what was saved, never the catalog's fallback, and
is named rather than reported refreshed. Claude's picker shows whatever the
Anthropic Models API listed, newest first, with the API's own limits and
efforts, so a model released after albedo shipped is offered without an
update. Every list is served on loopback or seeded on disk, so no live network
is reached. The class writes the shared home's list caches and models
settings, so it is exclusive and removes the caches again.
"""

import json
import shutil
import unittest
import urllib.parse

from harness import Albedo, Provider, exclusive, operation_id, text, wait_until

MODELS_CATALOG = {
    "fixture": {
        "id": "fixture",
        "name": "Fixture",
        "models": {
            "fixture-model": {"id": "fixture-model", "limit": {"context": 8000}}
        },
    },
    # Claims efforts the Anthropic API says the model does not take.
    "anthropic": {
        "id": "anthropic",
        "name": "Anthropic",
        "models": {
            "claude-fixture-small": {
                "id": "claude-fixture-small",
                "limit": {"context": 200000, "output": 8000},
                "reasoning_options": [
                    {"type": "effort", "values": ["low", "medium", "high"]}
                ],
            }
        },
    },
    # OpenCode Go's fallback before its own list lands, which must never
    # replace a list it fetched.
    "opencode-go": {
        "id": "opencode-go",
        "name": "OpenCode Go",
        "models": {"glm-from-models-dev": {"id": "glm-from-models-dev"}},
    },
    # Must not hide what a generic openai endpoint's own /models serves.
    "openai": {
        "id": "openai",
        "name": "OpenAI",
        "models": {"gpt-fixture": {"id": "gpt-fixture", "limit": {"context": 8000}}},
    },
}

OPENCODE_GO_MODELS = {"data": [{"id": "glm-5.3-flash"}, {"id": "glm-audio-1"}]}

# Zen's own list, free tier included, with a speech route the picker filters.
OPENCODE_ZEN_MODELS = {
    "data": [
        {"id": "glm-5.3-flash-free"},
        {"id": "deepseek-v4-pro"},
        {"id": "cat-jam-tts"},
    ]
}

GATEWAY_MODELS = {"data": [{"id": "local-b"}, {"id": "local-a"}]}

FIXTURE_MODELS = {"data": [{"id": "fixture-model"}]}

# As the Anthropic Models API answered, newest first; neither id is one
# albedo or models.dev knows.
CLAUDE_MODELS = [
    {
        "id": "claude-fixture-6",
        "context": 500000,
        "output": 32000,
        "images": True,
        "efforts": ["low", "high"],
    },
    {
        "id": "claude-fixture-small",
        "context": 200000,
        "output": 8000,
        "images": False,
        "efforts": [],
    },
]


# exclusive: writes global model caches/settings and reloads provider catalogs
@exclusive
class ModelCatalogReloadTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"), catalog=FIXTURE_MODELS)
        self.addCleanup(self.provider.close)
        self.catalog = Provider(lambda _request: text("ok"), catalog=MODELS_CATALOG)
        self.addCleanup(self.catalog.close)
        self.opencode_go = Provider(
            lambda _request: text("ok"), catalog=OPENCODE_GO_MODELS
        )
        self.addCleanup(self.opencode_go.close)
        self.opencode_zen = Provider(
            lambda _request: text("ok"), catalog=OPENCODE_ZEN_MODELS
        )
        self.addCleanup(self.opencode_zen.close)

        def prepare(app):
            (app.home / "claude-models.json").write_text(json.dumps(CLAUDE_MODELS))
            (app.home / "models.json").unlink(missing_ok=True)
            app.write_extensions({"models": {"url": self.catalog.url + "/models.json"}})

        self.app = Albedo(
            self.provider,
            prepare=prepare,
            providers={
                "fixture": {
                    "baseUrl": self.provider.url,
                    "apiKey": "fixture-key",
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                },
                "fixture-opencode-go": {
                    "extension": "opencode-go",
                    "baseUrl": self.opencode_go.url,
                    "apiKey": "fixture-opencode-go-key",
                    "model": "glm-5.3-flash",
                    "protocol": "chat_completions",
                },
                "fixture-opencode-zen": {
                    "extension": "opencode-zen",
                    "baseUrl": self.opencode_zen.url,
                    "apiKey": "fixture-opencode-zen-key",
                    "model": "glm-5.3-flash-free",
                    "protocol": "chat_completions",
                },
            },
        )
        self.app.__enter__()
        self.addCleanup((self.app.home / "claude-models.json").unlink, missing_ok=True)
        self.addCleanup(
            shutil.rmtree, self.app.home / "model-lists", ignore_errors=True
        )
        self.addCleanup(self.app.__exit__, None, None, None)

    def listed(self, provider, endpoint=""):
        query = urllib.parse.urlencode(
            {"provider": provider, **({"endpoint": endpoint} if endpoint else {})}
        )
        with self.app.api(f"/models?{query}") as response:
            return json.load(response)["items"]

    def reload(self, target):
        session = self.app.session()
        with self.app.api(
            f"/sessions/{session}/reload",
            {"target": target},
        ) as response:
            return json.load(response)

    def opencode_go_listed(self):
        return self.listed("opencode-go", self.opencode_go.url)

    def opencode_zen_listed(self):
        return self.listed("opencode-zen", self.opencode_zen.url)

    def test_reload_models_refetches_provider_lists_and_names_failures(self):
        def ids(items):
            return [item["id"] for item in items]

        # Non-chat entitlements stay filtered, as on any other fetch.
        self.assertEqual(ids(self.opencode_go_listed()), ["glm-5.3-flash"])
        # Zen's free tier reaches the picker, which is the point of fetching
        # its own list: models.dev lists a `-free` id the gateway may retire.
        self.assertEqual(
            ids(self.opencode_zen_listed()), ["deepseek-v4-pro", "glm-5.3-flash-free"]
        )
        self.opencode_go.catalog = None
        self.opencode_zen.catalog = {"data": [{"id": "kimi-free"}]}
        # A saved list answers until it is old or reloaded.
        self.assertEqual(
            ids(self.opencode_zen_listed()), ["deepseek-v4-pro", "glm-5.3-flash-free"]
        )

        outcome = self.reload("models")
        catalogs = {item["provider"]: item for item in outcome["models"]}
        # Only catalogs with something to fetch report: no profile here signs
        # in to Codex, Antigravity, or Claude.
        self.assertEqual(
            {name: item["state"] for name, item in catalogs.items()},
            {
                "models": "refreshed",
                "openai": "refreshed",
                "opencode-go": "failed",
                "opencode-zen": "refreshed",
                # The suite's Zed catalog refetches its own list.
                "zed": "refreshed",
            },
        )
        self.assertTrue(catalogs["opencode-go"]["failure"])
        self.assertEqual(ids(self.opencode_zen_listed()), ["kimi-free"])
        # A failed fetch keeps the saved list, not models.dev's fallback.
        self.assertEqual(ids(self.opencode_go_listed()), ["glm-5.3-flash"])
        # Claude was never fetched: its facts file answers.
        self.assertEqual(
            ids(self.listed("claude")), ["claude-fixture-6", "claude-fixture-small"]
        )

    def test_generic_openai_endpoint_lists_its_own_models(self):
        gateway = Provider(lambda _request: text("ok"), catalog=GATEWAY_MODELS)
        self.addCleanup(gateway.close)
        self.reload("models")
        self.assertEqual(
            [item["id"] for item in self.listed("openai", gateway.url + "/")],
            ["local-a", "local-b"],
        )
        gateway.catalog = {"data": [{"id": "uncached-change"}]}
        self.assertEqual(
            [item["id"] for item in self.listed("openai", gateway.url)],
            ["local-a", "local-b"],
        )

    def test_generic_openai_endpoint_answers_from_its_saved_list(self):
        gateway = Provider(lambda _request: text("ok"), catalog=GATEWAY_MODELS)
        self.addCleanup(gateway.close)

        def listed():
            return [item["id"] for item in self.listed("openai", gateway.url)]

        self.assertEqual(listed(), ["local-a", "local-b"])
        gateway.catalog = {"data": [{"id": "local-c"}]}
        # Saved lists turn stale after 3 s instead of 5 minutes.
        self.app.restart(
            prepare=lambda app: app.env.update(ALBEDO_TEST_TIME_SCALE="100")
        )
        # After the restart the saved list answers from disk without waiting
        # for the endpoint, and once stale it is refetched behind the caller.
        self.assertEqual(listed(), ["local-a", "local-b"])
        wait_until(
            lambda: listed() == ["local-c"], 10, "the saved list was never refreshed"
        )

    def test_claude_picker_offers_the_api_list_with_its_facts(self):
        self.reload("models")
        newest, small = self.listed("claude")
        self.assertEqual(
            [newest["id"], small["id"]], ["claude-fixture-6", "claude-fixture-small"]
        )
        self.assertEqual(
            (
                newest["default_context_tokens"],
                newest["max_output_tokens"],
                [effort["id"] for effort in newest["efforts"]],
            ),
            (500000, 32000, ["low", "high"]),
        )
        # No effort listed means the model takes none, not a guessed default.
        self.assertEqual(small["efforts"], [])


# exclusive: boots a fresh home whose settings name a loopback catalog
@exclusive
class ModelCatalogWarmTests(unittest.TestCase):
    def test_a_fresh_home_fetches_the_catalog_on_its_first_boot(self):
        catalog = Provider(lambda _request: text("ok"), catalog=MODELS_CATALOG)
        self.addCleanup(catalog.close)

        def prepare(app):
            app.write_extensions(
                {"models": {"url": catalog.url + "/models.json", "refreshHours": 24}}
            )

        with Albedo(prepare=prepare) as app:
            cached = app.home / "models.json"
            wait_until(cached.exists, 20, "the first boot never fetched the catalog")
            self.assertIn(
                "fixture-model", json.loads(cached.read_text())["fixture"]["models"]
            )


# exclusive: seeds global models catalog; several tests restart the daemon
@exclusive
class ModelCatalogSelectionTests(unittest.TestCase):
    """Disputed gateway facts must not borrow one provider's larger limits."""

    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        catalog = {
            "openai": {
                "api": "https://api.openai.example/v1",
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": 400000, "output": 8000},
                        "modalities": {"input": ["text", "image", "pdf"]},
                        "reasoning_options": [
                            {"type": "effort", "values": ["low", "medium", "high"]}
                        ],
                    }
                },
            },
            "mirror": {
                "api": "https://mirror.example/v1",
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": 200000, "output": 16000},
                        "modalities": {"input": ["image", "text"]},
                        "reasoning_options": [
                            {"type": "effort", "values": ["medium", "high"]}
                        ],
                    },
                    "vendor/qualified-model": {
                        "id": "vendor/qualified-model",
                        "limit": {"context": 32000},
                    },
                },
            },
            "unknown": {
                "models": {
                    "shared-model": {
                        "id": "shared-model",
                        "limit": {"context": None, "output": 0},
                    }
                }
            },
        }

        def prepare(app):
            (app.home / "models.json").write_text(json.dumps(catalog))
            (app.home / "models.json.index").unlink(missing_ok=True)
            app.write_extensions({"models": {"refreshHours": 0}})

        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def listed(self, provider, endpoint=""):
        query = urllib.parse.urlencode(
            {"provider": provider, **({"endpoint": endpoint} if endpoint else {})}
        )
        with self.app.api(f"/models?{query}") as response:
            return json.load(response)["items"]

    def test_gateway_uses_smallest_limits_and_shared_reported_capabilities(self):
        gateway = "https://gateway.example/v1"
        [shared] = self.listed("openai", gateway)
        self.assertEqual(shared["default_context_tokens"], 200000)
        self.assertEqual(shared["max_output_tokens"], 8000)
        self.assertEqual(shared["input_modalities"], ["image", "text"])
        self.assertEqual(
            [effort["id"] for effort in shared["efforts"]], ["medium", "high"]
        )
        self.assertEqual(self.listed("openai"), [shared])
        # The reduced index must give the same answer after a daemon restart.
        self.assertTrue((self.app.home / "models.json.index").exists())
        self.app.restart()
        self.assertEqual(self.listed("openai", gateway), [shared])

    def test_endpoint_selects_provider_facts_and_model_list(self):
        listed = self.listed("openai", "https://MIRROR.example/other-path")
        self.assertEqual(
            [item["id"] for item in listed],
            ["shared-model", "vendor/qualified-model"],
        )
        shared, qualified = listed
        self.assertEqual(shared["default_context_tokens"], 200000)
        self.assertEqual(shared["max_output_tokens"], 16000)
        self.assertEqual(shared["input_modalities"], ["image", "text"])
        self.assertEqual(qualified["default_context_tokens"], 32000)
        # ChatGPT has no matching API host in models.dev; it uses OpenAI identity.
        [subscription] = self.listed("openai", "https://chatgpt.com/backend-api")
        self.assertEqual(subscription["default_context_tokens"], 400000)
        self.assertEqual(subscription["max_output_tokens"], 8000)
        self.assertEqual(subscription["input_modalities"], ["text", "image", "pdf"])
        self.assertEqual(
            [effort["id"] for effort in subscription["efforts"]],
            ["low", "medium", "high"],
        )

    def test_known_reasoning_models_keep_empty_catalog_efforts(self):
        catalog = {
            "openai": {
                "models": {
                    "o3-disjoint": {
                        "id": "o3-disjoint",
                        "reasoning_options": [{"type": "effort", "values": ["low"]}],
                    },
                    "o3-empty": {"id": "o3-empty"},
                }
            },
            "mirror": {
                "models": {
                    "o3-disjoint": {
                        "id": "o3-disjoint",
                        "reasoning_options": [{"type": "effort", "values": ["high"]}],
                    }
                }
            },
        }
        (self.app.home / "models.json").write_text(json.dumps(catalog))
        self.app.restart()
        listed = self.listed("openai", "https://gateway.example/v1")
        self.assertEqual([item["id"] for item in listed], ["o3-disjoint", "o3-empty"])
        self.assertEqual([item["efforts"] for item in listed], [[], []])
        self.app.restart()
        self.assertEqual(self.listed("openai"), listed)

    def test_efforts_are_inferred_only_for_a_model_absent_from_a_valid_catalog(self):
        session = operation_id()
        self.app.api(
            f"/sessions/{session}",
            {
                "kind": "new",
                "workspace": str(self.app.workspace),
                "provider_profile": self.app.profile,
                "model": "o3-unlisted",
            },
            method="PUT",
            headers={"If-None-Match": "*"},
        ).close()
        query = urllib.parse.urlencode({"provider": "openai", "model": "o3-unlisted"})
        with self.app.api(f"/models?{query}") as response:
            [model] = json.load(response)["items"]
        self.assertEqual(
            [effort["id"] for effort in model["efforts"]], ["low", "medium", "high"]
        )
        # A corrupt catalog cannot establish that the model is absent.
        (self.app.home / "models.json").write_text("{")
        self.app.restart()
        with self.app.api(f"/models?{query}") as response:
            [model] = json.load(response)["items"]
        self.assertEqual(model["efforts"], [])


# exclusive: seeds global Codex catalog and restarts the daemon
@exclusive
class CodexCachedCatalogTests(unittest.TestCase):
    """Account caches keep picker precedence and facts across restart."""

    def test_cache_deduplicates_before_visibility_and_survives_restart(self):
        provider = Provider(lambda _request: text("ok"))
        self.addCleanup(provider.close)
        cache = {
            "clientVersion": "0.157.1",
            "versionCheckedAt": 123,
            "accounts": {
                "account-a": {
                    "fetchedAt": 123,
                    "clientVersion": "0.157.1",
                    "etag": "fixture-a",
                    "models": [
                        {"slug": "hidden-first", "visible": False},
                        {"slug": "hidden-first", "visible": True},
                        {
                            "slug": "codex-fixture",
                            "name": "Codex fixture",
                            "context": 200000,
                            "maxContext": 400000,
                            "input": ["text", "image"],
                            "efforts": ["low", "high"],
                            "priority": 2,
                        },
                        {"slug": "codex-fixture", "context": 1000, "priority": 0},
                    ],
                },
                "account-b": {
                    "models": [{"slug": "other-account", "priority": 1}],
                },
            },
        }

        def prepare(app):
            (app.home / "codex-models.json").write_text(json.dumps(cache))
            app.write_extensions({"models": {"refreshHours": 0}})

        with Albedo(provider, prepare=prepare) as app:

            def listed():
                with app.api("/models?provider=codex") as response:
                    return json.load(response)["items"]

            expected = ["other-account", "codex-fixture"]
            self.assertEqual([item["id"] for item in listed()], expected)
            facts = listed()
            self.assertEqual([item["id"] for item in facts], expected)
            model = facts[1]
            self.assertEqual(model["default_context_tokens"], 200000)
            self.assertEqual(model["max_context_tokens"], 400000)
            self.assertEqual(model["input_modalities"], ["text", "image"])
            self.assertEqual(
                [effort["id"] for effort in model["efforts"]], ["low", "high"]
            )
            app.restart()
            self.assertEqual([item["id"] for item in listed()], expected)
            self.assertEqual(listed(), facts)
