import albedo/harness/extension
import albedo/harness/extensions/zed/catalog
import albedo/harness/extensions/zed/stream
import albedo/harness/extensions/zed/wire
import albedo/harness/rotation
import albedo/openai_api/types
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn extension() -> extension.Extension {
  extension.Extension(
    "zed",
    "Zed hosted models over its native streaming API",
    ["models"],
    [
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider("zed", resolve)),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(context, "zed", "Zed", types.ChatCompletions)
  use #(endpoint, token) <- result.try(access(context.home, context.profile))
  Ok(extension.Upstream(
    endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
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
    fn(error) {
      case error {
        types.HttpError(401, _) ->
          Some(
            "Zed rejected the token; provide a fresh Zed JWT in this profile or ZED_TOKEN",
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
