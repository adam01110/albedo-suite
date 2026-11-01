//// Read-only projections at the native settings document boundary.
//// Values not validated by the original reader remain raw until encoding.

import albedo/daemon/configuration
import albedo/harness/cache_ttl
import albedo/harness/settings/declared
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Error {
  InvalidSection
  InvalidValue
}

type Profile {
  Profile(
    saved: configuration.SavedProfile,
    enabled: Dynamic,
    effort: Dynamic,
    image_edge: Dynamic,
    account_id: Dynamic,
    account_ids: Dynamic,
    project: Dynamic,
    location: Dynamic,
    has_key: Bool,
  )
}

type UI {
  UI(
    thinking: Bool,
    tools: Bool,
    dismissed_notices: List(String),
    web_allow: List(String),
    proxy_allow: List(String),
  )
}

type Source {
  Literal(String)
  Environment(Dynamic)
}

@external(erlang, "albedo_settings_read", "json_null")
fn null() -> Dynamic

fn object(fields: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    list.map(fields, fn(field) { #(dynamic.string(field.0), field.1) }),
  )
}

fn fields(value: Dynamic) -> Result(Dict(String, Dynamic), Error) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error(InvalidSection)
}

fn section(
  value: Dynamic,
  name: String,
) -> Result(Dict(String, Dynamic), Error) {
  use parent <- result.try(fields(value))
  section_fields(parent, name)
}

fn section_fields(
  parent: Dict(String, Dynamic),
  name: String,
) -> Result(Dict(String, Dynamic), Error) {
  case dict.get(parent, name) {
    Ok(saved) -> fields(saved)
    Error(_) -> Ok(dict.new())
  }
}

fn value(
  fields: Dict(String, Dynamic),
  name: String,
  default: Dynamic,
) -> Dynamic {
  dict.get(fields, name) |> result.unwrap(default)
}

fn nonempty(value: Dynamic) -> Dynamic {
  case decode.run(value, decode.string) {
    Ok("") -> null()
    _ -> value
  }
}

pub fn ui_group(picker: Dynamic) -> Result(Dynamic, Error) {
  let text = {
    use text <- decode.then(decode.string)
    case string.byte_size(text) >= 1 && string.byte_size(text) <= 512 {
      True -> decode.success(text)
      False -> decode.failure("", "notice identifier")
    }
  }
  let decoder = {
    use thinking <- decode.optional_field("thinking", False, decode.bool)
    use tools <- decode.optional_field("tools", False, decode.bool)
    use notices <- decode.optional_field(
      "dismissed_notices",
      [],
      decode.list(text),
    )
    use web_allow <- decode.optional_field("web_allow", [], decode.list(text))
    use proxy_allow <- decode.optional_field(
      "proxy_allow",
      [],
      decode.list(text),
    )
    decode.success(UI(thinking, tools, notices, web_allow, proxy_allow))
  }
  use ui <- result.try(
    decode.run(picker, decoder) |> result.replace_error(InvalidValue),
  )
  case
    list.length(ui.dismissed_notices) <= 1000
    && list.length(ui.web_allow) <= 64
    && list.length(ui.proxy_allow) <= 64
  {
    False -> Error(InvalidValue)
    True ->
      Ok(
        object([
          #("thinking", dynamic.bool(ui.thinking)),
          #("tools", dynamic.bool(ui.tools)),
          #(
            "dismissed_notices",
            dynamic.list(list.map(ui.dismissed_notices, dynamic.string)),
          ),
          #("web_allow", dynamic.list(list.map(ui.web_allow, dynamic.string))),
          #(
            "proxy_allow",
            dynamic.list(list.map(ui.proxy_allow, dynamic.string)),
          ),
        ]),
      )
  }
}

pub fn groups(
  documents: Dict(String, Dynamic),
  declarations: List(declared.Declared),
) -> Result(Dynamic, Error) {
  let assert Ok(config) = dict.get(documents, "config.json")
  let assert Ok(creds) = dict.get(documents, "creds.json")
  let assert Ok(extensions) = dict.get(documents, "extensions.json")
  let assert Ok(picker) = dict.get(documents, "picker.json")
  use named <- result.try(
    configuration.named_config(config) |> result.replace_error(InvalidSection),
  )
  let assert Ok(saved_profiles) = dict.get(named, "providers")
  use saved_profiles <- result.try(fields(saved_profiles))
  use profiles <- result.try(
    list.try_map(dict.to_list(saved_profiles), fn(entry) {
      use profile <- result.try(profile(entry.0, entry.1, creds))
      Ok(#(entry.0, profile))
    }),
  )
  use composition <- result.try(composition_groups(documents))
  use raised <- result.try(section(extensions, "raisedCaps"))
  use compact_at <- result.try(section(extensions, "compactAt"))
  use ui <- result.try(ui_group(picker))
  let providers =
    object([
      #("default_profile", nonempty(value(named, "active", null()))),
      #(
        "profiles",
        object(
          list.map(profiles, fn(entry) { #(entry.0, profile_value(entry.1)) }),
        ),
      ),
    ])
  let priors =
    profiles
    |> list.sort(fn(first, second) { string.compare(first.0, second.0) })
    |> list.take(200)
    |> list.map(fn(entry) { cache_prior(entry.0, entry.1.saved) })
  Ok(
    object(
      list.append(dict.to_list(composition), [
        #("providers", providers),
        #(
          "models",
          object([
            #("raised_caps", object(dict.to_list(raised))),
            #("compact_at", object(dict.to_list(compact_at))),
            #("cache_ttl_priors", dynamic.list(priors)),
          ]),
        ),
        #("extension_settings", declared.project(declarations, extensions)),
        #("ui", ui),
      ]),
    ),
  )
}

fn profile(
  name: String,
  raw: Dynamic,
  creds: Dynamic,
) -> Result(Profile, Error) {
  use saved <- result.try(
    configuration.validate_profile(name, raw)
    |> result.replace_error(InvalidValue),
  )
  use fields <- result.try(fields(raw))
  let has_inline_key = case
    decode.run(value(fields, "apiKey", null()), decode.string)
  {
    Ok(key) -> key != ""
    _ -> False
  }
  use has_key <- result.try(case has_inline_key {
    True -> Ok(True)
    False -> {
      use keys <- result.try(section(creds, "providers"))
      let stored_key = dict.get(keys, name) |> result.unwrap(object([]))
      // Non-map credential entries previously counted as missing keys.
      Ok(
        case
          decode.run(stored_key, {
            use key <- decode.field("apiKey", decode.string)
            decode.success(key)
          })
        {
          Ok(key) -> key != ""
          Error(_) -> False
        },
      )
    }
  })
  Ok(Profile(
    saved,
    value(fields, "enabled", dynamic.bool(True)),
    value(fields, "effort", null()),
    value(fields, "imageEdge", null()),
    value(fields, "accountId", null()),
    value(fields, "accountIds", null()),
    value(fields, "project", null()),
    value(fields, "location", null()),
    has_key || pinned_key(creds, saved),
  ))
}

fn pinned_key(creds: Dynamic, profile: configuration.SavedProfile) -> Bool {
  case profile.account_id {
    None -> False
    Some(id) -> {
      let accounts = section(creds, "accounts") |> result.unwrap(dict.new())
      let stored = value(accounts, profile.extension, null())
      let values =
        decode.run(stored, decode.list(decode.dynamic))
        |> result.unwrap([stored])
      list.any(values, fn(credential) {
        decode.run(credential, {
          use kind <- decode.field("type", decode.string)
          use account_id <- decode.field("_albedo_account_id", decode.string)
          use key <- decode.field("apiKey", decode.string)
          decode.success(kind == "key" && account_id == id && key != "")
        })
        |> result.unwrap(False)
      })
    }
  }
}

fn profile_value(profile: Profile) -> Dynamic {
  object([
    #("enabled", profile.enabled),
    #("extension", dynamic.string(profile.saved.extension)),
    #("api", case profile.saved.api {
      None -> null()
      Some(api) -> dynamic.string(api)
    }),
    #("endpoint", nonempty(dynamic.string(profile.saved.endpoint))),
    #("protocol", dynamic.string(types.protocol_name(profile.saved.protocol))),
    #("model", dynamic.string(profile.saved.model)),
    #("effort", profile.effort),
    #("image_edge", profile.image_edge),
    #("account_id", profile.account_id),
    #("account_ids", profile.account_ids),
    #("project", profile.project),
    #("location", profile.location),
    #("has_key", dynamic.bool(profile.has_key)),
  ])
}

pub fn composition_groups(
  documents: Dict(String, Dynamic),
) -> Result(Dict(String, Dynamic), Error) {
  let assert Ok(extensions) = dict.get(documents, "extensions.json")
  let assert Ok(capabilities) = dict.get(documents, "capabilities.json")
  let assert Ok(creds) = dict.get(documents, "creds.json")
  use mcp <- result.try(section(extensions, "mcp"))
  use definitions <- result.try(section_fields(mcp, "servers"))
  use views <- result.try(
    list.try_map(dict.to_list(definitions), fn(entry) {
      use secrets <- result.try(section(creds, "mcp"))
      let secret = dict.get(secrets, entry.0) |> result.unwrap(object([]))
      use view <- result.try(mcp_view(entry.1, secret))
      Ok(#(entry.0, view))
    }),
  )
  use defaults <- result.try(section(extensions, "enabled"))
  use global <- result.try(section(capabilities, "global"))
  use preferences <- result.try(
    list.try_fold(dict.to_list(global), [], fn(preferences, kind) {
      use choices <- result.try(
        fields(kind.1) |> result.replace_error(InvalidValue),
      )
      Ok(list.append(
        preferences,
        list.map(dict.to_list(choices), fn(choice) {
          #(kind.0 <> ":" <> choice.0, choice.1)
        }),
      ))
    }),
  )
  Ok(
    dict.from_list([
      #("mcp", object([#("definitions", object(views))])),
      #("extensions", object([#("defaults", object(dict.to_list(defaults)))])),
      #("capabilities", object([#("preferences", object(preferences))])),
    ]),
  )
}

fn mcp_view(raw: Dynamic, secret: Dynamic) -> Result(Dynamic, Error) {
  use definition <- result.try(
    fields(raw) |> result.replace_error(InvalidValue),
  )
  use transport <- result.try(
    dict.get(definition, "type") |> result.replace_error(InvalidValue),
  )
  let defaults =
    dict.from_list([
      #("enabled", dynamic.bool(True)),
      #("transport", transport),
      #("command", null()),
      #("arguments", dynamic.list([])),
      #("cwd", null()),
      #("url", null()),
      #("bearer_token_env_var", null()),
      #("enabled_tools", null()),
      #("disabled_tools", dynamic.list([])),
      #("startup_timeout_ms", dynamic.int(20_000)),
      #("call_timeout_ms", dynamic.int(60_000)),
    ])
  let public =
    list.fold(mcp_fields(), defaults, fn(public, name) {
      case dict.get(definition, name.1) {
        Ok(saved) -> dict.insert(public, name.0, saved)
        Error(_) -> public
      }
    })
  use environment <- result.try(source_view(definition, "env"))
  use headers <- result.try(source_view(definition, "headers"))
  use secret_fields <- result.try(
    fields(secret) |> result.replace_error(InvalidValue),
  )
  use secret_environment <- result.try(section_fields(secret_fields, "env"))
  use secret_headers <- result.try(section_fields(secret_fields, "headers"))
  Ok(
    object(
      list.append(dict.to_list(public), [
        #("environment", environment),
        #("headers", headers),
        #("auth", auth_view(secret_fields)),
        #(
          "secret_presence",
          object([
            #(
              "bearer_token",
              dynamic.bool(dict.has_key(secret_fields, "bearerToken")),
            ),
            #("environment", sorted_names(secret_environment)),
            #("headers", sorted_names(secret_headers)),
          ]),
        ),
      ]),
    ),
  )
}

/// A server's OAuth sign-in as clients show it: `none` until the server asks
/// for one, then `needs_sign_in`, `signed_in` or `signed_out`. A signed-in
/// server that asked for a wider scope also names it in `step_up`. Tokens
/// and client secrets never appear.
fn auth_view(secret: Dict(String, Dynamic)) -> Dynamic {
  let text = fn(record, key) {
    decode.run(record, decode.at([key], decode.string))
    |> result.map(dynamic.string)
    |> result.unwrap(null())
  }
  let registered =
    dict.get(secret, "oauth")
    |> result.try(fn(record) {
      decode.run(record, decode.at(["registration", "clientId"], decode.string))
      |> result.replace_error(Nil)
    })
  let client = case dict.has_key(secret, "oauthClient"), registered {
    True, _ -> dynamic.string("configured")
    False, Ok(_) -> dynamic.string("registered")
    False, Error(_) -> null()
  }
  case dict.get(secret, "oauth") {
    Error(_) ->
      object([
        #("state", dynamic.string("none")),
        #("account", null()),
        #("expires_at", null()),
        #("scope", null()),
        #("step_up", null()),
        #("reason", null()),
        #("client", client),
      ])
    Ok(record) -> {
      let state =
        decode.run(record, decode.at(["state"], decode.string))
        |> result.unwrap("needs_sign_in")
      let expires = case
        state,
        decode.run(record, decode.at(["expires"], decode.int))
      {
        "signed_in", Ok(ms) -> dynamic.string(native_timestamp(ms))
        _, _ -> null()
      }
      object([
        #("state", dynamic.string(state)),
        #("account", case state {
          "signed_in" -> text(record, "label")
          _ -> null()
        }),
        #("expires_at", expires),
        #("scope", text(record, "scope")),
        #("step_up", text(record, "stepUp")),
        #("reason", text(record, "reason")),
        #("client", client),
      ])
    }
  }
}

@external(erlang, "albedo_http_api", "timestamp")
fn native_timestamp(ms: Int) -> String

fn source_view(
  definition: Dict(String, Dynamic),
  key: String,
) -> Result(Dynamic, Error) {
  use sources <- result.try(section_fields(definition, key))
  let decoder =
    decode.one_of(decode.string |> decode.map(Literal), [
      {
        use name <- decode.field("env", decode.dynamic)
        decode.success(Environment(name))
      },
    ])
  use sources <- result.try(
    list.try_map(dict.to_list(sources), fn(entry) {
      use source <- result.try(
        decode.run(entry.1, decoder) |> result.replace_error(InvalidValue),
      )
      let #(kind, text) = case source {
        Literal(text) -> #("literal", dynamic.string(text))
        Environment(name) -> #("env", name)
      }
      Ok(#(
        entry.0,
        object([#("source", dynamic.string(kind)), #("value", text)]),
      ))
    }),
  )
  Ok(object(sources))
}

fn sorted_names(fields: Dict(String, Dynamic)) -> Dynamic {
  fields
  |> dict.keys
  |> list.sort(string.compare)
  |> list.map(dynamic.string)
  |> dynamic.list
}

fn cache_prior(name: String, profile: configuration.SavedProfile) -> Dynamic {
  let host =
    uri.parse(profile.endpoint)
    |> result.map(fn(uri) { uri.host })
    |> result.unwrap(None)
    |> option.unwrap("")
  let entry = cache_ttl.lookup(profile.extension, host, profile.model)
  let seconds =
    option.then(entry, cache_ttl.clock_tier)
    |> option.map(fn(tier) { tier.seconds })
  object([
    #("provider", dynamic.string(name)),
    #("model", dynamic.string(profile.model)),
    #("ttl_seconds", case seconds {
      Some(seconds) -> dynamic.int(seconds)
      None -> null()
    }),
    #(
      "source",
      dynamic.string(case entry {
        Some(entry) -> entry.source
        None -> "unknown"
      }),
    ),
  ])
}

pub fn mcp_fields() -> List(#(String, String)) {
  [
    #("enabled", "enabled"),
    #("transport", "type"),
    #("command", "command"),
    #("arguments", "args"),
    #("cwd", "cwd"),
    #("url", "url"),
    #("bearer_token_env_var", "bearerTokenEnvVar"),
    #("enabled_tools", "enabledTools"),
    #("disabled_tools", "disabledTools"),
    #("startup_timeout_ms", "startupTimeoutMs"),
    #("call_timeout_ms", "callTimeoutMs"),
  ]
}
