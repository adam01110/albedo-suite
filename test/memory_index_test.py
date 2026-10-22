"""The native startup index is bounded while all own/linked notes remain intact."""

import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(
    os.environ.get(
        "ALBEDO_MEMORY_ERLANG",
        Path(__file__).resolve().parents[1]
        / "src/server/src/albedo/harness/extensions/memory/albedo_memory.erl",
    )
)


class MemoryIndexTests(unittest.TestCase):
    def test_unicode_bounds_linked_recall_and_writes(self):
        original = (
            "Old hidden constraint\n"
            + "秘密 " * 3000
            + "\n\n"
            + "\n\n".join(f"Topic {i}\nBody {i}" for i in range(20))
        )
        encoded = base64.b64encode(original.encode()).decode()
        with tempfile.TemporaryDirectory(prefix="memory-index-test-") as directory:
            root = Path(directory)
            shutil.copyfile(SOURCE, root / "albedo_memory.erl")
            (root / "albedo_extension_settings.erl").write_text(
                '-module(albedo_extension_settings).\n-export([home/0]).\nhome() -> unicode:characters_to_binary(os:getenv("ALBEDO_HOME")).\n'
            )
            subprocess.run(
                [
                    "erlc",
                    "-Werror",
                    "-o",
                    directory,
                    str(root / "albedo_memory.erl"),
                    str(root / "albedo_extension_settings.erl"),
                ],
                check=True,
                capture_output=True,
            )
            code = f"""
                Own = <<"/workspace/own">>, Linked = <<"host:/workspace/linked">>,
                {{ok, <<>>}} = albedo_memory:load([]),
                {{ok, <<>>}} = albedo_memory:load([Own]),
                Original = base64:decode(<<"{encoded}">>),
                {{ok, _}} = albedo_memory:save(Own, Original),
                {{ok, _}} = albedo_memory:save(Linked, <<"Linked constraint\nLINKED_FULL_BODY">>),
                {{ok, Index}} = albedo_memory:load([Own, Linked]),
                true = string:length(Index) < 2200,
                nomatch = binary:match(Index, <<"Old hidden constraint">>),
                nomatch = binary:match(Index, <<"LINKED_FULL_BODY">>),
                {{_, _}} = binary:match(Index, <<"Topic 19">>),
                {{_, _}} = binary:match(Index, Linked),
                {{ok, Original}} = albedo_memory:read(Own),
                {{ok, _}} = albedo_memory:journal(Linked, <<"2026-10-23">>, <<"JOURNAL_FULL_BODY">>),
                {{Documents, false}} = albedo_memory:documents([Own, Linked]),
                true = lists:member({{Own, <<"memory.md">>, Original}}, Documents),
                true = lists:member({{Linked, <<"journal/2026-10-23.md">>, <<"JOURNAL_FULL_BODY\n">>}}, Documents),
                {{ok, _}} = albedo_memory:append(Own, <<"OWN_APPEND">>),
                {{ok, <<"Linked constraint\nLINKED_FULL_BODY">>}} = albedo_memory:read(Linked),
                {{ok, Current}} = albedo_memory:read(Own),
                {{_, _}} = binary:match(Current, <<"OWN_APPEND">>),
                io:format("memory index bytes=~p full bytes=~p~n", [byte_size(Index), byte_size(Original)]),
                halt().
            """
            result = subprocess.run(
                ["erl", "+S", "2:2", "-noshell", "-pa", directory, "-eval", code],
                env=dict(os.environ, ALBEDO_HOME=directory),
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
