"""Durable user questions. Asking records a request, not a blocking input read."""

from __future__ import annotations

from albedo_api import Host, PythonApi, Record
from typing import cast


class Questions:
    def __init__(self, host: Host):
        self._host = host

    async def ask(self, question: str, *, options: list[str] | None = None) -> Record:
        """Record a question for the user and return its pending record.

        End the turn after asking. The user answers in /questions; their answer
        arrives as a user turn in this session. Never poll or invent an answer.
        Options are suggestions: the user may supply another free-text answer.
        """
        return Record(
            cast(
                dict,
                await self._host(
                    "questions.ask",
                    {
                        "question": question,
                        "options": options if options is not None else [],
                    },
                ),
            )
        )

    async def get(self, id: int | str) -> Record:
        """Read this session's durable pending, answered or cancelled question."""
        return Record(cast(dict, await self._host("questions.get", {"id": str(id)})))

    async def list(self) -> list[Record]:
        """This session's pending questions, without waiting for answers."""
        return [
            Record(cast(dict, item))
            for item in cast(list, await self._host("questions.list", {}))
        ]

    async def cancel(self, id: int | str) -> Record:
        """Withdraw a pending question from this session."""
        return Record(cast(dict, await self._host("questions.cancel", {"id": str(id)})))


def setup(api: PythonApi) -> dict[str, object]:
    questions = Questions(api.host)
    return {
        "questions": questions,
        "ask_user": questions.ask,
        "QuestionError": api.HostError,
    }
