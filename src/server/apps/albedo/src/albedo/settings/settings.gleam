//// Daemon-owned persisted settings groups at the HTTP boundary. Reads project
//// the saved documents into groups. A patch is checked against the group's
//// ETag, applied to a candidate of the saved documents, validated, and
//// published as one group under the settings lock. Persisted names stay owned
//// by the harness, including callers from trusted model tools.
////
//// The saved documents and patches are native JSON terms. A patch value is
//// checked where it is used, in a fixed order, so a patch with several
//// faults reports the same one. A malformed value is
//// `400 invalid_request` with `invalid settings candidate`. A patch section
//// that is present but not an object, like a saved section that is not one,
//// is `503 settings_unavailable`.

import albedo/settings/projection
import albedo_json
import albedo_model as types
import albedo_protect
import albedo_sdk/capabilities
import albedo_sdk/credential_store
import albedo_sdk/extension
import albedo_sdk/key_accounts
import albedo_sdk/key_environment.{type KeyEnvironment}
import albedo_sdk/oauth
import albedo_sdk/profiles
import albedo_sdk/rotation
import albedo_sdk/settings/declared
import albedo_sdk/settings_store
import albedo_web/etag
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Group {
  Providers
  MCP
  Extensions
  /// What installed extensions declare in their own sections.
  DeclaredSettings
  Capabilities
  Models
  UI
}

pub fn parse_group(name: String) -> Result(Group, String) {
  case name {
    "providers" -> Ok(Providers)
    "mcp" -> Ok(MCP)
    "extensions" -> Ok(Extensions)
    "extension_settings" -> Ok(DeclaredSettings)
    "capabilities" -> Ok(Capabilities)
    "models" -> Ok(Models)
    "ui" -> Ok(UI)
    _ -> Error("unknown settings group")
  }
}

/// Whether saving `group` can change a session's composition. These are the
/// groups `composition_revision` hashes. The rest never call for a reload.
pub fn composes(group: Group) -> Bool {
  case group {
    Extensions | MCP | Capabilities -> True
    Providers | Models | UI | DeclaredSettings -> False
  }
}

pub type GroupSnapshot {
  GroupSnapshot(value: String, etag: Option(String))
}

/// A refusal as the HTTP boundary reports it: status, code, detail.
pub type Refusal =
  #(Int, String, String)

/// A settings document or section as a native JSON object.
type Object =
  Dict(String, Dynamic)

/// What a patch needs from the running daemon.
type Inputs {
  Inputs(
    home: String,
    group: String,
    providers: List(String),
    logins: List(oauth.Login),
    resolve: fn(Dynamic) ->
      Result(Dict(String, Dict(String, Option(Bool))), String),
    defaults: fn(List(#(String, Bool)), List(#(String, Option(Bool)))) ->
      Result(List(#(String, Bool)), Refusal),
    declarations: List(declared.Declared),
    mcp: Option(extension.McpServers),
    keys: KeyEnvironment,
  )
}

/// A validated candidate: every document, changed or not, and the
/// `validation` the response reports.
type Candidate =
  #(Object, String)

/// The outcome of the first locked pass of a patch.
type Captured {
  /// Published, with the response body.
  Complete(String)
  /// An `mcp` patch whose changed servers must be probed outside the lock
  /// before it is checked and published again.
  Probe(patch: Object, checked: List(Checked))
}

/// A changed MCP server's name, definition and secrets as probed.
type Checked =
  #(String, Dynamic, Object)

/// The documents a group projection reads.
const projected_documents = [
  "config.json",
  "creds.json",
  "extensions.json",
  "capabilities.json",
  "picker.json",
]

const revisions_file = "settings-revisions.json"

// ---- observe ----------------------------------------------------------------

/// One group's value with its ETag, or every group with each one's validator
/// when `group` is empty.
pub fn observe_group(
  home: String,
  group: String,
  declarations: List(declared.Declared),
) -> Result(GroupSnapshot, Refusal) {
  use <- locked(home)
  use groups <- result.try(case group {
    "ui" -> {
      use picker <- result.try(load(home, "picker.json"))
      use ui <- result.try(projected(projection.ui_group(dynamic_of(picker))))
      Ok(dict.from_list([#("ui", ui)]))
    }
    _ -> {
      use documents <- result.try(documents(home))
      groups(documents, declarations)
    }
  })
  use revisions <- result.try(load(home, revisions_file))
  case group {
    "" -> {
      use resources <- result.try(
        dict.to_list(groups)
        |> list.try_map(fn(entry) {
          use resource <- result.try(validator(entry.0, entry.1, revisions))
          Ok(#(entry.0, dynamic_of(resource)))
        }),
      )
      let value =
        dict.insert(
          groups,
          "group_resources",
          dynamic_of(dict.from_list(resources)),
        )
      Ok(GroupSnapshot(encode(dynamic_of(value)), None))
    }
    _ -> {
      use value <- result.try(group_value(group, groups))
      use tag <- result.try(group_etag(group, value, revisions))
      Ok(GroupSnapshot(encode(value), Some(tag)))
    }
  }
}

// ---- patch ------------------------------------------------------------------

/// Apply a JSON merge patch to one group when `etag` matches it, and answer
/// the published group with its new validator. `mcp` names the installed
/// extensions' MCP server checks. `keys` is the runtime's key environment.
pub fn patch_group(
  home: String,
  group: String,
  etag: String,
  patch: String,
  providers: List(String),
  logins: List(oauth.Login),
  resolve: fn(Dynamic) ->
    Result(Dict(String, Dict(String, Option(Bool))), String),
  defaults: fn(List(#(String, Bool)), List(#(String, Option(Bool)))) ->
    Result(List(#(String, Bool)), Refusal),
  declarations: List(declared.Declared),
  mcp: Option(extension.McpServers),
  keys: KeyEnvironment,
) -> Result(String, Refusal) {
  let inputs =
    Inputs(
      home:,
      group:,
      providers:,
      logins:,
      resolve:,
      defaults:,
      declarations:,
      mcp:,
      keys:,
    )
  let captured = {
    use <- locked(home)
    use #(documents, revisions) <- result.try(matched(inputs, etag))
    use patch <- result.try(case albedo_json.decode(<<patch:utf8>>) {
      Ok(value) -> object_or_invalid(value)
      Error(_) -> Error(invalid())
    })
    use #(next, validation) <- result.try(candidate(inputs, patch, documents))
    use _ <- result.try(case group {
      "providers" -> validate_provider_accounts(inputs, next)
      _ -> Ok(Nil)
    })
    let probe =
      group == "mcp"
      && dict.get(patch, "validate_connection") != Ok(dynamic.bool(False))
    case probe {
      True -> {
        use checked <- result.try(checked_candidates(patch, next))
        Ok(Probe(patch, checked))
      }
      False ->
        publish(inputs, documents, next, validation, revisions)
        |> result.map(Complete)
    }
  }
  case captured {
    Error(refusal) -> Error(refusal)
    Ok(Complete(response)) -> Ok(response)
    Ok(Probe(patch, checked)) -> {
      // Candidate clients are closed by the check before publication.
      // Starting them must not hold the lock unrelated readers wait on.
      use _ <- result.try(
        list.try_each(checked, fn(server) {
          use servers <- result.try(mcp_servers(mcp))
          case
            albedo_protect.attempt(fn() {
              servers.check(server.0, server.1, dynamic_of(server.2))
            })
          {
            Ok(Ok(Nil)) -> Ok(Nil)
            Ok(Error(_)) -> Error(unpublished())
            Error(_) -> Error(invalid())
          }
        }),
      )
      use <- locked(home)
      use #(documents, revisions) <- result.try(matched(inputs, etag))
      use #(next, validation) <- result.try(candidate(inputs, patch, documents))
      // Redacted validators alone cannot detect direct secret changes.
      use again <- result.try(checked_candidates(patch, next))
      use _ <- result.try(
        ensure(again == checked, #(
          412,
          "precondition_failed",
          "MCP candidate inputs changed during validation",
        )),
      )
      publish(inputs, documents, next, validation, revisions)
    }
  }
}

/// The saved documents and revisions, once the group's ETag matches `etag`.
fn matched(inputs: Inputs, etag: String) -> Result(#(Object, Object), Refusal) {
  use documents <- result.try(documents(inputs.home))
  use groups <- result.try(groups(documents, inputs.declarations))
  use prior <- result.try(group_value(inputs.group, groups))
  use revisions <- result.try(load(inputs.home, revisions_file))
  use _ <- result.try(case etag {
    "" -> Error(#(428, "precondition_required", "If-Match is required"))
    _ -> {
      use current <- result.try(group_etag(inputs.group, prior, revisions))
      ensure(etag == current, #(412, "precondition_failed", "settings changed"))
    }
  })
  Ok(#(documents, revisions))
}

/// The changed MCP servers of a patch as its candidate holds them. A probe
/// may record that a server asks for a sign-in, which is not a change.
fn checked_candidates(
  patch: Object,
  next: Object,
) -> Result(List(Checked), Refusal) {
  use extensions <- result.try(document(next, "extensions.json"))
  use mcp <- result.try(section(extensions, "mcp"))
  use definitions <- result.try(section(mcp, "servers"))
  use creds <- result.try(document(next, "creds.json"))
  use secrets <- result.try(section(creds, "mcp"))
  use changes <- result.try(section(patch, "definitions"))
  sorted(changes)
  |> list.filter(fn(change) { change.1 != null() })
  |> list.try_map(fn(change) {
    use definition <- result.try(
      dict.get(definitions, change.0) |> result.replace_error(invalid()),
    )
    use secret <- result.try(
      object_or_invalid(get_or(secrets, change.0, empty())),
    )
    Ok(#(change.0, definition, dict.delete(secret, "oauth")))
  })
}

/// Publish the changed documents with the group's next revision, and answer
/// the group, its validator and the candidate's validation.
fn publish(
  inputs: Inputs,
  documents: Object,
  next: Object,
  validation: String,
  revisions: Object,
) -> Result(String, Refusal) {
  let group = inputs.group
  use groups <- result.try(groups(next, inputs.declarations))
  use value <- result.try(group_value(group, groups))
  let changed =
    dict.filter(next, fn(file, value) { Ok(value) != dict.get(documents, file) })
  use revisions <- result.try(case dict.is_empty(changed) {
    True -> Ok(revisions)
    False -> {
      use counter <- result.try(
        decode.run(get_or(revisions, group, dynamic.int(0)), decode.int)
        |> result.replace_error(invalid()),
      )
      let updated = dict.insert(revisions, group, dynamic.int(counter + 1))
      use _ <- result.try(
        settings_store.commit(
          inputs.home,
          dict.insert(changed, revisions_file, dynamic_of(updated)),
        )
        |> result.map_error(fn(error) {
          case error {
            settings_store.Unavailable(_) -> unpublished()
            settings_store.Refused -> invalid()
          }
        }),
      )
      Ok(updated)
    }
  })
  use resource <- result.try(validator(group, value, revisions))
  Ok(
    encode(
      dynamic_of(
        dict.from_list([
          #("group", dynamic.string(group)),
          #("resource", dynamic_of(dict.insert(resource, "value", value))),
          #("validation", dynamic.string(validation)),
        ]),
      ),
    ),
  )
}

// ---- candidates -------------------------------------------------------------

fn candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  case inputs.group {
    "providers" -> providers_candidate(inputs, patch, documents)
    "extensions" -> extensions_candidate(inputs, patch, documents)
    "extension_settings" -> declared_candidate(inputs, patch, documents)
    "models" -> models_candidate(patch, documents)
    "ui" -> ui_candidate(patch, documents)
    "capabilities" -> capabilities_candidate(inputs, patch, documents)
    "mcp" -> mcp_candidate(inputs, patch, documents)
    _ -> Error(invalid())
  }
}

fn providers_candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(fields(patch, ["profiles", "default_profile", "renames"]))
  use config <- result.try(saved_config(documents))
  use creds <- result.try(document(documents, "creds.json"))
  use changes <- result.try(section(patch, "profiles"))
  use saved_keys <- result.try(section(creds, "providers"))
  use saved <- result.try(section(config, "providers"))
  // A key still in config.json moves to creds.json with its profile.
  use #(saved_profiles, saved_keys) <- result.try(
    dict.fold(saved, Ok(#(dict.new(), saved_keys)), fn(acc, name, profile) {
      use #(profiles, keys) <- result.try(acc)
      use profile <- result.try(object_or_invalid(profile))
      let keys = case dict.get(profile, "apiKey") {
        Ok(key) ->
          case decode.run(key, decode.string) {
            Ok(text) if text != "" -> dict.insert(keys, name, key_document(key))
            _ -> keys
          }
        Error(Nil) -> keys
      }
      Ok(#(
        dict.insert(profiles, name, dynamic_of(dict.delete(profile, "apiKey"))),
        keys,
      ))
    }),
  )
  use renames <- result.try(section(patch, "renames"))
  use #(renamed_profiles, renamed_keys, active) <- result.try(rename_profiles(
    renames,
    saved_profiles,
    saved_keys,
    nonempty(get_or(config, "active", null())),
  ))
  use accounts <- result.try(section(creds, "accounts"))
  use #(profiles, keys, accounts) <- result.try(
    dict.fold(
      changes,
      Ok(#(renamed_profiles, renamed_keys, accounts)),
      fn(acc, name, change) {
        use #(profiles, keys, accounts) <- result.try(acc)
        use _ <- result.try(text(dynamic.string(name), 1, 64))
        case change == null() {
          True ->
            Ok(#(dict.delete(profiles, name), dict.delete(keys, name), accounts))
          False ->
            profile_change(inputs, name, change, profiles, keys, accounts)
        }
      },
    ),
  )
  let default = get_or(patch, "default_profile", active)
  use _ <- result.try(
    ensure(
      default == null()
        || {
        case decode.run(default, decode.string) {
          Ok(name) -> dict.has_key(profiles, name)
          Error(_) -> False
        }
      },
      #(409, "invalid_default_profile", "replace or clear the selected profile"),
    ),
  )
  let config =
    config
    |> dict.insert("accountsVersion", dynamic.int(2))
    |> dict.insert("providers", dynamic_of(profiles))
    |> dict.insert("active", case default == null() {
      True -> dynamic.string("")
      False -> default
    })
  let creds =
    creds
    |> dict.insert("providers", dynamic_of(keys))
    |> dict.insert("accounts", dynamic_of(accounts))
  Ok(#(
    documents
      |> dict.insert("config.json", dynamic_of(config))
      |> dict.insert("creds.json", dynamic_of(creds)),
    "not_applicable",
  ))
}

/// One profile's change merged over its saved fields, with its key bound.
fn profile_change(
  inputs: Inputs,
  name: String,
  change: Dynamic,
  profiles: Object,
  keys: Object,
  accounts: Object,
) -> Result(#(Object, Object, Object), Refusal) {
  use change <- result.try(
    fields_of(change, [
      "enabled", "extension", "api", "endpoint", "protocol", "model", "effort",
      "image_edge", "account_id", "account_ids", "rotation", "project",
      "location", "api_key",
    ]),
  )
  // Availability toggles only a saved profile; a new one also needs a model.
  use _ <- result.try(case dict.get(change, "enabled") {
    Ok(enabled) ->
      ensure(result.is_ok(decode.run(enabled, decode.bool)), invalid())
    Error(Nil) -> Ok(Nil)
  })
  use _ <- result.try(
    ensure(
      dict.has_key(profiles, name)
        || !dict.has_key(change, "enabled")
        || dict.has_key(change, "model"),
      #(400, "invalid_request", "cannot toggle an unknown provider profile"),
    ),
  )
  use old <- result.try(object_or_invalid(get_or(profiles, name, empty())))
  let public = translate(dict.delete(change, "api_key"), provider_fields())
  let complete = dict.merge(old, public)
  let endpoint = case get_or(complete, "baseUrl", dynamic.string("")) {
    endpoint ->
      case is_null(endpoint) {
        True -> dynamic.string("")
        False -> endpoint
      }
  }
  let standard =
    complete
    |> dict.insert("baseUrl", endpoint)
    |> dict.insert(
      "protocol",
      get_or(complete, "protocol", dynamic.string("responses")),
    )
  use validated <- result.try(normalized(name, dynamic_of(standard)))
  let valid =
    dict.merge(
      dict.delete(standard, "apiKey"),
      dict.delete(validated, "apiKey"),
    )
  use #(bound, keys, accounts) <- result.try(profile_key(
    inputs,
    change,
    name,
    valid,
    keys,
    accounts,
  ))
  let effort = get_or(bound, "effort", null())
  use _ <- result.try(nullable_text(effort, 100))
  use _ <- result.try(case decode.run(effort, decode.string) {
    Ok("inherit") | Ok("default") | Error(_) -> Ok(Nil)
    Ok(level) ->
      ensure(result.is_ok(types.parse_effort(level)), #(
        400,
        "invalid_request",
        "unsupported reasoning effort: " <> level,
      ))
  })
  use _ <- result.try(nullable_text(get_or(bound, "accountId", null()), 512))
  let account_ids = get_or(bound, "accountIds", null())
  use _ <- result.try(case account_ids == null() {
    True -> Ok(Nil)
    False -> {
      use ids <- result.try(strings(account_ids, 50, 512))
      ensure(ids != [], #(
        400,
        "invalid_request",
        "account_ids must not be empty",
      ))
    }
  })
  use _ <- result.try(
    ensure(
      get_or(bound, "accountId", null()) == null() || account_ids == null(),
      #(
        400,
        "credential_conflict",
        "Clear account_id before selecting a rotation",
      ),
    ),
  )
  use _ <- result.try({
    let rotation = get_or(bound, "rotation", null())
    case is_null(rotation) || list.contains(rotations(), rotation) {
      True -> Ok(Nil)
      False ->
        Error(#(
          400,
          "invalid_request",
          "rotation must be failover, spread or first",
        ))
    }
  })
  use _ <- result.try(nullable_text(get_or(bound, "project", null()), 256))
  use _ <- result.try(nullable_text(get_or(bound, "location", null()), 256))
  use _ <- result.try({
    let edge = get_or(bound, "imageEdge", null())
    case is_null(edge) {
      True -> Ok(Nil)
      False -> counter(edge, 1, 65_536)
    }
  })
  Ok(#(dict.insert(profiles, name, dynamic_of(bound)), keys, accounts))
}

/// A rename moves the profile, its key and the default to the new name. The
/// sessions on it are the daemon's to move once this is published.
fn rename_profiles(
  renames: Object,
  profiles: Object,
  keys: Object,
  default: Dynamic,
) -> Result(#(Object, Object, Dynamic), Refusal) {
  let targets = dict.values(renames)
  use _ <- result.try(
    ensure(list.length(usort(targets)) == list.length(targets), #(
      400,
      "invalid_request",
      "two profiles cannot take one name",
    )),
  )
  let saved = profiles
  sorted(renames)
  |> list.try_fold(#(profiles, keys, default), fn(acc, rename) {
    let #(profiles, keys, default) = acc
    let #(from, to) = rename
    use _ <- result.try(
      ensure(dict.has_key(profiles, from), #(
        409,
        "unknown_profile",
        "no profile is named " <> from,
      )),
    )
    use to <- result.try(text(to, 1, 64))
    use _ <- result.try(
      ensure(!dict.has_key(saved, to), #(
        409,
        "profile_exists",
        "a profile is already named " <> to,
      )),
    )
    let assert Ok(profile) = dict.get(profiles, from)
    use _ <- result.try(normalized(to, profile))
    let keys = case dict.get(keys, from) {
      Ok(key) -> dict.delete(keys, from) |> dict.insert(to, key)
      Error(Nil) -> keys
    }
    Ok(
      #(
        dict.delete(profiles, from) |> dict.insert(to, profile),
        keys,
        case default == dynamic.string(from) {
          True -> dynamic.string(to)
          False -> default
        },
      ),
    )
  })
}

/// The saved values of a profile's `rotation`.
fn rotations() -> List(Dynamic) {
  list.map(["failover", "spread", "first"], dynamic.string)
}

/// Patch fields by their saved names.
fn provider_fields() -> List(#(String, String)) {
  [
    #("enabled", "enabled"),
    #("extension", "extension"),
    #("api", "api"),
    #("endpoint", "baseUrl"),
    #("protocol", "protocol"),
    #("model", "model"),
    #("effort", "effort"),
    #("image_edge", "imageEdge"),
    #("account_id", "accountId"),
    #("account_ids", "accountIds"),
    #("rotation", "rotation"),
    #("project", "project"),
    #("location", "location"),
  ]
}

/// A profile's `api_key` change. A key provider saves the key as an account
/// and pins the profile to it. Another provider keeps it by profile name.
/// Removing a key unpins a key account but keeps an OAuth pin.
fn profile_key(
  inputs: Inputs,
  change: Object,
  name: String,
  profile: Object,
  keys: Object,
  accounts: Object,
) -> Result(#(Object, Object, Object), Refusal) {
  let extension =
    get_or(profile, "extension", dynamic.string(profiles.default_extension()))
    |> decode.run(decode.string)
    |> result.unwrap("")
  let key_provider = list.contains(key_accounts.providers(), extension)
  let endpoint =
    get_or(profile, "baseUrl", dynamic.string(""))
    |> decode.run(decode.string)
    |> result.unwrap("")
  case dict.get(change, "api_key") |> result.map(classify) {
    Error(Nil) -> Ok(#(profile, keys, accounts))
    Ok(Null) ->
      case key_provider {
        False -> Ok(#(profile, dict.delete(keys, name), accounts))
        True -> {
          let id = get_or(profile, "accountId", null())
          let values =
            list.append(
              credential_store.values(accounts, extension),
              key_accounts.environment_values(
                inputs.home,
                extension,
                endpoint,
                inputs.keys,
              ),
            )
          let is_key =
            list.any(values, fn(value) {
              get_or(value, "_albedo_account_id", null()) == id
              && get_or(value, "type", null()) == dynamic.string("key")
            })
          let bound = case is_key {
            True -> dict.delete(profile, "accountId")
            False -> profile
          }
          Ok(#(bound, dict.delete(keys, name), accounts))
        }
      }
    Ok(Present(key)) -> {
      use key <- result.try(text(key, 1, 16_384))
      use _ <- result.try(normalized(
        name,
        dynamic_of(dict.insert(profile, "apiKey", dynamic.string(key))),
      ))
      case key_provider {
        False ->
          Ok(#(
            profile,
            dict.insert(keys, name, key_document(dynamic.string(key))),
            accounts,
          ))
        True -> {
          let values = credential_store.values(accounts, extension)
          let existing =
            list.filter(values, fn(value) {
              get_or(value, "type", null()) == dynamic.string("key")
              && get_or(value, "apiKey", null()) == dynamic.string(key)
              && get_or(value, "endpoint", null()) == dynamic.string(endpoint)
            })
          use #(id, accounts) <- result.try(case existing {
            [found, ..] ->
              dict.get(found, "_albedo_account_id")
              |> result.map(fn(id) { #(id, accounts) })
              |> result.replace_error(invalid())
            [] -> {
              let id =
                crypto.strong_random_bytes(16)
                |> bit_array.base16_encode
                |> string.lowercase
                |> dynamic.string
              let credential =
                dict.from_list([
                  #("type", dynamic.string("key")),
                  #("apiKey", dynamic.string(key)),
                  #("endpoint", dynamic.string(endpoint)),
                  #("label", dynamic.string(rotation.key_label(key))),
                  #("_albedo_account_id", id),
                ])
              Ok(#(
                id,
                credential_store.put_values(
                  accounts,
                  extension,
                  list.append(values, [credential]),
                ),
              ))
            }
          })
          Ok(#(
            profile
              |> dict.insert("accountId", id)
              |> dict.delete("accountIds"),
            dict.delete(keys, name),
            accounts,
          ))
        }
      }
    }
  }
}

/// Every profile's credential choice names an account its provider holds,
/// and a profile with a saved key selects no account.
fn validate_provider_accounts(
  inputs: Inputs,
  next: Object,
) -> Result(Nil, Refusal) {
  use config <- result.try(saved_config(next))
  use creds <- result.try(document(next, "creds.json"))
  use accounts <- result.try(section(creds, "accounts"))
  use keys <- result.try(section(creds, "providers"))
  use profiles <- result.try(section(config, "providers"))
  dict.to_list(profiles)
  |> list.try_each(fn(entry) {
    let #(name, profile) = entry
    use normalized <- result.try(normalized(name, profile))
    let text_field = fn(field) {
      get_or(normalized, field, dynamic.string(""))
      |> decode.run(decode.string)
      |> result.unwrap("")
    }
    let extension = text_field("extension")
    use _ <- result.try(
      ensure(list.contains(inputs.providers, extension), #(
        400,
        "provider_unknown",
        "Provider extension is not installed",
      )),
    )
    let key_provider = list.contains(key_accounts.providers(), extension)
    let stores =
      inputs.logins
      |> list.filter(fn(login) { login.provider == extension })
      |> list.map(fn(login) { login.store })
      |> list.append(case key_provider {
        True -> [extension]
        False -> []
      })
      |> list.unique
      |> list.sort(string.compare)
    let environment = case key_provider {
      True ->
        key_accounts.environment_values(
          inputs.home,
          extension,
          text_field("baseUrl"),
          inputs.keys,
        )
      False -> []
    }
    let values =
      list.flat_map(stores, credential_store.values(accounts, _))
      |> list.append(environment)
    let known = fn(id) {
      list.any(values, fn(credential) {
        get_or(credential, "_albedo_account_id", null()) == id
      })
    }
    use profile <- result.try(object_or_invalid(profile))
    let pin = get_or(profile, "accountId", null())
    let rotation = get_or(profile, "accountIds", null())
    let unknown = #(
      400,
      "account_unknown",
      "Account does not belong to this provider",
    )
    use _ <- result.try(
      ensure(pin == null() || rotation == null(), #(
        400,
        "credential_conflict",
        "Choose either account_id or account_ids",
      )),
    )
    use _ <- result.try(case pin == null() {
      True -> Ok(Nil)
      False -> ensure(known(pin), unknown)
    })
    use _ <- result.try(case rotation == null() {
      True -> Ok(Nil)
      False ->
        case decode.run(rotation, decode.list(decode.dynamic)) {
          Ok([_, ..]) -> {
            use _ <- result.try(strings(rotation, 50, 512))
            let assert Ok(ids) =
              decode.run(rotation, decode.list(decode.dynamic))
            list.try_each(ids, fn(id) { ensure(known(id), unknown) })
          }
          _ ->
            Error(#(
              400,
              "invalid_request",
              "account_ids must be a nonempty list",
            ))
        }
    })
    ensure(
      { pin == null() && rotation == null() } || !dict.has_key(keys, name),
      #(
        400,
        "credential_conflict",
        "Clear the API key before selecting accounts",
      ),
    )
  })
}

fn extensions_candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(fields(patch, ["defaults"]))
  use extensions <- result.try(document(documents, "extensions.json"))
  use current <- result.try(section(extensions, "enabled"))
  use changes <- result.try(section(patch, "defaults"))
  use _ <- result.try(boolean_choices(current, changes))
  use current <- result.try(
    sorted(current)
    |> list.try_map(fn(choice) {
      decode.run(choice.1, decode.bool)
      |> result.map(fn(enabled) { #(choice.0, enabled) })
      |> result.replace_error(invalid())
    }),
  )
  let changes =
    sorted(changes)
    |> list.map(fn(change) {
      #(change.0, decode.run(change.1, decode.bool) |> option.from_result)
    })
  use choices <- result.try(inputs.defaults(current, changes))
  let enabled =
    list.map(choices, fn(choice) { #(choice.0, dynamic.bool(choice.1)) })
    |> dict.from_list
  Ok(#(
    dict.insert(
      documents,
      "extensions.json",
      dynamic_of(dict.insert(extensions, "enabled", dynamic_of(enabled))),
    ),
    "not_applicable",
  ))
}

fn declared_candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(fields(patch, ["values"]))
  use values <- result.try(
    dict.get(patch, "values")
    |> result.replace_error(#(400, "invalid_request", "values is required")),
  )
  use extensions <- result.try(
    dict.get(documents, "extensions.json") |> result.replace_error(invalid()),
  )
  use next <- result.try(declared.patch(inputs.declarations, extensions, values))
  Ok(#(dict.insert(documents, "extensions.json", next), "not_applicable"))
}

fn models_candidate(
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(fields(patch, ["raised_caps", "compact_at"]))
  use extensions <- result.try(document(documents, "extensions.json"))
  use saved <- result.try(section(extensions, "raisedCaps"))
  use changes <- result.try(section(patch, "raised_caps"))
  use raised <- result.try(boolean_choices(saved, changes))
  use next <- result.try(case dict.has_key(patch, "compact_at") {
    False -> Ok(extensions)
    True -> {
      use saved <- result.try(section(extensions, "compactAt"))
      use changes <- result.try(section(patch, "compact_at"))
      use windows <- result.try(window_choices(saved, changes))
      Ok(dict.insert(extensions, "compactAt", dynamic_of(windows)))
    }
  })
  Ok(#(
    dict.insert(
      documents,
      "extensions.json",
      dynamic_of(dict.insert(next, "raisedCaps", dynamic_of(raised))),
    ),
    "not_applicable",
  ))
}

fn ui_candidate(
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(
    fields(patch, [
      "assistant_name", "thinking", "tools", "dismissed_notices", "web_allow",
      "proxy_allow",
    ]),
  )
  use _ <- result.try(
    dict.to_list(patch)
    |> list.try_each(fn(field) {
      case field.0 {
        "assistant_name" -> {
          use name <- result.try(text(field.1, 0, 320))
          let points = string.to_utf_codepoints(name)
          case
            list.length(points) <= 80
            && list.all(points, fn(cp) {
              let n = string.utf_codepoint_to_int(cp)
              n >= 32 && { n < 127 || n > 159 }
            })
          {
            True -> Ok(Nil)
            False -> Error(invalid())
          }
        }
        "dismissed_notices" ->
          strings(field.1, 1000, 512) |> result.replace(Nil)
        "web_allow" | "proxy_allow" ->
          strings(field.1, 64, 64) |> result.replace(Nil)
        _ ->
          decode.run(field.1, decode.bool)
          |> result.replace(Nil)
          |> result.replace_error(invalid())
      }
    }),
  )
  use picker <- result.try(document(documents, "picker.json"))
  Ok(#(
    dict.insert(documents, "picker.json", dynamic_of(dict.merge(picker, patch))),
    "not_applicable",
  ))
}

fn capabilities_candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(
    fields(patch, ["catalog_session_id", "catalog_revision", "choices"]),
  )
  use resolved <- result.try(
    inputs.resolve(dynamic_of(patch))
    |> result.map_error(fn(detail) { #(409, "catalog_changed", detail) }),
  )
  use saved <- result.try(document(documents, "capabilities.json"))
  use global <- result.try(section(saved, "global"))
  use global <- result.try(
    dict.fold(resolved, Ok(global), fn(acc, kind, changes) {
      use global <- result.try(acc)
      case dict.is_empty(changes) {
        True -> Ok(global)
        False -> {
          let changes =
            dict.map_values(changes, fn(_, choice) {
              case choice {
                Some(enabled) -> dynamic.bool(enabled)
                None -> null()
              }
            })
          use prior <- result.try(section(global, kind))
          use choices <- result.try(boolean_choices(prior, changes))
          Ok(dict.insert(global, kind, dynamic_of(choices)))
        }
      }
    }),
  )
  let updated = dict.insert(saved, "global", dynamic_of(global))
  use _ <- result.try(
    capabilities.validate(dynamic_of(updated))
    |> result.replace_error(unpublished()),
  )
  use _ <- result.try(
    ensure(
      string.byte_size(encode(dynamic_of(updated)))
        <= settings_store.capability_bytes,
      #(
        409,
        "settings_capacity",
        "capability preferences exceed their saved byte limit",
      ),
    ),
  )
  Ok(#(
    dict.insert(documents, "capabilities.json", dynamic_of(updated)),
    "not_applicable",
  ))
}

fn mcp_candidate(
  inputs: Inputs,
  patch: Object,
  documents: Object,
) -> Result(Candidate, Refusal) {
  use _ <- result.try(fields(patch, ["definitions", "validate_connection"]))
  use probe <- result.try(
    decode.run(
      get_or(patch, "validate_connection", dynamic.bool(True)),
      decode.bool,
    )
    |> result.replace_error(invalid()),
  )
  use extensions <- result.try(document(documents, "extensions.json"))
  use mcp <- result.try(section(extensions, "mcp"))
  use creds <- result.try(document(documents, "creds.json"))
  use definitions <- result.try(section(mcp, "servers"))
  use secrets <- result.try(section(creds, "mcp"))
  use changes <- result.try(section(patch, "definitions"))
  use #(definitions, secrets) <- result.try(
    dict.fold(changes, Ok(#(definitions, secrets)), fn(acc, name, change) {
      use #(definitions, secrets) <- result.try(acc)
      case change == null() {
        True ->
          Ok(#(dict.delete(definitions, name), dict.delete(secrets, name)))
        False -> {
          use servers <- result.try(mcp_servers(inputs.mcp))
          use #(definition, secret) <- result.try(mcp_server(
            change,
            get_or(definitions, name, empty()),
            get_or(secrets, name, empty()),
            servers.signed_out,
          ))
          use _ <- result.try(
            case
              albedo_protect.attempt(fn() {
                servers.validate(
                  name,
                  dynamic_of(definition),
                  dynamic_of(secret),
                )
              })
            {
              Ok(Ok(Nil)) -> Ok(Nil)
              _ -> Error(invalid())
            },
          )
          Ok(#(
            dict.insert(definitions, name, dynamic_of(definition)),
            dict.insert(secrets, name, dynamic_of(secret)),
          ))
        }
      }
    }),
  )
  let extensions =
    dict.insert(
      extensions,
      "mcp",
      dynamic_of(dict.insert(mcp, "servers", dynamic_of(definitions))),
    )
  let creds = dict.insert(creds, "mcp", dynamic_of(secrets))
  Ok(
    #(
      documents
        |> dict.insert("extensions.json", dynamic_of(extensions))
        |> dict.insert("creds.json", dynamic_of(creds)),
      case probe {
        True -> "passed"
        False -> "skipped"
      },
    ),
  )
}

/// The MCP extension checks server definitions. Without it no server can be
/// saved, while removing one still works.
fn mcp_servers(
  mcp: Option(extension.McpServers),
) -> Result(extension.McpServers, Refusal) {
  case mcp {
    Some(servers) -> Ok(servers)
    None ->
      Error(#(
        503,
        "mcp_unavailable",
        "no installed extension checks MCP servers",
      ))
  }
}

/// One server's patch over its saved definition and secrets. Public and
/// secret environment or header maps cannot name the same entry, and a
/// definition holds one bearer source.
fn mcp_server(
  change: Dynamic,
  prior: Dynamic,
  secrets: Dynamic,
  signed_out: fn(Dynamic) -> Dynamic,
) -> Result(#(Object, Object), Refusal) {
  use change <- result.try(fields_of(
    change,
    list.map(projection.mcp_fields(), fn(name) { name.0 })
      |> list.append(["environment", "headers", "secrets"]),
  ))
  use prior <- result.try(object_or_invalid(prior))
  let public = dict.merge(prior, translate(change, projection.mcp_fields()))
  use secret_patch <- result.try(section(change, "secrets"))
  use _ <- result.try(
    fields(secret_patch, [
      "bearer_token", "environment", "headers", "oauth", "oauth_client",
    ]),
  )
  use #(public, secrets) <- result.try(
    list.try_fold(
      [#("environment", "env"), #("headers", "headers")],
      #(public, secrets),
      fn(acc, names) {
        let #(public, secrets) = acc
        let #(wire, stored) = names
        let public_changes = get_or(change, wire, empty())
        let secret_changes = get_or(secret_patch, wire, empty())
        use prior_sources <- result.try(section(public, stored))
        use sources <- result.try(source_choices(prior_sources, public_changes))
        use secrets <- result.try(object_or_invalid(secrets))
        use prior_saved <- result.try(section(secrets, stored))
        use saved <- result.try(secret_choices(prior_saved, secret_changes))
        let public_names = set_names(public_changes)
        let secret_names = set_names(secret_changes)
        use _ <- result.try(ensure(
          !list.any(public_names, list.contains(secret_names, _)),
          invalid(),
        ))
        Ok(#(
          dict.insert(
            public,
            stored,
            dynamic_of(dict.drop(sources, secret_names)),
          ),
          dynamic_of(dict.insert(
            secrets,
            stored,
            dynamic_of(dict.drop(saved, public_names)),
          )),
        ))
      },
    ),
  )
  use secrets <- result.try(object_or_invalid(secrets))
  use #(public, secrets) <- result.try(
    case dict.get(secret_patch, "bearer_token") |> result.map(classify) {
      Error(Nil) -> Ok(#(public, secrets))
      Ok(Null) -> Ok(#(public, dict.delete(secrets, "bearerToken")))
      Ok(Present(token)) -> {
        use _ <- result.try(text(token, 1, 16_384))
        Ok(#(
          dict.delete(public, "bearerTokenEnvVar"),
          dict.insert(secrets, "bearerToken", token),
        ))
      }
    },
  )
  use secrets <- result.try(
    case
      decode.run(get_or(change, "bearer_token_env_var", null()), decode.string)
    {
      Ok(_) -> {
        use _ <- result.try(ensure(
          get_or(secret_patch, "bearer_token", null()) == null(),
          invalid(),
        ))
        Ok(dict.delete(secrets, "bearerToken"))
      }
      Error(_) -> Ok(secrets)
    },
  )
  use secrets <- result.try(oauth_choices(secrets, secret_patch, signed_out))
  let absent = fn(fields, name) { get_or(fields, name, null()) == null() }
  let none = fn(fields, name) {
    use found <- result.try(section(fields, name))
    ensure(dict.is_empty(found), invalid())
  }
  use _ <- result.try(case dict.get(public, "type") |> result.map(text_of) {
    Ok(Ok("http")) -> {
      use _ <- result.try(ensure(absent(public, "command"), invalid()))
      use _ <- result.try(ensure(absent(public, "cwd"), invalid()))
      use _ <- result.try(ensure(
        get_or(public, "args", dynamic.list([])) == dynamic.list([]),
        invalid(),
      ))
      none(public, "env")
    }
    Ok(Ok("stdio")) -> {
      use _ <- result.try(ensure(absent(public, "url"), invalid()))
      use _ <- result.try(ensure(absent(public, "bearerTokenEnvVar"), invalid()))
      use _ <- result.try(none(public, "headers"))
      use _ <- result.try(none(secrets, "headers"))
      ensure(absent(secrets, "bearerToken"), invalid())
    }
    _ -> Error(invalid())
  })
  use _ <- result.try(case dict.get(public, "startupTimeoutMs") {
    Ok(millis) -> counter(millis, 1, 300_000)
    Error(Nil) -> Ok(Nil)
  })
  Ok(#(public, secrets))
}

/// `oauth: null` signs the server out, keeping what it asked for. A sign-in
/// itself only comes from the daemon's sign-in flow. `oauth_client` is a
/// client id and secret the user registered with the server's authorization
/// server, or null to forget it.
fn oauth_choices(
  secrets: Object,
  secret_patch: Object,
  signed_out: fn(Dynamic) -> Dynamic,
) -> Result(Object, Refusal) {
  use signed <- result.try(
    case dict.get(secret_patch, "oauth") |> result.map(classify) {
      Error(Nil) -> Ok(secrets)
      Ok(Null) ->
        case dict.get(secrets, "oauth") {
          Ok(record) ->
            albedo_protect.attempt(fn() { signed_out(record) })
            |> result.map(dict.insert(secrets, "oauth", _))
            |> result.replace_error(invalid())
          Error(Nil) -> Ok(secrets)
        }
      Ok(Present(_)) -> Error(invalid())
    },
  )
  case dict.get(secret_patch, "oauth_client") |> result.map(classify) {
    Error(Nil) -> Ok(signed)
    Ok(Null) -> Ok(dict.delete(signed, "oauthClient"))
    Ok(Present(client)) -> {
      use client <- result.try(
        fields_of(client, ["client_id", "client_secret"]),
      )
      use id <- result.try(
        dict.get(client, "client_id") |> result.replace_error(invalid()),
      )
      use _ <- result.try(text(id, 1, 1024))
      let secret = get_or(client, "client_secret", null())
      use _ <- result.try(nullable_text(secret, 4096))
      Ok(dict.insert(
        signed,
        "oauthClient",
        dynamic_of(
          dict.from_list([#("clientId", id), #("clientSecret", secret)]),
        ),
      ))
    }
  }
}

/// Saved environment or header sources with a patch's changes: a literal
/// value, or the name of a daemon environment variable. A null patch clears
/// them all.
fn source_choices(prior: Object, changes: Dynamic) -> Result(Object, Refusal) {
  use <- bool.guard(changes == null(), Ok(dict.new()))
  use changes <- result.try(object_or_invalid(changes))
  dict.fold(changes, Ok(prior), fn(acc, name, value) {
    use sources <- result.try(acc)
    case value == null() {
      True -> Ok(dict.delete(sources, name))
      False -> {
        use value <- result.try(fields_of(value, ["source", "value"]))
        use text_value <- result.try(
          dict.get(value, "value") |> result.replace_error(invalid()),
        )
        use _ <- result.try(text(text_value, 0, 16_384))
        use source <- result.try(
          case dict.get(value, "source") |> result.map(text_of) {
            Ok(Ok("literal")) -> Ok(text_value)
            Ok(Ok("env")) ->
              Ok(dynamic_of(dict.from_list([#("env", text_value)])))
            _ -> Error(invalid())
          },
        )
        Ok(dict.insert(sources, name, source))
      }
    }
  })
}

/// Saved secret values with a patch's changes. A null patch clears them all.
fn secret_choices(prior: Object, changes: Dynamic) -> Result(Object, Refusal) {
  use <- bool.guard(changes == null(), Ok(dict.new()))
  use changes <- result.try(object_or_invalid(changes))
  dict.fold(changes, Ok(prior), fn(acc, name, value) {
    use saved <- result.try(acc)
    case value == null() {
      True -> Ok(dict.delete(saved, name))
      False -> {
        use _ <- result.try(text(value, 0, 16_384))
        Ok(dict.insert(saved, name, value))
      }
    }
  })
}

/// The names a patch map sets to a value rather than null.
fn set_names(changes: Dynamic) -> List(String) {
  case object_or_invalid(changes) {
    Ok(changes) ->
      dict.filter(changes, fn(_, value) { value != null() }) |> dict.keys
    Error(_) -> []
  }
}

fn window_choices(prior: Object, changes: Object) -> Result(Object, Refusal) {
  dict.fold(changes, Ok(prior), fn(acc, name, value) {
    use windows <- result.try(acc)
    case value == null() {
      True -> Ok(dict.delete(windows, name))
      False -> {
        use _ <- result.try(text(dynamic.string(name), 1, 512))
        use _ <- result.try(counter(value, 1, 100_000_000))
        Ok(dict.insert(windows, name, value))
      }
    }
  })
}

fn boolean_choices(prior: Object, changes: Object) -> Result(Object, Refusal) {
  dict.fold(changes, Ok(prior), fn(acc, name, value) {
    use choices <- result.try(acc)
    case value == null(), decode.run(value, decode.bool) {
      True, _ -> Ok(dict.delete(choices, name))
      False, Ok(_) -> {
        use _ <- result.try(text(dynamic.string(name), 1, 512))
        Ok(dict.insert(choices, name, value))
      }
      False, Error(_) -> Error(invalid())
    }
  })
}

// ---- documents and groups ---------------------------------------------------

/// Every document a group projection reads.
fn documents(home: String) -> Result(Object, Refusal) {
  list.try_map(projected_documents, fn(file) {
    use document <- result.try(load(home, file))
    Ok(#(file, dynamic_of(document)))
  })
  |> result.map(dict.from_list)
}

fn load(home: String, file: String) -> Result(Object, Refusal) {
  settings_store.load(home, file) |> result.replace_error(unpublished())
}

/// A saved document of a candidate. Every candidate holds every document.
fn document(documents: Object, file: String) -> Result(Object, Refusal) {
  dict.get(documents, file)
  |> result.unwrap(empty())
  |> object_or_invalid
}

/// `config.json` with legacy flat profiles named.
fn saved_config(documents: Object) -> Result(Object, Refusal) {
  dict.get(documents, "config.json")
  |> result.unwrap(empty())
  |> profiles.named_config
  |> result.replace_error(unpublished())
}

fn groups(
  documents: Object,
  declarations: List(declared.Declared),
) -> Result(Object, Refusal) {
  use groups <- result.try(
    projected(projection.groups(documents, declarations)),
  )
  object_or_invalid(groups)
}

fn projected(
  value: Result(Dynamic, projection.Error),
) -> Result(Dynamic, Refusal) {
  case value {
    Ok(value) -> Ok(value)
    Error(projection.InvalidSection) -> Error(unpublished())
    Error(projection.InvalidValue) -> Error(invalid())
  }
}

fn group_value(name: String, groups: Object) -> Result(Dynamic, Refusal) {
  dict.get(groups, name)
  |> result.replace_error(#(400, "invalid_request", "unknown settings group"))
}

fn validator(
  name: String,
  value: Dynamic,
  revisions: Object,
) -> Result(Object, Refusal) {
  use etag <- result.try(group_etag(name, value, revisions))
  Ok(
    dict.from_list([
      #("url", dynamic.string("/settings/" <> name)),
      #("etag", dynamic.string(etag)),
    ]),
  )
}

/// A group's ETag covers its value and its revision counter, which each
/// publication of the group advances.
fn group_etag(
  name: String,
  value: Dynamic,
  revisions: Object,
) -> Result(String, Refusal) {
  use revision <- result.try(
    decode.run(get_or(revisions, name, dynamic.int(0)), decode.int)
    |> result.replace_error(invalid()),
  )
  use _ <- result.try(ensure(revision >= 0, invalid()))
  use observed <- result.try(observed(name, value))
  Ok(
    etag.strong(
      encode(
        dynamic_of(
          dict.from_list([
            #("value", observed),
            #("revision", dynamic.int(revision)),
          ]),
        ),
      ),
    ),
  )
}

/// The cache priors list every profile's model, so a model switch would stale
/// a cap edit made against the models group it did not touch.
fn observed(name: String, value: Dynamic) -> Result(Dynamic, Refusal) {
  case name {
    "models" -> {
      use fields <- result.try(object_or_invalid(value))
      Ok(dynamic_of(dict.delete(fields, "cache_ttl_priors")))
    }
    _ -> Ok(value)
  }
}

/// Run `run` under the settings lock. A busy lock or an incomplete recovery
/// is `503 settings_unavailable` with its reason.
fn locked(home: String, run: fn() -> Result(a, Refusal)) -> Result(a, Refusal) {
  settings_store.lock(home, run, fn(failure) {
    Error(#(
      503,
      "settings_unavailable",
      settings_store.reason(failure, busy: "settings store is busy"),
    ))
  })
}

// ---- values -----------------------------------------------------------------

fn invalid() -> Refusal {
  #(400, "invalid_request", "invalid settings candidate")
}

fn unpublished() -> Refusal {
  #(503, "settings_unavailable", "settings could not be published")
}

fn ensure(condition: Bool, refusal: Refusal) -> Result(Nil, Refusal) {
  case condition {
    True -> Ok(Nil)
    False -> Error(refusal)
  }
}

/// The object under `key`, empty when absent. A value there that is not an
/// object is a settings failure, whether saved or patched.
fn section(document: Object, key: String) -> Result(Object, Refusal) {
  settings_store.section(document, key) |> result.replace_error(unpublished())
}

/// An object holding only `allowed` fields.
fn fields(value: Object, allowed: List(String)) -> Result(Nil, Refusal) {
  ensure(list.all(dict.keys(value), list.contains(allowed, _)), invalid())
}

fn fields_of(value: Dynamic, allowed: List(String)) -> Result(Object, Refusal) {
  use value <- result.try(object_or_invalid(value))
  use _ <- result.try(fields(value, allowed))
  Ok(value)
}

fn text(value: Dynamic, min: Int, max: Int) -> Result(String, Refusal) {
  case decode.run(value, decode.string) {
    Ok(text) -> {
      let size = string.byte_size(text)
      case size >= min && size <= max {
        True -> Ok(text)
        False -> Error(invalid())
      }
    }
    Error(_) -> Error(invalid())
  }
}

fn nullable_text(value: Dynamic, max: Int) -> Result(Nil, Refusal) {
  case value == null() {
    True -> Ok(Nil)
    False -> text(value, 1, max) |> result.replace(Nil)
  }
}

fn counter(value: Dynamic, min: Int, max: Int) -> Result(Nil, Refusal) {
  case decode.run(value, decode.int) {
    Ok(number) if number >= min && number <= max -> Ok(Nil)
    _ -> Error(invalid())
  }
}

fn strings(
  value: Dynamic,
  max: Int,
  width: Int,
) -> Result(List(String), Refusal) {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok(items) ->
      case list.length(items) <= max {
        True -> list.try_map(items, text(_, 1, width))
        False -> Error(invalid())
      }
    Error(_) -> Error(invalid())
  }
}

/// A saved profile normalized by its owner, or an invalid candidate.
fn normalized(name: String, profile: Dynamic) -> Result(Object, Refusal) {
  profiles.normalize_profile(name, profile) |> result.replace_error(invalid())
}

/// `fields` renamed from patch names to saved names, dropping the rest.
fn translate(fields: Object, names: List(#(String, String))) -> Object {
  list.filter_map(names, fn(name) {
    dict.get(fields, name.0) |> result.map(fn(value) { #(name.1, value) })
  })
  |> dict.from_list
}

/// The `creds.json` entry holding a profile's key.
fn key_document(key: Dynamic) -> Dynamic {
  dynamic_of(dict.from_list([#("apiKey", key)]))
}

/// An empty string as null, as the saved default profile reads.
fn nonempty(value: Dynamic) -> Dynamic {
  case value == dynamic.string("") {
    True -> null()
    False -> value
  }
}

/// An object's entries in name order.
fn sorted(fields: Object) -> List(#(String, Dynamic)) {
  dict.to_list(fields)
  |> list.sort(fn(first, second) { string.compare(first.0, second.0) })
}

/// A patch value that is JSON null or something else.
type Value {
  Null
  Present(Dynamic)
}

fn classify(value: Dynamic) -> Value {
  case is_null(value) {
    True -> Null
    False -> Present(value)
  }
}

fn is_null(value: Dynamic) -> Bool {
  value == null()
}

fn text_of(value: Dynamic) -> Result(String, Nil) {
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

fn get_or(fields: Object, name: String, default: Dynamic) -> Dynamic {
  dict.get(fields, name) |> result.unwrap(default)
}

fn object_or_invalid(value: Dynamic) -> Result(Object, Refusal) {
  case is_map(value) {
    True -> Ok(unsafe_object(value))
    False -> Error(invalid())
  }
}

fn empty() -> Dynamic {
  dynamic_of(dict.new())
}

fn null() -> Dynamic {
  settings_store.null()
}

/// A native JSON value as compact JSON text, encoded as the saved documents
/// and validators always have been.
fn encode(value: Dynamic) -> String {
  albedo_json.encode(value)
}

@external(erlang, "gleam_stdlib", "identity")
fn dynamic_of(value: a) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn unsafe_object(value: Dynamic) -> Object

@external(erlang, "erlang", "is_map")
fn is_map(value: Dynamic) -> Bool

/// Distinct values by Erlang's term order, where `1` and `1.0` are equal.
@external(erlang, "lists", "usort")
fn usort(values: List(Dynamic)) -> List(Dynamic)
