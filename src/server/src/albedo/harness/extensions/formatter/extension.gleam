//// Format explicitly edited workspace files before an accepted final response.

import albedo/harness/extension
import albedo/harness/extensions/python/kernel as python
import albedo/harness/rpc
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string

pub fn extension() -> extension.Extension {
  extension.Extension(
    "formatter",
    "Defer formatting of explicitly edited files until the final reply.",
    ["files", "python"],
    [
      extension.ManagedPlugin(fn(_, _, _) {
        let assert Ok(empty_config) = json.parse("{}", decode.dynamic)
        use config <- result.try(settings.load(
          "formatter",
          decode.dynamic,
          empty_config,
        ))
        Ok(
          extension.Managed(
            ..extension.empty(),
            instructions: "Files edited with files.write() or files.edit() are tracked for deferred formatting. Do not run formatters on unfinished edits: the harness checks formatting before accepting your final reply. If it reports formatter changes or errors, review the changes, repair errors, and regenerate your final report. Shell/remote writes are not automatically tracked; format those explicitly when the work is complete. Unrelated dirty files are not formatted.",
            python_modules: ["formatter"],
            routes: [
              #("formatter", fn(_, request) {
                rpc.serve(
                  request,
                  #("invalid", "invalid formatter request"),
                  fn(method, _) {
                    case method {
                      "formatter.config" -> Ok(types.encode_value(config))
                      _ ->
                        Error(#(
                          "method",
                          "unknown formatter operation: " <> method,
                        ))
                    }
                  },
                  fn(failure) { failure },
                )
              }),
            ],
            before_final: Some(check),
          ),
        )
      }),
    ],
    fn(_) { Ok(Nil) },
  )
}

fn check(context: extension.Context) -> Result(Nil, String) {
  // Interim reports must not format files still being changed by background work.
  case python.observation(context.kernel) {
    Ok(observed) ->
      case python.awaits_jobs(observed) {
        True -> Ok(Nil)
        False -> check_files(context)
      }
    Error(_) -> check_files(context)
  }
}

fn check_files(context: extension.Context) -> Result(Nil, String) {
  let code =
    "import json, albedo_formatter\nprint(json.dumps(await albedo_formatter.finish()))"
  case python.execute(context.kernel, context.call_id, code, 55_000) {
    Ok(outcome) if outcome.status == python.Succeeded -> {
      let decoder = {
        use ok <- decode.field("ok", decode.bool)
        use changed <- decode.field("changed", decode.bool)
        use error <- decode.optional_field("error", "", decode.string)
        decode.success(#(ok, changed, error))
      }
      case json.parse(string.trim(outcome.output), decoder) {
        Ok(#(True, False, _)) -> Ok(Nil)
        Ok(#(True, True, _)) ->
          Error(
            "Formatting changed edited files. Review the resulting changes and regenerate your final report; do not repeat unfinished edits.",
          )
        Ok(#(False, _, error)) ->
          Error("Formatting failed: " <> string.slice(error, 0, 16_384))
        Error(_) ->
          Error(
            "Formatter returned an invalid result; inspect before retrying.",
          )
      }
    }
    Error(python.Busy) -> Ok(Nil)
    _ ->
      Error(
        "Formatter did not complete. Inspect the files and running work before retrying.",
      )
  }
}
