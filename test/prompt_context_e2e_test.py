"""Reduced startup references retain capabilities and append-only request prefixes."""

import json
import re
import unittest

from harness import Albedo, Provider, LOOPBACK_REMOTE, python, system_prompt, text


def inputs(request):
    return request.get("input", request.get("messages", []))


def instructions(request):
    # The system prompt opens the input as a developer or system message.
    return system_prompt(request)


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
        self.memory.write_text(self.note)
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


class ResponsesPromptContextTests(PromptContextTests):
    def test_startup_names_the_reference_bindings_and_the_remote_kernel_reads(self):
        requests = self.turn(
            "local = await api_docs.read('agents')\n"
            + LOOPBACK_REMOTE
            + "reference = await rem.api_docs.read('agents')\n"
            "assert reference == local\n"
            "await rem.close()\n"
            "print('PROBE_OK')"
        )
        prompt = instructions(requests[0])
        self.assertEqual(prompt.count("UNIQUE_SKILL_DISCOVERY_DESCRIPTION"), 1)
        self.assertNotIn("SKILL_BODY_秘密", prompt)
        self.assertIn("memory.search", prompt)
        self.assertIn("api_docs.read", prompt)
        self.assertIn("await skills.read(name", prompt)

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
        self.assertNotIn(
            "NEW_MEMORY_SHOULD_NOT_REWRITE_STARTUP", instructions(following)
        )
        self.assertIn("NEW_MEMORY_SHOULD_NOT_REWRITE_STARTUP", self.memory.read_text())


class ChatPromptContextTests(ResponsesPromptContextTests):
    protocol = "chat_completions"


class SkillPageTests(PromptContextTests):
    """The printed skill page is the suite's own rendering; one wire is enough."""

    def test_skill_pages_render_continuation_and_activation_take_arguments(self):
        self.turn(
            "page = await skills.read('token-fixture')\n"
            "assert chr(10) in str(page) and 'second line' in str(page)\n"
            "partial = await skills.read('token-fixture', limit=20)\n"
            "assert partial.truncated and 'continued at offset=' in str(partial)\n"
            "activation = await commands.invoke('/token-fixture', {'arguments': 'opaque 秘密'})\n"
            "assert activation['arguments'] == 'opaque 秘密'\n"
            "assert 'SKILL_BODY_秘密' in activation['instructions']\n"
            "print('PROBE_OK')"
        )


if __name__ == "__main__":
    unittest.main()
