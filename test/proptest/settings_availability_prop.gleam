//// The providers settings group against an independent model of the saved
//// document: reading a group projects a profile's saved fields, and the
//// documented availability toggle disables and re-enables a saved profile
//// without disturbing anything else (docs/provider-availability.md).

import albedo/settings/settings
import albedo_json
import albedo_sdk/key_environment
import albedo_sdk/profiles as configuration
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// The extensions a profile may name; every one is installed here, so the
/// account check accepts it.
const extensions = ["openai", "anthropic-api", "bedrock", "zed"]

pub type Saved {
  Saved(
    name: String,
    extension: String,
    model: String,
    endpoint: String,
    protocol: String,
    effort: Option(String),
    image_edge: Option(Int),
    project: Option(String),
    /// A saved credential in creds.json for this profile.
    key: Bool,
    /// A key account this profile is pinned to in creds.json accounts.
    pinned: Bool,
    /// A profile saved as disabled before the property starts.
    disabled: Bool,
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn optional_text(values: List(String)) -> qcheck.Generator(Option(String)) {
  qcheck.from_weighted_generators(
    #(2, qcheck.return(None)),
    list.map(values, fn(value) { #(1, qcheck.return(Some(value))) }),
  )
}

fn saved() -> qcheck.Generator(Saved) {
  use #(extension, model, protocol), #(effort, image_edge), #(project, key, pinned, disabled) <- qcheck.map3(
    qcheck.tuple3(
      pick(["openai", "anthropic-api", "bedrock"]),
      pick(["m1", "m2"]),
      pick(["responses", "chat_completions"]),
    ),
    qcheck.tuple2(
      optional_text(["low", "medium", "high"]),
      qcheck.from_weighted_generators(
        #(2, qcheck.return(None)),
        [#(1, qcheck.bounded_int(1, 65_536) |> qcheck.map(Some))],
      ),
    ),
    qcheck.map3(
      optional_text(["p", "q"]),
      qcheck.bool(),
      qcheck.bool(),
      fn(project, key, pinned) {
        // Pinning moves the key into an account; a profile keeps one or the other.
        #(project, case pinned {
          True -> False
          False -> key
        }, pinned, pinned)
      },
    ),
  )
  // A pinned account lives in a key provider's store.
  let extension = case pinned {
    True -> "openai"
    False -> extension
  }
  Saved(
    "",
    extension,
    model,
    case extension {
      "openai" | "anthropic-api" -> "https://" <> extension <> ".example/v1"
      _ -> ""
    },
    protocol,
    effort,
    image_edge,
    project,
    key,
    pinned,
    disabled,
  )
}

/// Names follow position, so every saved name is unique.
fn case_generator() -> qcheck.Generator(List(Saved)) {
  qcheck.map(
    qcheck.generic_list(saved(), qcheck.bounded_int(1, 3)),
    fn(profiles) {
      list.index_map(profiles, fn(profile, index) {
        Saved(..profile, name: "p" <> int.to_string(index))
      })
    },
  )
}

fn saved_json(profile: Saved) -> json.Json {
  json.object(
    list.append(
      list.append(
        case profile.disabled {
          True -> [#("enabled", json.bool(False))]
          False -> []
        },
        list.append(
          [
            #("extension", json.string(profile.extension)),
            #("baseUrl", json.string(profile.endpoint)),
            #("model", json.string(profile.model)),
            #("protocol", json.string(profile.protocol)),
          ],
          case profile.pinned {
            True -> [#("accountId", json.string(account_id(profile)))]
            False -> []
          },
        ),
      ),
      list.append(
        list.append(
          case profile.effort {
            None -> []
            Some(value) -> [#("effort", json.string(value))]
          },
          case profile.image_edge {
            None -> []
            Some(value) -> [#("imageEdge", json.int(value))]
          },
        ),
        case profile.project {
          None -> []
          Some(value) -> [#("project", json.string(value))]
        },
      ),
    ),
  )
}

fn account_id(profile: Saved) -> String {
  "acc-" <> profile.name
}

/// creds.json holds a saved key for the profiles that have one.
fn creds_json(profiles: List(Saved)) -> String {
  let keys =
    profiles
    |> list.filter(fn(profile) { profile.key })
    |> list.map(fn(profile) {
      #(profile.name, json.object([#("apiKey", json.string("sk-test"))]))
    })
  // Every pinned profile's key account lives in the openai store, one list.
  let pinned =
    profiles
    |> list.filter(fn(profile) { profile.pinned })
  let accounts =
    list.map(pinned, fn(profile) {
      json.object([
        #("type", json.string("key")),
        #("apiKey", json.string("sk-account")),
        #("endpoint", json.string("https://openai.example/v1")),
        #("label", json.string("account")),
        #("_albedo_account_id", json.string(account_id(profile))),
      ])
    })
  let stores = case accounts {
    [] -> []
    _ -> [#("openai", json.preprocessed_array(accounts))]
  }
  json.object([
    #("providers", json.object(keys)),
    #("accounts", json.object(stores)),
  ])
  |> json.to_string
}

fn config_json(profiles: List(Saved)) -> String {
  let entries = list.map(profiles, fn(profile) {
    #(profile.name, saved_json(profile))
  })
  json.object([
    #("active", json.string("p0")),
    #("providers", json.object(entries)),
  ])
  |> json.to_string
}

// The projection, read as text field values from the group alone.

fn profiles_of(value: Dynamic) -> dict.Dict(String, Dynamic) {
  let assert Ok(profiles) = decode.run(
    value,
    decode.at(["profiles"], decode.dict(decode.string, decode.dynamic)),
  )
  profiles
}

fn field_names() -> List(String) {
  [
    "enabled", "extension", "endpoint", "protocol", "model", "effort",
    "image_edge", "project", "has_key", "account_id",
  ]
}

fn field_text(profile_value: Dynamic) -> List(#(String, String)) {
  field_names()
  |> list.map(fn(name) {
    let assert Ok(value) = decode.run(
      profile_value,
      decode.at([name], decode.dynamic),
    )
    #(name, albedo_json.encode(value))
  })
}

fn quoted(value: String) -> String {
  json.to_string(json.string(value))
}

/// The fields a profile reads as, from the saved document alone.
fn model_fields(profile: Saved) -> List(#(String, String)) {
  [
    #("enabled", case profile.disabled {
      True -> "false"
      False -> "true"
    }),
    #("extension", quoted(profile.extension)),
    #("endpoint", case profile.endpoint {
      "" -> "null"
      value -> quoted(value)
    }),
    #("protocol", quoted(profile.protocol)),
    #("model", quoted(profile.model)),
    #("effort", case profile.effort {
      None -> "null"
      Some(value) -> quoted(value)
    }),
    #("image_edge", case profile.image_edge {
      None -> "null"
      Some(value) -> int.to_string(value)
    }),
    #("project", case profile.project {
      None -> "null"
      Some(value) -> quoted(value)
    }),
    #("has_key", case profile.key || profile.pinned {
      True -> "true"
      False -> "false"
    }),
    #("account_id", case profile.pinned {
      True -> quoted(account_id(profile))
      False -> "null"
    }),
  ]
}

fn with_enabled(
  fields: List(#(String, String)),
  enabled: Bool,
) -> List(#(String, String)) {
  list.map(fields, fn(field) {
    case field.0 {
      "enabled" -> #("enabled", case enabled {
        True -> "true"
        False -> "false"
      })
      _ -> field
    }
  })
}

fn show(fields: List(#(String, String))) -> String {
  fields
  |> list.map(fn(entry) { entry.0 <> "=" <> entry.1 })
  |> string.join(" ")
}

fn sorted(fields: List(#(String, String))) -> List(#(String, String)) {
  list.sort(fields, fn(first, second) { string.compare(first.0, second.0) })
}

fn expect_fields(
  what: String,
  found: List(#(String, String)),
  expected: List(#(String, String)),
) -> Nil {
  case sorted(found) == sorted(expected) {
    True -> Nil
    False ->
      panic as {
        what <> ": found " <> show(found) <> ", expected " <> show(expected)
      }
  }
}

fn unused_resolve(
  _value: Dynamic,
) -> Result(dict.Dict(String, dict.Dict(String, Option(Bool))), String) {
  Error("the providers group does not resolve capabilities")
}

fn unused_defaults(
  _prior: List(#(String, Bool)),
  _changes: List(#(String, Option(Bool))),
) -> Result(List(#(String, Bool)), settings.Refusal) {
  Error(#(400, "invalid_request", "the providers group checks no defaults"))
}

/// One patch, answering the projected group value and its next ETag.
fn patch(
  home: String,
  etag: String,
  body: json.Json,
) -> Result(#(Dynamic, String), settings.Refusal) {
  use response <- result.try(settings.patch_group(
    home,
    "providers",
    etag,
    json.to_string(body),
    extensions,
    [],
    unused_resolve,
    unused_defaults,
    fn(_, commit) { commit() },
    [],
    None,
    key_environment.empty(),
  ))
  let assert Ok(value) = json.parse(
    response,
    decode.at(["resource", "value"], decode.dynamic),
  )
  let assert Ok(next) = json.parse(
    response,
    decode.at(["resource", "etag"], decode.string),
  )
  Ok(#(value, next))
}

fn toggle_body(name: String, enabled: Bool) -> json.Json {
  json.object([
    #(
      "profiles",
      json.object([
        #(name, json.object([#("enabled", json.bool(enabled))])),
      ]),
    ),
  ])
}

fn expect_ok(what: String, outcome: Result(a, settings.Refusal)) -> a {
  case outcome {
    Ok(value) -> value
    Error(#(status, code, detail)) ->
      panic as {
        what
        <> " refused: "
        <> int.to_string(status)
        <> " "
        <> code
        <> " "
        <> detail
      }
  }
}

fn default_profile(value: Dynamic) -> String {
  case decode.run(value, decode.at(["default_profile"], decode.dynamic)) {
    Ok(found) -> albedo_json.encode(found)
    Error(_) -> "missing"
  }
}

fn selectable(home: String) -> List(String) {
  case configuration.providers(home) {
    Ok(found) -> list.map(found, fn(provider) { provider.name })
    Error(_) -> []
  }
}

fn enabled_text(enabled: Bool) -> String {
  case enabled {
    True -> "true"
    False -> "false"
  }
}

fn toggle(
  home: String,
  etag: String,
  profile: Saved,
  enabled: Bool,
) -> String {
  let label = "enabled=" <> enabled_text(enabled) <> " on " <> profile.name
  let #(value, etag) =
    expect_ok(label, patch(home, etag, toggle_body(profile.name, enabled)))
  let assert Ok(projected) = dict.get(profiles_of(value), profile.name)
  proptest.bump(case enabled {
    True -> "enable"
    False -> "disable"
  })
  expect_fields(label, field_text(projected), with_enabled(model_fields(profile), enabled))
  etag
}

pub fn main() -> Nil {
  proptest.check(
    "providers projection and availability round trip",
    25,
    case_generator(),
    fn(profiles) {
      let home = "/tmp/albedo-proptest-settings-" <> int.to_string(proptest.unique())
      proptest.remove_tree(home)
      proptest.putenv("ALBEDO_HOME", home)
      proptest.write_file(
        home <> "/config.json",
        <<config_json(profiles):utf8>>,
        1_700_000_000,
      )
      let creds = creds_json(profiles)
      proptest.write_file(home <> "/creds.json", <<creds:utf8>>, 1_700_000_000)
      let assert Ok(snapshot) = settings.observe_group(home, "providers", [])
      let assert Some(etag) = snapshot.etag
      let assert Ok(initial) = json.parse(snapshot.value, decode.dynamic)

      // A freshly saved document projects its own fields.
      list.each(profiles, fn(profile) {
        let assert Ok(value) = dict.get(profiles_of(initial), profile.name)
        proptest.bump("profile")
        expect_fields(
          "fresh projection of " <> profile.name,
          field_text(value),
          model_fields(profile),
        )
      })

      // Every profile toggles off and back on: the projection returns to the
      // saved fields, and availability follows the flag.
      let wanted_default = default_profile(initial)
      list.fold(profiles, etag, fn(etag, profile) {
        let etag = toggle(home, etag, profile, False)
        case list.contains(selectable(home), profile.name) {
          True ->
            panic as {
              profile.name <> " stayed selectable while disabled"
            }
          False -> Nil
        }
        case configuration.named(home, profile.name) {
          Error(configuration.Disabled) -> Nil
          _ ->
            panic as {
              profile.name <> " did not report itself disabled after the patch"
            }
        }
        let assert Ok(disabled) =
          settings.observe_group(home, "providers", [])
        let assert Ok(disabled_value) =
          json.parse(disabled.value, decode.dynamic)
        case default_profile(disabled_value) == wanted_default {
          True -> Nil
          False ->
            panic as {
              "disabling "
              <> profile.name
              <> " changed the default profile"
            }
        }
        let etag = toggle(home, etag, profile, True)
        case list.contains(selectable(home), profile.name) {
          True -> Nil
          False ->
            panic as {
              profile.name <> " stayed unavailable after re-enabling"
            }
        }
        etag
      })
      // Availability never touches saved credentials.
      case read_file(home <> "/creds.json") {
        Ok(bytes) ->
          case bytes == <<creds:utf8>> {
            True -> Nil
            False -> panic as "the credentials file changed across the toggles"
          }
        Error(_) -> panic as "the credentials file is missing"
      }
      proptest.remove_tree(home)
    },
  )
  field_patch_property()
}

// ---- field-wise patches -----------------------------------------------------

/// One profile's patch: the API fields and values, and the projection fields
/// they must show afterwards.
pub type Edit {
  Edit(name: String, api: List(#(String, json.Json)), shown: List(#(String, String)))
}

fn edit_set() -> qcheck.Generator(List(#(String, json.Json, String))) {
  let effort =
    qcheck.from_weighted_generators(
      #(2, qcheck.return(#("effort", json.null(), "null"))),
      [#(2, pick(["low", "high"]) |> qcheck.map(fn(level) {
        #("effort", json.string(level), quoted(level))
      }))],
    )
  let image_edge =
    qcheck.from_weighted_generators(
      #(2, qcheck.return(#("image_edge", json.null(), "null"))),
      [#(2, qcheck.bounded_int(1, 65_536) |> qcheck.map(fn(edge) {
        #("image_edge", json.int(edge), int.to_string(edge))
      }))],
    )
  let project =
    qcheck.from_weighted_generators(
      #(2, qcheck.return(#("project", json.null(), "null"))),
      [#(2, pick(["r", "s"]) |> qcheck.map(fn(value) {
        #("project", json.string(value), quoted(value))
      }))],
    )
  let model =
    pick(["m3", "m4"])
    |> qcheck.map(fn(value) { #("model", json.string(value), quoted(value)) })
  let protocol =
    pick(["responses", "chat_completions"])
    |> qcheck.map(fn(value) { #("protocol", json.string(value), quoted(value)) })
  qcheck.map5(
    qcheck.option_from(effort),
    qcheck.option_from(image_edge),
    qcheck.option_from(project),
    qcheck.option_from(model),
    qcheck.option_from(protocol),
    fn(effort, image_edge, project, model, protocol) {
      list.filter_map([effort, image_edge, project, model, protocol], fn(found) {
        case found {
          Some(change) -> Ok(change)
          None -> Error(Nil)
        }
      })
    },
  )
}

fn apply_edits(
  base: List(#(String, String)),
  edits: List(#(String, String)),
) -> List(#(String, String)) {
  list.fold(edits, base, fn(fields, edit) {
    list.map(fields, fn(field) {
      case field.0 == edit.0 {
        True -> edit
        False -> field
      }
    })
  })
}

fn field_patch_property() -> Nil {
  proptest.check(
    "a providers patch overrides only the fields it names",
    25,
    qcheck.bind(
      qcheck.generic_list(saved(), qcheck.bounded_int(1, 3)),
      fn(raw) {
        let profiles =
          list.index_map(raw, fn(profile, index) {
            Saved(..profile, name: "p" <> int.to_string(index))
          })
        qcheck.map(
          qcheck.fixed_length_list_from(edit_set(), list.length(profiles)),
          fn(edits) { #(profiles, edits) },
        )
      },
    ),
    fn(input) {
      let #(profiles, edits) = input
      let home = "/tmp/albedo-proptest-fields-" <> int.to_string(proptest.unique())
      proptest.remove_tree(home)
      proptest.putenv("ALBEDO_HOME", home)
      proptest.write_file(
        home <> "/config.json",
        <<config_json(profiles):utf8>>,
        1_700_000_000,
      )
      let creds = creds_json(profiles)
      proptest.write_file(home <> "/creds.json", <<creds:utf8>>, 1_700_000_000)
      let assert Ok(snapshot) = settings.observe_group(home, "providers", [])
      let assert Some(etag) = snapshot.etag
      let assert Ok(initial) = json.parse(snapshot.value, decode.dynamic)
      let members =
        list.map(list.zip(profiles, edits), fn(pair) {
          let #(profile, changes) = pair
          #(profile.name, json.object(list.map(changes, fn(change) {
            #(change.0, change.1)
          })))
        })
      let #(after, _) =
        expect_ok(
          "field patch",
          patch(home, etag, json.object([#("profiles", json.object(members))])),
        )
      list.each(list.zip(profiles, edits), fn(pair) {
        let #(profile, changes) = pair
        let assert Ok(before) = dict.get(profiles_of(initial), profile.name)
        let assert Ok(now) = dict.get(profiles_of(after), profile.name)
        proptest.bump("patched")
        expect_fields(
          "patch on " <> profile.name,
          field_text(now),
          apply_edits(
            field_text(before),
            list.map(changes, fn(change) { #(change.0, change.2) }),
          ),
        )
      })
      proptest.remove_tree(home)
    },
  )
}
