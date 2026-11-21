//// Profile endpoints (albedo/session/session_provider.gleam): the single
//// reader and the bulk reader must agree, a Zed profile must list its catalog
//// under its own name rather than a shared endpoint, and an ordinary profile's
//// endpoint is its saved base URL trimmed.

import albedo/session/session_provider
import albedo_sdk/extension
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

pub type Saved {
  Saved(name: String, extension: String, endpoint: String)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn saved() -> qcheck.Generator(Saved) {
  qcheck.map3(
    pick(["zed", "openai", "anthropic-api", "bedrock"]),
    pick(["", "https://a.example/v1", "  https://b.example/v1  ", "https://c.example/v1/"]),
    qcheck.return(""),
    fn(extension, endpoint, _) { Saved("", extension, endpoint) },
  )
}

fn case_generator() -> qcheck.Generator(List(Saved)) {
  qcheck.map(
    qcheck.generic_list(saved(), qcheck.bounded_int(0, 4)),
    fn(profiles) {
      list.index_map(profiles, fn(profile, index) {
        Saved(..profile, name: "p" <> int.to_string(index))
      })
    },
  )
}

fn json_text(value: String) -> String {
  "\"" <> value <> "\""
}

fn config_json(profiles: List(Saved)) -> String {
  let members =
    list.map(profiles, fn(profile) {
      json_text(profile.name)
      <> ":{\"extension\":"
      <> json_text(profile.extension)
      <> ",\"baseUrl\":"
      <> json_text(profile.endpoint)
      <> ",\"model\":\"m1\",\"protocol\":\"responses\"}"
    })
  "{\"active\":\"p0\",\"providers\":{" <> string.join(members, ",") <> "}}"
}

fn show(found: Option(String)) -> String {
  case found {
    None -> "none"
    Some(value) -> value
  }
}

pub fn main() -> Nil {
  proptest.check(
    "profile endpoints agree between the single and bulk readers",
    100,
    case_generator(),
    fn(profiles) {
      let home = "/tmp/albedo-proptest-endpoints-" <> int.to_string(proptest.unique())
      proptest.remove_tree(home)
      proptest.putenv("ALBEDO_HOME", home)
      proptest.write_file(
        home <> "/config.json",
        <<config_json(profiles):utf8>>,
        1_700_000_000,
      )
      let bulk = session_provider.profile_endpoints(home)
      let names = list.map(profiles, fn(profile) { profile.name })
      // The bulk reader names every saved profile once.
      case list.sort(dict.keys(bulk), string.compare) == names {
        True -> Nil
        False ->
          panic as {
            "profile_endpoints named "
            <> string.join(dict.keys(bulk), ",")
            <> " instead of "
            <> string.join(names, ",")
          }
      }
      list.each(profiles, fn(profile) {
        let single = session_provider.profile_endpoint(home, profile.name)
        let from_bulk =
          dict.get(bulk, profile.name)
          |> result.unwrap(None)
        proptest.bump("profile")
        case show(single) == show(from_bulk) {
          True -> Nil
          False ->
            panic as {
              "profile_endpoint("
              <> profile.name
              <> ") is "
              <> show(single)
              <> " but profile_endpoints gave "
              <> show(from_bulk)
            }
        }
        let ordinary = extension.clean_endpoint(profile.endpoint)
        case profile.extension {
          "zed" -> {
            // A Zed profile's catalog is its own: the endpoint names the
            // profile, and two Zed profiles never share it.
            proptest.bump("zed")
            case
              single == Some("albedo:zed:profile:" <> profile.name)
            {
              True -> Nil
              False ->
                panic as {
                  "zed profile "
                  <> profile.name
                  <> " lists under "
                  <> show(single)
                }
            }
          }
          _ ->
            case show(single) == show(ordinary) {
              True -> Nil
              False ->
                panic as {
                  profile.name
                  <> " (" <> profile.extension <> ") is "
                  <> show(single)
                  <> " instead of its base URL "
                  <> show(ordinary)
                }
            }
        }
      })
      // Distinct Zed profiles must not share one endpoint.
      let zed =
        profiles
        |> list.filter(fn(profile) { profile.extension == "zed" })
        |> list.map(fn(profile) {
          dict.get(bulk, profile.name) |> result.unwrap(None)
        })
      case list.unique(zed) == zed {
        True -> Nil
        False -> panic as "two Zed profiles shared one catalog endpoint"
      }
      proptest.remove_tree(home)
    },
  )
}
