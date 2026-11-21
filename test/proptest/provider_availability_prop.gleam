//// Provider availability (albedo_sdk/profiles.gleam) against an independent
//// model of docs/provider-availability.md: a missing `enabled` means enabled,
//// a disabled profile stays saved but is never selectable, and a profile that
//// cannot decode is unusable whatever its flag says.

import albedo_sdk/profiles as configuration
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

/// A saved `enabled` value: absent, a boolean, or something else.
pub type Flag {
  Missing
  Flag(Bool)
  Other(String)
}

/// One saved profile as the document spells it.
pub type Saved {
  Saved(
    name: String,
    extension: Option(String),
    model: Option(String),
    protocol: Option(String),
    api: Option(String),
    endpoint: Option(String),
    flag: Flag,
  )
}

pub type Kind {
  Usable
  Disabled
  Unusable
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn flag() -> qcheck.Generator(Flag) {
  qcheck.from_weighted_generators(
    #(6, qcheck.return(Missing)),
    [
      #(2, qcheck.return(Flag(True))),
      #(3, qcheck.return(Flag(False))),
      // A raw JSON value in place of the flag.
      #(1, pick(["null", "3", "\"no\"", "[]"]) |> qcheck.map(Other)),
    ],
  )
}

fn optional(values: List(a)) -> qcheck.Generator(Option(a)) {
  qcheck.from_weighted_generators(
    #(2, qcheck.return(None)),
    list.map(values, fn(value) { #(1, qcheck.return(Some(value))) }),
  )
}

fn model_field() -> qcheck.Generator(Option(String)) {
  qcheck.from_weighted_generators(
    #(8, pick(["m1", "m2"]) |> qcheck.map(Some)),
    [
      #(1, qcheck.return(Some(""))),
      #(1, qcheck.return(None)),
    ],
  )
}

fn protocol_field() -> qcheck.Generator(Option(String)) {
  qcheck.from_weighted_generators(
    #(8, pick(["responses", "chat_completions"]) |> qcheck.map(Some)),
    [#(1, qcheck.return(Some("messages"))), #(1, qcheck.return(None))],
  )
}

fn saved_generator() -> qcheck.Generator(Saved) {
  qcheck.map6(
    qcheck.from_weighted_generators(
      #(8, pick(["openai", "anthropic-api"])),
      [#(2, pick(["bedrock", "zed", ""]))],
    ),
    model_field(),
    protocol_field(),
    optional(["messages", "converse", "text"]),
    optional(["https://a.example/v1", "http://b.example", ""]),
    flag(),
    fn(extension, model, protocol, api, endpoint, flag) {
      Saved("", Some(extension), model, protocol, api, endpoint, flag)
    },
  )
}

pub type Document {
  Named(active: Option(String), profiles: List(Saved))
  Legacy(profile: Saved)
}

fn named_generator() -> qcheck.Generator(Document) {
  qcheck.map3(
    qcheck.generic_list(saved_generator(), qcheck.bounded_int(0, 5)),
    qcheck.from_weighted_generators(
      #(6, qcheck.return(None)),
      [
        #(2, pick(["p0", "p1", ""]) |> qcheck.map(Some)),
        #(2, qcheck.return(Some("ghost"))),
      ],
    ),
    qcheck.from_weighted_generators(
      #(9, qcheck.return("")),
      [#(1, pick(["p0", "p1"]))],
    ),
    fn(entries, active, drop) {
      // Names follow position, so each saved name is unique.
      let profiles =
        entries
        |> list.index_map(fn(entry, index) {
          Saved(..entry, name: "p" <> int.to_string(index))
        })
        |> list.filter(fn(profile) { profile.name != drop })
      Named(active, profiles)
    },
  )
}

fn case_generator() -> qcheck.Generator(Document) {
  let legacy =
    qcheck.from_weighted_generators(
      #(9, qcheck.return(False)),
      [#(1, qcheck.return(True))],
    )
  qcheck.bind(legacy, fn(legacy) {
    case legacy {
      True ->
        qcheck.map(saved_generator(), fn(profile) {
          Legacy(Saved(..profile, name: "default"))
        })
      False -> named_generator()
    }
  })
}

// Rendering: the document text, built here rather than through a codec.

fn json_text(value: String) -> String {
  "\"" <> value <> "\""
}

fn flag_fields(flag: Flag) -> List(String) {
  case flag {
    Missing -> []
    Flag(value) -> ["\"enabled\":" <> case value {
      True -> "true"
      False -> "false"
    }]
    Other(raw) -> ["\"enabled\":" <> raw]
  }
}

fn profile_text(profile: Saved) -> String {
  let field = fn(name, value) { json_text(name) <> ":" <> json_text(value) }
  list.append(
    flag_fields(profile.flag),
    list.append(
      list.append(
        case profile.extension {
          None -> []
          Some(value) -> [field("extension", value)]
        },
        list.append(
          case profile.model {
            None -> []
            Some(value) -> [field("model", value)]
          },
          list.append(
            case profile.protocol {
              None -> []
              Some(value) -> [field("protocol", value)]
            },
            list.append(
              case profile.api {
                None -> []
                Some(value) -> [field("api", value)]
              },
              case profile.endpoint {
                None -> []
                Some(value) -> [field("baseUrl", value)]
              },
            ),
          ),
        ),
      ),
      [field("effort", "medium"), field("project", "p")],
    ),
  )
  |> string.join(",")
}

fn document_json(document: Document) -> String {
  case document {
    Named(active, profiles) -> {
      let members =
        list.map(profiles, fn(profile) {
          json_text(profile.name) <> ":{" <> profile_text(profile) <> "}"
        })
      let active = case active {
        None -> ""
        Some(name) -> "\"active\":" <> json_text(name) <> ","
      }
      "{" <> active <> "\"providers\":{" <> string.join(members, ",") <> "}}"
    }
    Legacy(profile) -> "{" <> profile_text(profile) <> "}"
  }
}

// The model: which kind each saved entry is, from the documented rules alone.

/// provider_decoder: `model` is required text, `protocol` is one of two
/// names, `extension` defaults to openai, and a bedrock API mode is known.
fn decodes(profile: Saved) -> Bool {
  let extension = unwrap(profile.extension, "openai")
  let model_ok = case profile.model {
    Some(_) -> True
    None -> False
  }
  let protocol_ok = case profile.protocol {
    Some("responses") | Some("chat_completions") -> True
    _ -> False
  }
  let api_ok = case extension, profile.api {
    "bedrock", Some("messages") | "bedrock", Some("converse") -> True
    "bedrock", Some(_) -> False
    _, _ -> True
  }
  model_ok && protocol_ok && api_ok
}

/// `configured` additionally refuses a blank name, extension or model.
fn configured(profile: Saved) -> Bool {
  let extension = unwrap(profile.extension, "openai")
  let model = unwrap(profile.model, "")
  string.trim(model) != "" && string.trim(extension) != ""
}

fn unwrap(value: Option(String), default: String) -> String {
  case value {
    Some(value) -> value
    None -> default
  }
}

fn kind(profile: Saved) -> Kind {
  case profile.flag {
    // A saved `enabled` that is not a boolean is refused, null included.
    Other(_) -> Unusable
    Flag(False) -> Disabled
    _ ->
      case decodes(profile) && configured(profile) {
        True -> Usable
        False -> Unusable
      }
  }
}

pub type Expected {
  Readable(List(#(String, Kind)))
  Unreadable
}

fn expected(document: Document) -> Expected {
  case document {
    // A legacy flat config predates the flag: only whether it decodes and
    // names a usable profile matters.
    Legacy(profile) ->
      case decodes(profile) {
        False -> Unreadable
        True ->
          Readable([
            #(profile.name, case configured(profile) {
              True -> Usable
              False -> Unusable
            }),
          ])
      }
    Named(_, profiles) ->
      Readable(
        profiles
        |> list.map(fn(profile) { #(profile.name, kind(profile)) })
        |> list.sort(fn(first, second) { string.compare(first.0, second.0) }),
      )
  }
}

fn active_name(document: Document) -> Option(String) {
  case document {
    Legacy(_) -> Some("default")
    Named(active, _) -> active
  }
}

fn describe(kind: Kind) -> String {
  case kind {
    Usable -> "usable"
    Disabled -> "disabled"
    Unusable -> "unusable"
  }
}

fn found_kind(
  entry: Result(configuration.Provider, #(String, configuration.Failure)),
) -> Kind {
  case entry {
    Ok(_) -> Usable
    Error(#(_, configuration.Disabled)) -> Disabled
    Error(_) -> Unusable
  }
}

fn expect_kind(what: String, found: Kind, expected: Kind) -> Nil {
  case found == expected {
    True -> Nil
    False ->
      panic as {
        what <> ": found " <> describe(found) <> ", expected " <> describe(expected)
      }
  }
}

fn check_profiles(home: String, wanted: List(#(String, Kind))) -> Nil {
  let wanted_names = list.map(wanted, fn(entry) { entry.0 })
  let profiles = case configuration.profiles(home) {
    Ok(profiles) -> profiles
    Error(_) ->
      panic as "profiles() reported a read failure for a saved document"
  }
  let found_names =
    list.map(profiles, fn(entry) {
      case entry {
        Ok(provider) -> provider.name
        Error(#(name, _)) -> name
      }
    })
  case found_names == wanted_names {
    True -> Nil
    False ->
      panic as {
        "profiles() named "
        <> string.join(found_names, ",")
        <> " instead of "
        <> string.join(wanted_names, ",")
      }
  }
  list.each(list.zip(profiles, wanted), fn(pair) {
    let #(entry, want) = pair
    proptest.bump(describe(want.1))
    expect_kind("profiles() " <> want.0, found_kind(entry), want.1)
  })
}

fn check_selectable(home: String, wanted: List(#(String, Kind))) -> Nil {
  let selectable =
    wanted
    |> list.filter(fn(entry) { entry.1 == Usable })
    |> list.map(fn(entry) { entry.0 })
  let offered = case configuration.providers(home) {
    Ok(found) -> list.map(found, fn(provider) { provider.name })
    Error(_) -> []
  }
  case offered == selectable {
    True -> Nil
    False ->
      panic as {
        "providers() offered "
        <> string.join(offered, ",")
        <> " instead of "
        <> string.join(selectable, ",")
      }
  }
}

fn check_named(home: String, wanted: List(#(String, Kind))) -> Nil {
  list.each(wanted, fn(want) {
    let found = configuration.named(home, want.0)
    case want.1 {
      Disabled ->
        case found {
          Error(configuration.Disabled) -> Nil
          _ ->
            panic as {
              "named(" <> want.0 <> ") did not report the profile disabled"
            }
        }
      Usable ->
        case found {
          Ok(provider) ->
            case provider.name == want.0 {
              True -> Nil
              False ->
                panic as {
                  "named(" <> want.0 <> ") answered another profile"
                }
            }
          Error(failure) ->
            panic as {
              "named("
              <> want.0
              <> ") refused a usable profile: "
              <> configuration.explain(failure)
            }
        }
      Unusable ->
        case found {
          Ok(_) ->
            panic as {
              "named(" <> want.0 <> ") accepted an unusable profile"
            }
          Error(configuration.Disabled) ->
            panic as {
              "named(" <> want.0 <> ") called an unusable profile disabled"
            }
          Error(_) -> Nil
        }
    }
  })
}

fn kind_of(wanted: List(#(String, Kind)), name: String) -> Option(Kind) {
  case list.find(wanted, fn(entry) { entry.0 == name }) {
    Ok(entry) -> Some(entry.1)
    Error(_) -> None
  }
}

fn check_active(
  home: String,
  document: Document,
  wanted: List(#(String, Kind)),
) -> Nil {
  let chosen = case active_name(document) {
    None -> None
    Some(name) -> kind_of(wanted, name)
  }
  case configuration.active(home) {
    Ok(provider) ->
      case kind_of(wanted, provider.name) {
        Some(Usable) -> Nil
        _ ->
          panic as "active() answered a profile the model calls unusable"
      }
    Error(failure) ->
      case chosen {
        Some(Usable) ->
          panic as {
            "active() refused a usable profile: " <> configuration.explain(failure)
          }
        _ -> Nil
      }
  }
}

fn check_unreadable(home: String) -> Nil {
  proptest.bump("unreadable")
  case configuration.profiles(home) {
    Ok(_) -> panic as "profiles() read a document that does not decode"
    Error(_) -> Nil
  }
  case configuration.providers(home) {
    Ok(_) -> panic as "providers() read a document that does not decode"
    Error(_) -> Nil
  }
  case configuration.active(home) {
    Ok(_) -> panic as "active() read a document that does not decode"
    Error(_) -> Nil
  }
}

pub fn main() -> Nil {
  proptest.check(
    "saved profiles split into usable, disabled and unusable",
    100,
    case_generator(),
    fn(document) {
      let home = "/tmp/albedo-proptest-avail-" <> int.to_string(proptest.unique())
      proptest.remove_tree(home)
      proptest.putenv("ALBEDO_HOME", home)
      proptest.write_file(
        home <> "/config.json",
        <<document_json(document):utf8>>,
        1_700_000_000,
      )
      case expected(document) {
        Unreadable -> check_unreadable(home)
        Readable(wanted) -> {
          check_profiles(home, wanted)
          check_selectable(home, wanted)
          check_named(home, wanted)
          check_active(home, document, wanted)
        }
      }
      proptest.remove_tree(home)
    },
  )
}
