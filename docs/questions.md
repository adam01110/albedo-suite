# User questions

The suite adds a default-enabled `questions` extension. It uses Albedo's
existing resource-page UI, sidebar and authenticated services, not a terminal
stdin read or a blocking daemon actor.

```python
q = await ask_user("Where should this deploy?", options=["staging", "production"])
# q.status is pending. End the turn here.
```

The tool records a question and returns immediately. End the turn rather than
polling or continuing work that needs the answer. Tell the user to open
`/questions`. The sidebar shows pending questions for the current session.
The page accepts a free-text answer with `ctrl+e`; options are suggestions,
not restrictions. `ctrl+d` dismisses a question after confirmation.
Answering or dismissing submits a user turn to the **asking session**, which resumes
when available. No model-accessible answer operation exists.

```python
await questions.list()       # This session's pending questions.
await questions.get(q.id)    # Saved status and answer.
await questions.cancel(q.id) # Withdraw a pending request.
```

Questions persist across reloads, daemon restarts and interrupted turns.
Session deletion removes them. There are at most 32 pending questions per
session; question text is capped at 4096 bytes, suggested options at 16 entries
of 512 bytes each, and answers at 8192 bytes. Do not ask for secrets: questions
and answers are saved in the ledger and the session transcript. After an
interrupted ask, inspect `questions.list()` before asking again: creation may
have completed even when its response was lost.

## HTTP clients

All endpoints require daemon-token authentication:

- `GET /extensions/questions/items?session_id=<session>` lists pending questions
  and the generic client-page descriptor.
- `GET /extensions/questions/items/<id>?session_id=<session>` reads a saved
  question and its ETag.
- `POST /extensions/questions/items/<id>/answer?session_id=<session>` accepts
  `{"answer": "..."}` with `If-Match` set to that ETag.
- `POST /extensions/questions/items/<id>/cancel?session_id=<session>` accepts
  `{}` with `If-Match`.

A terminal transition has one winner. Stale answers are rejected rather than
replayed. Each successful mutation returns a saved resource and a notification
state. `notification.state = "failed"` means the answer was saved but its user turn
has unconfirmed delivery; inspect the returned detail and the session's queued
inputs and transcript before submitting it manually. A timeout does not prove
non-delivery. Retrying the answer does not submit another turn.

Disable with `settings.enabled.questions = false` in Home Manager, or through
Albedo's extension selector. Disabling hides the tool and UI without deleting
saved questions. Unit tests cover binding behavior; daemon tests cover storage,
scope, bounds, restart, concurrent answers and notification delivery.
