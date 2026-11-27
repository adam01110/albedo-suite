//// Provider settings, account resources, and sign-in operations.

import albedo/composition/capability_catalog
import albedo/composition/selection
import albedo/history/conversation
import albedo/http/http_api
import albedo/observation/bus
import albedo/refusal
import albedo/runtime
import albedo/runtime/catalog as session_catalog
import albedo/session/registry.{type Config, type Message}
import albedo/settings/composition
import albedo/settings/core_settings
import albedo/settings/settings
import albedo_bytes/scalars
import albedo_json
import albedo_sdk/auth_accounts
import albedo_sdk/extension
import albedo_sdk/extension/grants
import albedo_sdk/http_api as sdk_http_api
import albedo_sdk/oauth
import albedo_sdk/oauth_flows
import albedo_sdk/store
import albedo_web/etag
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http.{Delete, Get, Patch, Put}
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mist

pub fn settings(
  config: Config,
  group: String,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(case group {
      "" if req.method == Get -> Ok(Nil)
      _ ->
        settings.parse_group(group)
        |> result.replace(Nil)
        |> result.map_error(sdk_http_api.invalid)
    })
    case req.method {
      Get -> {
        use host <- result.try(
          registry.host(registry) |> result.map_error(refusal.failure),
        )
        use observed <- result.try(
          settings.observe_group(
            config.home,
            group,
            core_settings.all(runtime.installed(host)),
          )
          |> result.map_error(http_api.native_failure),
        )
        let response = sdk_http_api.raw(200, observed.value)
        Ok(case observed.etag {
          None -> response
          Some(etag) -> response |> response.set_header("etag", etag)
        })
      }
      _ -> {
        let allowed = case group {
          "providers" -> ["default_profile", "profiles", "renames"]
          "mcp" -> ["definitions", "validate_connection"]
          "extensions" -> ["defaults"]
          "extension_settings" -> ["values"]
          "capabilities" -> [
            "catalog_session_id",
            "catalog_revision",
            "choices",
          ]
          "models" -> ["raised_caps", "compact_at"]
          _ -> [
            "assistant_name",
            "thinking",
            "tools",
            "dismissed_notices",
            "web_allow",
            "proxy_allow",
          ]
        }
        use patch <- result.try(sdk_http_api.body(req, allowed, decode.dynamic))
        use host <- result.try(
          registry.host(registry) |> result.map_error(refusal.failure),
        )
        let logins = runtime.logins(host)
        let providers =
          runtime.installed(host)
          |> list.filter(fn(item) {
            list.any(item.plugins, fn(plugin) {
              case plugin {
                extension.ModelProviderPlugin(_) -> True
                _ -> False
              }
            })
          })
          |> list.map(fn(item) { item.name })
        let composes =
          settings.parse_group(group)
          |> result.map(settings.composes)
          |> result.unwrap(False)
        use before <- result.try(case composes {
          True ->
            composition.composition_revision(config.home)
            |> result.map(Some)
            |> result.map_error(refusal.unavailable)
          False -> Ok(None)
        })
        let patch_group = fn(commit_defaults) {
          settings.patch_group(
            config.home,
            group,
            request.get_header(req, "if-match") |> result.unwrap(""),
            albedo_json.encode(patch),
            providers,
            logins,
            fn(patch) { resolve_global_capabilities(config.home, host, patch) },
            fn(current, changes) {
              selection.change_defaults(
                runtime.installed(host),
                runtime.base_defaults(host),
                current,
                changes,
              )
              |> result.map_error(fn(error) {
                case error {
                  selection.ConflictingStrategies -> #(
                    400,
                    "selection_conflict",
                    "choose one compaction strategy in each patch",
                  )
                  selection.InvalidSelection(detail) -> #(
                    400,
                    "selection_invalid",
                    detail,
                  )
                }
              })
            },
            commit_defaults,
            core_settings.all(runtime.installed(host)),
            extension.mcp_servers(runtime.installed(host)),
            runtime.key_environment(host),
          )
        }
        use changed <- result.try({
          case group {
            // Serialize the writer before taking the settings lock. A delivery
            // may read the current default while checking its grant on that writer.
            "extensions" ->
              store.query(runtime.ledger(host), fn(conn) {
                patch_group(fn(choices, publish) {
                  let enabled =
                    selection.defaults_with(
                      runtime.installed(host),
                      runtime.base_defaults(host),
                      choices,
                    )
                  let refused = fn(_) {
                    #(
                      503,
                      "settings_unavailable",
                      "extension grants could not be updated",
                    )
                  }
                  use <- store.transaction_with(conn, refused)
                  use _ <- result.try(
                    grants.reconcile(conn, list.contains(enabled, _))
                    |> result.map_error(refused),
                  )
                  publish()
                })
              })
            _ -> patch_group(fn(_, publish) { publish() })
          }
          |> result.map_error(http_api.native_failure)
        })
        use fields <- result.try(sdk_http_api.fields(changed))
        let warnings = case group {
          "providers" -> follow_renames(registry, host, patch)
          _ -> []
        }
        use revision <- result.try(
          composition.composition_revision(config.home)
          |> result.map_error(refusal.unavailable),
        )
        use enabled <- result.try(
          runtime.global(host) |> result.map_error(refusal.unavailable),
        )
        let service_names =
          list.filter_map(enabled, fn(item) {
            case extension.service(enabled, item.name) {
              Ok(_) -> Ok(item.name)
              Error(_) -> Error(Nil)
            }
          })
        let service_revision =
          etag.strong(json.array(service_names, json.string) |> json.to_string)
        let application =
          json.object([
            #("desired_revision", json.string(revision)),
            #("active_service_revision", json.string(service_revision)),
            // Which sessions are behind is asked separately, through
            // GET /sessions?needs_reload=true: it observes every loaded one.
            #(
              "composition_changed",
              json.bool(composes && before != Some(revision)),
            ),
            #(
              "validation",
              list.key_find(fields, "validation")
                |> result.unwrap(json.string("not_applicable")),
            ),
            #("warnings", json.array(warnings, fn(value) { value })),
          ])
        let fields = list.filter(fields, fn(field) { field.0 != "validation" })
        case
          group,
          decode.run(
            patch,
            decode.field("assistant_name", decode.string, decode.success),
          )
        {
          "ui", Ok(_) -> registry.chat_name_changed(registry)
          _, _ -> Nil
        }
        bus.invalidate(["/settings", "/sessions"], [], True)
        Ok(sdk_http_api.reply(
          200,
          json.object([#("application", application), ..fields]),
        ))
      }
    }
  }
  http_api.answer(outcome)
}

/// Sessions on a renamed profile take its new name, once the settings that
/// rename it are published. Rows of a deleted profile are retired, so a
/// profile that later takes its name does not take them over.
fn follow_renames(
  registry: Subject(Message),
  host: runtime.Runtime,
  patch: Dynamic,
) -> List(json.Json) {
  let renames =
    decode.run(
      patch,
      decode.optional_field(
        "renames",
        dict.new(),
        decode.dict(decode.string, decode.string),
        decode.success,
      ),
    )
    |> result.unwrap(dict.new())
    |> dict.to_list
  // A profile a rename moved away is not deleted by a null under its old name.
  let deleted =
    decode.run(
      patch,
      decode.optional_field(
        "profiles",
        dict.new(),
        decode.dict(decode.string, decode.optional(decode.dynamic)),
        decode.success,
      ),
    )
    |> result.unwrap(dict.new())
    |> dict.to_list
    |> list.filter_map(fn(change) {
      case change.1, list.key_find(renames, change.0) {
        None, Error(Nil) -> Ok(#(change.0, conversation.retired))
        _, _ -> Error(Nil)
      }
    })
  let changes = list.append(renames, deleted)
  let ledger = runtime.ledger(host)
  let failed =
    list.filter_map(changes, fn(change) {
      let saved = case change.1 == conversation.retired {
        True -> conversation.retire_provider(ledger, change.0)
        False -> conversation.rename_provider(ledger, change.0, change.1)
      }
      case saved {
        Ok(Nil) -> Error(Nil)
        Error(_) -> Ok(change.0)
      }
    })
  case changes {
    [] -> Nil
    _ -> registry.rename_profiles(registry, changes)
  }
  list.map(failed, fn(name) {
    json.object([
      #("code", json.string("sessions_not_renamed")),
      #(
        "detail",
        json.string(
          "sessions on " <> name <> " still name it; choose their profile again",
        ),
      ),
    ])
  })
}

pub fn keys(
  config: Config,
  req: request.Request(BitArray),
  id: String,
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use submitted <- result.try(
      sdk_http_api.body(req, ["provider", "endpoint", "api_key", "label"], {
        use provider <- decode.field("provider", decode.string)
        use endpoint <- decode.field("endpoint", decode.string)
        use api_key <- decode.field("api_key", decode.string)
        use label <- decode.optional_field("label", "", decode.string)
        decode.success(#(provider, endpoint, api_key, label))
      }),
    )
    let #(provider, endpoint, api_key, label) = submitted
    use value <- result.try(
      auth_accounts.put_key(config.home, provider, id, endpoint, api_key, label)
      |> result.map_error(http_api.native_failure),
    )
    Ok(sdk_http_api.raw(
      case value.0 {
        True -> 201
        False -> 200
      },
      value.1,
    ))
  }
  http_api.answer(outcome)
}

pub fn auth(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use host <- result.try(
      registry.host(registry) |> result.map_error(refusal.failure),
    )
    use value <- result.try(
      auth_accounts.auth_snapshot(
        config.home,
        runtime.logins(host),
        runtime.key_environment(host),
      )
      |> result.map_error(http_api.native_failure),
    )
    Ok(sdk_http_api.raw(200, value))
  }
  http_api.answer(outcome)
}

/// The model and protocol of the profile a first model sign-in to
/// `provider` creates: the first model its catalog lists, as clients pick
/// when they create one, and the protocol its adapter takes. The sign-in asks
/// only when no profile uses the extension, outside the settings lock.
fn first_profile(
  host: runtime.Runtime,
  provider: String,
) -> oauth_flows.FirstProfile {
  let installed = runtime.installed(host)
  let keys = runtime.key_environment(host)
  fn() {
    case extension.provider_model_names(installed, provider, None, keys) {
      [model, ..] -> Some(#(model, sign_in_protocol(provider)))
      [] -> None
    }
  }
}

/// The wire protocol a sign-in provider's adapter requires: ChatGPT's takes
/// the Responses API, every other sign-in chat completions. The clients'
/// sign-in tables hold the same rule.
fn sign_in_protocol(provider: String) -> String {
  case provider {
    "codex" -> "responses"
    _ -> "chat_completions"
  }
}

pub fn login(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use logins <- result.try(
      registry.logins(registry) |> result.map_error(refusal.unavailable),
    )
    case req.method {
      Put -> {
        use submitted <- result.try(
          sdk_http_api.body(req, ["provider", "flow", "values"], {
            use provider <- decode.field("provider", decode.string)
            use flow <- decode.optional_field("flow", "browser", decode.string)
            use values <- decode.field(
              "values",
              decode.dict(decode.string, decode.dynamic),
            )
            decode.success(#(provider, flow, values))
          }),
        )
        let #(provider, flow, values) = submitted
        use _ <- result.try(
          case
            list.contains(["browser", "manual"], flow) && dict.size(values) == 0
          {
            True -> Ok(Nil)
            False ->
              Error(sdk_http_api.invalid(
                "provider supports browser and manual flows with no form values",
              ))
          },
        )
        let intent =
          json.object([
            #("provider", json.string(provider)),
            #("flow", json.string(flow)),
            #("values", json.object([])),
          ])
          |> json.to_string
        use #(login, keep) <- result.try(
          case list.find(logins, fn(login) { login.provider == provider }) {
            Ok(login) -> Ok(#(Some(login), None))
            Error(Nil) -> resolved_login(config, registry, provider)
          },
        )
        use host <- result.try(
          registry.host(registry) |> result.map_error(refusal.failure),
        )
        use created <- result.try(
          oauth_flows.start_identified(
            config.oauth,
            config.home,
            id,
            provider,
            login,
            keep,
            intent,
            first_profile(host, provider),
          )
          |> result.map_error(http_api.native_failure),
        )
        let response =
          sdk_http_api.raw(
            case created.0 {
              True -> 201
              False -> 200
            },
            created.1,
          )
          |> response.set_header("etag", etag.strong(created.1))
        Ok(case created.0 {
          True ->
            response |> response.set_header("location", "/auth/logins/" <> id)
          False -> response
        })
      }
      Get -> {
        use value <- result.try(
          oauth_flows.get_identified(config.oauth, config.home, id, logins)
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          sdk_http_api.raw(200, value)
          |> response.set_header("etag", etag.strong(value)),
        )
      }
      Patch -> {
        use supplied <- result.try(sdk_http_api.body(
          req,
          ["response"],
          decode.field("response", decode.string, decode.success),
        ))
        use _ <- result.try(
          case
            scalars.length(supplied) > 0
            && bit_array.byte_size(bit_array.from_string(supplied)) <= 16_384
          {
            True -> Ok(Nil)
            False ->
              Error(sdk_http_api.invalid(
                "response must contain at most 16384 bytes",
              ))
          },
        )
        use value <- result.try(
          oauth_flows.input_identified(
            config.oauth,
            config.home,
            id,
            request.get_header(req, "if-match") |> result.unwrap(""),
            supplied,
            logins,
          )
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          sdk_http_api.raw(200, value)
          |> response.set_header("etag", etag.strong(value)),
        )
      }
      _ -> {
        use _ <- result.try(sdk_http_api.empty_body(req))
        use _ <- result.try(
          oauth_flows.cancel_identified(config.oauth, config.home, id, logins)
          |> result.map_error(http_api.native_failure),
        )
        Ok(
          response.new(204)
          |> response.set_body(mist.Bytes(bytes_tree.new()))
          |> response.set_header("cache-control", "no-store"),
        )
      }
    }
  }
  http_api.answer(outcome)
}

/// A sign-in an extension names at request time, such as an MCP server's,
/// and how it keeps the credential. One it names but cannot start yet is
/// refused with its reason.
fn resolved_login(
  config: Config,
  registry: Subject(Message),
  provider: String,
) -> Result(#(Option(oauth.Login), Option(oauth.Keep)), sdk_http_api.Failure) {
  use host <- result.try(
    registry.host(registry) |> result.map_error(refusal.failure),
  )
  case extension.resolve_login(runtime.installed(host), config.home, provider) {
    None -> Ok(#(None, None))
    Some(Ok(#(login, keep))) -> Ok(#(Some(login), Some(keep)))
    Some(Error(reason)) ->
      Error(sdk_http_api.Failure(409, "sign_in_unavailable", reason))
  }
}

pub fn account(
  config: Config,
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = case req.method {
    Patch -> {
      use #(label, enabled) <- result.try(
        sdk_http_api.body(req, ["label", "enabled"], {
          use label <- decode.optional_field(
            "label",
            None,
            decode.map(decode.string, Some),
          )
          use enabled <- decode.optional_field(
            "enabled",
            None,
            decode.map(decode.bool, Some),
          )
          decode.success(#(label, enabled))
        }),
      )
      use _ <- result.try(http_api.json_parameters(req, []))
      use host <- result.try(
        registry.host(registry) |> result.map_error(refusal.failure),
      )
      use value <- result.try(
        auth_accounts.patch_account(
          config.home,
          runtime.logins(host),
          id,
          label,
          enabled,
          runtime.key_environment(host),
        )
        |> result.map_error(http_api.native_failure),
      )
      Ok(sdk_http_api.raw(200, value))
    }
    Delete -> {
      use _ <- result.try(http_api.json_parameters(req, []))
      use _ <- result.try(sdk_http_api.empty_body(req))
      use host <- result.try(
        registry.host(registry) |> result.map_error(refusal.failure),
      )
      use _ <- result.try(
        auth_accounts.remove_account(
          config.home,
          runtime.logins(host),
          id,
          runtime.key_environment(host),
        )
        |> result.map_error(http_api.native_failure),
      )
      Ok(
        response.new(204)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
        |> response.set_header("cache-control", "no-store"),
      )
    }
    _ -> Error(sdk_http_api.invalid("method not allowed"))
  }
  http_api.answer(outcome)
}

fn resolve_global_capabilities(
  home: String,
  host: runtime.Runtime,
  submitted: Dynamic,
) -> Result(Dict(String, Dict(String, Option(Bool))), String) {
  let decoder = {
    use id <- decode.field("catalog_session_id", decode.string)
    use revision <- decode.field("catalog_revision", decode.string)
    use choices <- decode.field(
      "choices",
      decode.dict(decode.string, decode.optional(decode.bool)),
    )
    decode.success(#(id, revision, choices))
  }
  use #(id, revision, choices) <- result.try(
    decode.run(submitted, decoder)
    |> result.replace_error("invalid capability choices"),
  )
  use catalog <- result.try(
    session_catalog.inspect(home, runtime.inventory(host), id)
    |> result.map_error(session_catalog.failure_text),
  )
  use _ <- result.try(case catalog.revision == revision {
    True -> Ok(Nil)
    False -> Error("catalog changed; refresh before changing a capability")
  })
  use resolved <- result.try(
    list.try_map(dict.to_list(choices), fn(choice) {
      use candidate <- result.try(
        list.find(catalog.candidates, fn(candidate) { candidate.id == choice.0 })
        |> result.replace_error("candidate was not found"),
      )
      use key <- result.try(option.to_result(
        candidate.preference_key,
        "candidate has no preference key",
      ))
      use kind <- result.try(case candidate.kind {
        capability_catalog.Skill -> Ok("skills")
        capability_catalog.Instruction -> Ok("instructions")
        capability_catalog.Mcp -> Ok("mcp")
        _ -> Error("extension defaults belong to the extensions settings group")
      })
      use _ <- result.try(case choice.1 {
        Some(True) ->
          case candidate.valid && candidate.shadowed_by == None {
            True -> Ok(Nil)
            False -> Error("candidate is invalid or shadowed")
          }
        _ -> Ok(Nil)
      })
      Ok(#(kind, key, choice.1))
    }),
  )
  Ok(
    dict.from_list(
      list.map(["skills", "instructions", "mcp"], fn(kind) {
        #(
          kind,
          dict.from_list(
            list.filter_map(resolved, fn(change) {
              case change.0 == kind {
                True -> Ok(#(change.1, change.2))
                False -> Error(Nil)
              }
            }),
          ),
        )
      }),
    ),
  )
}
