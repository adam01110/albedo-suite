//// Model → tools → model. The session owns cancellation and durable commits.

import albedo/kernel/tool as cell_tool
import albedo_env/log
import albedo_protect
import albedo_sdk/session_info

import albedo/history/conversation
import albedo/history/image_fit
import albedo/history/tool_count
import albedo/history/tool_results
import albedo/kernel/journal
import albedo/kernel/result_view as python_view
import albedo/model_loop/repetition
import albedo/observation/events as view
import albedo/observation/stream_trace
import albedo/observation/tool_progress
import albedo/runtime
import albedo/storage/requests
import albedo/usage/cache_fade
import albedo/usage/usage
import albedo_bytes/scalars
import albedo_clock
import albedo_model as types
import albedo_model/refusal
import albedo_model/size
import albedo_sdk/cache_ttl
import albedo_sdk/compaction
import albedo_sdk/context_block
import albedo_sdk/extension
import albedo_sdk/hook
import albedo_sdk/message_content
import albedo_sdk/note
import albedo_sdk/projection
import albedo_sdk/python_repair
import albedo_sdk/storage
import albedo_sdk/store
import albedo_sdk/transcript
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A switch applied between requests, with history projected for its new provider.
pub type Selection {
  Selection(
    model: String,
    effort: Option(types.Effort),
    profile: String,
    upstream: extension.Upstream,
    inputs: List(transcript.Entry),
  )
}

pub type Loop {
  Loop(
    model: String,
    effort: Option(types.Effort),
    host: runtime.Runtime,
    /// The session's composition: instructions, tools, and hooks.
    prepared: runtime.Prepared,
    /// The session's kernel for one tool call, and the notice its arrival
    /// left for the model; the turn holds no kernel between calls.
    acquire: fn() -> Result(runtime.Session, String),
    pin: Pin,
    upstream: extension.Upstream,
    publish: fn(view.Event) -> Bool,
    generation: String,
    progress_delta: fn(Int, Int, Int, String, String) -> Bool,
    progress_running: fn(Int, Int, Int, String, String) -> Bool,
    progress_reset: fn(Int) -> Nil,
    progress_finish: fn(String) -> Nil,
    /// Commits inputs at a stage; a model response passes how long the
    /// model thought before it, and what its commit also saves. Answers the
    /// shared daemon time and the seq of its first assistant row, or the
    /// identified tool result.
    commit: fn(
      List(types.Input),
      conversation.Stage,
      Option(Int),
      Option(conversation.ToolIdentity),
      conversation.Follow,
    ) -> Result(#(Int, Option(Int)), String),
    /// Appends image fit rows ahead of the request that needs them.
    commit_fits: fn(List(transcript.ImageFit)) -> Result(Int, String),
    record_context: fn(
      String,
      types.Protocol,
      types.Request,
      Option(compaction.Observation),
      Bool,
    ) -> Nil,
    drain_steering: fn() -> Result(#(Int, List(types.Input)), String),
    /// Reports the pin's compaction baseline (`Some`) or that compaction
    /// replaced the history the pinned prompt was cached with (`None`).
    report_pin: fn(Option(Int)) -> Nil,
    /// Reports each successful turn call as it went out, for the session's
    /// extensions to hear.
    report_call: fn(extension.SentCall) -> Nil,
    /// The session whose provider requests are recorded.
    session: String,
    /// The saved profile those calls went through.
    profile: String,
    run_id: String,
    /// A measured baseline and how much history its count already covers.
    reported: Option(ReportedUsage),
    /// Updates compaction progress until the prepared request clears it.
    report_compacting: fn(compaction.ProgressUpdate) -> Nil,
    /// Whether this run already told the session its window is too small
    /// for compaction to make room.
    warned_small: Bool,
    /// How often a `Stopping` hook already kept this turn going.
    held: Int,
    /// Commits what a provider attempt that failed for this reason streamed,
    /// with a note to continue from it, and answers what it wrote: nothing
    /// when the attempt showed nothing.
    salvage: fn(String) -> Result(#(Int, List(types.Input)), String),
    /// Attempts this step already spent on streams that broke after showing
    /// output; its next call counts its retries on from them.
    spent: Int,
    /// Accepted timeouts already spent by this step, including salvaged attempts.
    accepted_timeouts: Int,
    /// Returns the model switch a parent queued; `run` applies it before a request.
    refresh: fn() -> Result(Option(Selection), String),
    /// Whether this step may finish without assistant text: an editor prompt,
    /// or a step the model ended quietly (`end_turn()`). Asked only when
    /// a step comes back empty.
    allow_empty_reply: fn() -> Bool,
    /// Whether `end_turn()` ended this step during its tool calls, so the loop
    /// checks steering and `Stopping` hooks before finishing or continuing.
    quieted: fn() -> Bool,
    /// Clears the quiet state when steering or a `Stopping` hook continues
    /// the turn onto the next step.
    unquiet: fn() -> Nil,
    /// Whether this turn's steps keep calling the same bindings with nearly
    /// the same code.
    repeats: repetition.Watch,
    /// Whether this turn already compacted because the provider said its
    /// request did not fit; a second refusal ends the turn.
    overflowed: Bool,
  )
}

/// The provider's reported total for the last request, the transcript rows it
/// covered, and how many history inputs it carried (as the strategy projected
/// them, its reply included) with their chain: a later request whose first
/// `sent` inputs have the same chain continues it.
pub type ReportedUsage {
  ReportedUsage(tokens: Int, history_items: Int, sent: Int, chain: String)
}

fn carried(inputs: List(types.Input)) -> #(Int, String) {
  #(list.length(inputs), requests.input_chain("", [], inputs))
}

/// Dependencies shared by turn, summarizer, and background provider calls.
pub type CallContext {
  CallContext(
    ledger: store.Store,
    upstream: extension.Upstream,
    session: String,
    profile: String,
    run_id: String,
    report_call: Option(fn(extension.SentCall) -> Nil),
  )
}

fn call_context(state: Loop) -> CallContext {
  CallContext(
    runtime.ledger(state.host),
    state.upstream,
    state.session,
    state.profile,
    state.run_id,
    Some(state.report_call),
  )
}

/// A live session keeps the system prompt it was cached with after its
/// capabilities change; the change reaches the model as a transcript update
/// instead. `head` is how many original inputs compaction had replaced when
/// the pin was first used, so a new compaction, which invalidates the cache
/// anyway, can drop the pin.
pub type Pin {
  Unpinned
  Pinned(prompt: conversation.PinnedPrompt, head: Option(Int))
}

/// Why a run ended without finishing. `message` is what people read.
pub type Failure {
  /// The provider refused or failed the model call.
  ProviderFailed(error: types.Error, message: String)
  /// The model stopped for a reason other than finishing its answer.
  ModelStopped(finish: types.Finish, message: String)
  /// Anything else: storage, hooks, a tool, a cancelled turn.
  RunFailed(message: String)
}

pub fn failure_message(failure: Failure) -> String {
  case failure {
    ProviderFailed(_, message)
    | ModelStopped(_, message)
    | RunFailed(message) -> message
  }
}

/// A step whose failure is ours, not the provider's or the model's.
fn plain(outcome: Result(a, String)) -> Result(a, Failure) {
  result.map_error(outcome, RunFailed)
}

/// Why a turn ended without finishing, with what it said first. A turn
/// names no output limit of its own, so a `LengthLimit` says which one
/// `ceiling` gave `request` and where it came from.
pub fn stopped_message(
  finish: types.Finish,
  output: List(types.ReplayItem),
  ceiling: extension.OutputCeiling,
  request: types.Request,
  endpoint: String,
) -> String {
  let failure = case finish {
    types.ContentFiltered -> "model stopped: its provider filtered the content"
    types.OtherFinish(reason) -> "model stopped: " <> reason
    types.LengthLimit | types.Complete | types.ToolCalls -> "model stopped"
  }
  let failure = case finish, ceiling {
    types.LengthLimit, extension.ModelCeiling(tokens, window, source) ->
      failure
      <> limit_sent(
        tokens,
        window,
        request,
        endpoint,
        "the model's ceiling is " <> int.to_string(tokens) <> " from " <> source,
      )
    types.LengthLimit, extension.FallbackCeiling(window) ->
      failure
      <> limit_sent(
        extension.output_fallback,
        window,
        request,
        endpoint,
        "no output limit in the model list; albedo's fallback of "
          <> int.to_string(extension.output_fallback),
      )
    types.LengthLimit, extension.NoCeiling ->
      failure <> " at the provider's own output limit; albedo sent none"
    types.LengthLimit, extension.ProviderCeiling ->
      failure
      <> " at the provider's own output limit; albedo sends this provider none"
    _, _ -> failure
  }
  let response =
    output
    |> list.map(message_content.output_text)
    |> list.filter(fn(text) { text != "" })
    |> string.join("\n\n")
  case response {
    "" -> failure
    response -> failure <> "\n\n" <> response
  }
}

/// The limit a `LengthLimit` stopped at: `tokens` clamped to the window, then
/// `origin`, where `tokens` came from.
fn limit_sent(
  tokens: Int,
  window: Option(Int),
  request: types.Request,
  endpoint: String,
  origin: String,
) -> String {
  case extension.output_limit(tokens, window, request, endpoint) {
    extension.OutputLimit(sent, False) ->
      " at the "
      <> int.to_string(sent)
      <> "-token output limit albedo sent; "
      <> origin
    extension.OutputLimit(sent, True) ->
      " at the "
      <> int.to_string(sent)
      <> "-token output limit albedo sent, clamped to fit the window: the prompt leaves no more of its "
      <> int.to_string(option.unwrap(window, 0))
      <> " tokens; "
      <> origin
  }
}

pub fn run(
  state: Loop,
  id: String,
  inputs: List(transcript.Entry),
  step: Int,
) -> Result(Nil, Failure) {
  use _ <- result.try(plain(checkpoint(state)))
  use selection <- result.try(plain(state.refresh()))
  let #(state, inputs) = case selection {
    None -> #(state, inputs)
    Some(selected) -> #(
      Loop(
        ..state,
        model: selected.model,
        effort: selected.effort,
        profile: selected.profile,
        upstream: selected.upstream,
        reported: None,
        warned_small: False,
      ),
      selected.inputs,
    )
  }
  use prompted <- result.try(plain(prompted(state, inputs, step)))
  case prompted {
    None -> Ok(Nil)
    Some(inputs) -> {
      let state = case step {
        0 -> Loop(..state, reported: restored_usage(state, inputs))
        _ -> state
      }
      converse(state, id, inputs, step)
    }
  }
}

/// Reuse a completed request only while its head, history prefix and saved
/// compaction projection still match. This also works after a daemon restart.
fn restored_usage(
  state: Loop,
  inputs: List(transcript.Entry),
) -> Option(ReportedUsage) {
  let restored = {
    use last <- result.try(
      requests.last_turn(runtime.ledger(state.host), state.session)
      |> result.replace_error(Nil),
    )
    use #(previous, _) <- result.try(option.to_result(last, Nil))
    use usage <- result.try(option.to_result(requests.row_usage(previous), Nil))
    use <- bool.guard(
      previous.model != state.model
        || previous.profile != state.profile
        || previous.effort != option.map(state.effort, types.effort_name)
        || previous.provider
        != types.protocol_name(state.upstream.protocol)
        <> ":"
        <> state.upstream.endpoint,
      Error(Nil),
    )
    use #(request, prefix, _) <- result.try(
      rebuild_observed(
        state.host,
        state.prepared,
        state.model,
        state.effort,
        state.pin,
        state.upstream,
        list.reverse(inputs),
        None,
      )
      |> result.replace_error(Nil),
    )
    let before = requests.row_prefix(previous)
    use <- bool.guard(
      prefix.head_hash != before.head_hash
        || prefix.replaced != before.replaced
        || prefix.projection_hash != before.projection_hash
        || prefix.strategy != before.strategy
        || prefix.inputs < before.inputs,
      Error(Nil),
    )
    let chain =
      requests.input_chain(
        option.unwrap(request.instructions, ""),
        request.tools,
        list.take(request.input, before.inputs),
      )
    use <- bool.guard(previous.input_chain != Some(chain), Error(Nil))
    let appended = list.drop(request.input, before.inputs)
    let after_response =
      list.drop_while(appended, fn(input) {
        case input {
          types.Replay(_) -> True
          _ -> False
        }
      })
    // The completed response is already priced by its output usage. Without
    // its replay here, this is no longer a continuation of that request.
    use <- bool.guard(appended == after_response, Error(Nil))
    // What arrived after the response is not in the provider's numbers. The
    // strategy's projection of the history is what a later request is
    // measured against, so the carried inputs are counted in it.
    let original = list.map(list.reverse(inputs), fn(entry) { entry.input })
    use projected <- result.try(
      runtime.project_view_scoped(
        state.host,
        state.prepared,
        state.model,
        request_source(state.upstream, state.model),
        extension.clean_endpoint(state.upstream.endpoint),
        prompt_text(request_prompt(state)),
        original,
        state.upstream.images,
        None,
      )
      |> result.replace_error(Nil),
    )
    let #(sent, chain) =
      carried(list.take(
        projected.inputs,
        list.length(projected.inputs) - list.length(after_response),
      ))
    Ok(ReportedUsage(
      usage.input_tokens + usage.output_tokens,
      list.length(inputs) - list.length(after_response),
      sent,
      chain,
    ))
  }
  option.from_result(restored)
}

fn converse(
  state: Loop,
  id: String,
  inputs: List(transcript.Entry),
  step: Int,
) -> Result(Nil, Failure) {
  use inputs <- result.try(plain(fit_history(state, inputs)))
  let original_entries = list.reverse(inputs)
  let original = list.map(original_entries, fn(entry) { entry.input })
  use prepared <- result.try(plain(prepare(state, original_entries, False)))
  let #(state, history) = settle_pin(state, original, prepared.inputs)
  case state.pin {
    Unpinned ->
      state.report_pin(Some(
        list.length(original) - compaction.common_suffix(original, history),
      ))
    Pinned(..) -> Nil
  }
  let state = warn_small(state, prepared.observation)
  let history_entries = match_entries(original_entries, history)
  let request = request(state, request_prompt(state), history_entries)
  let prefix_original = request_entries(original_entries, state.upstream.images)
  state.record_context(
    state.profile,
    state.upstream.protocol,
    request,
    prepared.observation,
    prepared.compacted,
  )
  // The stream callbacks run in the stream's own process and are copied there
  // with everything they capture: they take these fields, not the loop state.
  let #(run_id, publish, progress_delta) = #(
    state.run_id,
    state.publish,
    state.progress_delta,
  )
  let answer = fn(request: types.Request) {
    call(
      call_context(state),
      requests.Turn,
      request,
      request_prefix(request, prefix_original, prepared.observation),
      publish,
      fn(event) {
        case
          view.stream_event(run_id, run_id <> ":" <> int.to_string(step), event)
        {
          Some(serialized) ->
            case publish(serialized) {
              True -> types.Continue
              False -> types.Stop
            }
          None -> types.Continue
        }
      },
      fn(attempt, event) {
        case event {
          types.ArgumentsDelta(output_index, name, fragment) ->
            case progress_delta(step, attempt, output_index, name, fragment) {
              True -> types.Continue
              False -> types.Stop
            }
          _ -> types.Continue
        }
      },
      state.progress_reset,
      state.salvage,
      state.spent + 1,
      accepted_timeouts: state.accepted_timeouts,
    )
    |> result.map_error(fn(error) {
      ProviderFailed(error, describe(state.upstream, state.model, error))
    })
  }
  let first = answer(request)
  use <- overflowed(state, id, inputs, step, first)
  use called <- result.try(first)
  use answered <- go_on(state, id, inputs, step, called)
  // A turn that ends with neither a reply nor a call left the user nothing.
  // Sending the same request again buys another full reasoning pass that
  // likely ends the same way, so the one retry says what went wrong.
  use called <- result.try(
    case speechless(answered.turn) && !state.allow_empty_reply() {
      False -> Ok(Answered(answered))
      True -> {
        let nudge = types.User(speechless_nudge)
        case state.publish(view.Retry(state.run_id, 2, speechless_retry, 0)) {
          False -> Error(RunFailed("cancelled"))
          True ->
            answer(
              types.Request(
                ..request,
                input: list.append(request.input, [nudge]),
              ),
            )
        }
      }
    },
  )
  use Called(attempt, row, turn, sent) <- go_on(state, id, inputs, step, called)
  let cache = fading(state, sent)
  let cache_loss = case row {
    Some(id) ->
      requests.cache_loss(
        runtime.ledger(state.host),
        state.session,
        id,
        option.then(cache, cache_fade.whole_for_ms),
      )
    None -> None
  }
  // The successful attempt's span, as its request row records it. A clock
  // that steps back reads as zero.
  let completed_usage =
    usage.from_completion(
      state.model,
      turn.usage,
      usage.now(),
      cache,
      Some(int.max(0, sent.finished_ms - sent.started_ms)),
      cache_loss,
    )
  // Each report teaches the route's estimate how the provider counts.
  let _ =
    option.map(turn.usage, fn(usage) {
      size.observe(route(state), usage.input_tokens, request)
    })
  let replay = list.map(turn.output, types.Replay)
  // The request row learns the seq of the row it produced, and the session
  // its usage, in the response's own commit.
  use #(replay_ts, _) <- result.try(
    plain(state.commit(
      replay,
      case turn.tool_calls {
        [] -> session_info.Idle
        _ -> session_info.Tool
      },
      turn.thought_ms,
      None,
      conversation.Follow(
        row,
        Some(completed_usage),
        case turn.finish, turn.tool_calls {
          types.Complete, [] -> Some("final")
          types.Complete, _ | types.ToolCalls, _ -> Some("commentary")
          _, _ -> None
        },
        sent_rows(state, history_entries),
        [],
      ),
    )),
  )
  let replay_entries = stamped_entries(replay, Some(replay_ts))
  let speechless_turn = speechless(turn) && !state.allow_empty_reply()
  let state =
    Loop(
      ..state,
      spent: 0,
      accepted_timeouts: 0,
      reported: option.map(turn.usage, fn(usage) {
        {
          let #(sent, chain) = carried(list.append(history, replay))
          ReportedUsage(
            tokens: usage.input_tokens + usage.output_tokens,
            history_items: list.length(inputs) + list.length(replay),
            sent:,
            chain:,
          )
        }
      }),
    )
  case turn.tool_calls {
    [] ->
      case turn.finish {
        types.Complete if speechless_turn ->
          Error(RunFailed(speechless_message(state.model)))
        types.Complete -> {
          use #(steer_ts, steering) <- result.try(plain(state.drain_steering()))
          let steering = stamped_entries(steering, Some(steer_ts))
          stop_or_continue(
            state,
            id,
            inputs,
            step,
            turn.output,
            [replay_entries, steering],
            steering,
          )
        }
        finish ->
          Error(ModelStopped(
            finish,
            stopped_message(
              finish,
              turn.output,
              state.upstream.output,
              request,
              state.upstream.endpoint,
            ),
          ))
      }
    calls -> {
      use ran <- result.try(
        plain(
          list.try_map(calls, fn(call) {
            let output_index =
              list.find(turn.call_indices, fn(binding) { binding.0 == call.id })
            case output_index {
              Ok(binding) -> run_tool(state, id, step, attempt, binding.1, call)
              Error(_) ->
                Error("provider completed a tool call without its output index")
            }
          }),
        ),
      )
      let results = list.map(ran, fn(item) { item.0 })
      let #(repeats, repeated) =
        repetition.step(
          state.repeats,
          list.filter_map(ran, fn(item) { item.2 }),
        )
      let added =
        list.append(
          list.flat_map(ran, fn(item) { item.1 }),
          repeating(repeated),
        )
      let state = Loop(..state, repeats:)
      use added <- result.try(
        plain(commit_hooked(state, added, session_info.Tool)),
      )
      use #(steer_ts, steering) <- result.try(plain(state.drain_steering()))
      let steering = stamped_entries(steering, Some(steer_ts))
      use _ <- result.try(
        plain(state.commit(
          [],
          session_info.Model,
          None,
          None,
          conversation.no_follow,
        )),
      )
      let call_replay =
        list.map(replay, fn(input) {
          case input {
            types.Replay(item) -> types.Replay(replay_repair(item))
            other -> other
          }
        })
        |> stamped_entries(Some(replay_ts))
      case state.quieted() {
        False ->
          run(
            state,
            id,
            unshift(inputs, [call_replay, results, added, steering]),
            step + 1,
          )
        True ->
          stop_or_continue(
            state,
            id,
            inputs,
            step,
            turn.output,
            [call_replay, results, added, steering],
            steering,
          )
      }
    }
  }
}

/// Runs `Stopping` hooks and continues when hooks or steering added input;
/// otherwise finishes the turn cleanly.
fn stop_or_continue(
  state: Loop,
  id: String,
  inputs: List(transcript.Entry),
  step: Int,
  output: List(types.ReplayItem),
  batches: List(List(transcript.Entry)),
  steering: List(transcript.Entry),
) -> Result(Nil, Failure) {
  use held <- result.try(plain(stopping(state, output)))
  case held, steering {
    [], [] -> Ok(Nil)
    _, _ -> {
      state.unquiet()
      let state = case held {
        [] -> state
        _ -> Loop(..state, held: state.held + 1)
      }
      run(state, id, unshift(inputs, list.append(batches, [held])), step + 1)
    }
  }
}

/// What the model is told when its turn ended with only reasoning, or
/// nothing at all: gemini-cli nudges the same way.
const speechless_nudge =
  "[albedo: your previous response ended with no reply and no tool call, so the user saw nothing. Give your answer now, or call a tool.]"

const speechless_retry = "model ended its turn without a reply"

fn speechless_message(model: String) -> String {
  model
  <> " ended its turn without a reply or a tool call, even when asked again; send a message to continue"
}

/// Whether a completed turn said nothing the user can read and called no
/// tool: Gemini routes sometimes stop after thinking alone.
fn speechless(turn: types.Turn) -> Bool {
  turn.tool_calls == []
  && turn.finish == types.Complete
  && list.all(turn.output, fn(item) {
    case message_content.visible_assistant_text(types.Replay(item)) {
      Some(text) -> string.trim(text) == ""
      None -> True
    }
  })
}

/// `inputs`, newest first, with the images the provider would refuse swapped
/// for fitted copies. The fits are committed first, so a history loaded from
/// the transcript carries the same copies.
fn fit_history(
  state: Loop,
  inputs: List(transcript.Entry),
) -> Result(List(transcript.Entry), String) {
  use fits <- result.try(image_fit.needed(
    state.upstream.images,
    inputs |> list.reverse |> list.map(fn(entry) { entry.input }),
  ))
  case fits {
    [] -> Ok(inputs)
    _ -> {
      use timestamp <- result.try(state.commit_fits(fits))
      let notes =
        fits
        |> list.map(fn(fit) { types.User(fit.note) })
        |> stamped_entries(Some(timestamp))
      inputs
      |> list.map(fn(entry) {
        transcript.Entry(
          ..entry,
          input: list.fold(fits, entry.input, image_fit.apply),
        )
      })
      |> list.append(list.reverse(notes), _)
      |> Ok
    }
  }
}

/// Force the session's selected strategy without sending an ordinary assistant turn.
/// The durable transcript remains unchanged; the next request uses the saved projection.
pub fn compact(
  state: Loop,
  inputs: List(transcript.Entry),
) -> Result(Nil, String) {
  use _ <- result.try(checkpoint(state))
  // `inputs` accumulates newest-first; strategies read chronological history.
  let original_entries = list.reverse(inputs)
  let original = list.map(original_entries, fn(entry) { entry.input })
  use prepared <- result.try(prepare(state, original_entries, True))
  let history = prepared.inputs
  // The projection keeps a verbatim tail, so everything before the shared
  // suffix is what the strategy's replacement stands in for.
  let suffix = compaction.common_suffix(original, history)
  let evicted = list.length(inputs) - suffix
  // A source-backed fold can change the projection while its verbatim tail
  // still covers every original input. Report that committed change as well.
  let changed = prepared.compacted || evicted > 0
  let _ = case changed {
    True -> {
      // The summary replaced the history the pinned prompt was cached with.
      case state.pin {
        Pinned(..) -> state.report_pin(None)
        Unpinned -> Nil
      }
      state.publish(view.Compacted(
        prepared.observation,
        evicted,
        display_text(list.take(history, list.length(history) - suffix)),
      ))
    }
    False ->
      state.publish(view.note(
        "daemon",
        "history already fits; nothing new to compact",
      ))
  }
  state.report_pin(Some(evicted))
  let prompt = case changed {
    True -> kernel_prompt(state.prepared)
    False -> request_prompt(state)
  }
  // A forced compaction keeps the default options; an ordinary turn sets effort.
  let compacted =
    request(state, prompt, match_entries(original_entries, history))
  state.record_context(
    state.profile,
    state.upstream.protocol,
    types.Request(
      ..compacted,
      options: types.Options(
        ..types.defaults,
        shared_instructions: compacted.options.shared_instructions,
      ),
    ),
    prepared.observation,
    prepared.compacted,
  )
  Ok(Nil)
}

/// The summary of `inputs`, newest first like the other entry points, which a
/// rewind removes. `extra` is the user's own wish for what it should keep.
pub fn summarize_branch(
  state: Loop,
  inputs: List(transcript.Entry),
  extra: Option(String),
) -> Result(String, String) {
  let chronological = list.reverse(inputs)
  summarize(
    state,
    chronological,
    compaction.SummaryRequest(
      state.model,
      None,
      list.map(chronological, fn(entry) { entry.input }),
      4096,
      case extra {
        Some(wish) ->
          compaction.branch_summary_instructions
          <> " The user also asks: "
          <> wish
        None -> compaction.branch_summary_instructions
      },
      None,
    ),
  )
  |> result.map(fn(summary) { summary.text })
  |> result.map_error(fn(error) { error.reason })
}

/// One background call: `request` sent exactly as given — never rebuilt
/// through `prepare`, which could compact or call the summarizer — and
/// recorded under `prefix`. It commits nothing and publishes nothing; it
/// answers the call's usage and its reply's text.
pub type SideReply {
  SideReply(text: String, finish: types.Finish)
}

pub fn side(
  state: CallContext,
  request: types.Request,
  prefix: requests.Prefix,
) -> Result(SideReply, String) {
  auxiliary_turn(state, request, prefix, requests.Side)
  |> result.map(fn(called) {
    SideReply(visible_text(called.turn), called.turn.finish)
  })
}

pub fn auxiliary(
  state: CallContext,
  request: types.Request,
  prefix: requests.Prefix,
  kind: requests.Kind,
) -> Result(compaction.Answer, String) {
  auxiliary_turn(state, request, prefix, kind)
  |> result.map(fn(called) {
    compaction.Answer(
      called.turn.usage,
      compaction.reply_text(
        visible_text(called.turn),
        called.turn.finish,
        called.row,
      )
        |> result.map_error(fn(error) { error.reason }),
    )
  })
}

fn auxiliary_turn(
  state: CallContext,
  request: types.Request,
  prefix: requests.Prefix,
  kind: requests.Kind,
) -> Result(Called, String) {
  call(
    state,
    kind,
    request,
    prefix,
    // Auxiliary calls do not publish stream events.
    fn(_event) { True },
    fn(_event) { types.Continue },
    fn(_attempt, _event) { types.Continue },
    fn(_attempt) { Nil },
    keep_nothing,
    case kind {
      requests.Title | requests.Side -> attempts
      _ -> 1
    },
    accepted_timeouts: 0,
  )
  |> result.try(whole)
  |> result.map_error(describe(state.upstream, request.model, _))
}

/// Start a tool only after its running projection is acknowledged. Remove
/// that projection before committing and publishing the tool result. Hooks
/// may refuse the call or rewrite its arguments; what they add for the model
/// comes back beside the result, and so does the cell a python call ran.
fn run_tool(
  state: Loop,
  run_id: String,
  step: Int,
  attempt: Int,
  output_index: Int,
  call: types.ToolCall,
) -> Result(
  #(transcript.Entry, List(Told), Result(repetition.Cell, Nil)),
  String,
) {
  let progress_id =
    tool_progress.progress_id(
      generation: state.generation,
      run_id: run_id,
      step: step,
      attempt: attempt,
      output_index: output_index,
    )
  case state.progress_running(step, attempt, output_index, call.id, call.name) {
    False -> Error("cancelled before tool execution")
    True -> {
      let invoked = invoke(state, call)
      // Drop the running projection before committing the result. A reset
      // racing with that commit must not snapshot the just-finished call.
      state.progress_finish(progress_id)
      use Invoked(call, output, failed, added, halt) <- result.try(invoked)
      use #(timestamp, position) <- result.try(state.commit(
        [output],
        session_info.Tool,
        None,
        Some(conversation.ToolIdentity(
          progress_id,
          tool_progress.call_title(call),
          failed,
        )),
        conversation.no_follow,
      ))
      let saved = saved_trace(state, output)
      let _ = case output {
        types.ToolOutput(_, body, images) -> {
          let trace = option.map(saved, types.encode_value)
          case position {
            Some(position) ->
              state.publish(view.ToolWithImages(
                call,
                body,
                trace,
                progress_id,
                position,
                images,
                failed,
                tool_count.total(runtime.ledger(state.host), state.session),
              ))
            None ->
              state.publish(view.Failure(
                Some(state.run_id),
                view.ToolPublicationFailed,
                "committed tool result identity could not be observed",
              ))
          }
        }
        _ -> True
      }
      case halt {
        Some(reason) -> Error("stopped by a hook: " <> reason)
        None ->
          Ok(#(
            transcript.Entry(
              output,
              Some(timestamp),
              None,
              None,
              None,
              None,
              True,
            ),
            added,
            ran_cell(call, saved),
          ))
      }
    }
  }
}

/// The trace the kernel saved for the cell a tool result names.
fn saved_trace(state: Loop, output: types.Input) -> Option(Dynamic) {
  case output {
    types.ToolOutput(_, body, _) ->
      json.parse(body, decode.field("cell_id", decode.string, decode.success))
      |> option.from_result
      |> option.then(journal.saved_trace(
        storage.host(runtime.ledger(state.host)),
        _,
      ))
    _ -> None
  }
}

/// The cell a python call ran, for the repetition watch: its code and the
/// bindings its saved trace says it called.
fn ran_cell(
  call: types.ToolCall,
  saved: Option(Dynamic),
) -> Result(repetition.Cell, Nil) {
  case call.name {
    name if name == cell_tool.name -> {
      use code <- result.map(
        json.parse(
          call.arguments,
          decode.field("code", decode.string, decode.success),
        )
        |> result.replace_error(Nil),
      )
      let calls = case saved {
        Some(trace) ->
          decode.run(trace, decode.at(["calls"], decode.list(decode.string)))
          |> result.unwrap([])
        None -> []
      }
      repetition.Cell(code, calls)
    }
    _ -> Error(Nil)
  }
}

/// The note that tells the model, and the user who sees it in the
/// transcript, that the turn's steps keep repeating.
fn repeating(repeated: Option(repetition.Repeated)) -> List(Told) {
  case repeated {
    None -> []
    Some(repeated) -> [
      transcript.note_row("repetition", repetition.note(repeated)),
    ]
  }
}

/// What the model is told in a note: the input it reads and the kind of row
/// that records it.
type Told =
  #(types.Input, transcript.Kind)

/// A tool call as its hooks left it: the call that ran (or was refused), its
/// output, what the hooks added for the model, and a hook's request to end
/// the turn once the result is committed.
type Invoked {
  Invoked(
    call: types.ToolCall,
    output: types.Input,
    failed: Bool,
    added: List(Told),
    halt: Option(String),
  )
}

fn invoke(state: Loop, call: types.ToolCall) -> Result(Invoked, String) {
  // Before the hooks, so they judge the cell that runs.
  let call = runtime.as_cell(state.prepared, call)
  let asked = hook.Call(call.id, call.name, call.arguments, None)
  let started = requests.now()
  use hook.Answer(calling, _, calling_context) <- result.try(hooked(
    state,
    hook.Calling(asked),
  ))
  let call =
    types.ToolCall(
      ..call,
      arguments: option.unwrap(calling.arguments, call.arguments),
    )
  use #(output, failed) <- result.try(case calling.block {
    Some(reason) -> Ok(#(refused(call, "blocked by a hook: " <> reason), True))
    None ->
      case state.acquire() {
        // The model hears why and may go on; a cancelled turn stops at its
        // next checkpoint.
        Error(why) -> Ok(#(refused(call, why), True))
        Ok(kernel) ->
          runtime.invoke(state.host, kernel, call, state.upstream.images)
      }
  })
  let body = case output {
    types.ToolOutput(_, body, _) -> body
    _ -> ""
  }
  let hook.Answer(called, by, called_context) =
    runtime.hook(
      state.prepared,
      hook.Called(
        hook.Call(..asked, arguments: call.arguments),
        body,
        started,
        requests.now(),
      ),
    )
  note(state, called)
  // A block after the call cannot undo it: its reason is context.
  let added =
    list.flatten([
      calling_context,
      option.values([option.map(called.block, hook.Given(by, _))]),
      called_context,
    ])
  Ok(Invoked(call, output, failed, list.map(added, given_told), called.halt))
}

/// A call that did not run, answered in the JSON shape tools report errors in.
fn refused(call: types.ToolCall, message: String) -> types.Input {
  types.ToolOutput(
    call.id,
    json.to_string(json.object([#("error", json.string(message))])),
    [],
  )
}

/// Asks the session's hooks, shows the user their notes, and ends the turn
/// if one of them asked to.
fn hooked(state: Loop, event: hook.Event) -> Result(hook.Answer, String) {
  let answer = runtime.hook(state.prepared, event)
  note(state, answer.verdict)
  case answer.verdict.halt {
    Some(reason) -> Error("stopped by a hook: " <> reason)
    None -> Ok(answer)
  }
}

fn note(state: Loop, verdict: hook.Verdict) -> Nil {
  list.each(verdict.notes, fn(text) { state.publish(view.note("hook", text)) })
}

fn commit_hooked(
  state: Loop,
  told: List(Told),
  stage: conversation.Stage,
) -> Result(List(transcript.Entry), String) {
  case told {
    [] -> Ok([])
    _ -> {
      let inputs = list.map(told, fn(item) { item.0 })
      let kinds = list.index_map(told, fn(item, offset) { #(offset, item.1) })
      state.commit(
        inputs,
        stage,
        None,
        None,
        conversation.Follow(..conversation.no_follow, kinds:),
      )
      |> result.map(fn(committed) { stamped_entries(inputs, Some(committed.0)) })
    }
  }
}

fn given_told(given: hook.Given) -> Told {
  transcript.note_row(given.by, given.text)
}

/// Asks the hooks about a turn's newest user message before its first model
/// call. Their context goes ahead of that call; a block (`None`) ends the
/// turn after telling the user why. The message was committed before any
/// hook saw it, so it stays in the transcript.
fn prompted(
  state: Loop,
  inputs: List(transcript.Entry),
  step: Int,
) -> Result(Option(List(transcript.Entry)), String) {
  case step, inputs {
    0, [transcript.Entry(input: types.User(text), ..), ..]
    | 0, [transcript.Entry(input: types.UserImage(text, _), ..), ..]
    -> {
      use hook.Answer(verdict, _, given) <- result.try(hooked(
        state,
        hook.Prompted(text),
      ))
      case verdict.block {
        Some(reason) -> {
          state.publish(view.note(
            "hook",
            "prompt blocked by a hook: " <> reason,
          ))
          Ok(None)
        }
        None -> {
          let added = list.map(given, given_told)
          use added <- result.try(commit_hooked(
            state,
            added,
            session_info.Model,
          ))
          Ok(Some(unshift(inputs, [added])))
        }
      }
    }
    _, _ -> Ok(Some(inputs))
  }
}

/// Asks the hooks when the model ends its turn without a tool call. A block
/// or context becomes the next input and the turn goes on, at most
/// `max_held` times.
fn stopping(
  state: Loop,
  output: List(types.ReplayItem),
) -> Result(List(transcript.Entry), String) {
  case state.held >= max_held {
    True -> Ok([])
    False -> {
      let reply =
        output
        |> list.map(message_content.output_text)
        |> list.filter(fn(text) { text != "" })
        |> string.join("\n\n")
      use hook.Answer(verdict, by, given) <- result.try(hooked(
        state,
        hook.Stopping(reply, state.held),
      ))
      let block = option.map(verdict.block, hook.Given(by, _))
      let held =
        list.map(list.append(option.values([block]), given), given_told)
      commit_hooked(state, held, session_info.Model)
    }
  }
}

const max_held = 8

/// The repair the host applies to each replay item before a model sees it:
/// the items it projects from a transcript and the calls a turn sends back.
/// Every session runs the python tool, so it is the python tool's
/// (`sdk/python_repair`).
pub fn replay_repair(item: types.ReplayItem) -> types.ReplayItem {
  python_repair.replay_item(item)
}

/// A checkpoint event a client may refuse; a refusal ends the turn cancelled.
fn checkpoint(state: Loop) -> Result(Nil, String) {
  compaction.require(state.publish(view.Checkpoint), "cancelled")
}

/// Tells the session once per run that its strategy sends requests over the
/// trigger because a fold cannot make room, so the cause is seen rather than
/// guessed from a growing context.
fn warn_small(
  state: Loop,
  observation: Option(compaction.Observation),
) -> Loop {
  case observation, state.warned_small {
    Some(compaction.Observation(status: "window_too_small", source:, ..)), False
    -> {
      let _ = state.publish(view.note("compaction", source))
      Loop(..state, warned_small: True)
    }
    _, _ -> state
  }
}

/// The request this turn or a forced compaction prepares: its scoped strategy
/// view of `original`, the chronological history.
fn prepare(
  state: Loop,
  original_entries: List(transcript.Entry),
  force: Bool,
) -> Result(compaction.Prepared, String) {
  let original = list.map(original_entries, fn(entry) { entry.input })
  runtime.prepare_view_scoped(
    state.host,
    state.prepared,
    state.model,
    request_source(state.upstream, state.model),
    extension.clean_endpoint(state.upstream.endpoint),
    prompt_text(request_prompt(state)),
    summarize(state, original_entries, _),
    original,
    force,
    state.upstream.images,
    state.report_compacting,
    fn(rows) {
      rows
      |> list.reverse
      |> list.map(fn(row) {
        transcript.Entry(row.1, None, row.0, None, None, None, False)
      })
      |> projection.for_model(
        state.profile,
        state.upstream.protocol,
        replay_repair,
      )
      // The projection answers newest first, as the session keeps history.
      |> result.map(list.reverse)
    },
    fn() { cached(state) },
    Some(sizing(state, original_entries)),
  )
}

/// The route this turn's sizes are learned and estimated for.
fn route(state: Loop) -> size.Route {
  size.Route(state.upstream.endpoint, state.model)
}

/// How big this turn's requests and rows are: the provider's count of a
/// request when its route has a count endpoint, else the usage it reported
/// for the last request plus an estimate of what arrived since; each row
/// from the reported usage of the calls that wrote and first sent it.
fn sizing(
  state: Loop,
  original_entries: List(transcript.Entry),
) -> compaction.Sizing {
  let route = route(state)
  let prompt = request_prompt(state)
  // A count that fails, or a provider extension's encoder that raises, only
  // leaves the request to the reported and estimated sizes.
  let counted = fn(inputs) {
    use count <- option.then(state.upstream.count)
    let request =
      request(state, prompt, match_entries(original_entries, inputs))
    case albedo_protect.attempt(fn() { count(request) }) {
      Ok(Ok(tokens)) -> Some(tokens)
      Ok(Error(_)) -> None
      Error(crash) -> {
        log.warning("token count raised: " <> crash)
        None
      }
    }
  }
  compaction.Sizing(
    request: fn(inputs) {
      // The reported total covers `inputs` only while they start with what
      // that request carried, as its strategy projected it.
      let continues = case state.reported {
        Some(usage) ->
          carried(list.take(inputs, usage.sent)) == #(usage.sent, usage.chain)
        None -> False
      }
      case counted(inputs), state.reported {
        Some(tokens), _ ->
          size.total([size.Measured(tokens, size.CountEndpoint)])
        None, Some(usage) if continues ->
          size.total([
            size.Measured(usage.tokens, size.ReportedUsage),
            size.estimate(route, list.drop(inputs, usage.sent)),
          ])
        None, _ -> {
          let empty = request(state, prompt, [])
          size.total([
            size.estimate_request(
              route,
              option.unwrap(empty.instructions, ""),
              empty.tools,
              inputs,
            ),
          ])
        }
      }
    },
    inputs: fn(inputs) { row_sizes(state, route, original_entries, inputs) },
    image: fn(width, height) { size.estimate_image(route, width, height) },
  )
}

/// Each of `inputs` as reported usage priced the row it came from, else
/// estimated.
fn row_sizes(
  state: Loop,
  route: size.Route,
  entries: List(transcript.Entry),
  inputs: List(types.Input),
) -> List(size.Size) {
  let seqs =
    entries
    |> list.filter_map(fn(entry) {
      case entry.source {
        Some(transcript.SourceRef(session, seq)) if session == state.session ->
          Ok(#(entry.input, seq))
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
  let asked = list.filter_map(inputs, fn(input) { dict.get(seqs, input) })
  let costs =
    requests.row_costs(runtime.ledger(state.host), state.session, asked)
    |> result.unwrap(dict.new())
  list.map(inputs, fn(input) {
    case dict.get(seqs, input) |> result.try(dict.get(costs, _)) {
      Ok(tokens) -> size.Measured(tokens, size.ReportedUsage)
      Error(Nil) -> size.estimate(route, [input])
    }
  })
}

/// Newest-first `inputs` with each newest-first batch unshifted ahead of it,
/// earliest batch last.
fn unshift(inputs: List(a), batches: List(List(a))) -> List(a) {
  list.fold(batches, inputs, fn(accumulated, batch) {
    list.append(list.reverse(batch), accumulated)
  })
}

fn stamped_entries(
  inputs: List(types.Input),
  timestamp: Option(Int),
) -> List(transcript.Entry) {
  list.map(inputs, transcript.Entry(_, timestamp, None, None, None, None, True))
}

/// Re-attach `original`'s timestamps to `kept` inputs produced by compaction,
/// matching the retained suffix verbatim first so duplicate messages map to
/// their kept instance, and scanning forward for any earlier kept items.
fn match_entries(
  original: List(transcript.Entry),
  kept: List(types.Input),
) -> List(transcript.Entry) {
  let original_inputs = list.map(original, fn(entry) { entry.input })
  let suffix = compaction.common_suffix(original_inputs, kept)
  let prefix_len = list.length(kept) - suffix
  let orig_prefix_len = list.length(original) - suffix
  let matched_prefix =
    scan_entries(
      list.take(original, orig_prefix_len),
      list.take(kept, prefix_len),
      [],
    )
  list.append(matched_prefix, list.drop(original, orig_prefix_len))
}

fn scan_entries(
  original: List(transcript.Entry),
  kept: List(types.Input),
  acc: List(transcript.Entry),
) -> List(transcript.Entry) {
  case kept {
    [] -> list.reverse(acc)
    [input, ..rest_kept] ->
      case drop_until(original, input) {
        Some(#(matched, rest_orig)) ->
          scan_entries(rest_orig, rest_kept, [matched, ..acc])
        None ->
          scan_entries(original, rest_kept, [
            transcript.Entry(input, None, None, None, None, None, False),
            ..acc
          ])
      }
  }
}

fn drop_until(
  entries: List(transcript.Entry),
  target: types.Input,
) -> Option(#(transcript.Entry, List(transcript.Entry))) {
  case entries {
    [] -> None
    [head, ..tail] if head.input == target -> Some(#(head, tail))
    [_, ..tail] -> drop_until(tail, target)
  }
}

fn display_text(items: List(types.Input)) -> String {
  items
  |> list.map(fn(input) {
    case input {
      types.User(text) -> text
      types.UserImage(text, _) -> text <> "\n[image omitted from this view]"
      types.ToolOutput(id, _, _) -> "[tool output " <> id <> " omitted]"
      input ->
        option.unwrap(
          message_content.visible_assistant_text(input),
          "[assistant tool call omitted]",
        )
    }
  })
  |> string.join("\n\n")
  |> bounded(20_000, "\n[remainder omitted]")
}

/// Truncated views of oversized text: `limit` scalars, then why it ends.
fn bounded(text: String, limit: Int, note: String) -> String {
  case scalars.length(text) > limit {
    True -> scalars.take(text, limit) <> note
    False -> text
  }
}

/// Streams one provider call, recording one provider request per attempt: what
/// it cost, how it ended, and the prefix identity it went out with. The row
/// id of the attempt that succeeded is answered so its transcript seq can be
/// attached once committed, with the call as it went out. A row that cannot
/// be written is logged and skipped, never a failed turn. Attempts count from
/// `first`; a retryable failure after the stream showed output keeps that
/// output through `salvage` and resumes instead of retrying.
fn call(
  state: CallContext,
  kind: requests.Kind,
  request: types.Request,
  prefix: requests.Prefix,
  publish: fn(view.Event) -> Bool,
  on_event: fn(types.Event) -> types.Control,
  progress_event: fn(Int, types.Event) -> types.Control,
  reset_progress: fn(Int) -> Nil,
  salvage: fn(String) -> Result(#(Int, List(types.Input)), String),
  first: Int,
  accepted_timeouts accepted_timeouts: Int,
) -> Result(Attempt(Called), types.Error) {
  let input_chain =
    requests.input_chain(
      option.unwrap(request.instructions, ""),
      request.tools,
      request.input,
    )
  retry_stream(
    fn(attempt) {
      let started_event = case kind {
        requests.Summarizer -> view.Checkpoint
        _ -> view.ProviderStarted
      }
      use _ <- result.try(case publish(started_event) {
        True -> Ok(Nil)
        False -> Error(types.Cancelled)
      })
      let started = requests.now()
      let trace = stream_trace.new(started)
      let outcome =
        state.upstream.stream(request, fn(event) {
          stream_trace.observe(trace, event, requests.now())
          case on_event(event) {
            types.Continue -> progress_event(attempt, event)
            types.Stop -> types.Stop
          }
        })
      let finished = requests.now()
      let reported = stream_trace.reported(trace)
      // A failed call costs what its stream last metered.
      let usage = case outcome {
        Ok(turn) -> turn.usage
        Error(_) -> reported.usage
      }
      let marks = state.upstream.cache_marks(request)
      // The account label is read after the attempt: rotation records which
      // account served while the request streams.
      let row =
        requests.record(
          state.ledger,
          requests.Call(
            state.session,
            kind,
            state.profile,
            types.protocol_name(state.upstream.protocol)
              <> ":"
              <> state.upstream.endpoint,
            state.upstream.account(),
            request.model,
            option.map(request.options.effort, types.effort_name),
            started,
            finished,
            requests.outcome(outcome),
            usage,
            prefix,
            marks,
            state.run_id,
            input_chain,
            stream_trace.streamed(trace),
            reported,
          ),
        )
      let row = case row {
        Ok(id) -> Some(id)
        Error(error) -> {
          io.println_error(
            "provider request record failed for session "
            <> state.session
            <> ": "
            <> error,
          )
          None
        }
      }
      let sent =
        extension.SentCall(
          request,
          prefix,
          usage,
          marks,
          state.profile,
          state.upstream.endpoint,
          state.upstream.protocol,
          started,
          finished,
        )
      // Extensions hear a turn's call as sent, never a rebuilt one.
      case kind, outcome {
        requests.Turn, Ok(_) ->
          case state.report_call {
            Some(report) -> report(sent)
            None -> Nil
          }
        _, _ -> Nil
      }
      case outcome {
        Ok(turn) -> Ok(Called(attempt, row, turn, sent))
        Error(error) -> Error(error)
      }
    },
    publish,
    state.run_id,
    reset_progress,
    salvage,
    first,
    accepted_timeouts,
  )
}

/// One provider call that ended: the attempt that made it, the request row
/// that it left, the turn that it settled, and the call as it went out.
type Called {
  Called(
    attempt: Int,
    row: Option(Int),
    turn: types.Turn,
    sent: extension.SentCall,
  )
}

/// How a provider call ended for its turn.
type Attempt(a) {
  Answered(a)
  /// The stream broke after it showed output; `kept` is what was committed
  /// of it, and the turn goes on from there at attempt `next`.
  Resumed(
    timestamp: Int,
    kept: List(types.Input),
    next: Int,
    accepted_timeouts: Int,
  )
}

/// For calls that keep nothing a broken stream showed, so never resume.
fn keep_nothing(_reason: String) -> Result(#(Int, List(types.Input)), String) {
  Ok(#(0, []))
}

/// The answer of a call that cannot resume.
fn whole(called: Attempt(a)) -> Result(a, types.Error) {
  case called {
    Answered(value) -> Ok(value)
    Resumed(..) -> Error(types.UnexpectedEnd)
  }
}

/// A request the provider refused as too long for the model's window is
/// compacted with the session's strategy and sent once more; a second
/// refusal, or no strategy to compact with, ends the turn with the first.
fn overflowed(
  state: Loop,
  id: String,
  inputs: List(transcript.Entry),
  step: Int,
  called: Result(a, Failure),
  otherwise: fn() -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  case called, state.overflowed {
    Error(ProviderFailed(types.Refused(types.ContextTooLong, ..), _) as failure),
      False
    -> {
      let _ =
        state.publish(view.note(
          "daemon",
          "the provider said the request is too long for the model; compacting and sending it again",
        ))
      case compact(state, inputs) {
        Ok(Nil) ->
          converse(
            Loop(..state, overflowed: True, reported: None),
            id,
            inputs,
            step,
          )
        Error(_) -> Error(failure)
      }
    }
    _, _ -> otherwise()
  }
}

/// The seqs of this session's transcript rows a request carried.
fn sent_rows(state: Loop, entries: List(transcript.Entry)) -> List(Int) {
  list.filter_map(entries, fn(entry) {
    case entry.source {
      Some(transcript.SourceRef(session, seq)) if session == state.session ->
        Ok(seq)
      _ -> Error(Nil)
    }
  })
}

/// Goes on with an answered call; a resumed one starts the step again from
/// history that ends with what its broken stream showed.
fn go_on(
  state: Loop,
  id: String,
  inputs: List(transcript.Entry),
  step: Int,
  called: Attempt(a),
  answered: fn(a) -> Result(Nil, Failure),
) -> Result(Nil, Failure) {
  case called {
    Answered(value) -> answered(value)
    Resumed(timestamp, kept, next, accepted_timeouts) -> {
      use kept <- result.try(
        kept
        |> list.reverse
        |> stamped_entries(Some(timestamp))
        |> projection.entries_for_model(
          state.profile,
          state.upstream.protocol,
          replay_repair,
        )
        |> plain,
      )
      run(
        Loop(..state, spent: next - 1, accepted_timeouts:),
        id,
        unshift(inputs, [list.reverse(kept)]),
        step + 1,
      )
    }
  }
}

/// How the cached count of a turn's call fades, by the cache table's entry
/// for where it went and the request ledger's measure of its head.
fn fading(state: Loop, sent: extension.SentCall) -> Option(cache_fade.Fade) {
  cache_fade.fade(
    cache_ttl.for_call(state.profile, sent.endpoint, sent.request.model),
    sent.marks,
    sent.usage,
    fn() {
      requests.head_tokens(
        runtime.ledger(state.host),
        state.profile,
        sent.request.model,
        sent.prefix.head_hash,
      )
    },
    sent.started_ms,
    sent.finished_ms,
  )
}

/// The request's prefix identity: its head, and the projection that stands in
/// for the history compaction replaced.
fn request_prefix(
  request: types.Request,
  original: List(types.Input),
  observation: Option(compaction.Observation),
) -> requests.Prefix {
  requests.prefix(
    option.unwrap(request.instructions, ""),
    request.tools,
    request.input,
    original,
    option.map(observation, fn(observation) { observation.strategy }),
  )
}

/// Attempts per provider call. Waits double from 250ms, so the last retry
/// comes about 32s after the first failure: long enough to outlast a network
/// handoff or a host whose ephemeral ports sit in TIME_WAIT.
const attempts = 8

/// Retries for a call that timed out after the provider accepted it. The
/// provider was generating, and billing, the whole time, and the identical
/// request most likely thinks just as long again, so it gets one more go.
const accepted_timeout_retries = 1

/// Reissue transient transport and gateway failures. A failed attempt that
/// showed nothing is sent again as it was; one that showed output keeps it
/// through `salvage`, and the call resumes from it instead.
fn retry_stream(
  run: fn(Int) -> Result(a, types.Error),
  publish: fn(view.Event) -> Bool,
  run_id: String,
  reset_progress: fn(Int) -> Nil,
  salvage: fn(String) -> Result(#(Int, List(types.Input)), String),
  attempt: Int,
  accepted_timeouts: Int,
) -> Result(Attempt(a), types.Error) {
  case run(attempt) {
    Error(error) -> {
      let accepted = accepted_timeout(error)
      let accepted_timeouts = case accepted {
        True -> accepted_timeouts + 1
        False -> accepted_timeouts
      }
      case
        attempt < attempts
        && retryable(error)
        && accepted_timeouts <= accepted_timeout_retries
      {
        False -> Error(error)
        True -> {
          let reason = case accepted {
            True -> "provider went silent after accepting the request"
            False -> "transient provider request failure"
          }
          let delay = int.bitwise_shift_left(250, attempt - 1)
          // Before the retry notice, which discards the attempt's live output.
          let #(salvage_ts, kept) = case salvage(reason) {
            Ok(kept) -> kept
            Error(error) -> {
              io.println_error(
                "keeping a broken stream's output failed for run "
                <> run_id
                <> ": "
                <> error,
              )
              #(0, [])
            }
          }
          case publish(view.Retry(run_id, attempt + 1, reason, delay)) {
            False -> Error(types.Cancelled)
            True -> {
              reset_progress(attempt)
              albedo_clock.sleep(delay)
              case kept {
                [] ->
                  retry_stream(
                    run,
                    publish,
                    run_id,
                    reset_progress,
                    salvage,
                    attempt + 1,
                    accepted_timeouts,
                  )
                kept ->
                  Ok(Resumed(salvage_ts, kept, attempt + 1, accepted_timeouts))
              }
            }
          }
        }
      }
    }
    Ok(value) -> Ok(Answered(value))
  }
}

fn accepted_timeout(error: types.Error) -> Bool {
  case error {
    types.Timeout(phase, _) -> types.accepted(phase)
    _ -> False
  }
}

/// What a request says before the conversation: the system prompt, how many
/// of its leading bytes every session shares, and the turns that open the
/// conversation.
type Prompt {
  Prompt(instructions: String, shared: Int, opening: List(types.Input))
}

fn request_prompt(state: Loop) -> Prompt {
  prompt_for(state.pin, state.prepared)
}

/// The prompt a request carries: the pinned one while a pin holds, else the
/// kernel's current one.
fn prompt_for(pin: Pin, kernel: runtime.Prepared) -> Prompt {
  case pin {
    Pinned(prompt, _) -> prompt_of(prompt.instructions, prompt.context)
    Unpinned -> kernel_prompt(kernel)
  }
}

fn kernel_prompt(kernel: runtime.Prepared) -> Prompt {
  prompt_of(runtime.instructions(kernel), runtime.context(kernel))
}

/// `instructions`, which every session shares, then the workspace's context
/// blocks. The memory snapshot opens the conversation instead, as the notes
/// the model wrote for itself: it reads them in its own voice, and a memory
/// that changed leaves the system prompt cached.
fn prompt_of(
  instructions: String,
  context: List(context_block.ContextBlock),
) -> Prompt {
  let #(notes, blocks) =
    list.partition(context, fn(block) { block.name == "memory" })
  let opening =
    list.map(notes, fn(block) {
      let context_block.ContextBlock(_, body) = block
      [
        types.User(notes_prompt),
        types.Assistant("<memory.md>\n" <> body <> "\n</memory.md>"),
      ]
    })
    |> list.flatten
  Prompt(
    instructions <> context_text(blocks),
    string.byte_size(instructions),
    opening,
  )
}

const notes_prompt =
  "These are the notes you have written for yourself in this workspace's memory."

/// The prompt's text, as compaction counts it against the window.
fn prompt_text(prompt: Prompt) -> String {
  prompt.instructions <> input_text(prompt.opening)
}

/// The request this loop state implies for one prepared history: its model,
/// tools, and effort setting.
fn request(
  state: Loop,
  prompt: Prompt,
  history: List(transcript.Entry),
) -> types.Request {
  request_for(
    state.model,
    state.effort,
    state.prepared,
    state.upstream.images,
    prompt,
    history,
  )
}

/// `instructions` and `history` as a model held to `images` reads them. A
/// model that takes no images is told so up front, and each image becomes a
/// note in its message. Only the request changes; the transcript keeps the
/// images for a model that reads them.
fn readable(
  images: types.ImageLimits,
  instructions: String,
  history: List(types.Input),
) -> #(String, List(types.Input)) {
  case images.max_images {
    Some(0) -> #(
      instructions <> "\n\n" <> text_only,
      list.map(history, without_images),
    )
    _ -> #(instructions, history)
  }
}

const text_only =
  "This model reads text only, so no image reaches it: show_image, view_diff and view_code raise, and screenshots come back without the picture. Review changes with `git diff` and read code with files.read instead."

fn without_images(input: types.Input) -> types.Input {
  case input {
    types.UserImage(text, [_, ..] as images) ->
      types.User(text <> omitted_images(images))
    types.ToolOutput(id, output, [_, ..] as images) ->
      types.ToolOutput(id, output <> omitted_images(images), [])
    _ -> input
  }
}

fn omitted_images(images: List(types.Image)) -> String {
  "\n["
  <> int.to_string(list.length(images))
  <> " image(s) omitted: this model reads text only]"
}

fn request_entries(
  entries: List(transcript.Entry),
  images: types.ImageLimits,
) -> List(types.Input) {
  let cells =
    python_view.cell_calls(list.map(entries, fn(entry) { entry.input }))
  let stamped =
    list.map(entries, fn(entry) {
      python_view.request_entry(
        entry.input,
        transcript.model_timestamp(entry),
        cells,
      )
    })
  case images.max_images {
    Some(0) -> list.map(stamped, without_images)
    _ -> stamped
  }
}

fn request_for(
  model: String,
  effort: Option(types.Effort),
  kernel: runtime.Prepared,
  images: types.ImageLimits,
  prompt: Prompt,
  history: List(transcript.Entry),
) -> types.Request {
  let history = list.append(prompt.opening, request_entries(history, images))
  let #(instructions, history) = readable(images, prompt.instructions, history)
  types.Request(
    model,
    Some(instructions),
    tool_results.pair(history),
    runtime.tools(kernel),
    None,
    types.Options(
      ..types.defaults,
      effort: effort,
      shared_instructions: prompt.shared,
    ),
  )
}

fn context_text(context: List(context_block.ContextBlock)) -> String {
  context
  |> list.map(context_block.render)
  |> string.join("\n\n")
  |> fn(text) {
    case text {
      "" -> ""
      _ -> "\n\n" <> text
    }
  }
}

/// Keeps the pin while compaction has replaced no further inputs. More
/// replaced inputs mean compaction rewrote history, so the cached prompt is
/// already lost: the pin is dropped and the current system prompt is used.
fn settle_pin(
  state: Loop,
  original: List(types.Input),
  history: List(types.Input),
) -> #(Loop, List(types.Input)) {
  let pin = settled(state.pin, original, history)
  case state.pin, pin {
    Pinned(_, None), Pinned(_, head) -> state.report_pin(head)
    Pinned(_, Some(_)), Unpinned -> state.report_pin(None)
    _, _ -> Nil
  }
  #(Loop(..state, pin:), history)
}

/// The pin a request for `history`, projected from `original`, is sent
/// under. Strategies may rebuild recap text every request, but the count of
/// original inputs they stand in for only grows when compaction runs, so a
/// pin's first request records that count and a later, larger one drops it.
fn settled(
  pin: Pin,
  original: List(types.Input),
  history: List(types.Input),
) -> Pin {
  case pin {
    Unpinned -> Unpinned
    Pinned(prompt, baseline) -> {
      let head =
        list.length(original) - compaction.common_suffix(original, history)
      case baseline {
        None -> Pinned(prompt, Some(head))
        Some(previous) if previous == head -> pin
        Some(_) -> Unpinned
      }
    }
  }
}

/// The request a turn call sends for `original`, the chronological history,
/// and its prefix identity, built as `run` builds it but projected under the
/// strategy's saved state without ever compacting: building it writes
/// nothing and calls no model. Whether it is the request an earlier call
/// sent is for the caller to judge, by comparing their prefix identities.
pub fn rebuild(
  host: runtime.Runtime,
  kernel: runtime.Prepared,
  model: String,
  effort: Option(types.Effort),
  pin: Pin,
  upstream: extension.Upstream,
  original: List(transcript.Entry),
) -> Result(#(types.Request, requests.Prefix), String) {
  rebuild_observed(host, kernel, model, effort, pin, upstream, original, None)
  |> result.map(fn(rebuilt) { #(rebuilt.0, rebuilt.1) })
}

/// `rebuild` with what the strategy observed preparing the request, which an
/// inspector shows beside it. `reported` is the input the provider reported
/// for the request being rebuilt, when the caller knows it: the observation
/// then sizes it by that number instead of an estimate.
pub fn rebuild_observed(
  host: runtime.Runtime,
  kernel: runtime.Prepared,
  model: String,
  effort: Option(types.Effort),
  pin: Pin,
  upstream: extension.Upstream,
  original_entries: List(transcript.Entry),
  reported: Option(Int),
) -> Result(
  #(types.Request, requests.Prefix, Option(compaction.Observation)),
  String,
) {
  let original = list.map(original_entries, fn(entry) { entry.input })
  let project = fn(sizing) {
    runtime.project_view_scoped(
      host,
      kernel,
      model,
      request_source(upstream, model),
      extension.clean_endpoint(upstream.endpoint),
      prompt_text(prompt_for(pin, kernel)),
      original,
      upstream.images,
      sizing,
    )
  }
  use prepared <- result.try(project(None))
  // The reported input measured the projection that call sent, and nothing
  // else a strategy sizes while projecting (the prompt alone, a candidate
  // fold): those stay estimated, so projecting again sizes them apart.
  use prepared <- result.map(case reported {
    None -> Ok(prepared)
    Some(tokens) -> {
      let estimated =
        compaction.estimated_sizing(
          size.Route(upstream.endpoint, model),
          prompt_text(prompt_for(pin, kernel)),
          runtime.tools(kernel),
        )
      project(Some(
        compaction.Sizing(..estimated, request: fn(inputs) {
          case inputs == prepared.inputs {
            True -> size.total([size.Measured(tokens, size.ReportedUsage)])
            False -> estimated.request(inputs)
          }
        }),
      ))
    }
  })
  let history = prepared.inputs
  let prompt = prompt_for(settled(pin, original, history), kernel)
  let request =
    request_for(
      model,
      effort,
      kernel,
      upstream.images,
      prompt,
      match_entries(original_entries, history),
    )
  #(
    request,
    request_prefix(
      request,
      request_entries(original_entries, upstream.images),
      prepared.observation,
    ),
    prepared.observation,
  )
}

fn describe(
  upstream: extension.Upstream,
  model: String,
  error: types.Error,
) -> String {
  case error {
    types.Timeout(phase, waited_ms) -> timeout_message(model, phase, waited_ms)
    _ ->
      upstream.explain(error)
      |> option.lazy_unwrap(fn() { refusal.describe(error) })
  }
}

/// A call that timed out on every attempt it was allowed.
fn timeout_message(
  model: String,
  phase: types.TimeoutPhase,
  waited_ms: Int,
) -> String {
  let seconds = int.to_string(waited_ms / 1000) <> " s"
  case phase {
    types.AwaitingFirstEvent ->
      model
      <> " produced no output for "
      <> seconds
      <> " after the provider accepted the request; it may be thinking past the timeout. Try a lower effort, or retry"
    types.Streaming ->
      model
      <> " stopped streaming for "
      <> seconds
      <> "; try a lower effort, or retry"
    types.Connecting | types.AwaitingHeaders ->
      "the provider request timed out "
      <> types.phase_name(phase)
      <> " ("
      <> seconds
      <> ") on every attempt"
  }
}

fn retryable(error: types.Error) -> Bool {
  case error {
    types.ConnectionError(_)
    | types.Timeout(..)
    | types.UnexpectedEnd
    | types.Refused(types.Unavailable, ..) -> True
    _ -> False
  }
}

fn summarize(
  state: Loop,
  original_entries: List(transcript.Entry),
  request: compaction.SummaryRequest,
) -> Result(compaction.Summary, compaction.SummaryError) {
  let compaction.SummaryRequest(
    model,
    previous,
    evicted,
    max_output_tokens,
    instructions,
    replay,
  ) = request
  let summary_request = case replay {
    Some(current) ->
      replayed(
        state,
        model,
        match_entries(original_entries, current),
        instructions,
      )
    None ->
      separate(
        state,
        model,
        previous,
        match_entries(original_entries, evicted),
        instructions,
      )
  }
  let summary_request =
    types.Request(..summary_request, max_output_tokens: Some(max_output_tokens))
  state.report_compacting(compaction.CallStarted)
  let outcome =
    call(
      call_context(state),
      requests.Summarizer,
      summary_request,
      // The summarizer's history is exactly what it says; nothing replaced.
      requests.direct_prefix(
        option.unwrap(summary_request.instructions, ""),
        summary_request.tools,
        summary_request.input,
      ),
      state.publish,
      fn(_) { types.Continue },
      fn(_, _) { types.Continue },
      fn(_) { Nil },
      keep_nothing,
      1,
      accepted_timeouts: 0,
    )
    |> result.try(whole)
    |> result.map_error(fn(error) {
      compaction.Failed(
        "summarizer provider request failed: "
        <> describe(state.upstream, model, error),
      )
    })
  state.report_compacting(compaction.CallFinished)
  use called <- result.try(outcome)
  compaction.reply_text(
    visible_text(called.turn),
    called.turn.finish,
    called.row,
  )
}

/// The request a turn would send now, under its own prompt, tools, tool
/// choice and cache marks, with the summary asked for in a note at its end:
/// the provider reads everything before the note from the cache the
/// session's last request wrote (compaction offers it only while `cached`
/// holds). Changing the tool choice would invalidate its cache of the
/// messages, so the note asks for no tool call instead.
fn replayed(
  state: Loop,
  model: String,
  current: List(transcript.Entry),
  instructions: String,
) -> types.Request {
  request_for(
    model,
    state.effort,
    state.prepared,
    state.upstream.images,
    request_prompt(state),
    list.append(
      current,
      stamped_entries([types.User(note.wrap("compaction", instructions))], None),
    ),
  )
}

/// Whether the provider still holds the session's last turn request in its
/// cache, so a request that extends it reads that prefix: the same model and
/// head as a request sent now, sent or kept warm inside the lifetime its
/// cache marks or the cache table give, with a tenth spare. Once that cache
/// is gone, extending the request would pay full price for all of it, tail
/// included. A provider whose cache has no clock never counts as cached.
fn cached(state: Loop) -> Bool {
  let now = request(state, request_prompt(state), [])
  let head =
    requests.direct_prefix(option.unwrap(now.instructions, ""), now.tools, [])
    |> fn(prefix) { prefix.head_hash }
  case requests.last_turn(runtime.ledger(state.host), state.session) {
    Ok(Some(#(turn, pings))) -> {
      let entry =
        cache_ttl.for_call(state.profile, state.upstream.endpoint, now.model)
      let latest = list.last(pings) |> result.unwrap(turn)
      let since = case cache_ttl.from_start(entry) {
        True -> latest.started_ms
        False -> latest.finished_ms
      }
      let marks = list.map(turn.cache_marks, fn(mark) { mark.ttl_seconds })
      case cache_ttl.lifetime(marks, entry) {
        None -> False
        Some(_) if turn.model != now.model -> False
        Some(_) if turn.head_hash != head -> False
        Some(seconds) -> requests.now() < since + seconds * 900
      }
    }
    _ -> False
  }
}

/// A summarizer request of its own. The evicted history goes out as the
/// conversation it was, so a provider reads its own signed or encrypted
/// reasoning the way a turn would, and a foreign model's turns replay as
/// that model's wire replays them. The session's tools ride along because a
/// provider may refuse tool calls in a request that defines none; the
/// summary asks for none, and since nothing sends this prefix again, it
/// writes no cache. It asks for medium effort, which the provider maps onto
/// what the model takes; a replayed request keeps the turn's effort, part of
/// the prefix it reads.
fn separate(
  state: Loop,
  model: String,
  previous: Option(String),
  evicted: List(transcript.Entry),
  instructions: String,
) -> types.Request {
  let opening = case previous {
    Some(previous) ->
      stamped_entries(
        [
          types.User(
            "<previous-summary>\n" <> previous <> "\n</previous-summary>",
          ),
        ],
        None,
      )
    None -> []
  }
  let kept_evicted =
    list.filter(evicted, fn(entry) { !compaction.superseded_note(entry.input) })
  let history =
    list.flatten([
      opening,
      kept_evicted,
      stamped_entries([types.User(summary_close)], None),
    ])
  let base =
    request_for(
      model,
      Some(types.Medium),
      state.prepared,
      state.upstream.images,
      Prompt(instructions, 0, []),
      history,
    )
  types.Request(
    ..base,
    options: types.Options(
      ..base.options,
      tool_choice: Some(types.NoTool),
      cache: False,
    ),
  )
}

/// What a reply shows a reader: its visible text, without reasoning.
fn visible_text(turn: types.Turn) -> String {
  turn.output
  |> list.filter_map(fn(item) {
    message_content.visible_assistant_text(types.Replay(item))
    |> option.to_result(Nil)
  })
  |> string.join("")
}

/// The turn that closes a summarizer request: everything before it is the
/// history being folded.
fn input_text(context: List(types.Input)) -> String {
  context
  |> list.filter_map(fn(input) {
    case input {
      types.User(text) | types.Assistant(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n\n")
  |> fn(text) {
    case text {
      "" -> ""
      _ -> "\n\n" <> text
    }
  }
}

const summary_close =
  "<newly-evicted-history>\nEverything above, after any previous summary, is newly evicted history. Write the summary of it now as your instructions describe. Do not call tools.\n</newly-evicted-history>"

fn request_source(upstream: extension.Upstream, model: String) -> String {
  string.join(
    [types.protocol_name(upstream.protocol), upstream.endpoint, model],
    ":",
  )
}
