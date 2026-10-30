import albedo/harness/extension
import albedo/harness/extensions/zed/catalog
import albedo/harness/extensions/zed/stream
import albedo/harness/extensions/zed/wire
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "zed",
    "Zed hosted models over its native streaming API",
    ["models"],
    [
      extension.ModelsPlugin(catalog.catalog()),
      extension.LoginPlugin(login()),
      extension.ModelProviderPlugin(extension.ModelProvider("zed", resolve)),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(context, "zed", "Zed", types.ChatCompletions)
  use #(endpoint, _) <- result.try(access(context.home, context.profile))
  Ok(extension.Upstream(
    endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
      exchange(
        context.home,
        context.profile,
        fn(endpoint, token, on_event) {
          use provider <- result.try(
            route(context.home, endpoint, token, request.model)
            |> result.map_error(types.InvalidRequest),
          )
          use exchange <- result.try(wire.encode(
            provider,
            endpoint,
            token,
            context.session,
            request,
          ))
          stream.exchange(provider, exchange, request, on_event)
        },
        on_event,
      )
    },
    fn(error) {
      case error {
        types.HttpError(401, _) ->
          Some(
            "Zed rejected the token; sign in again with /login zed, or update your explicit manual JWT",
          )
        types.HttpError(451, _) ->
          Some("Zed does not allow requests from this network region")
        _ -> None
      }
    },
    fn() { None },
    fn(_) { [] },
    types.anthropic_images,
  ))
}

@external(erlang, "albedo_zed", "access")
pub fn access(
  home: String,
  profile: String,
) -> Result(#(String, String), String)

@external(erlang, "albedo_zed", "route")
fn route(
  home: String,
  endpoint: String,
  token: String,
  model: String,
) -> Result(String, String)

fn login() -> oauth.Login {
  oauth.Login(
    "zed",
    "add Zed account",
    "browser sign-in · automatically renewed inference tokens",
    oauth.Model,
    "zed",
    oauth.Device(native_start),
    fn(_) { "" },
    fn(_, _, _) { Error("Zed uses native browser sign-in") },
    native_account,
  )
}

@external(erlang, "albedo_zed_auth", "start")
fn native_start() -> Result(
  #(
    String,
    String,
    fn(fn(String) -> Nil) -> Result(Dict(String, Dynamic), String),
  ),
  String,
)

@external(erlang, "albedo_zed_auth", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_zed", "exchange")
fn exchange(
  home: String,
  profile: String,
  run: fn(String, String, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error)
