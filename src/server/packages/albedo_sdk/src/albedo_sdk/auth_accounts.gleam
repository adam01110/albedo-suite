//// Provider accounts as the /auth API describes and edits them. The settings
//// store owns persistence. No secret value leaves this module: projections
//// carry public identities, labels, endpoints and limit times.
////
//// Projections are native JSON objects encoded by the native JSON codec, so
//// the wire bytes match the stored terms field for field.

import albedo_bytes/digest
import albedo_bytes/scalars
import albedo_clock
import albedo_json
import albedo_protect
import albedo_sdk/accounts as account_pools
import albedo_sdk/credential_store.{type Object}
import albedo_sdk/key_accounts
import albedo_sdk/key_environment.{type KeyEnvironment}
import albedo_sdk/oauth.{type Account, type Login}
import albedo_sdk/profiles
import albedo_sdk/rotation
import albedo_sdk/settings_store
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// An HTTP status, error code, and message.
pub type Failure =
  #(Int, String, String)

const storage_unavailable = #(
  503,
  "auth_unavailable",
  "Provider account storage is unavailable.",
)

const sign_in_unavailable = #(
  503,
  "auth_unavailable",
  "Provider sign-in storage is unavailable.",
)

/// Project saved credentials through this login's account descriptor callback.
/// An unreadable or missing store returns an empty list. The callback must
/// return public metadata and must not expose secrets.
pub fn accounts(home: String, login: Login) -> List(Account) {
  case credential_store.accounts(credential_store.path(home)) {
    Ok(data) ->
      credential_store.values(data, login.store)
      |> list.map(fn(value) { login.account(dyn(value)) })
    Error(_) -> []
  }
}

/// Merge a signed-in account into `creds` without writing. The caller commits
/// it with the login. A credential with the same provider identity replaces
/// the saved one and keeps its public ID. Returns the public ID and the next
/// creds.json document.
pub fn signed_in(
  creds: Dynamic,
  store: String,
  credential: Dynamic,
  account: fn(Dynamic) -> Account,
  raw_id: String,
  provider: String,
) -> #(String, Dynamic) {
  let assert Ok(creds) = credential_store.object(creds)
  let saved = settings_store.object("accounts", creds)
  let values = credential_store.values(saved, store)
  let matches = fn(value: Object) { account(dyn(value)).id == raw_id }
  let previous = list.find(values, matches)
  let public_id = case previous {
    Ok(previous) -> existing_id(previous)
    Error(_) -> token()
  }
  let described = account(credential)
  let assert Ok(credential) = credential_store.object(credential)
  // A renamed account keeps its name; a new sign-in is named by its email,
  // told apart from the other accounts of the provider on that email.
  let label = case
    previous |> result.try(dict.get(_, "label")),
    described.email
  {
    Ok(label), _ -> Some(label)
    Error(_), Some(email) ->
      Some(
        dyn(scalars.take(distinct_label(email, described, values, account), 256)),
      )
    Error(_), None -> None
  }
  let credential = case label {
    Some(label) -> dict.insert(credential, "label", label)
    None -> credential
  }
  // Signing in again keeps an account the user disabled switched off.
  let credential = case
    previous |> result.map(fn(value) { account_pools.disabled(dyn(value)) })
  {
    Ok(True) -> dict.insert(credential, "enabled", dyn(False))
    _ -> credential
  }
  let credential =
    credential
    |> dict.insert("_albedo_account_id", dyn(public_id))
    |> dict.insert(
      "_albedo_account_meta",
      object([
        #("provider", dyn(provider)),
        #("label", dyn(scalars.take(described.label, 256))),
        #("detail", dyn(scalars.take(described.detail, 4096))),
      ]),
    )
  let next = case list.any(values, matches) {
    False -> list.append(values, [credential])
    True ->
      list.map(values, fn(value) {
        case matches(value) {
          True -> credential
          False -> value
        }
      })
  }
  #(
    public_id,
    dyn(dict.insert(
      creds,
      "accounts",
      dyn(credential_store.put_values(saved, store, next)),
    )),
  )
}

/// A new sign-in's label: its email, unless another account of the provider
/// already has that email (several accounts can share one), then the email
/// with the workspace name, else the plan, else `#N`, whichever no other
/// account is labelled with yet. Existing accounts are never renamed.
fn distinct_label(
  email: String,
  described: Account,
  values: List(Object),
  account: fn(Dynamic) -> Account,
) -> String {
  let others = list.map(values, fn(value) { #(value, account(dyn(value))) })
  let shared =
    list.filter(others, fn(other) { { other.1 }.email == Some(email) })
  let taken =
    list.map(others, fn(other) {
      case credential_store.text(other.0, "label") {
        Ok(label) -> label
        Error(_) -> { other.1 }.label
      }
    })
  case shared {
    [] -> email
    _ -> {
      let suffixes =
        list.flatten([
          option.to_result(described.workspace, Nil)
            |> result.map(list.wrap)
            |> result.unwrap([]),
          option.to_result(described.plan, Nil)
            |> result.map(list.wrap)
            |> result.unwrap([]),
          ["#" <> int.to_string(list.length(shared) + 1)],
        ])
      suffixes
      |> list.map(fn(suffix) { email <> " · " <> suffix })
      |> list.find(fn(label) { !list.contains(taken, label) })
      |> result.unwrap(
        email <> " · #" <> int.to_string(list.length(values) + 1),
      )
    }
  }
}

/// The saved account's public ID. A hand edit can leave one that is not a
/// string; signing in again replaces it with a fresh ID instead of failing.
fn existing_id(value: Object) -> String {
  credential_store.text(value, "_albedo_account_id")
  |> result.lazy_unwrap(token)
}

/// Change a saved account's label by public ID under the settings lock.
/// Environment accounts cannot be renamed. Return the public account as JSON
/// or `#(HTTP status, code, message)` on failure.
pub fn rename_account(
  home: String,
  logins: List(Login),
  id: String,
  label: String,
  keys: KeyEnvironment,
) -> Result(String, Failure) {
  patch_account(home, logins, id, Some(label), None, keys)
}

/// Change a saved account's label, its `enabled` switch, or both, by public
/// ID under the settings lock. A disabled account stays saved and signed in;
/// rotation and pins skip it. Environment accounts cannot be changed and tool
/// sign-ins cannot be disabled. Return the public account as JSON or
/// `#(HTTP status, code, message)` on failure.
pub fn patch_account(
  home: String,
  logins: List(Login),
  id: String,
  label: option.Option(String),
  enabled: option.Option(Bool),
  keys: KeyEnvironment,
) -> Result(String, Failure) {
  use <- locked(home)
  let selected =
    account_projection(home, logins, keys)
    |> list.filter(has_id(_, id))
  use <- ensure(selected != [], #(
    404,
    "account_unknown",
    "Unknown provider account.",
  ))
  use <- ensure(
    list.all(selected, fn(account) { field(account, "source") == dyn("saved") }),
    #(409, "account_external", "Environment accounts cannot be changed."),
  )
  use <- ensure(label != None || enabled != None, #(
    400,
    "invalid_request",
    "label or enabled is required.",
  ))
  use <- ensure(
    case label {
      Some(label) -> {
        let size = string.byte_size(label)
        size > 0 && size <= 256
      }
      None -> True
    },
    #(400, "invalid_request", "label is required."),
  )
  use <- ensure(
    enabled != Some(False)
      || !list.any(selected, fn(account) {
      field(account, "kind") == dyn("service")
    }),
    #(409, "account_service", "Tool sign-ins cannot be disabled."),
  )
  let change = fn(value: Object) {
    let value = case label {
      Some(label) -> dict.insert(value, "label", dyn(label))
      None -> value
    }
    case enabled {
      Some(False) -> dict.insert(value, "enabled", dyn(False))
      Some(True) -> dict.delete(value, "enabled")
      None -> value
    }
  }
  let creds = settings_store.read(home, "creds.json")
  let stored = settings_store.object("accounts", creds)
  let updated =
    list.fold(dict.keys(stored), stored, fn(saved, store) {
      credential_store.values(saved, store)
      |> list.map(fn(value) {
        case field(value, "_albedo_account_id") == dyn(id) {
          True -> change(value)
          False -> value
        }
      })
      |> credential_store.put_values(saved, store, _)
    })
  case updated == stored {
    True -> Nil
    False -> commit_creds(home, creds, updated)
  }
  let assert [public, ..] =
    account_projection(home, logins, keys)
    |> list.filter(has_id(_, id))
  Ok(encode(dyn(public)))
}

/// Create an identified key account for a supported key provider. `id` must
/// be a UUIDv7, and the key and endpoint must pass profile validation.
/// Return `#(created, public_account_json)` or `#(HTTP status, code, message)`.
/// An existing identity must match the original submitted intent.
pub fn put_key(
  home: String,
  provider: String,
  id: String,
  endpoint: String,
  key: String,
  label: String,
) -> Result(#(Bool, String), Failure) {
  use <- locked(home)
  use <- ensure(list.contains(key_accounts.providers(), provider), #(
    400,
    "provider_unknown",
    "Key accounts require a key provider.",
  ))
  use <- ensure(uuid_v7(id), #(
    400,
    "identity_invalid",
    "Account identity must be a UUIDv7.",
  ))
  let key_size = string.byte_size(key)
  use <- ensure(key_size > 0 && key_size <= 16_384, #(
    400,
    "invalid_request",
    "api_key is required.",
  ))
  use <- ensure(endpoint != "", #(
    400,
    "invalid_request",
    "endpoint is required.",
  ))
  use <- ensure(
    string.byte_size(endpoint) <= 4096 && profiles.valid_key_endpoint(endpoint),
    #(
      400,
      "invalid_request",
      "Invalid endpoint: use an http or https URL with a host, and no credentials, query or fragment.",
    ),
  )
  use <- ensure(profiles.valid_api_key(key), #(
    400,
    "invalid_request",
    "Invalid API key: it must not contain spaces or control characters.",
  ))
  let label = case label {
    "" -> rotation.key_label(key)
    _ -> label
  }
  let label_size = string.byte_size(label)
  use <- ensure(label_size > 0 && label_size <= 256, #(
    400,
    "invalid_request",
    "label must contain 1 to 256 bytes.",
  ))
  let creds = settings_store.read(home, "creds.json")
  let saved = settings_store.object("accounts", creds)
  let value =
    dict.from_list([
      #("type", dyn("key")),
      #("apiKey", dyn(key)),
      #("endpoint", dyn(endpoint)),
      #("label", dyn(label)),
      #("_albedo_account_id", dyn(id)),
    ])
  let identified =
    dict.keys(saved)
    |> list.flat_map(fn(store) {
      credential_store.values(saved, store)
      |> list.filter(fn(value) { field(value, "_albedo_account_id") == dyn(id) })
      |> list.map(fn(value) { #(store, value) })
    })
  let conflict = #(409, "conflict", "Account identity has different content.")
  use created <- result.try(case identified {
    [] -> {
      let existing =
        credential_store.values(saved, provider)
        |> list.filter(fn(value) {
          field(value, "type") == dyn("key")
          && field(value, "apiKey") == dyn(key)
          && field(value, "endpoint") == dyn(endpoint)
        })
      case existing {
        [previous, ..] -> {
          let assert Ok(previous_id) =
            credential_store.text(previous, "_albedo_account_id")
          Error(#(
            409,
            "key_exists",
            "Key already exists as account " <> previous_id <> ".",
          ))
        }
        [] -> {
          credential_store.values(saved, provider)
          |> list.append([value])
          |> credential_store.put_values(saved, provider, _)
          |> commit_creds(home, creds, _)
          Ok(True)
        }
      }
    }
    [#(store, previous)] if store == provider ->
      case dict.take(previous, dict.keys(value)) == value {
        True -> Ok(False)
        False -> Error(conflict)
      }
    _ -> Error(conflict)
  })
  let config = settings_store.read(home, "config.json")
  let saved_profiles =
    dict.get(config, "providers") |> result.unwrap(dyn(empty()))
  let assert [public] =
    key_projection(
      provider,
      settings_store.object("accounts", settings_store.read(home, "creds.json")),
      saved_profiles,
    )
    |> list.filter(has_id(_, id))
  Ok(#(created, encode(dyn(public))))
}

/// Whether `id` is a lowercase UUIDv7 in its canonical form. A single
/// trailing newline is accepted, as the anchored pattern this replaces did.
fn uuid_v7(id: String) -> Bool {
  case <<id:utf8>> {
    <<body:bytes-size(36), 10>> -> uuid_layout(body, 0)
    bytes -> uuid_layout(bytes, 0)
  }
}

fn uuid_layout(bytes: BitArray, index: Int) -> Bool {
  case bytes {
    <<>> -> index == 36
    <<byte, rest:bytes>> -> {
      let valid = case index {
        8 | 13 | 18 | 23 -> byte == 0x2D
        14 -> byte == 0x37
        19 -> byte == 0x38 || byte == 0x39 || byte == 0x61 || byte == 0x62
        _ ->
          { byte >= 0x30 && byte <= 0x39 } || { byte >= 0x61 && byte <= 0x66 }
      }
      valid && uuid_layout(rest, index + 1)
    }
    _ -> False
  }
}

/// Read the public authentication resource as serialized JSON under the
/// settings lock. Login declarations supply provider descriptors, and `keys`
/// names the environment key accounts. Errors are `#(HTTP status, code, message)`.
pub fn auth_snapshot(
  home: String,
  logins: List(Login),
  keys: KeyEnvironment,
) -> Result(String, Failure) {
  use <- locked(home)
  let providers =
    list.map(logins, fn(login) {
      object([
        #("id", dyn(login.provider)),
        #("label", dyn(login.label)),
        #("detail", dyn(login.detail)),
        #("kind", dyn(kind(login))),
        #(
          "flows",
          dyn(case login.callback {
            oauth.Device(_) -> ["browser"]
            _ -> ["browser", "manual"]
          }),
        ),
        #("fields", dyn([])),
        #("terms", terms(login)),
      ])
    })
  Ok(
    encode(
      object([
        #("providers", dyn(providers)),
        #("accounts", dyn(account_projection(home, logins, keys))),
      ]),
    ),
  )
}

fn kind(login: Login) -> String {
  case login.kind {
    oauth.Model -> "model"
    oauth.Service -> "service"
  }
}

fn terms(login: Login) -> Dynamic {
  case login.terms {
    None -> credential_store.null()
    Some(oauth.Terms(about, headline, paragraphs)) ->
      object([
        #("id", dyn("terms:" <> login.provider)),
        #("about", dyn(about)),
        #("headline", dyn(headline)),
        #("paragraphs", dyn(paragraphs)),
      ])
  }
}

/// Every account `GET /auth` describes, with its Google project and
/// per-meter limit marks. Secret values are never part of it.
pub fn account_overview(
  home: String,
  logins: List(Login),
  keys: KeyEnvironment,
) -> Result(json.Json, String) {
  let result = {
    use <- locked(home)
    let projected = account_projection(home, logins, keys)
    let stored =
      settings_store.object("accounts", settings_store.read(home, "creds.json"))
    let credentials =
      dict.keys(stored)
      |> list.flat_map(credential_store.values(stored, _))
      |> list.filter_map(fn(credential) {
        dict.get(credential, "_albedo_account_id")
        |> result.map(fn(id) { #(id, credential) })
      })
      |> dict.from_list
    Ok(
      list.map(projected, fn(account) {
        let credential =
          dict.get(credentials, field(account, "id"))
          |> result.unwrap(dict.new())
        dyn(overview(account, credential))
      })
      |> dyn
      |> albedo_json.to_json,
    )
  }
  result.map_error(result, fn(failure) { failure.2 })
}

fn overview(account: Object, credential: Object) -> Object {
  let meters =
    dict.get(credential, "limitedMeters")
    |> result.try(credential_store.object)
    |> result.unwrap(dict.new())
  let project = case credential_store.text(credential, "projectId") {
    Ok(project) if project != "" -> dyn(project)
    _ -> credential_store.null()
  }
  let limited =
    dict.to_list(meters)
    |> list.filter_map(fn(entry) {
      case decode.run(entry.1, decode.int) {
        Ok(until) if until > 0 ->
          Ok(#(entry.0, dyn(albedo_clock.format_rfc3339(until))))
        _ -> Error(Nil)
      }
    })
  account
  |> dict.insert("project", project)
  |> dict.insert("limited_meters", object(limited))
}

/// The saved accounts and then the environment key accounts. The caller holds
/// the settings lock. Missing account metadata may be persisted.
pub fn account_projection(
  home: String,
  logins: List(Login),
  keys: KeyEnvironment,
) -> List(Object) {
  let #(saved, saved_profiles) = saved_projection(home, logins)
  list.append(saved, env_key_projection(home, saved_profiles, keys))
}

/// The saved accounts alone, for a caller that never names an environment
/// account, such as a sign-in listing the accounts it created. The caller
/// holds the settings lock.
pub fn saved_accounts(home: String, logins: List(Login)) -> List(Dynamic) {
  saved_projection(home, logins).0 |> list.map(dyn)
}

fn saved_projection(
  home: String,
  logins: List(Login),
) -> #(List(Object), Dynamic) {
  let creds = settings_store.read(home, "creds.json")
  let saved = settings_store.object("accounts", creds)
  let config = settings_store.read(home, "config.json")
  let saved_profiles =
    dict.get(config, "providers") |> result.unwrap(dyn(empty()))
  let updated =
    list.fold(logins, saved, fn(accounts, login) {
      credential_store.values(accounts, login.store)
      |> list.map(fn(value) {
        case field(value, "type") == dyn("key") {
          True -> value
          False -> {
            let described = login.account(dyn(value))
            let fresh = token()
            value
            |> dict.insert(
              "_albedo_account_id",
              dict.get(value, "_albedo_account_id")
                |> result.unwrap(dyn(fresh)),
            )
            |> dict.insert(
              "_albedo_account_meta",
              object([
                #("provider", dyn(login.provider)),
                #("label", dyn(scalars.take(described.label, 256))),
                #("detail", dyn(scalars.take(described.detail, 4096))),
                #("kind", dyn(kind(login))),
              ]),
            )
          }
        }
      })
      |> credential_store.put_values(accounts, login.store, _)
    })
  case updated == saved {
    True -> Nil
    False -> commit_creds(home, creds, updated)
  }
  let oauth_accounts =
    dict.keys(updated)
    |> list.sort(string.compare)
    |> list.flat_map(fn(store) {
      credential_store.values(updated, store)
      |> list.filter_map(fn(credential) {
        case field(credential, "type") == dyn("key") {
          True -> Error(Nil)
          False ->
            case
              dict.get(credential, "_albedo_account_id"),
              dict.get(credential, "_albedo_account_meta")
            {
              Ok(id), Ok(meta) -> {
                let assert Ok(meta) = credential_store.object(meta)
                let assert Ok(meta_label) = dict.get(meta, "label")
                let label =
                  dict.get(credential, "label") |> result.unwrap(meta_label)
                let #(email, plan, refused) = case
                  list.find(logins, fn(login) { login.store == store })
                {
                  Ok(login) -> {
                    let described = login.account(dyn(credential))
                    #(described.email, described.plan, described.needs_sign_in)
                  }
                  Error(_) -> #(None, None, False)
                }
                Ok(
                  meta
                  |> dict.insert("id", id)
                  |> dict.insert("label", label)
                  |> dict.insert("source", dyn("saved"))
                  |> dict.insert("endpoint", credential_store.null())
                  |> dict.insert("limited_until", limited_until(credential))
                  |> dict.insert("email", reported(email, 320))
                  |> dict.insert("plan", reported(plan, 64))
                  |> dict.insert(
                    "needs_sign_in",
                    dyn(refused || credential_store.needs_sign_in(credential)),
                  )
                  |> dict.insert(
                    "enabled",
                    dyn(!account_pools.disabled(dyn(credential))),
                  )
                  |> dict.insert(
                    "selected_by_profiles",
                    dyn(selected_profiles(saved_profiles, id)),
                  )
                  |> dict.insert(
                    "rotated_by_profiles",
                    dyn(rotated_profiles(saved_profiles, id)),
                  ),
                )
              }
              _, _ -> Error(Nil)
            }
        }
      })
    })
  let key_accounts =
    list.flat_map(key_accounts.providers(), fn(store) {
      key_projection(store, updated, saved_profiles)
    })
  #(list.append(oauth_accounts, key_accounts), saved_profiles)
}

fn env_key_projection(
  home: String,
  saved_profiles: Dynamic,
  keys: KeyEnvironment,
) -> List(Object) {
  let providers = key_accounts.providers()
  profile_entries(saved_profiles)
  |> list.filter_map(fn(entry) {
    let profile = entry.1
    let extension = case dict.get(profile, "extension") {
      Error(_) -> Ok(profiles.default_extension())
      Ok(extension) -> decode.run(extension, decode.string)
    }
    case extension {
      Ok(extension) ->
        case list.contains(providers, extension) {
          True -> Ok(#(extension, text_or(profile, "baseUrl", "")))
          False -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
  |> usort
  |> list.flat_map(fn(pair) {
    let #(provider, endpoint) = pair
    key_accounts.environment_values(home, provider, endpoint, keys)
    |> list.filter_map(key_descriptor(provider, _, saved_profiles))
  })
  |> usort
}

/// The string field, `default` when absent or not a string.
fn text_or(value: Object, name: String, default: String) -> String {
  credential_store.text(value, name) |> result.unwrap(default)
}

/// A reported email or plan within the contract's length, else JSON null.
fn reported(value: option.Option(String), limit: Int) -> Dynamic {
  case value {
    Some(text) if text != "" -> dyn(scalars.take(text, limit))
    _ -> credential_store.null()
  }
}

fn limited_until(credential: Object) -> Dynamic {
  case decode.run(field(credential, "limitedUntil"), decode.int) {
    Ok(until) if until > 0 -> dyn(albedo_clock.format_rfc3339(until))
    _ -> credential_store.null()
  }
}

/// The saved profiles by name. Crashes, like the projection it serves, when
/// the providers section or one of its profiles is not an object.
fn profile_entries(saved_profiles: Dynamic) -> List(#(String, Object)) {
  let assert Ok(entries) = credential_store.object(saved_profiles)
  dict.to_list(entries)
  |> list.map(fn(entry) {
    let assert Ok(profile) = credential_store.object(entry.1)
    #(entry.0, profile)
  })
}

fn rotation_ids(profile: Object) -> List(Dynamic) {
  decode.run(field(profile, "accountIds"), decode.list(decode.dynamic))
  |> result.unwrap([])
}

fn selected_profiles(saved_profiles: Dynamic, id: Dynamic) -> List(String) {
  profile_entries(saved_profiles)
  |> list.filter(fn(entry) { field(entry.1, "accountId") == id })
  |> list.map(fn(entry) { entry.0 })
  |> list.sort(string.compare)
}

fn rotated_profiles(saved_profiles: Dynamic, id: Dynamic) -> List(String) {
  profile_entries(saved_profiles)
  |> list.filter(fn(entry) { list.contains(rotation_ids(entry.1), id) })
  |> list.map(fn(entry) { entry.0 })
  |> list.sort(string.compare)
}

fn key_projection(
  store: String,
  saved: Object,
  saved_profiles: Dynamic,
) -> List(Object) {
  credential_store.values(saved, store)
  |> list.filter(fn(credential) { field(credential, "type") == dyn("key") })
  |> list.filter_map(key_descriptor(store, _, saved_profiles))
}

/// The public descriptor of a key account. A hand-edited creds.json can hold
/// a malformed key account. One without an ID, or without a label and a key
/// that bytes can be read from, is an error, so the listing skips it rather
/// than fail for every account.
fn key_descriptor(
  store: String,
  credential: Object,
  saved_profiles: Dynamic,
) -> Result(Object, Nil) {
  use id <- result.try(dict.get(credential, "_albedo_account_id"))
  use label <- result.try(case dict.get(credential, "label") {
    Ok(label) -> Ok(label)
    Error(_) ->
      field(credential, "apiKey")
      |> decode.run(key_bytes())
      |> result.map(fn(key) { dyn(rotation.key_bytes_label(key)) })
      |> result.replace_error(Nil)
  })
  let endpoint = field(credential, "endpoint")
  let null = credential_store.null()
  Ok(
    dict.from_list([
      #("id", id),
      #("provider", dyn(store)),
      #("label", label),
      #("detail", case endpoint == null {
        True -> dyn("")
        False -> host(endpoint)
      }),
      #("kind", dyn("key")),
      #("source", dict.get(credential, "source") |> result.unwrap(dyn("saved"))),
      #("endpoint", endpoint),
      #("limited_until", limited_until(credential)),
      #("email", credential_store.null()),
      #("plan", credential_store.null()),
      #("needs_sign_in", dyn(False)),
      #("enabled", dyn(!account_pools.disabled(dyn(credential)))),
      #("selected_by_profiles", dyn(selected_profiles(saved_profiles, id))),
      #("rotated_by_profiles", dyn(rotated_profiles(saved_profiles, id))),
    ]),
  )
}

/// A saved key's bytes, read as Erlang reads iodata: a string, or a list of
/// byte values and nested lists. The key label hashes these bytes, so a key a
/// hand edit stored as `[115, 107]` keeps the label of `"sk"`.
fn key_bytes() -> decode.Decoder(BitArray) {
  use <- decode.recursive
  let byte = {
    use value <- decode.then(decode.int)
    case value >= 0 && value <= 255 {
      True -> decode.success(<<value>>)
      False -> decode.failure(<<>>, "Byte")
    }
  }
  decode.one_of(decode.bit_array, [
    decode.list(decode.one_of(byte, [key_bytes()]))
    |> decode.map(bit_array.concat),
  ])
}

/// The endpoint's host, or the endpoint itself when it has none.
fn host(endpoint: Dynamic) -> Dynamic {
  case
    decode.run(
      uri_parse(endpoint),
      decode.field(atom.create("host"), decode.dynamic, decode.success),
    )
  {
    Ok(host) -> host
    Error(_) -> endpoint
  }
}

/// Remove a saved account by public ID under the settings lock, and take it
/// out of every profile (see `without_account`). Only an unknown or
/// environment account is refused, as `#(HTTP status, code, message)`.
pub fn remove_account(
  home: String,
  logins: List(Login),
  id: String,
  keys: KeyEnvironment,
) -> Result(Nil, Failure) {
  use <- locked(home)
  let selected =
    account_projection(home, logins, keys)
    |> list.filter(has_id(_, id))
  use <- ensure(selected != [], #(
    404,
    "account_unknown",
    "Unknown provider account.",
  ))
  use <- ensure(
    list.all(selected, fn(account) {
      { dict.get(account, "source") |> result.unwrap(dyn("saved")) }
      == dyn("saved")
    }),
    #(409, "account_external", "Environment accounts cannot be changed."),
  )
  let config = settings_store.read(home, "config.json")
  let saved_profiles =
    dict.get(config, "providers") |> result.unwrap(dyn(empty()))
  let entries = profile_entries(saved_profiles)
  let creds = settings_store.read(home, "creds.json")
  let stored = settings_store.object("accounts", creds)
  // Rotation forgets when the account was last given to a session, by the
  // identities selection knows it by: its public ID (keys) and its login's.
  list.each(dict.keys(stored), fn(store) {
    credential_store.values(stored, store)
    |> list.filter(fn(value) { field(value, "_albedo_account_id") == dyn(id) })
    |> list.each(fn(value) {
      account_pools.forget_account(id)
      case list.find(logins, fn(login) { login.store == store }) {
        Ok(login) -> account_pools.forget_account(login.account(dyn(value)).id)
        Error(_) -> Nil
      }
    })
  })
  let updated =
    list.fold(dict.keys(stored), stored, fn(saved, store) {
      credential_store.values(saved, store)
      |> list.filter(fn(value) { field(value, "_albedo_account_id") != dyn(id) })
      |> credential_store.put_values(saved, store, _)
    })
  let next_profiles =
    list.map(entries, fn(entry) {
      let #(name, profile) = entry
      #(name, dyn(without_account(profile, dyn(id))))
    })
  settings_store.commit_group(
    home,
    dict.from_list([
      #("creds.json", dyn(dict.insert(creds, "accounts", dyn(updated)))),
      #(
        "config.json",
        dyn(
          config
          |> dict.insert("accountsVersion", dyn(2))
          |> dict.insert("providers", object(next_profiles)),
        ),
      ),
    ]),
  )
  Ok(Nil)
}

/// The next `config.json` once a new model sign-in `id` for `extension`,
/// saved under `store` in `creds`, joins its service:
///
/// - each profile of the extension with `accountIds` gains it at the end;
/// - each with neither a pin nor a list, nor a saved key, rotates through
///   every saved sign-in of the store, in file order, the new one last;
/// - a profile pinned by `accountId` is left alone;
/// - when no profile uses the extension, `first` (a model and protocol)
///   creates one named after it (`name`, `name-2`, ...) that rotates through
///   the new account, and it becomes the default when none is set.
///
/// Pure: the caller commits the result with the credential.
pub fn joined(
  config: Dynamic,
  creds: Dynamic,
  store: String,
  extension: String,
  id: String,
  first: option.Option(#(String, String)),
) -> Dynamic {
  let assert Ok(config) = credential_store.object(config)
  let assert Ok(creds) = credential_store.object(creds)
  // A legacy flat config is one profile without a name to join.
  use <- bool.guard(
    !dict.has_key(config, "providers") && dict.has_key(config, "model"),
    dyn(config),
  )
  let saved = dict.get(config, "providers") |> result.unwrap(dyn(empty()))
  let entries = profile_entries(saved)
  let keys = settings_store.object("providers", creds)
  let signed_in_ids =
    credential_store.values(settings_store.object("accounts", creds), store)
    |> list.filter(fn(value) { field(value, "type") != dyn("key") })
    |> list.filter_map(fn(value) {
      credential_store.text(value, "_albedo_account_id")
    })
  let own =
    list.filter(entries, fn(entry) {
      text_or(entry.1, "extension", profiles.default_extension()) == extension
    })
  let null = credential_store.null()
  let next = case own, first {
    [], Some(#(model, protocol)) -> {
      let name = free_name(extension, entries, 1)
      let profile =
        dict.from_list([
          #("extension", dyn(extension)),
          #("baseUrl", dyn("")),
          #("model", dyn(model)),
          #("protocol", dyn(protocol)),
          #("accountIds", dyn([id])),
          #("rotation", dyn("failover")),
        ])
      let config =
        dict.insert(
          config,
          "providers",
          object([
            #(name, dyn(profile)),
            ..list.map(entries, fn(entry) { #(entry.0, dyn(entry.1)) })
          ]),
        )
      case field(config, "active") {
        active if active == null -> dict.insert(config, "active", dyn(name))
        active ->
          case decode.run(active, decode.string) {
            Ok("") | Error(_) -> dict.insert(config, "active", dyn(name))
            Ok(_) -> config
          }
      }
    }
    [], None -> config
    _, _ -> {
      let updated =
        list.map(entries, fn(entry) {
          let #(name, profile) = entry
          let joins = list.contains(own, entry)
          let pinned = field(profile, "accountId") != null
          let listed =
            decode.run(
              field(profile, "accountIds"),
              decode.list(decode.dynamic),
            )
          let next = case joins, pinned, listed {
            False, _, _ | _, True, _ -> profile
            True, False, Ok([_, ..] as ids) ->
              case list.contains(ids, dyn(id)) {
                True -> profile
                False ->
                  dict.insert(
                    profile,
                    "accountIds",
                    dyn(list.append(ids, [dyn(id)])),
                  )
              }
            True, False, _ ->
              case dict.has_key(keys, name) || has_inline_key(profile) {
                True -> profile
                False -> dict.insert(profile, "accountIds", dyn(signed_in_ids))
              }
          }
          #(name, dyn(next))
        })
      dict.insert(config, "providers", object(updated))
    }
  }
  dyn(next)
}

fn has_inline_key(profile: Object) -> Bool {
  case credential_store.text(profile, "apiKey") {
    Ok(key) -> key != ""
    Error(_) -> False
  }
}

/// `base`, else `base-2`, `base-3`, ... the first no profile takes.
fn free_name(base: String, entries: List(#(String, Object)), n: Int) -> String {
  let name = case n {
    1 -> base
    _ -> base <> "-" <> int.to_string(n)
  }
  case list.any(entries, fn(entry) { entry.0 == name }) {
    True -> free_name(base, entries, n + 1)
    False -> name
  }
}

/// A profile once account `id` is signed out: a pin to it goes back to
/// automatic selection, and it leaves the rotation list, which becomes null
/// when it empties.
fn without_account(profile: Object, id: Dynamic) -> Object {
  let profile = case field(profile, "accountId") == id {
    True -> dict.delete(profile, "accountId")
    False -> profile
  }
  case decode.run(field(profile, "accountIds"), decode.list(decode.dynamic)) {
    Ok(ids) ->
      case list.filter(ids, fn(value) { value != id }) {
        [] -> dict.delete(profile, "accountIds")
        kept -> dict.insert(profile, "accountIds", dyn(kept))
      }
    Error(_) -> profile
  }
}

// ---- helpers ----------------------------------------------------------------

/// Run `run` under the settings lock. A busy or unrecoverable store is the
/// sign-in storage failure. Any crash, including a raised settings failure,
/// is the account storage failure.
fn locked(home: String, run: fn() -> Result(a, Failure)) -> Result(a, Failure) {
  case
    albedo_protect.attempt(fn() {
      settings_store.lock(home, fn() { Ok(run()) }, fn(_) { Error(Nil) })
    })
  {
    Ok(Ok(result)) -> result
    Ok(Error(_)) -> Error(sign_in_unavailable)
    Error(_) -> Error(storage_unavailable)
  }
}

fn ensure(
  condition: Bool,
  failure: Failure,
  next: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case condition {
    True -> next()
    False -> Error(failure)
  }
}

fn commit_creds(home: String, creds: Object, accounts: Object) -> Nil {
  settings_store.commit_group(
    home,
    dict.from_list([
      #("creds.json", dyn(dict.insert(creds, "accounts", dyn(accounts)))),
    ]),
  )
  Nil
}

fn has_id(account: Object, id: String) -> Bool {
  field(account, "id") == dyn(id)
}

/// The field, JSON `null` when absent.
fn field(value: Object, name: String) -> Dynamic {
  credential_store.field(value, name)
}

fn object(fields: List(#(String, Dynamic))) -> Dynamic {
  dyn(dict.from_list(fields))
}

fn empty() -> Dict(String, Dynamic) {
  dict.new()
}

fn token() -> String {
  digest.hex(crypto.strong_random_bytes(16))
}

fn encode(value: Dynamic) -> String {
  albedo_json.encode(value)
}

fn dyn(value: a) -> Dynamic {
  credential_store.to_dynamic(value)
}

@external(erlang, "lists", "usort")
fn usort(values: List(a)) -> List(a)

@external(erlang, "uri_string", "parse")
fn uri_parse(url: Dynamic) -> Dynamic
