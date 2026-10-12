import albedo/harness/extension
import albedo/harness/extensions/claude/stream as messages_stream
import albedo/harness/extensions/claude/wire as messages_wire
import albedo/harness/extensions/models/extension as models
import albedo/harness/settings
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree

const endpoint = "https://opencode.ai/zen/go/v1"

pub fn extension() -> extension.Extension {
  extension.Extension(
    "opencode-go",
    "OpenCode Go API-key provider with per-model OpenAI and Anthropic routing",
    ["models"],
    [
      extension.ModelsPlugin(extension.ModelCatalog(
        lookup,
        list_models,
        Some(fn() { reload(settings.home()) }),
      )),
      extension.ModelProviderPlugin(extension.ModelProvider(
        "opencode-go",
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  use <- bool.guard(
    !owns_endpoint(settings.home(), option.unwrap(at, "")),
    None,
  )
  models.lookup_provider("opencode-go", id)
  |> option.map(fn(info) {
    extension.ModelInfo(
      ..info,
      provider: "opencode-go",
      endpoint: Some(option.unwrap(at, endpoint)),
    )
  })
}

fn list_models(provider: String, at: Option(String)) -> List(String) {
  use <- bool.guard(provider != "opencode-go", [])
  case native_models(settings.home(), option.unwrap(at, endpoint)) {
    Ok(ids) -> ids
    Error(_) -> models.list("opencode-go", Some(endpoint))
  }
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- bool.guard(context.provider != "opencode-go", None)
  Some({
    use #(base_url, key) <- result.try(access(context.home, context.profile))
    let route = route(context.home, context.model)
    let protocol = case route {
      "responses" -> types.Responses
      _ -> types.ChatCompletions
    }
    let client = openai_api.client(protocol, base_url, key)
    Ok(
      extension.Upstream(
        base_url,
        protocol,
        fn(request, on_event) {
          case route {
            "messages" -> {
              use exchange <- result.try(messages_exchange(
                context.home,
                base_url,
                key,
                request,
              ))
              openai_api.exchange(
                exchange,
                messages_stream.reducer(request.model, request.tools),
                on_event,
              )
            }
            _ -> openai_api.stream(client, request, on_event)
          }
        },
        explain,
        fn() { None },
        fn(_) { [] },
        case route {
          "messages" -> types.ImageLimits(2000, Some(100))
          _ -> types.any_images
        },
      ),
    )
  })
}

pub fn messages_exchange(
  home: String,
  base_url: String,
  key: String,
  request: types.Request,
) -> Result(openai_api.Exchange, types.Error) {
  use exchange <- result.map(messages_wire.encode(
    home,
    messages_wire.ApiKey(key),
    request,
  ))
  openai_api.Exchange(
    ..exchange,
    url: string.remove_suffix(base_url, "/") <> "/messages",
    headers: [
      #("x-api-key", key),
      #("anthropic-version", "2023-06-01"),
      #("content-type", "application/json"),
      #("accept", "text/event-stream"),
    ],
    body: exchange.body
      |> string_tree.to_string
      |> compatible_body
      |> string_tree.from_string,
  )
}

fn explain(error: types.Error) -> Option(String) {
  case error {
    types.HttpError(401, _) ->
      Some(
        "OpenCode Go rejected the API key; run /login or check OPENCODE_API_KEY",
      )
    types.HttpError(429, _) ->
      Some("OpenCode Go usage limit reached; check your Go subscription usage")
    _ -> None
  }
}

@external(erlang, "albedo_opencode_go", "owns_endpoint")
fn owns_endpoint(home: String, endpoint: String) -> Bool

@external(erlang, "albedo_opencode_go", "access")
fn access(home: String, profile: String) -> Result(#(String, String), String)

@external(erlang, "albedo_opencode_go", "route")
fn route(home: String, model: String) -> String

@external(erlang, "albedo_opencode_go", "models")
fn native_models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_opencode_go", "reload")
fn reload(home: String) -> Result(Nil, String)

@external(erlang, "albedo_opencode_go", "compatible_body")
fn compatible_body(body: String) -> String
