//// Session listing and its bounded invalidation subscription.

import albedo/clock
import albedo/daemon/bus
import albedo/daemon/http_api
import albedo/daemon/http_session_resource
import albedo/daemon/http_stream
import albedo/daemon/http_wire
import albedo/daemon/moves
import albedo/daemon/registry.{type Config, type Message}
import albedo/daemon/session
import albedo/daemon/session_collection
import albedo/daemon/session_cost
import albedo/daemon/usage
import albedo/harness/runtime
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist

fn collection_filter(
  config: Config,
  host: runtime.Runtime,
  parameters: List(#(String, String)),
) -> Result(session_collection.Filter, http_api.Failure) {
  let value = fn(name) { list.key_find(parameters, name) |> option.from_result }
  let parent = value("parent_id")
  let family = value("family_id")
  let scope =
    option.unwrap(value("scope"), case parent != None || family != None {
      True -> "all"
      False -> "roots"
    })
  let sort = option.unwrap(value("sort"), "activity")
  use _ <- result.try(
    case
      parent != None
      && family != None
      || !list.contains(["roots", "all"], scope)
      || scope == "roots"
      && { parent != None || family != None }
      || !list.contains(["activity", "frequent"], sort)
    {
      True ->
        Error(http_api.invalid(
          "choose roots/all, one parent or family filter, and an activity/frequent sort",
        ))
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(
    list.try_each(parameters, fn(parameter) {
      let maximum = case parameter.0 {
        "search" -> 256
        "workspace" -> 4096
        _ -> 16_384
      }
      case http_api.scalar_prefix(parameter.1, maximum) == parameter.1 {
        True -> Ok(Nil)
        False -> Error(http_api.invalid(parameter.0 <> " is too long"))
      }
    }),
  )
  use archived <- result.try(http_api.boolean_parameter(parameters, "archived"))
  use acp <- result.try(http_api.boolean_parameter(parameters, "acp"))
  use needs_reload <- result.try(http_api.boolean_parameter(
    parameters,
    "needs_reload",
  ))
  use pending <- result.try(case needs_reload {
    None -> Ok([])
    Some(_) ->
      runtime.needs_reload(host, config.home)
      |> result.map_error(http_api.failure)
  })
  Ok(
    session_collection.Filter(
      scope == "roots",
      parent,
      family,
      value("workspace"),
      value("search"),
      archived,
      acp,
      sort == "frequent",
      case needs_reload {
        Some(True) -> Some(pending)
        _ -> None
      },
      case needs_reload {
        Some(False) -> pending
        _ -> []
      },
    ),
  )
}

fn collection_key() -> decode.Decoder(session_collection.Key) {
  use opens <- decode.field("opens", decode.int)
  use activity <- decode.field("activity", decode.int)
  use id <- decode.field("id", decode.string)
  decode.success(session_collection.Key(opens, activity, id))
}

pub fn read(
  config: Config,
  registry: Subject(Message),
  req: request.Request(BitArray),
  live: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let outcome = {
    use parameters <- result.try(
      http_api.parameters(req, [
        "scope",
        "parent_id",
        "family_id",
        "workspace",
        "search",
        "archived",
        "acp",
        "needs_reload",
        "sort",
        "limit",
        "next",
      ]),
    )
    use watching <- result.try(http_api.wants_events(req))
    use _ <- result.try(
      case
        watching
        && list.any(parameters, fn(parameter) {
          list.contains(["sort", "limit", "next"], parameter.0)
        })
      {
        True ->
          Error(http_api.invalid(
            "collection watch accepts scope filters without sort or pagination",
          ))
        False -> Ok(Nil)
      },
    )
    use host <- result.try(
      registry.host(registry) |> result.map_error(http_api.failure),
    )
    use filter <- result.try(collection_filter(config, host, parameters))
    case watching {
      True -> {
        use _ <- result.try(
          session_collection.page(runtime.ledger(host), filter, None, 1)
          |> result.map_error(http_api.failure),
        )
        use _ <- result.try(http_stream.configure(live.body))
        let coded = http_stream.coded(live)
        Ok(mist.chunked(
          live,
          http_stream.response(live, coded),
          fn(subject) {
            process.send(subject, StreamWake)
            let _ = clock.send_after(subject, 5000, StreamTick)
            CollectionStream(
              None,
              fn() {
                open(config, host, parameters, fn() {
                  process.send(subject, StreamWake)
                })
              },
              subject,
              http_stream.writer(live, coded),
              True,
            )
          },
          collection_stream_loop,
        ))
      }
      False -> {
        use limit <- result.try(http_api.limit_parameter(parameters, 50))
        let binding = http_api.page_binding(req, parameters)
        use cursor <- result.try(case list.key_find(parameters, "next") {
          Error(_) -> Ok(None)
          Ok(token) -> {
            use state <- result.try(
              http_api.page_state(config.token, binding, token)
              |> result.map_error(fn(_) {
                http_api.invalid(
                  "session continuation does not belong to this query",
                )
              }),
            )
            json.parse(state, collection_key())
            |> result.map(Some)
            |> result.map_error(fn(_) {
              http_api.invalid("invalid session continuation")
            })
          }
        })
        use page <- result.try(
          session_collection.page(runtime.ledger(host), filter, cursor, limit)
          |> result.map_error(http_api.failure),
        )
        let cost =
          session_cost.totals(
            runtime.ledger(host),
            list.map(page.items, fn(durable) { durable.info.id }),
          )
        use items <- result.try(
          list.try_map(page.items, fn(durable) {
            use live <- result.try(
              registry.existing(registry, durable.info.id)
              |> result.map_error(http_api.failure),
            )
            use live <- result.try(case live {
              None -> Ok(None)
              Some(worker) ->
                case session.summary(worker) {
                  Ok(summary) -> Ok(Some(summary))
                  Error(reason) ->
                    // An unloading session can stop after the lookup.
                    case session.alive(worker) {
                      True -> Error(http_api.failure(reason))
                      False -> Ok(None)
                    }
                }
            })
            Ok(http_wire.summary(
              durable,
              live,
              usage.now(),
              list.append(
                http_session_resource.acp_field(
                  runtime.ledger(host),
                  durable.info.id,
                ),
                [
                  #(
                    "session_cost_usd",
                    json.nullable(cost(durable.info.id), json.float),
                  ),
                  ..moves.moved_field(runtime.ledger(host), durable.info.id)
                ],
              ),
            ))
          }),
        )
        let next =
          json.nullable(page.next, fn(key) {
            json.string(http_api.page_token(
              config.token,
              binding,
              json.to_string(
                json.object([
                  #("opens", json.int(key.opens)),
                  #("activity", json.int(key.activity)),
                  #("id", json.string(key.id)),
                ]),
              ),
            ))
          })
        let family = case page.family {
          None -> []
          Some(family) -> [
            #(
              "family",
              json.object([
                #("root_id", json.string(family.root_id)),
                #(
                  "revision",
                  json.string(
                    "family-"
                    <> family.root_id
                    <> "-"
                    <> int.to_string(family.revision),
                  ),
                ),
              ]),
            ),
          ]
        }
        Ok(http_api.reply(
          200,
          json.object([
            #("items", json.array(items, fn(value) { value })),
            #("next", next),
            ..family
          ]),
        ))
      }
    }
  }
  http_api.answer(outcome)
}

type StreamMessage {
  StreamWake
  StreamTick
}

type CollectionStream {
  CollectionStream(
    /// None until the first message: opening reads every session in scope,
    /// which can outlast the second mist gives a chunked response to start.
    follow: Option(Result(Follow, http_api.Failure)),
    open: fn() -> Result(Follow, http_api.Failure),
    subject: Subject(StreamMessage),
    writer: http_stream.Writer,
    initial: Bool,
  )
}

pub fn overflow_batch() -> String {
  json.object([
    #(
      "events",
      json.array(
        [
          json.object([
            #("type", json.string("overflow")),
            #("data", json.object([])),
          ]),
        ],
        fn(value) { value },
      ),
    ),
  ])
  |> json.to_string
}

fn collection_overflow(writer: http_stream.Writer) -> mist.ChunkNext(a) {
  let _ = http_stream.send(writer, overflow_batch())
  http_stream.close(writer)
  mist.ChunkStop
}

/// A collection subscription owned by the process that opens it.
pub opaque type Follow {
  Follow(
    config: Config,
    host: runtime.Runtime,
    parameters: List(#(String, String)),
    subscription: bus.Subscription,
  )
}

pub fn open(
  config: Config,
  host: runtime.Runtime,
  parameters: List(#(String, String)),
  notify: fn() -> Nil,
) -> Result(Follow, http_api.Failure) {
  let subscription = bus.subscribe_filtered(process.self(), notify, [])
  let follow = Follow(config, host, parameters, subscription)
  case refresh(follow) {
    Ok(_) -> Ok(follow)
    Error(reason) -> {
      close(follow)
      Error(reason)
    }
  }
}

fn refresh(follow: Follow) -> Result(Nil, http_api.Failure) {
  let revision = bus.filter_revision(follow.subscription)
  use filter <- result.try(collection_filter(
    follow.config,
    follow.host,
    follow.parameters,
  ))
  use ids <- result.try(
    session_collection.ids(runtime.ledger(follow.host), filter)
    |> result.map_error(http_api.failure),
  )
  bus.set_filter(follow.subscription, revision, ids)
  Ok(Nil)
}

/// Return the initial batch or queued events; an empty drain returns None.
pub fn next(
  follow: Follow,
  initial: Bool,
) -> Result(Option(String), http_api.Failure) {
  let batch = case initial {
    True ->
      Ok(Some(
        json.object([
          #(
            "events",
            json.array(
              [
                json.object([
                  #("type", json.string("ready")),
                  #("data", json.object([])),
                ]),
                json.object([
                  #("type", json.string("reset")),
                  #("data", json.object([#("reason", json.string("initial"))])),
                ]),
              ],
              fn(value) { value },
            ),
          ),
        ])
        |> json.to_string,
      ))
    False ->
      case bus.drain(follow.subscription) {
        bus.Overflow -> Error(http_api.failure("collection_overflow"))
        bus.Batch(encoded, invalidated) -> {
          use _ <- result.try(case invalidated {
            True -> refresh(follow)
            False -> Ok(Nil)
          })
          // Bus events are already encoded; the batch only joins them.
          Ok(case encoded {
            [] -> None
            _ -> Some("{\"events\":[" <> string.join(encoded, ",") <> "]}")
          })
        }
      }
  }
  use batch <- result.try(batch)
  case
    string.byte_size(option.unwrap(batch, "")) <= http_api.response_limit - 1024
  {
    True -> Ok(batch)
    False -> Error(http_api.failure("collection_overflow"))
  }
}

pub fn ack(follow: Follow, wake_consumed: Bool) -> Nil {
  bus.rearm(follow.subscription, wake_consumed)
}

pub fn close(follow: Follow) -> Nil {
  bus.unsubscribe(follow.subscription)
}

fn collection_stream_loop(
  state: CollectionStream,
  message: StreamMessage,
  _connection: mist.Connection,
) -> mist.ChunkNext(CollectionStream) {
  let opened = option.lazy_unwrap(state.follow, state.open)
  let state = CollectionStream(..state, follow: Some(opened))
  let batch = {
    use follow <- result.try(opened)
    next(follow, state.initial)
  }
  case batch {
    Error(_) -> {
      let _ = result.map(opened, close)
      collection_overflow(state.writer)
    }
    Ok(batch) -> {
      let sent = case batch, message {
        Some(encoded), _ -> http_stream.send(state.writer, encoded)
        None, StreamWake -> Ok(Nil)
        None, StreamTick -> http_stream.keepalive(state.writer)
      }
      case sent {
        Error(_) -> {
          let _ = result.map(opened, close)
          mist.ChunkStop
        }
        Ok(_) -> {
          case state.initial {
            True -> process.send(state.subject, StreamWake)
            False -> {
              let _ = result.map(opened, ack(_, message == StreamWake))
              case message {
                StreamWake -> Nil
                StreamTick -> {
                  let _ = clock.send_after(state.subject, 5000, StreamTick)
                  Nil
                }
              }
            }
          }
          mist.ChunkContinue(CollectionStream(..state, initial: False))
        }
      }
    }
  }
}
