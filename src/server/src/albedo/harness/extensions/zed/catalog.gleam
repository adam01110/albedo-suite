import albedo/harness/extension
import albedo/harness/settings
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const endpoint = "https://cloud.zed.dev"

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(
    lookup,
    list_models,
    Some(fn() { reload(settings.home()) }),
  )
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  case at {
    Some(url) ->
      native_lookup(settings.home(), string.remove_suffix(url, "/"), id)
    None -> None
  }
}

fn list_models(provider: String, at: Option(String)) -> List(String) {
  case provider {
    "zed" ->
      native_models(
        settings.home(),
        string.remove_suffix(option.unwrap(at, endpoint), "/"),
      )
      |> result.unwrap([])
    _ -> []
  }
}

@external(erlang, "albedo_zed", "models")
fn native_models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_zed", "lookup")
fn native_lookup(
  home: String,
  endpoint: String,
  id: String,
) -> Option(extension.ModelInfo)

@external(erlang, "albedo_zed", "reload")
fn reload(home: String) -> Result(Nil, String)
