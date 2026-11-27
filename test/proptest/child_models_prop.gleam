//// Which profile and model a child runs on, checked against a reference
//// model built from the generated profile set rather than from the code.
////
//// A case is a set of model-list groups (an extension name plus an optional
//// endpoint, listing model ids) and saved profiles that point at them, each
//// enabled or disabled. Every group becomes a fake catalog, so the runtime
//// lists exactly what the case says, with no network. The properties then
//// check resolve, available, resolve_switch and fits against the case.

import albedo/history/conversation
import albedo/refusal
import albedo/runtime
import albedo/runtime/admission
import albedo/runtime/shared
import albedo/runtime/state as runtime_state
import albedo/session/child_models
import albedo/storage/core_store
import albedo_model
import albedo_sdk/extension
import albedo_sdk/key_environment
import albedo_sdk/profiles as configuration
import albedo_sdk/session_info
import albedo_sdk/store
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import proptest
import qcheck

const profiles_at_most = 3

const names = ["default", "p1", "p1x", "p2", "p3"]

/// `a/b` stands for a catalog id that contains a slash, as gateway ids do.
const models = ["m1", "m2", "m3", "a/b"]

const endpoints = [None, Some("https://a"), Some("https://b")]

pub type Group {
  Group(extension: String, endpoint: Option(String), models: List(String))
}

pub type Profile {
  Profile(name: String, group: Int, model: String, enabled: Bool)
}

pub type Case {
  Case(
    home: String,
    groups: List(Group),
    profiles: List(Profile),
    active: String,
    parent: String,
    parent_model: String,
    requests: List(String),
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn at(values: List(a), index: Int) -> Result(a, Nil) {
  list.first(list.drop(values, index))
}

fn subset(values: List(a)) -> qcheck.Generator(List(a)) {
  qcheck.map(
    qcheck.generic_list(qcheck.bool(), qcheck.bounded_int(0, 4)),
    fn(flags) {
      list.index_map(flags, fn(flag, i) { #(flag, i) })
      |> list.filter_map(fn(entry) {
        case entry.0, at(values, entry.1) {
          True, Ok(value) -> Ok(value)
          _, _ -> Error(Nil)
        }
      })
      |> list.take(3)
    },
  )
}

/// Names for the profiles: a labelled random subset, filled from the rest so
/// profiles never share a name.
fn name_set(count: Int) -> qcheck.Generator(List(String)) {
  qcheck.map(subset(names), fn(chosen) {
    list.unique(list.append(chosen, list.filter(names, fn(name) {
      !list.contains(chosen, name)
    })))
    |> list.take(count)
  })
}

/// Groups that share an extension and endpoint would list one set, so their
/// case merges them.
fn merge_groups(raw: List(Group), merged: List(Group)) -> List(Group) {
  case raw {
    [] -> list.reverse(merged)
    [group, ..rest] -> {
      let same = fn(other: Group) {
        other.extension == group.extension && other.endpoint == group.endpoint
      }
      case list.find(merged, same) {
        Error(Nil) -> merge_groups(rest, [group, ..merged])
        Ok(_) ->
          merge_groups(
            rest,
            list.map(merged, fn(other) {
              case same(other) {
                True -> Group(..other, models: list.unique(list.append(other.models, group.models)))
                False -> other
              }
            }),
          )
      }
    }
  }
}

fn group_generator() -> qcheck.Generator(Group) {
  qcheck.map3(
    pick(["ext0", "ext1", "ext2"]),
    pick(endpoints),
    subset(models),
    fn(extension, endpoint, listed) { Group(extension, endpoint, listed) },
  )
}

fn case_generator() -> qcheck.Generator(Case) {
  use count <- qcheck.bind(qcheck.bounded_int(1, profiles_at_most))
  use chosen <- qcheck.bind(name_set(count))
  use groups <- qcheck.bind(
    qcheck.map(
      qcheck.generic_list(group_generator(), qcheck.bounded_int(1, 3)),
      merge_groups(_, []),
    ),
  )
  let group_count = list.length(groups)
  use profiles <- qcheck.bind(
    qcheck.map(
      qcheck.fixed_length_list_from(
        qcheck.map3(
          pick(models),
          qcheck.bounded_int(0, int.max(0, group_count - 1)),
          qcheck.from_weighted_generators(#(8, qcheck.return(True)), [
            #(3, qcheck.return(False)),
          ]),
          fn(model, group, enabled) { #(model, group, enabled) },
        ),
        count,
      ),
      fn(raw) {
        list.index_map(raw, fn(parts, index) {
          Profile(
            name: at(chosen, index) |> result.unwrap("unnamed"),
            group: parts.1,
            model: parts.0,
            enabled: parts.2,
          )
        })
      },
    ),
  )
  let names_here = list.map(profiles, fn(profile) { profile.name })
  let active = at(names_here, 0) |> result.unwrap("default")
  use parent <- qcheck.bind(pick(["", "missing", "none", ..names_here]))
  use parent_model <- qcheck.bind(pick(["m1", "m2", "m99", "a/b"]))
  let requests = [
    "m1", "m99", "a/b",
    ..list.flat_map(names_here, fn(name) {
      [name <> "/m1", name <> "/a/b", name <> "/m99"]
    }),
  ]
  use extra <- qcheck.bind(subset(requests))
  qcheck.return(Case(
    "",
    groups,
    profiles,
    active,
    parent,
    parent_model,
    list.unique(list.append(extra, [""])),
  ))
}

fn find(c: Case, name: String) -> Result(Profile, Nil) {
  list.find(c.profiles, fn(profile) { profile.name == name })
}

fn group_of(c: Case, profile: Profile) -> Group {
  at(c.groups, profile.group)
  |> result.unwrap(Group("none", None, []))
}

/// The profile the parent runs on: "" means the legacy session, which uses
/// `default` when it is saved and the active profile otherwise.
fn current(c: Case) -> Result(Profile, Nil) {
  case c.parent {
    "" ->
      case find(c, "default") {
        Ok(profile) -> Ok(profile)
        Error(_) -> find(c, c.active)
      }
    name -> find(c, name)
  }
}

/// The parent's profile when a child may run on it.
fn parent_profile(c: Case) -> Result(Profile, Nil) {
  use profile <- result.try(current(c))
  case profile.enabled {
    True -> Ok(profile)
    False -> Error(Nil)
  }
}

/// The profile's own model, or one its group's catalog lists.
fn offers(c: Case, profile: Profile, model: String) -> Bool {
  profile.model == model || list.contains(group_of(c, profile).models, model)
}

fn enabled(c: Case, name: String) -> Bool {
  case find(c, name) {
    Ok(profile) -> profile.enabled
    Error(Nil) -> False
  }
}

fn config_json(c: Case) -> String {
  let entries =
    list.map(c.profiles, fn(profile) {
      let group = group_of(c, profile)
      "\""
      <> profile.name
      <> "\":{\"extension\":\""
      <> group.extension
      <> "\",\"model\":\""
      <> profile.model
      <> "\",\"protocol\":\"responses\""
      <> case group.endpoint {
        None -> ""
        Some(url) -> ",\"baseUrl\":\"" <> url <> "\""
      }
      <> ",\"enabled\":"
      <> case profile.enabled {
        True -> "true"
        False -> "false"
      }
      <> "}"
    })
    |> string.join(",")
  "{\"active\":\""
  <> c.active
  <> "\",\"providers\":{"
  <> entries
  <> "}}"
}

@external(erlang, "proptest_ffi", "models_table")
fn models_table() -> Dynamic

@external(erlang, "proptest_ffi", "put_models")
fn put_models(table: Dynamic, key: String, models: List(String)) -> Nil

@external(erlang, "proptest_ffi", "clear_models")
fn clear_models(table: Dynamic) -> Nil

@external(erlang, "proptest_ffi", "models")
fn listed_models(table: Dynamic, key: String) -> List(String)

const extension_names = ["ext0", "ext1", "ext2"]

/// The catalogs read the current case's ids from the table, so one published
/// runtime serves every case.
fn catalog(table: Dynamic, name: String, endpoint: String) -> extension.Plugin {
  let catalog =
    extension.ModelCatalog(
      lookup: fn(_, _) { None },
      list: fn(provider, asked, _keys) {
        case provider == name && endpoint_text(asked) == endpoint {
          True -> extension.Local(listed_models(table, name <> "|" <> endpoint))
          False -> extension.Unlisted
        }
      },
      reload: None,
    )
  extension.ModelsPlugin(catalog)
}

fn endpoint_text(endpoint: Option(String)) -> String {
  case endpoint {
    None -> ""
    Some(url) -> url
  }
}

fn extension_for(table: Dynamic, name: String) -> extension.Extension {
  let endpoints = ["", "https://a", "https://b"]
  let provider =
    extension.ModelProvider(
      catalog_provider: name,
      resolve: fn(_) { None },
      fast_mode: None,
    )
  extension.Extension(
    name: name,
    description: "",
    requires: [],
    plugins: list.append(
      list.map(endpoints, catalog(table, name, _)),
      [extension.ModelProviderPlugin(provider)],
    ),
    initialise: extension.no_initialise,
    tables: [],
    uses: [],
  )
}

pub type Bench {
  Bench(table: Dynamic, host: runtime.Runtime)
}

fn bench() -> Bench {
  let assert Ok(ledger) = store.start(":memory:", fn(_) { Ok(Nil) }, core_store.tables())
  let pool =
    admission.start(process.new_subject(), fn(_, message) { message }, fn(_) {
      Nil
    })
  let table = models_table()
  let extensions =
    list.map(extension_names, fn(name) { extension_for(table, name) })
  let base =
    at(extensions, 0)
    |> result.unwrap(extension_for(table, "none"))
  let installed =
    runtime_state.Installed(
      base: base,
      extensions: extensions,
      default_enabled: [],
      quarantined: [],
      followers: [],
      schedules: [],
      keys: key_environment.empty(),
      preload: [],
    )
  Bench(
    table,
    runtime_state.Runtime(
      process.new_subject(),
      ledger,
      shared.publish(installed),
      pool,
    ),
  )
}

fn info(c: Case, model: String) -> conversation.Info {
  session_info.Info(
    id: "parent",
    title: "",
    cwd: "/tmp",
    provider: c.parent,
    model: model,
    protocol: albedo_model.Responses,
    stage: session_info.Idle,
    last_assistant_at: None,
    effort: None,
    fast: False,
    cyber_access: None,
  )
}

fn prepare(b: Bench, c: Case) -> Case {
  let home = "/tmp/proptest-child-models/" <> int.to_string(proptest.unique())
  let c = Case(..c, home: home)
  proptest.write_file(
    home <> "/config.json",
    <<config_json(c):utf8>>,
    1_700_000_000,
  )
  clear_models(b.table)
  list.each(c.groups, fn(group) {
    put_models(
      b.table,
      group.extension <> "|" <> endpoint_text(group.endpoint),
      group.models,
    )
  })
  c
}

fn clean(c: Case) -> Nil {
  proptest.remove_tree(c.home)
}

/// A choice's profile and model, or a category, so a mismatch reads.
fn name_of(choice: child_models.Choice) -> Result(#(String, String), String) {
  case choice {
    Ok(#(profile, model)) -> Ok(#(profile.name, model))
    Error(refusal.ModelUnavailable(provider)) ->
      Error("model-unavailable " <> provider)
    Error(refusal.ModelAmbiguous) -> Error("ambiguous")
    Error(refusal.ProviderUnconfigured(_)) -> Error("config")
    Error(refusal.Unavailable(_)) -> Error("unavailable")
    Error(_) -> Error("other")
  }
}

/// The profile name a request names, when a saved profile's prefix matches.
fn qualified(c: Case, request: String) -> Option(#(String, String)) {
  list.find_map(c.profiles, fn(profile) {
    let prefix = profile.name <> "/"
    case string.starts_with(request, prefix) {
      True -> Ok(#(profile.name, string.drop_start(request, string.length(prefix))))
      False -> Error(Nil)
    }
  })
  |> result.map(Some)
  |> result.unwrap(None)
}

/// The model of a bare request, following the documented move rules.
fn expected_move(c: Case, model: String) -> Result(#(String, String), String) {
  use parent <- result.try(case parent_profile(c) {
    Ok(profile) -> Ok(profile)
    Error(_) -> Error("config")
  })
  case offers(c, parent, model) {
    True -> Ok(#(parent.name, model))
    False -> {
      let others =
        list.filter(c.profiles, fn(profile) {
          profile.name != parent.name && profile.enabled && offers(c, profile, model)
        })
      case others {
        [] -> Ok(#(parent.name, model))
        [one] -> Ok(#(one.name, model))
        _ -> Error("ambiguous")
      }
    }
  }
}

/// Every profile and model the session may hand a child, in the documented
/// order: its own model, its own provider's models, then other providers'.
fn expected_available(c: Case) -> List(String) {
  let parent_name = case parent_profile(c) {
    Ok(profile) -> Some(profile.name)
    Error(_) -> None
  }
  let entries = fn(profile: Profile) {
    list.map(
      list.unique([profile.model, ..group_of(c, profile).models]),
      fn(model) { profile.name <> "/" <> model },
    )
  }
  let own = case parent_name {
    None -> []
    Some(name) -> [name <> "/" <> c.parent_model]
  }
  let enabled_profiles =
    list.filter(c.profiles, fn(profile) { profile.enabled })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
  let #(same, other) =
    list.partition(enabled_profiles, fn(profile) {
      parent_name == Some(profile.name)
    })
  list.unique(
    list.append(own, list.flat_map(list.append(same, other), entries)),
  )
}

fn expected_fit(c: Case, want: #(String, String, String)) -> #(Bool, Bool, List(String)) {
  let #(_, provider, model) = want
  let profile = find(c, provider)
  let has_profile = case profile {
    Ok(found) -> found.enabled
    Error(_) -> False
  }
  let offering =
    c.profiles
    |> list.filter(fn(found) { found.enabled && offers(c, found, model) })
    |> list.map(fn(found) { found.name })
  let ok = list.contains(offering, provider)
  #(has_profile, ok, case ok {
    True -> []
    False -> offering
  })
}

fn fail(message: String) -> Nil {
  panic as message
}

fn context(c: Case) -> String {
  " from config "
  <> config_json(c)
  <> " parent "
  <> string.inspect(c.parent)
  <> "/"
  <> c.parent_model
  <> ", groups "
  <> string.inspect(c.groups)
}

pub fn main() -> Nil {
  let b = bench()

  proptest.check("resolve never picks a disabled or unknown profile", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    list.each(c.requests, fn(request) {
      case child_models.resolve(h, c.home, info(c, c.parent_model), request) {
        Ok(#(profile, _)) ->
          case enabled(c, profile.name) {
            True -> proptest.bump("ok_enabled")
            False ->
              fail(
                "resolve picked "
                <> profile.name
                <> " for "
                <> string.inspect(request)
                <> context(c),
              )
          }
        Error(_) -> proptest.bump("refused")
      }
    })
    clean(c)
  })

  proptest.check("a disabled provider's explicit model is refused", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    let disabled = list.filter(c.profiles, fn(profile) { !profile.enabled })
    list.each(disabled, fn(profile) {
      list.each(list.append([profile.model, ..group_of(c, profile).models], ["m1"]), fn(model) {
        let request = profile.name <> "/" <> model
        let found =
          child_models.resolve(h, c.home, info(c, c.parent_model), request)
        let expected =
          Error(refusal.ProviderUnconfigured(configuration.Disabled))
        proptest.bump(case found == expected {
          True -> "refused_disabled"
          False -> "other"
        })
        case found == expected {
          True -> Nil
          False ->
            fail(
              "disabled "
              <> profile.name
              <> " answered "
              <> string.inspect(found)
              <> " for "
              <> string.inspect(request)
              <> context(c),
            )
        }
      })
    })
    clean(c)
  })

  proptest.check("an enabled provider keeps an explicit model it lists", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    list.each(c.profiles, fn(profile) {
      case profile.enabled {
        False -> Nil
        True ->
          list.each(list.unique([profile.model, ..group_of(c, profile).models]), fn(model) {
            let found =
              child_models.resolve(
                h,
                c.home,
                info(c, c.parent_model),
                profile.name <> "/" <> model,
              )
            let expected = Ok(#(profile.name, model))
            proptest.bump(case name_of(found) == expected {
              True -> "kept"
              False -> "moved"
            })
            case name_of(found) == expected {
              True -> Nil
              False ->
                fail(
                  "explicit "
                  <> string.inspect(profile.name <> "/" <> model)
                  <> " answered "
                  <> string.inspect(name_of(found))
                  <> context(c),
                )
            }
          })
      }
    })
    clean(c)
  })

  proptest.check("bare models follow the documented move rules", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    list.each(c.requests, fn(request) {
      case qualified(c, request) {
        // A named profile's model is the exporter's business, not this one's.
        Some(_) -> Nil
        None -> {
          let found =
            name_of(
              child_models.resolve(h, c.home, info(c, c.parent_model), request),
            )
          let wanted = case request {
            "" -> c.parent_model
            _ -> request
          }
          let expected = expected_move(c, wanted)
          proptest.bump(case found == expected {
            True -> "agrees"
            False -> "differs"
          })
          case found == expected {
            True -> Nil
            False ->
              fail(
                "bare "
                <> string.inspect(request)
                <> " answered "
                <> string.inspect(found)
                <> " expected "
                <> string.inspect(expected)
                <> context(c),
              )
          }
        }
      }
    })
    clean(c)
  })

  proptest.check("available lists what the session may hand a child", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    let entries = child_models.available(h, c.home, info(c, c.parent_model))
    let expected = expected_available(c)
    // Two profiles on one extension with different endpoints list apart.
    let shared =
      c.groups
      |> list.map(fn(group) { group.extension })
      |> list.unique
      |> list.length
    proptest.bump(case shared < list.length(c.groups) {
      True -> "shared_extension"
      False -> "distinct_extension"
    })
    proptest.bump(case entries == expected {
      True -> "order_agrees"
      False -> "order_differs"
    })
    case entries == expected {
      True -> Nil
      False ->
        fail(
          "available listed "
          <> string.inspect(entries)
          <> " expected "
          <> string.inspect(expected)
          <> context(c),
        )
    }
    // Every entry must come back as itself.
    list.each(entries, fn(entry) {
      let found =
        name_of(child_models.resolve(h, c.home, info(c, c.parent_model), entry))
      let wanted = list.find_map(expected, fn(other) {
        case other == entry {
          True -> Ok(other)
          False -> Error(Nil)
        }
      })
      case wanted, found {
        Ok(_), Ok(#(provider, model)) ->
          case entry == provider <> "/" <> model {
            True -> proptest.bump("self")
            False ->
              fail(
                "entry "
                <> string.inspect(entry)
                <> " resolved to "
                <> string.inspect(found)
                <> context(c),
              )
          }
        _, _ ->
          fail(
            "entry "
            <> string.inspect(entry)
            <> " resolved to "
            <> string.inspect(found)
            <> context(c),
          )
      }
    })
    clean(c)
  })

  proptest.check("switching agrees with spawning on offered models", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    list.each(c.requests, fn(request) {
      let parent = info(c, c.parent_model)
      let spawned = name_of(child_models.resolve(h, c.home, parent, request))
      let switched = name_of(child_models.resolve_switch(h, c.home, parent, request))
      let expected = case spawned {
        Error(reason) -> Error(reason)
        Ok(#(provider, model)) ->
          case find(c, provider) {
            Ok(profile) ->
              case offers(c, profile, model) {
                True -> Ok(#(provider, model))
                False -> Error("unavailable")
              }
            Error(_) -> Error("unavailable")
          }
      }
      proptest.bump(case switched == expected {
        True -> "agrees"
        False -> "differs"
      })
      case switched == expected {
        True -> Nil
        False ->
          fail(
            "switch of "
            <> string.inspect(request)
            <> " answered "
            <> string.inspect(switched)
            <> " expected "
            <> string.inspect(expected)
            <> context(c),
          )
      }
    })
    clean(c)
  })

  proptest.check("fits reports whether a session can move here", 50, case_generator(), fn(c) {
    let c = prepare(b, c)
    let h = b.host
    let wants =
      list.index_map(c.profiles, fn(profile, index) {
        #(int.to_string(index), profile.name, profile.model)
      })
      |> list.append([
        #("missing", "no-such-profile", "m1"),
        #("slash", "no-such-profile", "a/b"),
      ])
    let found = child_models.fits(h, c.home, wants)
    list.each(list.zip(wants, found), fn(pair) {
      let #(want, fit) = pair
      let #(has_profile, ok, alternatives) = expected_fit(c, want)
      let agrees =
        fit.session == want.0
        && fit.profile == want.1
        && fit.model == want.2
        && fit.has_profile == has_profile
        && fit.ok == ok
        && list.sort(fit.alternatives, string.compare)
          == list.sort(alternatives, string.compare)
      proptest.bump(case agrees {
        True -> "agrees"
        False -> "differs"
      })
      case agrees {
        True -> Nil
        False ->
          fail(
            "fit of "
            <> string.inspect(want)
            <> " was "
            <> string.inspect(fit)
            <> " expected "
            <> string.inspect(#(has_profile, ok, alternatives))
            <> context(c),
          )
      }
    })
    clean(c)
  })

  io.println("done")
}
