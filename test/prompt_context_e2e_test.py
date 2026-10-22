"""Reduced startup references retain capabilities and append-only request prefixes."""

import json
import re
import unittest

from harness import Albedo, Provider, LOOPBACK_REMOTE, python, text


def inputs(request):
    return request.get("input", request.get("messages", []))


def instructions(request):
    if "instructions" in request:
        return request["instructions"]
    return "\n".join(
        message["content"]
        for message in request["messages"]
        if message.get("role") in {"system", "developer"}
    )


class PromptContextTests(unittest.TestCase):
    protocol = "responses"

    def setUp(self):
        self.code = ""

        def reply(request):
            if (
                inputs(request)[-1].get("type") == "function_call_output"
                or inputs(request)[-1].get("role") == "tool"
            ):
                return text("done")
            return python(self.code) if self.code else text("ok")

        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol=self.protocol)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        skill = self.app.workspace / ".agents/skills/token-fixture/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: token-fixture\ndescription: UNIQUE_SKILL_DISCOVERY_DESCRIPTION\n---\n"
            "SKILL_BODY_秘密\nsecond line\n"
        )
        slug = re.sub(r"[^A-Za-z0-9]", "-", str(self.app.workspace))
        self.memory = self.app.home / "memories" / slug / "memory.md"
        self.memory.parent.mkdir(parents=True)
        self.note = "Old constraint\nRETRIEVABLE_OLD_CONSTRAINT " + "preserved " * 1000
        self.memory.write_text(
            self.note
            + "\n\n"
            + "\n\n".join(
                f"Recent topic {index}\nDetail {index} 秘密" for index in range(20)
            )
        )
        self.session = self.app.session()

    def turn(self, code=""):
        self.code = code
        before = len(self.provider.requests)
        self.app.prompt(self.session, "probe reduced prompt").close()
        self.app.idle(self.session)
        requests = [item["request"] for item in self.provider.requests[before:]]
        if code:
            output = next(
                item.get("output", item.get("content"))
                for item in reversed(inputs(requests[-1]))
                if item.get("type") == "function_call_output"
                or item.get("role") == "tool"
            )
            self.assertIn("PROBE_OK", output, output)
        return requests

    def test_startup_is_smaller_and_every_reference_is_retrievable(self):
        requests = self.turn(
            "topics = await api_docs.catalog()\n"
            "assert {'agents', 'remote', 'browser', 'mail', 'paperclips'} <= set(topics), topics\n"
            "for topic in topics:\n"
            "    reference = await api_docs.read(topic)\n"
            "    assert isinstance(reference, str) and reference.strip(), topic\n"
            "assert 'agents.self.spawn' in await api_docs.read('agents')\n"
            "assert 'await rem.files.read' in await api_docs.read('remote')\n"
            "try:\n"
            "    await api_docs.read('not-an-active-extension')\n"
            "    assert False\n"
            "except ApiDocsError:\n"
            "    pass\n"
            "print('PROBE_OK')"
        )
        prompt = instructions(requests[0])
        self.assertEqual(prompt.count("UNIQUE_SKILL_DISCOVERY_DESCRIPTION"), 1)
        self.assertNotIn("SKILL_BODY_秘密", prompt)
        self.assertNotIn("RETRIEVABLE_OLD_CONSTRAINT", prompt)
        self.assertIn("Recent topic 19", prompt)
        self.assertIn("memory.search", prompt)
        self.assertIn("api_docs.read", prompt)
        self.assertNotIn("A dropped connection stays dropped", prompt)
        self.assertLess(len(prompt.encode()), 43000)

    def test_docs_and_memory_operations_leave_the_request_prefix_unchanged(self):
        first = self.turn()[0]
        probe = self.turn(
            "reference = await api_docs.read('agents')\n"
            "memory.append('NEW_MEMORY_SHOULD_NOT_REWRITE_STARTUP')\n"
            "assert 'RETRIEVABLE_OLD_CONSTRAINT' in str(memory.search('RETRIEVABLE_OLD_CONSTRAINT'))\n"
            "print('PROBE_OK')"
        )
        following = self.turn()[0]
        requests = [first, *probe, following]
        for previous, current in zip(requests, requests[1:]):
            self.assertEqual(instructions(current), instructions(first))
            self.assertEqual(json.dumps(current["tools"]), json.dumps(first["tools"]))
            self.assertEqual(
                json.dumps(inputs(current)[: len(inputs(previous))]),
                json.dumps(inputs(previous)),
            )
            self.assertEqual(
                current.get("prompt_cache_key"), first.get("prompt_cache_key")
            )
        self.assertNotIn(
            "NEW_MEMORY_SHOULD_NOT_REWRITE_STARTUP", instructions(following)
        )
        self.assertIn("NEW_MEMORY_SHOULD_NOT_REWRITE_STARTUP", self.memory.read_text())

    def test_skill_pages_preserve_metadata_paging_and_activation(self):
        self.turn(
            "page = await skills.read('token-fixture')\n"
            "assert 'SKILL_BODY_秘密' in page.content\n"
            "assert page['content'] == page.content\n"
            "assert page.path.endswith('/token-fixture/SKILL.md')\n"
            "assert chr(10) in str(page) and 'second line' in str(page)\n"
            "partial = await skills.read('token-fixture', limit=20)\n"
            "assert partial.truncated and 'continued at offset=' in str(partial)\n"
            "rest = await skills.read('token-fixture', offset=partial.next_offset)\n"
            "assert partial.content + rest.content == page.content\n"
            "activation = await commands.invoke('/token-fixture', {'arguments': 'opaque 秘密'})\n"
            "assert activation['arguments'] == 'opaque 秘密'\n"
            "assert 'SKILL_BODY_秘密' in activation['instructions']\n"
            "print('PROBE_OK')"
        )

    def test_reference_retrieval_works_from_remote_kernel(self):
        self.turn(
            "local = await api_docs.read('remote')\n"
            + LOOPBACK_REMOTE
            + "reference = await rem.api_docs.read('remote')\n"
            "assert reference == local\n"
            "await rem.close()\n"
            "print('PROBE_OK')"
        )


class ChatPromptContextTests(PromptContextTests):
    protocol = "chat_completions"
