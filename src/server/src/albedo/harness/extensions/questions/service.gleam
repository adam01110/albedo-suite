//// Authenticated resource page uses Albedo's existing form and sidebar clients.

import albedo/daemon/bus
import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/questions/ledger
import albedo/harness/page
import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mist

pub fn resource_url(session: String, _workspace: String) -> String {
  "/extensions/questions/items?session_id=" <> uri.percent_encode(session)
}

pub fn changed(session: String) -> Nil {
  bus.invalidate([resource_url(session, "")], [], True)
}

fn failure(message: String) -> api.Failure {
  api.Failure(409, "question_conflict", message)
}

pub fn sidebar(
  storage: store.Store,
  session: String,
  _workspace: String,
) -> Result(page.Glance, String) {
  use items <- result.try(ledger.pending(storage, session))
  Ok(page.Glance(
    "questions",
    list.map(list.take(items, 12), fn(item) {
      page.Row(
        int.to_string(item.id),
        api.content_preview(item.question, 64),
        "pending",
        page.Warning,
        api.content_preview(string.join(item.options, " · "), 512),
      )
    }),
  ))
}

pub fn handle(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
  _live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case dispatch(daemon, path, req) {
    Ok(reply) -> reply
    Error(error) -> api.fail(error)
  }
}

fn dispatch(
  daemon: extension.Daemon,
  path: List(String),
  req: request.Request(BitArray),
) -> Result(response.Response(mist.ResponseData), api.Failure) {
  use _ <- result.try(
    api.wants_events(req)
    |> result.try(fn(events) {
      case events {
        True -> Error(api.Failure(406, "not_acceptable", "questions use JSON"))
        False -> Ok(Nil)
      }
    }),
  )
  use query <- result.try(api.parameters(req, ["session_id"]))
  use session <- result.try(
    list.key_find(query, "session_id")
    |> result.replace_error(api.invalid("session_id required")),
  )
  use _ <- result.try(case session == "" || string.byte_size(session) > 512 {
    True -> Error(api.invalid("invalid session_id"))
    False -> Ok(Nil)
  })
  case req.method, path {
    Get, ["items"] -> {
      use items <- result.try(
        ledger.pending(daemon.ledger, session) |> result.map_error(failure),
      )
      Ok(api.reply(
        200,
        json.object([
          #("items", json.array(items, resource)),
          #("next", json.null()),
          #("page", descriptor(items, session)),
        ]),
      ))
    }
    Get, ["items", id] -> {
      use item <- result.try(find(daemon.ledger, session, id))
      Ok(
        api.reply(200, ledger.value(item))
        |> response.set_header("etag", etag(item)),
      )
    }
    Post, ["items", id, action] if action == "answer" || action == "cancel" -> {
      use item <- result.try(find(daemon.ledger, session, id))
      use _ <- result.try(api.require_match(req, etag(item)))
      use answer <- result.try(case action {
        "answer" ->
          api.body(
            req,
            ["answer"],
            decode.field("answer", decode.string, decode.success),
          )
        _ -> api.body(req, [], decode.success(""))
      })
      use item <- result.try(
        ledger.finish(
          daemon.ledger,
          item,
          case action {
            "answer" -> "answered"
            _ -> "cancelled"
          },
          answer,
        )
        |> result.map_error(failure),
      )
      // Persist first; delivery failure is explicit and the answer remains readable.
      let notification =
        command.context(session).state(command.Submit(
          "User " <> item.status <> " question #" <> id,
          "User "
            <> item.status
            <> " question #"
            <> id
            <> ": "
            <> item.question
            <> "\nAnswer: "
            <> item.answer,
          "questions",
        ))
      changed(session)
      Ok(api.reply(
        200,
        json.object([
          #("resource", resource(item)),
          #("notification", case notification {
            Ok(_) -> json.object([#("state", json.string("queued"))])
            Error(detail) ->
              json.object([
                #("state", json.string("failed")),
                #("detail", json.string(detail)),
              ])
          }),
        ]),
      ))
    }
    _, _ -> Error(api.Failure(404, "not_found", "unknown questions resource"))
  }
}

fn find(
  storage: store.Store,
  session: String,
  id: String,
) -> Result(ledger.Item, api.Failure) {
  use id <- result.try(
    int.parse(id) |> result.replace_error(api.invalid("invalid question id")),
  )
  ledger.get(storage, session, id)
  |> result.map_error(fn(_) {
    api.Failure(404, "not_found", "question not found")
  })
}

fn etag(item: ledger.Item) -> String {
  "\"question-"
  <> int.to_string(item.id)
  <> "-"
  <> int.to_string(item.revision)
  <> "\""
}

fn resource(item: ledger.Item) -> json.Json {
  json.object([
    #(
      "url",
      json.string(
        "/extensions/questions/items/"
        <> int.to_string(item.id)
        <> "?session_id="
        <> uri.percent_encode(item.session),
      ),
    ),
    #("etag", json.string(etag(item))),
    #("value", ledger.value(item)),
  ])
}

fn descriptor(items: List(ledger.Item), session: String) -> json.Json {
  client_api.page(client_api.Page(
    title: "questions",
    summary: "Answer a question to resume its session",
    empty_state: "no pending questions",
    glance: None,
    actions: [
      client_api.Action(
        "answer",
        "answer",
        "ctrl+e",
        None,
        [client_api.text_field("answer", True)],
        operation(
          "answerQuestion",
          "answer",
          session,
          client_api.form_body(["answer"]),
        ),
      ),
      client_api.Action(
        "cancel",
        "dismiss",
        "ctrl+d",
        Some("Dismiss this question?"),
        [],
        operation("dismissQuestion", "cancel", session, []),
      ),
    ],
    rows: list.map(items, fn(item) {
      client_api.PageRow(
        int.to_string(item.id),
        api.content_preview(item.question, 160),
        Some("pending"),
        "warning",
        Some(api.content_preview(
          item.question
            <> "\nSuggested answers: "
            <> string.join(item.options, " · "),
          4000,
        )),
        resource(item),
      )
    }),
  ))
}

fn operation(
  name: String,
  action: String,
  session: String,
  body: List(#(String, client_api.Binding)),
) -> client_api.Operation {
  client_api.Operation(
    ..client_api.operation_defaults(
      name,
      Post,
      "/extensions/questions/items/{id}/" <> action,
      200,
    ),
    path: [#("id", client_api.Row("/resource/value/id"))],
    query: [#("session_id", client_api.Literal(json.string(session)))],
    headers: [#("If-Match", client_api.Row("/resource/etag"))],
    body: body,
  )
}
