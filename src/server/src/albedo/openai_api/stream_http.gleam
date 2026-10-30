//// The streaming HTTP pump every provider wire shares: open the exchange, read
//// its headers, feed body frames to a reducer, and settle a turn only once the
//// response is complete.
////
//// A wire supplies only what makes it different: how a chunk becomes frames,
//// what payload a frame carries, when a body is its stream, and whether its
//// reducer may settle a turn before the body ends.

import albedo/clock
import albedo/openai_api/stream
import albedo/openai_api/transport
import albedo/openai_api/types
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string_tree.{type StringTree}

const max_error_bytes = 65_536

/// One exchange as the pump needs it: where the request goes and the budgets
/// it runs under. A wire converts its own exchange to this.
pub type Exchange {
  Exchange(
    url: String,
    headers: List(#(String, String)),
    body: StringTree,
    timeout_ms: Int,
    first_event_timeout_ms: Option(Int),
    max_event_bytes: Int,
  )
}

/// What a response whose body is not this wire's stream means.
pub type Body {
  /// Feed the body to the reducer as frames.
  Pump
  /// Read the body and report it as the HTTP error its status carries.
  HttpError
  /// Refuse with this message instead of reading the body.
  Refuse(String)
}

/// Whether a reducer may settle the turn before the body ends. A wire that
/// validates a whole document at EOF refuses an early turn instead.
pub type Settle {
  BeforeEnd
  OnlyAtEnd(String)
}

/// One wire's framing and its rules for a response.
pub type Wire(parser, frame) {
  Wire(
    /// The frame parser, given the exchange's event byte limit.
    start: fn(Int) -> parser,
    feed: fn(parser, BitArray) -> Result(#(parser, List(frame)), types.Error),
    /// Frames completed by a flush when the body ends.
    finish: fn(parser) -> Result(List(frame), types.Error),
    /// The reducer payload one frame carries.
    payload: fn(frame) -> Result(String, types.Error),
    body: fn(List(#(String, String))) -> Body,
    settle: Settle,
    /// Discard the socket after any error instead of pooling it.
    discard_on_error: Bool,
  )
}

pub fn exchange(
  exchange: Exchange,
  wire: Wire(parser, frame),
  reducer: stream.Reducer,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  exchange_with_status(exchange, wire, reducer, on_event, fn(status, _) {
    status
  })
}

pub fn exchange_with_status(
  exchange: Exchange,
  wire: Wire(parser, frame),
  reducer: stream.Reducer,
  on_event: fn(types.Event) -> types.Control,
  response_status: fn(Int, List(#(String, String))) -> Int,
) -> Result(types.Turn, types.Error) {
  let exchange = capped(exchange, transport.budget_cap())
  let sent = clock.monotonic_ms()
  let wait =
    Wait(
      exchange.timeout_ms,
      option.map(exchange.first_event_timeout_ms, fn(budget) {
        #(sent + budget, budget)
      }),
    )
  use connection <- result.try(
    transport.open(
      exchange.url,
      exchange.headers,
      exchange.body,
      exchange.timeout_ms,
    )
    |> result.map_error(transport_error(
      _,
      types.Connecting,
      exchange.timeout_ms,
    )),
  )
  use <- with_connection(connection, wire.discard_on_error)
  use first <- result.try(receive(connection, wait, types.AwaitingHeaders))
  case first {
    transport.Headers(status, headers, final) -> {
      let status = response_status(status, headers)
      use _ <- result.try(notify([types.Responded(status)], on_event))
      case status >= 200 && status < 300 {
        False -> http_error(connection, wait, status, final, [], 0)
        True ->
          case wire.body(headers) {
            HttpError -> http_error(connection, wait, status, final, [], 0)
            Refuse(message) -> Error(types.InvalidEvent(message))
            Pump ->
              case final {
                True -> Error(types.UnexpectedEnd)
                False ->
                  pump(
                    connection,
                    wait,
                    types.AwaitingFirstEvent,
                    wire.start(exchange.max_event_bytes),
                    wire,
                    reducer,
                    Thinking(0, sent, None),
                    on_event,
                  )
              }
          }
      }
    }
    _ -> Error(types.InvalidEvent("HTTP data arrived before headers"))
  }
}

fn pump(
  connection: transport.Connection,
  wait: Wait,
  phase: types.TimeoutPhase,
  parser: parser,
  wire: Wire(parser, frame),
  reducer: stream.Reducer,
  thinking: Thinking,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  use message <- result.try(receive(connection, wait, phase))
  case message {
    transport.Data(bytes, final) -> {
      let now = clock.monotonic_ms()
      use #(parser, frames) <- result.try(wire.feed(parser, bytes))
      let phase = case frames {
        [] -> phase
        _ -> types.Streaming
      }
      use #(reducer, thinking, done) <- result.try(deliver(
        wire,
        reducer,
        thinking,
        now,
        frames,
        on_event,
      ))
      case done, final {
        Some(turn), _ -> Ok(timed(turn, thinking, now))
        None, True -> {
          use frames <- result.try(wire.finish(parser))
          use #(reducer, thinking, done) <- result.try(deliver(
            wire,
            reducer,
            thinking,
            now,
            frames,
            on_event,
          ))
          case done {
            Some(turn) -> Ok(turn)
            None -> reducer.finish()
          }
          |> result.map(timed(_, thinking, now))
        }
        None, False ->
          pump(
            connection,
            wait,
            phase,
            parser,
            wire,
            reducer,
            thinking,
            on_event,
          )
      }
    }
    _ -> Error(types.InvalidEvent("unexpected HTTP headers inside stream"))
  }
}

fn deliver(
  wire: Wire(parser, frame),
  reducer: stream.Reducer,
  thinking: Thinking,
  now: Int,
  frames: List(frame),
  on_event: fn(types.Event) -> types.Control,
) -> Result(#(stream.Reducer, Thinking, Option(types.Turn)), types.Error) {
  case frames {
    [] -> Ok(#(reducer, thinking, None))
    [frame, ..rest] -> {
      use payload <- result.try(wire.payload(frame))
      use #(reducer, updates, turn) <- result.try(reducer.feed(payload))
      use _ <- result.try(settle(wire.settle, turn))
      use _ <- result.try(notify(updates, on_event))
      let thinking =
        list.fold(updates, thinking, fn(t, event) { think(t, event, now) })
      case turn {
        Some(_) -> Ok(#(reducer, thinking, turn))
        None -> deliver(wire, reducer, thinking, now, rest, on_event)
      }
    }
  }
}

fn settle(
  policy: Settle,
  turn: Option(types.Turn),
) -> Result(Nil, types.Error) {
  case policy, turn {
    BeforeEnd, _ -> Ok(Nil)
    OnlyAtEnd(message), Some(_) -> Error(types.InvalidEvent(message))
    OnlyAtEnd(_), None -> Ok(Nil)
  }
}

fn with_connection(
  connection: transport.Connection,
  discard_on_error: Bool,
  run: fn() -> value,
) -> value {
  case discard_on_error {
    True -> transport.with_connection_discard_errors(connection, run)
    False -> transport.with_connection(connection, run)
  }
}

/// `exchange` with every budget held to `cap` ms, when `cap` is positive.
fn capped(exchange: Exchange, cap: Int) -> Exchange {
  case cap > 0 {
    False -> exchange
    True ->
      Exchange(
        ..exchange,
        timeout_ms: int.min(exchange.timeout_ms, cap),
        first_event_timeout_ms: option.map(
          exchange.first_event_timeout_ms,
          int.min(_, cap),
        ),
      )
  }
}

/// Time spent thinking so far, when the last other event came (the request
/// itself, at first), and when the spell under way began.
type Thinking {
  Thinking(total: Int, last: Int, since: Option(Int))
}

/// A spell runs from the event before its first thinking delta to the next
/// other event: summarized thinking streams only once it is written, so the
/// thought began before its first delta did.
fn think(thinking: Thinking, event: types.Event, now: Int) -> Thinking {
  case event, thinking.since {
    types.ThinkingDelta(_), None ->
      Thinking(..thinking, since: Some(thinking.last))
    types.ThinkingDelta(_), Some(_) -> thinking
    _, Some(_) -> Thinking(elapsed(thinking, now), now, None)
    _, None -> Thinking(..thinking, last: now)
  }
}

/// A turn that ends while it is still thinking thought until its end.
fn timed(turn: types.Turn, thinking: Thinking, now: Int) -> types.Turn {
  case elapsed(thinking, now) {
    0 -> turn
    total -> types.Turn(..turn, thought_ms: Some(total))
  }
}

/// Thinking time so far, closing the spell under way if there is one.
fn elapsed(thinking: Thinking, now: Int) -> Int {
  case thinking.since {
    Some(since) -> thinking.total + now - since
    None -> thinking.total
  }
}

/// The budgets one exchange waits under; `first_event` is the deadline its
/// headers and first event must meet, and the budget that deadline came from.
type Wait {
  Wait(idle_ms: Int, first_event: Option(#(Int, Int)))
}

/// The next message, within what is left of the first-event deadline while
/// one runs, else within the idle budget until the first event. Once events
/// flow, a body chunk waits while the connection is alive.
fn receive(
  connection: transport.Connection,
  wait: Wait,
  phase: types.TimeoutPhase,
) -> Result(transport.Message, types.Error) {
  case wait.first_event, phase {
    Some(#(deadline, total)), types.AwaitingHeaders
    | Some(#(deadline, total)), types.AwaitingFirstEvent
    ->
      transport.receive_until(connection, deadline)
      |> result.map_error(transport_error(_, phase, total))
    _, types.Streaming ->
      transport.receive(connection)
      |> result.map_error(transport_error(_, phase, wait.idle_ms))
    _, _ ->
      transport.receive_within(connection, wait.idle_ms)
      |> result.map_error(transport_error(_, phase, wait.idle_ms))
  }
}

fn transport_error(
  error: transport.Error,
  phase: types.TimeoutPhase,
  waited_ms: Int,
) -> types.Error {
  case error {
    transport.InvalidUrl -> types.InvalidRequest("invalid HTTP endpoint")
    transport.RequestRefused(message) -> types.InvalidRequest(message)
    transport.TransportError(message) -> types.ConnectionError(message)
    transport.TimedOut -> types.Timeout(phase, waited_ms)
  }
}

fn http_error(
  connection: transport.Connection,
  wait: Wait,
  status: Int,
  final: Bool,
  chunks: List(BitArray),
  size: Int,
) -> Result(a, types.Error) {
  case final || size >= max_error_bytes {
    True -> {
      let body =
        chunks
        |> list.reverse
        |> bit_array.concat
        |> bit_array.to_string
        |> result.unwrap("<non-UTF-8 response body>")
      Error(types.HttpError(status, body))
    }
    False -> {
      use message <- result.try(receive(
        connection,
        wait,
        types.AwaitingFirstEvent,
      ))
      case message {
        transport.Data(bytes, final) -> {
          let remaining = max_error_bytes - size
          let bytes = case bit_array.byte_size(bytes) > remaining {
            True -> bit_array.slice(bytes, 0, remaining) |> result.unwrap(<<>>)
            False -> bytes
          }
          http_error(
            connection,
            wait,
            status,
            final,
            [bytes, ..chunks],
            size + bit_array.byte_size(bytes),
          )
        }
        _ -> Error(types.HttpError(status, "unexpected response framing"))
      }
    }
  }
}

/// One request whose response is a whole body rather than a stream. `run` gets
/// it before the connection is pooled (or discarded, if any step failed).
pub fn with_body(
  exchange: Exchange,
  limit: Int,
  discard_on_error: Bool,
  on_event: fn(types.Event) -> types.Control,
  run: fn(String) -> Result(a, types.Error),
) -> Result(a, types.Error) {
  let exchange = capped(exchange, transport.budget_cap())
  let sent = clock.monotonic_ms()
  let wait =
    Wait(
      exchange.timeout_ms,
      option.map(exchange.first_event_timeout_ms, fn(budget) {
        #(sent + budget, budget)
      }),
    )
  use connection <- result.try(
    transport.open(
      exchange.url,
      exchange.headers,
      exchange.body,
      exchange.timeout_ms,
    )
    |> result.map_error(transport_error(
      _,
      types.Connecting,
      exchange.timeout_ms,
    )),
  )
  use <- with_connection(connection, discard_on_error)
  use first <- result.try(receive(connection, wait, types.AwaitingHeaders))
  case first {
    transport.Headers(status, _, final) -> {
      use _ <- result.try(notify([types.Responded(status)], on_event))
      case status >= 200 && status < 300 {
        False -> http_error(connection, wait, status, final, [], 0)
        True -> {
          use bytes <- result.try(collect(
            connection,
            wait,
            types.AwaitingFirstEvent,
            final,
            [],
            0,
            limit,
          ))
          use body <- result.try(
            bit_array.to_string(bytes)
            |> result.replace_error(types.InvalidEvent(
              "response body is not UTF-8",
            )),
          )
          run(body)
        }
      }
    }
    _ -> Error(types.InvalidEvent("HTTP data arrived before headers"))
  }
}

fn collect(
  connection: transport.Connection,
  wait: Wait,
  phase: types.TimeoutPhase,
  final: Bool,
  chunks: List(BitArray),
  size: Int,
  limit: Int,
) -> Result(BitArray, types.Error) {
  case final {
    True -> Ok(chunks |> list.reverse |> bit_array.concat)
    False -> {
      use message <- result.try(receive(connection, wait, phase))
      case message {
        transport.Data(bytes, final) -> {
          let size = size + bit_array.byte_size(bytes)
          case size > limit {
            True -> Error(types.EventTooLarge)
            False ->
              collect(
                connection,
                wait,
                case bytes {
                  <<>> -> phase
                  _ -> types.Streaming
                },
                final,
                [bytes, ..chunks],
                size,
                limit,
              )
          }
        }
        _ -> Error(types.InvalidEvent("unexpected HTTP headers inside body"))
      }
    }
  }
}

/// Deliver events to the caller's callback; Stop cancels the exchange.
pub fn notify(
  events: List(types.Event),
  on_event: fn(types.Event) -> types.Control,
) -> Result(Nil, types.Error) {
  list.try_each(events, fn(event) {
    case on_event(event) {
      types.Continue -> Ok(Nil)
      types.Stop -> Error(types.Cancelled)
    }
  })
}
