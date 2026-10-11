import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/questions/ledger
import albedo/harness/extensions/questions/service
import albedo/harness/rpc
import gleam/dynamic
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "questions",
    "Durable user questions and answers, scoped to the asking session.",
    ["python"],
    [
      extension.CommandPlugin([
        command.resource(
          "/questions",
          "Answer or dismiss this session's pending questions.",
          [],
        ),
      ]),
      extension.ClientPlugin([
        client_api.Command(
          "/questions",
          client_api.Read,
          [],
          client_api.Operation(
            ..client_api.operation_defaults(
              "listQuestions",
              http.Get,
              "/extensions/questions/items",
              200,
            ),
            query: [#("session_id", client_api.Session("/id"))],
          ),
        ),
      ]),
      extension.GlancePlugin(service.sidebar, service.resource_url),
      extension.ServicePlugin(extension.Service(
        fn(_, _) { extension.Admission(extension.DaemonToken, 32_768) },
        service.handle,
      )),
      extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["questions"], session)
      }),
      extension.ToolPlugin(
        "await ask_user(question, options=[...]) records a durable question for the user and returns its pending record; it does not wait for the answer. Ask only when user input is needed, then end the turn and state that /questions accepts the answer. Do not poll, guess, or continue dependent work. The user's answer or dismissal is submitted as a user turn to this session. Options are suggestions, not restrictions. await questions.get(id) reads its saved answer; await questions.list() lists pending questions; await questions.cancel(id) withdraws one. QuestionError reports a failed request. After an interrupted ask, check questions.list() before asking again; the request may have been saved. Pending questions survive restarts and interrupted turns until answered or cancelled.",
        [],
        ["questions"],
        [],
      ),
      extension.ManagedPlugin(fn(storage, session, _) {
        Ok(
          extension.Managed(..extension.empty(), routes: [
            #("questions", fn(_, request) {
              rpc.serve(
                request,
                "invalid question request",
                fn(method, args) { dispatch(storage, session, method, args) },
                fn(message) { #("question_error", message) },
              )
            }),
          ]),
        )
      }),
    ],
    ledger.initialise,
  )
}

fn dispatch(
  storage: store.Store,
  session: String,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, String) {
  case method {
    "questions.ask" -> {
      let decoder = {
        use question <- decode.field("question", decode.string)
        use options <- decode.optional_field(
          "options",
          [],
          decode.list(decode.string),
        )
        decode.success(#(question, options))
      }
      use #(question, options) <- result.try(rpc.args(
        args,
        decoder,
        "invalid question arguments",
      ))
      use item <- result.try(ledger.ask(storage, session, question, options))
      service.changed(session)
      Ok(ledger.value(item))
    }
    "questions.list" ->
      ledger.pending(storage, session)
      |> result.map(json.array(_, ledger.value))
    "questions.get" | "questions.cancel" -> {
      use id <- result.try(rpc.args(
        args,
        decode.field("id", decode.string, decode.success),
        "invalid question id",
      ))
      use id <- result.try(
        int.parse(id) |> result.replace_error("invalid question id"),
      )
      use item <- result.try(ledger.get(storage, session, id))
      case method {
        "questions.get" -> Ok(ledger.value(item))
        _ -> {
          use item <- result.try(ledger.finish(storage, item, "cancelled", ""))
          service.changed(session)
          Ok(ledger.value(item))
        }
      }
    }
    _ -> Error("unknown questions method")
  }
}
