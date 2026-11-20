//// Daemon catalogs, workspace browsing, host observations, storage reports,
//// and usage totals.

import albedo/composition/selection
import albedo/http/http_api
import albedo/http/http_wire
import albedo/refusal
import albedo/runtime
import albedo/session/registry.{type Config, type Message}
import albedo/session/session_lookup
import albedo/session/session_provider
import albedo/storage/storage_report
import albedo/usage/usage
import albedo/usage/usage_hours
import albedo/usage/usage_profile
import albedo/workspace/changes
import albedo/workspace/folders
import albedo/workspace/hosts
import albedo/workspace/ssh
import albedo_clock
import albedo_model as types
import albedo_process/within
import albedo_sdk/cache_ttl
import albedo_sdk/extension
import albedo_sdk/http_api as sdk_http_api
import albedo_sdk/location
import albedo_sdk/profiles as configuration
import albedo_sdk/storage
import albedo_web/etag
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/uri
import mist

pub fn hosts(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["target", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    use sessions <- result.try(
      registry.list(registry) |> result.map_error(refusal.unavailable),
    )
    let targets = case list.key_find(parameters, "target") {
      Ok(target) -> [target]
      Error(_) -> hosts.targets(sessions)
    }
    let revision = etag.strong(json.to_string(json.array(targets, json.string)))
    use offset <- result.try(http_api.page_offset(
      config.token,
      req,
      parameters,
      revision,
      0,
    ))
    let shown = list.drop(targets, offset) |> list.take(limit)
    let next = case offset + list.length(shown) < list.length(targets) {
      True ->
        http_api.continuation(
          config.token,
          req,
          parameters,
          revision,
          offset + list.length(shown),
        )
      False -> json.null()
    }
    Ok(sdk_http_api.reply(
      200,
      json.object([
        #(
          "items",
          json.array(shown, fn(target) {
            sdk_http_api.host(ssh.observe(target, False))
          }),
        ),
        #("next", next),
      ]),
    ))
  }
  http_api.answer(outcome)
}

/// `GET /usage`: what the provider calls used over the last `days` days (7 by
/// default, at most 90), a day being the client's own: `utc_offset_minutes` is
/// how far ahead of UTC its clock runs. `days` has one total for each, `lines`
/// one for each profile, account and model over the whole window, and `scopes`
/// every provider and account the window saw, which is what `provider` and
/// `account` choose from. `provider` narrows the days and lines to one
/// provider's rows, and `account` to one account of it; neither narrows
/// `scopes`, so a client still learns what it could show. An empty `account` is
/// a provider without an account pool, and an account needs the provider it
/// belongs to.
pub fn usage_summary(
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, [
        "days",
        "utc_offset_minutes",
        "provider",
        "account",
      ]),
    )
    use days <- result.try(sdk_http_api.integer_parameter(
      parameters,
      "days",
      7,
      // A year of whole weeks, enough for the profile's calendar.
      371,
    ))
    use _ <- result.try(case days > 0 {
      True -> Ok(Nil)
      False ->
        Error(sdk_http_api.invalid("query integer is outside its allowed range"))
    })
    use offset <- result.try(utc_offset(parameters))
    use filter <- result.try(usage_filter(parameters))
    use host <- result.try(
      registry.host(registry) |> result.map_error(refusal.failure),
    )
    let now = albedo_clock.system_ms()
    use summary <- result.try(
      usage_hours.summary(
        runtime.ledger(host),
        now,
        days,
        offset * 60_000,
        filter,
      )
      |> result.map_error(refusal.unavailable),
    )
    use profile <- result.try(
      usage_profile.read(runtime.ledger(host), now, offset * 60_000)
      |> result.map_error(refusal.unavailable),
    )
    Ok(sdk_http_api.reply(
      200,
      json.object([
        #("generated_at", json.string(albedo_clock.format_rfc3339(now))),
        #("utc_offset_minutes", json.int(offset)),
        #("days", json.array(summary.days, http_wire.usage_day)),
        #("lines", json.array(summary.lines, http_wire.usage_line)),
        #("scopes", json.array(summary.scopes, http_wire.usage_scope)),
        #("lines_truncated", json.bool(summary.lines_truncated)),
        #("scopes_truncated", json.bool(summary.scopes_truncated)),
        #("profile", usage_profile.to_json(profile)),
      ]),
    ))
  }
  http_api.answer(outcome)
}

/// What `GET /usage` was asked to count: one provider's rows, and one account of
/// them when `account` is given. An empty account is a provider without an
/// account pool, and an account with no provider to belong to is a mistake,
/// because two providers can label accounts the same way.
fn usage_filter(
  parameters: List(#(String, String)),
) -> Result(usage_hours.Filter, sdk_http_api.Failure) {
  case list.key_find(parameters, "provider") {
    Ok("") -> Error(sdk_http_api.invalid("provider must not be empty"))
    Ok(provider) ->
      Ok(usage_hours.OfProvider(
        provider,
        list.key_find(parameters, "account") |> option.from_result,
      ))
    Error(_) ->
      case list.key_find(parameters, "account") {
        Ok(_) ->
          Error(sdk_http_api.invalid("account needs the provider it belongs to"))
        Error(_) -> Ok(usage_hours.AllScopes)
      }
  }
}

fn utc_offset(
  parameters: List(#(String, String)),
) -> Result(Int, sdk_http_api.Failure) {
  case list.key_find(parameters, "utc_offset_minutes") {
    Error(_) -> Ok(0)
    Ok(value) ->
      case int.parse(value) {
        Ok(minutes) if minutes >= -720 && minutes <= 840 -> Ok(minutes)
        _ ->
          Error(sdk_http_api.invalid(
            "utc_offset_minutes must be between -720 and 840",
          ))
      }
  }
}

/// `target` is the raw path segment: a bracketed IPv6 host arrives
/// percent-encoded (`%5B::1%5D`), so it is decoded before it is parsed.
pub fn probe(
  target: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use _ <- result.try(http_api.json_parameters(req, []))
    use _ <- result.try(sdk_http_api.empty_body(req))
    use target <- result.try(
      uri.percent_decode(target)
      |> result.replace_error(sdk_http_api.invalid(
        "host is not validly encoded",
      )),
    )
    use _ <- result.try(
      location.parse(target <> ":/")
      |> result.replace(Nil)
      |> result.map_error(sdk_http_api.invalid),
    )
    Ok(sdk_http_api.reply(202, sdk_http_api.host(ssh.observe(target, True))))
  }
  http_api.answer(outcome)
}

/// Longer than the ssh round trip a remote workspace already bounds itself
/// with, so it only ends a local read stuck in the system call.
const folder_read_ms = 30_000

/// A folder read that does not finish is a refused request: a hung mount or a
/// disk under pressure holds the system call, and the request would hold with it.
fn folder_read(
  read: fn() -> Result(a, e),
  refuse: fn(e) -> sdk_http_api.Failure,
) -> Result(a, sdk_http_api.Failure) {
  case within.run(folder_read_ms, read) {
    Ok(found) -> result.map_error(found, refuse)
    Error(Nil) ->
      Error(sdk_http_api.Failure(
        503,
        "workspace_unavailable",
        "the folder did not answer in time",
      ))
  }
}

fn folder_failure(failure: folders.Failure) -> sdk_http_api.Failure {
  let detail =
    json.parse(
      json.to_string(failure.1),
      decode.field("error", decode.string, decode.success),
    )
    |> result.unwrap("workspace is unavailable")
  sdk_http_api.Failure(failure.0, "workspace_unavailable", detail)
}

pub fn workspaces(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["location", "include", "limit", "next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    case list.key_find(parameters, "location") {
      Error(_) -> {
        use _ <- result.try(case list.key_find(parameters, "include") {
          Error(_) -> Ok(Nil)
          _ -> Error(sdk_http_api.invalid("include requires location"))
        })
        use sessions <- result.try(
          registry.list(registry) |> result.map_error(refusal.unavailable),
        )
        let workspaces =
          list.fold(sessions, dict.new(), fn(workspaces, info) {
            dict.upsert(workspaces, info.cwd, fn(prior) {
              case prior {
                None -> #(1, info.last_assistant_at)
                Some(#(count, at)) -> #(
                  count + 1,
                  case at, info.last_assistant_at {
                    Some(old), Some(next) -> Some(int.max(old, next))
                    None, next -> next
                    old, _ -> old
                  },
                )
              }
            })
          })
          |> dict.to_list
          |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        let revision = etag.strong(string.inspect(workspaces))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(workspaces, offset) |> list.take(limit)
        let next = case offset + list.length(shown) < list.length(workspaces) {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        Ok(sdk_http_api.reply(
          200,
          json.object([
            #(
              "items",
              json.array(shown, fn(entry) {
                json.object([
                  #("location", json.string(entry.0)),
                  #("use_count", json.int(entry.1.0)),
                  #(
                    "activity_at",
                    json.nullable(entry.1.1, fn(seconds) {
                      http_wire.timestamp(seconds * 1000)
                    }),
                  ),
                ])
              }),
            ),
            #("next", next),
          ]),
        ))
      }
      Ok(at) -> {
        use #(preview, files) <- result.try(
          workspace_include(list.key_find(parameters, "include")),
        )
        use directory <- result.try(folder_read(
          fn() { folders.directory(at, files) },
          folder_failure,
        ))
        let revision = etag.strong(string.inspect(directory))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(directory.items, offset) |> list.take(limit)
        let next = case
          offset + list.length(shown) < list.length(directory.items)
        {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        let host =
          location.parse(directory.location)
          |> result.map(location.ssh_target)
          |> result.unwrap(Error(Nil))
          |> option.from_result
        let fields = [
          #("directory", json.string(directory.location)),
          #("parent", json.nullable(directory.parent, json.string)),
          #("home", json.string(directory.home)),
          #(
            "host",
            json.nullable(host, fn(target) {
              sdk_http_api.host(ssh.observe(target, False))
            }),
          ),
          #(
            "items",
            json.array(shown, fn(item) {
              let listed = case files {
                False -> []
                True -> [
                  #(
                    "kind",
                    json.string(case item.file {
                      True -> "file"
                      False -> "directory"
                    }),
                  ),
                  #("size", case item.file {
                    True -> json.int(item.size)
                    False -> json.null()
                  }),
                  #("ignored", json.nullable(item.ignored, json.bool)),
                ]
              }
              json.object([
                #("name", json.string(item.name)),
                #("location", json.string(item.location)),
                #("vcs", json.nullable(item.vcs, json.string)),
                #("modified_at", http_wire.timestamp(item.modified * 1000)),
                #("hidden", json.bool(item.hidden)),
                ..listed
              ])
            }),
          ),
          #("next", next),
        ]
        use fields <- result.try(case preview {
          False -> Ok(fields)
          True ->
            folder_read(
              fn() { folders.observe_preview(directory.location) },
              folder_failure,
            )
            |> result.map(fn(preview) {
              [
                #(
                  "preview",
                  http_wire.workspace_preview(preview, directory.location),
                ),
                ..fields
              ]
            })
        })
        Ok(sdk_http_api.reply(200, json.object(fields)))
      }
    }
  }
  http_api.answer(outcome)
}

/// Whether `include` asks for the preview and for files: `preview`,
/// `files`, or both comma-separated.
fn workspace_include(
  include: Result(String, Nil),
) -> Result(#(Bool, Bool), sdk_http_api.Failure) {
  case include {
    Error(Nil) -> Ok(#(False, False))
    Ok(include) ->
      string.split(include, ",")
      |> list.try_fold(#(False, False), fn(wanted, part) {
        case part {
          "preview" -> Ok(#(True, wanted.1))
          "files" -> Ok(#(wanted.0, True))
          _ -> Error(sdk_http_api.invalid("unknown workspace include"))
        }
      })
  }
}

/// A session checkout's changes against a base, read on the machine the
/// workspace is on. The ETag hashes the answer, so a client polling with
/// `If-None-Match` gets 304 while nothing changed.
pub fn changes(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(http_api.json_parameters(req, ["base"]))
    use base <- result.try(case list.key_find(parameters, "base") {
      Error(Nil) | Ok("uncommitted") -> Ok(changes.Uncommitted)
      Ok("upstream") -> Ok(changes.Upstream)
      Ok(_) ->
        Error(sdk_http_api.invalid("base must be uncommitted or upstream"))
    })
    use host <- result.try(
      registry.host(registry) |> result.map_error(refusal.failure),
    )
    use info <- result.try(
      session_lookup.info(storage.host(runtime.ledger(host)), id)
      |> result.map_error(refusal.failure),
    )
    use workspace <- result.try(
      location.parse(info.cwd)
      |> result.map_error(fn(why) {
        sdk_http_api.Failure(503, "workspace_unavailable", why)
      }),
    )
    use found <- result.try(
      changes.read(workspace, base) |> result.map_error(changes_failure),
    )
    let body = fitted(found)
    let encoded = json.to_string(body)
    let etag = etag.strong(encoded)
    Ok(
      case request.get_header(req, "if-none-match") == Ok(etag) {
        True ->
          response.new(304)
          |> response.set_header("cache-control", "no-store")
          |> response.set_body(mist.Bytes(bytes_tree.new()))
        False -> sdk_http_api.raw(200, encoded)
      }
      |> response.set_header("etag", etag),
    )
  }
  http_api.answer(outcome)
}

/// The answer's JSON, with the diff budget cut further when paths and
/// escaping would carry it past the response limit.
fn fitted(found: changes.Changes) -> json.Json {
  let body = changes_json(found)
  let over = sdk_http_api.encoded_size(body) - sdk_http_api.response_limit
  case over > 0 {
    False -> body
    True -> {
      let spent = changes.spend(found, changes.budget - over - 65_536)
      changes_json(spent)
    }
  }
}

fn changes_json(found: changes.Changes) -> json.Json {
  json.object([
    #(
      "checkout",
      json.object([
        #("kind", json.string(found.kind)),
        #("root", json.string(found.root)),
        #("head", json.nullable(found.head, json.string)),
        #("branch", json.nullable(found.branch, json.string)),
      ]),
    ),
    #(
      "base",
      json.object([
        #(
          "spec",
          json.string(case found.base {
            changes.Uncommitted -> "uncommitted"
            changes.Upstream -> "upstream"
          }),
        ),
        #("label", json.string(found.label)),
        #("commit", json.nullable(found.commit, json.string)),
      ]),
    ),
    #(
      "files",
      json.array(found.files, fn(file) {
        json.object([
          #("path", json.string(file.path)),
          #("old_path", json.nullable(file.old_path, json.string)),
          #(
            "status",
            json.string(case file.status {
              changes.Modified -> "modified"
              changes.Added -> "added"
              changes.Deleted -> "deleted"
              changes.Renamed -> "renamed"
              changes.Untracked -> "untracked"
            }),
          ),
          #("added", json.int(file.added)),
          #("removed", json.int(file.removed)),
          #("binary", json.bool(file.binary)),
          #("diff", case file.diff {
            Ok(diff) -> json.string(diff)
            Error(_) -> json.null()
          }),
          #("omitted", case file.diff {
            Ok(_) -> json.null()
            Error(changes.Binary) -> json.string("binary")
            Error(changes.TooLarge) -> json.string("too_large")
            Error(changes.OverBudget) -> json.string("budget")
          }),
        ])
      }),
    ),
    #("truncated", json.bool(found.truncated)),
  ])
}

fn changes_failure(failure: changes.Failure) -> sdk_http_api.Failure {
  case failure {
    changes.NotARepository(detail) ->
      sdk_http_api.Failure(409, "not_a_repository", detail)
    changes.NoUpstream(detail) ->
      sdk_http_api.Failure(409, "no_upstream", detail)
    changes.TimedOut(detail) -> sdk_http_api.Failure(504, "vcs_timeout", detail)
    changes.CommandFailed(detail) ->
      sdk_http_api.Failure(502, "vcs_failed", detail)
    changes.Unavailable(failure) -> folder_failure(failure)
  }
}

/// A UTF-8 text file in a session's workspace, read on the machine the
/// workspace is on.
pub fn file(
  registry: Subject(Message),
  id: String,
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(http_api.json_parameters(req, ["path"]))
    use path <- result.try(
      list.key_find(parameters, "path")
      |> result.replace_error(sdk_http_api.invalid("path is required")),
    )
    use host <- result.try(
      registry.host(registry) |> result.map_error(refusal.failure),
    )
    use info <- result.try(
      session_lookup.info(storage.host(runtime.ledger(host)), id)
      |> result.map_error(refusal.failure),
    )
    use workspace <- result.try(
      location.parse(info.cwd)
      |> result.map_error(fn(why) {
        sdk_http_api.Failure(503, "workspace_unavailable", why)
      }),
    )
    use file <- result.try(folder_read(
      fn() { folders.read_file(workspace, path) },
      file_failure,
    ))
    let body =
      json.object([
        #("path", json.string(file.location)),
        #("size", json.int(file.size)),
        #("modified_at", http_wire.timestamp(file.modified * 1000)),
        #("text", json.string(file.text)),
      ])
    // Escaping can carry a file within the read limit past the response one.
    case sdk_http_api.encoded_size(body) > sdk_http_api.response_limit {
      True ->
        Error(sdk_http_api.Failure(
          413,
          "file_too_large",
          file.location <> " is too large to answer as JSON",
        ))
      False -> Ok(sdk_http_api.reply(200, body))
    }
  }
  http_api.answer(outcome)
}

fn file_failure(failure: folders.FileFailure) -> sdk_http_api.Failure {
  case failure {
    folders.BadPath(detail) -> sdk_http_api.invalid(detail)
    folders.NotAFile(location, why) ->
      sdk_http_api.Failure(404, "file_not_found", location <> " " <> why)
    folders.TooLarge(location, size) ->
      sdk_http_api.Failure(
        413,
        "file_too_large",
        location
          <> " is "
          <> int.to_string(size)
          <> " bytes, over the "
          <> int.to_string(folders.file_limit)
          <> " byte limit",
      )
    folders.NotText(location) ->
      sdk_http_api.Failure(
        415,
        "file_not_text",
        location <> " is not UTF-8 text",
      )
    folders.FileUnavailable(failure) -> folder_failure(failure)
  }
}

pub fn models(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, [
        "view",
        "extension",
        "host",
        "model",
        "provider_profile",
        "session",
        "initial",
        "provider",
        "endpoint",
        "limit",
        "next",
      ]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    let view = list.key_find(parameters, "view") |> result.unwrap("catalogue")
    case view {
      "cache-policy" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(
                ["provider", "provider_profile", "endpoint"],
                pair.0,
              )
            })
          {
            True ->
              Error(sdk_http_api.invalid(
                "cache-policy does not accept provider parameters",
              ))
            False -> Ok(Nil)
          },
        )
        let table = cache_ttl.table()
        let revision = etag.strong(json.to_string(cache_ttl.table_json(table)))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(table.entries, offset) |> list.take(limit)
        let next = case
          offset + list.length(shown) < list.length(table.entries)
        {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        let matched =
          cache_ttl.lookup(
            list.key_find(parameters, "extension") |> result.unwrap(""),
            list.key_find(parameters, "host") |> result.unwrap(""),
            list.key_find(parameters, "model") |> result.unwrap(""),
          )
        Ok(sdk_http_api.reply(
          200,
          json.object([
            #("entries", json.array(shown, cache_ttl.entry_json)),
            #(
              "layers",
              json.array(table.layers, fn(layer) {
                json.object([
                  #("name", json.string(layer.name)),
                  #("path", json.string(layer.path)),
                  #("loaded", json.bool(layer.loaded)),
                  #(
                    "error",
                    json.nullable(layer.error, fn(detail) {
                      sdk_http_api.reason("cache_policy_layer_failed", detail)
                    }),
                  ),
                ])
              }),
            ),
            #("matched", json.nullable(matched, cache_ttl.entry_json)),
            #("next", next),
          ]),
        ))
      }
      "catalogue" -> {
        use _ <- result.try(
          case
            list.any(parameters, fn(pair) {
              list.contains(["extension", "host"], pair.0)
            })
          {
            True ->
              Error(sdk_http_api.invalid(
                "catalogue does not accept cache selectors",
              ))
            False -> Ok(Nil)
          },
        )
        use host <- result.try(
          registry.host(registry) |> result.map_error(refusal.failure),
        )
        use provider <- result.try(
          case
            list.key_find(parameters, "provider_profile"),
            list.key_find(parameters, "provider"),
            list.key_find(parameters, "endpoint")
          {
            Ok(profile), Error(_), Error(_) ->
              configuration.named(config.home, profile)
              |> result.map(fn(profile) {
                #(
                  profile.extension,
                  session_provider.profile_endpoint(config.home, profile.name),
                )
              })
              |> result.map_error(fn(why) {
                refusal.failure(refusal.ProviderUnconfigured(why))
              })
            Error(_), Ok(provider), endpoint ->
              Ok(#(provider, option.from_result(endpoint)))
            _, _, _ ->
              Error(sdk_http_api.invalid(
                "choose exactly one of provider_profile or provider; endpoint requires provider",
              ))
          },
        )
        let models = case list.key_find(parameters, "model") {
          Error(_) -> runtime.listed_models(host, provider.0, provider.1)
          Ok(id) -> {
            let info =
              extension.provider_model_info(
                runtime.global(host) |> result.unwrap([]),
                provider.0,
                id,
                provider.1,
              )
            [
              runtime.ListedModel(
                id,
                info,
                option.map(info, fn(info) { info.efforts }) |> option.unwrap([]),
              ),
            ]
          }
        }
        let profile =
          list.key_find(parameters, "provider_profile") |> option.from_result
        let models =
          list.map(models, fn(model) {
            let override =
              option.then(profile, fn(profile) {
                runtime.profile_effort_override(
                  host,
                  config.home,
                  profile,
                  model.id,
                )
              })
            case override {
              Some(efforts) -> runtime.ListedModel(..model, efforts: efforts)
              None -> model
            }
          })
        let session = list.key_find(parameters, "session") |> result.unwrap("")
        let initial = list.key_find(parameters, "initial") |> result.unwrap("")
        use _ <- result.try(case initial, session {
          "", "" -> Ok(Nil)
          "", id ->
            session_lookup.info(storage.host(runtime.ledger(host)), id)
            |> result.map(fn(_) { Nil })
            |> result.map_error(refusal.failure)
          "true", id if id != "" && profile != None ->
            case session_lookup.info(storage.host(runtime.ledger(host)), id) {
              Ok(_) ->
                Error(sdk_http_api.invalid(
                  "initial preview requires a new session ID",
                ))
              Error(refusal.SessionNotFound) -> Ok(Nil)
              Error(reason) -> Error(refusal.failure(reason))
            }
          _, _ ->
            Error(sdk_http_api.invalid(
              "initial=true requires session and provider_profile",
            ))
        })
        // Resolve the selected account/bearer once: legacy rows trigger at
        // most one unconditional refresh for this page, not one per model.
        let catalog = case profile, provider.0 {
          Some(profile_name), "codex" ->
            Some(runtime.cyber_catalog(
              host,
              session,
              config.home,
              profile_name,
              provider.0,
              types.Responses,
            ))
          _, _ -> None
        }
        let catalog =
          option.map(catalog, fn(snapshot) {
            result.map(snapshot, dict.from_list)
          })
        let blue =
          list.map(models, fn(model) {
            let access = case catalog {
              None -> None
              Some(Error(reason)) -> Some(Error(reason))
              Some(Ok(rows)) ->
                Some(case dict.get(rows, model.id) {
                  Error(_) -> Ok(False)
                  Ok(Some(available)) -> Ok(available)
                  Ok(None) ->
                    Error(
                      "ChatGPT account catalog does not advertise cyber-access metadata",
                    )
                })
            }
            #(model, access)
          })
        let encoded =
          json.array(blue, fn(pair) {
            model_json(pair.0, provider.0, provider.1, pair.1)
          })
        let revision = etag.strong(json.to_string(encoded))
        use offset <- result.try(http_api.page_offset(
          config.token,
          req,
          parameters,
          revision,
          0,
        ))
        let shown = list.drop(blue, offset) |> list.take(limit)
        let next = case offset + list.length(shown) < list.length(models) {
          True ->
            http_api.continuation(
              config.token,
              req,
              parameters,
              revision,
              offset + list.length(shown),
            )
          False -> json.null()
        }
        Ok(sdk_http_api.reply(
          200,
          json.object([
            #(
              "items",
              json.array(shown, fn(pair) {
                model_json(pair.0, provider.0, provider.1, pair.1)
              }),
            ),
            #("next", next),
          ]),
        ))
      }
      _ -> Error(sdk_http_api.invalid("unknown model view"))
    }
  }
  http_api.answer(outcome)
}

fn model_json(
  model: runtime.ListedModel,
  provider: String,
  endpoint: Option(String),
  access: Option(Result(Bool, String)),
) -> json.Json {
  let fact = fn(read) { option.then(model.info, read) }
  let host =
    option.then(endpoint, fn(endpoint) {
      uri.parse(endpoint)
      |> result.map(fn(uri) { uri.host })
      |> result.unwrap(None)
    })
    |> option.unwrap("")
  let policy = cache_ttl.lookup(provider, host, model.id)
  let ttl =
    option.then(policy, cache_ttl.clock_tier)
    |> option.map(fn(tier) { tier.seconds })
  let cyber = case access {
    Some(Ok(True)) -> json.object([#("status", json.string("supported"))])
    Some(Ok(False)) ->
      json.object([
        #("status", json.string("unsupported")),
        #(
          "detail",
          json.string("this account/model does not advertise Daybreak Blue"),
        ),
      ])
    Some(Error(reason)) ->
      json.object([
        #("status", json.string("unknown")),
        #("detail", json.string(reason)),
      ])
    None ->
      json.object([
        #("status", json.string("unsupported")),
        #(
          "detail",
          json.string(
            "select a Codex profile to inspect account-specific access",
          ),
        ),
      ])
  }
  json.object([
    #("cyber_access", cyber),
    #("id", json.string(model.id)),
    #(
      "label",
      json.string(
        option.then(model.info, fn(info) { info.display_name })
        |> option.map(string.trim)
        |> option.then(fn(name) {
          case name {
            "" -> None
            _ -> Some(name)
          }
        })
        |> option.unwrap(model.id),
      ),
    ),
    #(
      "default_effort_source",
      json.string(
        option.map(model.info, fn(info) { info.default_effort_source })
        |> option.unwrap("provider"),
      ),
    ),
    #(
      "default_effort",
      json.nullable(
        option.then(model.info, fn(info) { info.default_effort }),
        fn(effort) { json.string(types.effort_name(effort)) },
      ),
    ),
    #(
      "efforts",
      json.array(model.efforts, fn(effort) {
        let name = types.effort_name(effort)
        json.object([#("id", json.string(name)), #("label", json.string(name))])
      }),
    ),
    #(
      "default_context_tokens",
      json.nullable(fact(fn(info) { info.context_tokens }), json.int),
    ),
    #(
      "effective_context_tokens",
      json.nullable(fact(selection.window), json.int),
    ),
    #(
      "max_context_tokens",
      json.nullable(fact(fn(info) { info.max_context_tokens }), json.int),
    ),
    #(
      "max_output_tokens",
      json.nullable(fact(fn(info) { info.max_output_tokens }), json.int),
    ),
    #(
      "input_modalities",
      json.array(
        option.map(model.info, fn(info) { info.input_modalities })
          |> option.unwrap([]),
        json.string,
      ),
    ),
    #("image_edge", json.null()),
    #("raised", json.bool(list.contains(selection.raised_caps(), model.id))),
    #("compact_at", json.nullable(selection.compact_at(model.id), json.int)),
    #("cap_key", json.string(model.id)),
    #(
      "cache_policy",
      json.object([
        #("ttl_seconds", json.nullable(ttl, json.int)),
        #(
          "source",
          json.nullable(
            option.map(policy, fn(policy) { policy.source }),
            json.string,
          ),
        ),
      ]),
    ),
    #(
      "source",
      json.string(
        option.map(model.info, fn(info) { info.source })
        |> option.unwrap("unknown"),
      ),
    ),
    #("observed_at", json.null()),
  ])
}

pub fn storage(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.json_parameters(req, ["limit", "sessions_next", "files_next"]),
    )
    use limit <- result.try(http_api.limit_parameter(parameters, 50))
    use host <- result.try(
      registry.host(registry) |> result.map_error(refusal.failure),
    )
    use observed <- result.try(
      storage_report.observe(runtime.ledger(host), config.home)
      |> result.map_error(refusal.unavailable),
    )
    let base = list.filter(parameters, fn(pair) { pair.0 == "limit" })
    let session_parameters = case list.key_find(parameters, "sessions_next") {
      Ok(token) -> [#("next", token), ..base]
      Error(_) -> base
    }
    // Sessions come ordered by id, so a page resumes after the last id shown:
    // a session written, added or deleted meanwhile cannot void the token.
    use after <- result.try(http_api.page_cursor(
      config.token,
      req,
      session_parameters,
      "sessions",
    ))
    let db = observed.database
    let files = observed.files
    let rest = case after {
      None -> db.sessions
      Some(id) ->
        list.drop_while(db.sessions, fn(session) {
          string.compare(session.id, id) != order.Gt
        })
    }
    let shown = list.take(rest, limit)
    let next =
      sdk_http_api.next_page(
        config.token,
        http_api.page_binding(req, base) <> "sessions",
        list.length(rest) > limit,
        list.last(shown) |> result.map(fn(session) { session.id }),
      )
    let total =
      list.fold(db.sessions, 0, fn(sum, session) { sum + session.bytes })
    let file_items =
      list.map(files.old_kernels, fn(file) { #(file, "kernel", "old_kernel") })
      |> list.append(
        list.map(files.old_backups, fn(file) { #(file, "backup", "old_backup") }),
      )
    let file_revision = etag.strong(string.inspect(file_items))
    let file_parameters = case list.key_find(parameters, "files_next") {
      Ok(token) -> [#("next", token), ..base]
      Error(_) -> base
    }
    use file_offset <- result.try(http_api.page_offset(
      config.token,
      req,
      file_parameters,
      "files" <> file_revision,
      0,
    ))
    let file_shown = list.drop(file_items, file_offset) |> list.take(limit)
    let files_next = case
      file_offset + list.length(file_shown) < list.length(file_items)
    {
      True ->
        http_api.continuation(
          config.token,
          req,
          base,
          "files" <> file_revision,
          file_offset + list.length(file_shown),
        )
      False -> json.null()
    }
    Ok(sdk_http_api.reply(
      200,
      json.object([
        #(
          "database",
          json.object([
            #("main_file_bytes", json.int(files.database)),
            #("wal_bytes", json.int(files.wal)),
            #("page_size_bytes", json.int(db.page_size)),
            #("page_count", json.int(db.page_count)),
            #("free_page_count", json.int(db.free_pages)),
            #(
              "used_bytes",
              json.int({ db.page_count - db.free_pages } * db.page_size),
            ),
          ]),
        ),
        #(
          "sessions",
          json.object([
            #(
              "items",
              json.array(shown, fn(session) {
                json.object([
                  #("id", json.string(session.id)),
                  #("title", json.string(session.title)),
                  #("workspace", json.string(session.workspace)),
                  #(
                    "created_at",
                    json.nullable(session.created_at, http_wire.timestamp),
                  ),
                  #(
                    "activity_at",
                    json.nullable(session.activity_at, http_wire.timestamp),
                  ),
                  #("estimated_content_bytes", json.int(session.bytes)),
                ])
              }),
            ),
            #("next", next),
            #("total_count", json.int(list.length(db.sessions))),
            #("total_estimated_content_bytes", json.int(total)),
          ]),
        ),
        #(
          "images",
          json.object([
            #("count", json.int(db.image_count)),
            #("bytes", json.int(db.images)),
          ]),
        ),
        #(
          "files",
          json.object([
            #(
              "items",
              json.array(file_shown, fn(item) {
                json.object([
                  #("path", json.string(item.0.path)),
                  #("category", json.string(item.1)),
                  #("bytes", json.int(item.0.bytes)),
                  #("modified_at", json.null()),
                  #("cleanup_candidate", json.bool(True)),
                  #("cleanup_reason", json.string(item.2)),
                ])
              }),
            ),
            #("next", files_next),
            #(
              "totals",
              json.object([
                #("kernel_bytes", json.int(files.kernels)),
                #("backup_bytes", json.int(files.backups)),
                #("other_bytes", json.int(files.other)),
                #("shell_output_bytes", json.int(files.shell_output)),
                #("recent_backup_bytes", json.int(files.recent_backups)),
                #("recent_backup_count", json.int(files.recent_backup_count)),
              ]),
            ),
          ]),
        ),
        #("measured_at", http_wire.timestamp(usage.now())),
      ]),
    ))
  }
  http_api.answer(outcome)
}
