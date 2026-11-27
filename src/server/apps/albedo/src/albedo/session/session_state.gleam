//// Actor-owned session data and its bounded event stream.

import albedo/commands/shell_commands
import albedo/composition/selection
import albedo/history/conversation
import albedo/model_loop/loop
import albedo/observation/active_output
import albedo/observation/bus
import albedo/observation/context_snapshot
import albedo/observation/event_buffer
import albedo/observation/events as view
import albedo/observation/tool_progress
import albedo/runtime
import albedo/runtime/admission
import albedo/session/session_activity
import albedo/session/side_question
import albedo/session/turn.{type Submission}
import albedo/storage/active_output_store
import albedo/storage/mail
import albedo/storage/operations
import albedo/usage/usage
import albedo_clock
import albedo_model as types
import albedo_sdk/queue
import albedo_sdk/store
import albedo_sdk/transcript
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Watcher {
  Watcher(
    owner: process.Pid,
    key: String,
    monitor: process.Monitor,
    notify: fn() -> Nil,
    notified: Bool,
  )
}

pub type PendingSwitch {
  PendingSwitch(caller: String, provider: String, model: String)
}

pub type TitleJob {
  TitleJob(
    revision: Int,
    initial_order: Option(Int),
    worker: process.Pid,
    stop: turn.Latch,
  )
}

pub type KernelNotice {
  KernelNotice(text: String, resets: Bool)
}

/// Why mail wakes are paused until the model, safety tier, or history
/// changes.
pub type SafetyHalt {
  SafetyHalt(provider: String, model: String, cyber_access: Option(String))
}

pub type State(message) {
  State(
    title_job: Option(TitleJob),
    title_revision: Int,
    active_output: active_output.Projection,
    side_question: Option(side_question.Exchange),
    shell_commands: List(shell_commands.Command),
    shell_worker: Option(#(String, process.Pid)),
    info: conversation.Info,
    acp: Bool,
    host: runtime.Runtime,
    kernel: Option(runtime.Session),
    /// The kernel the idle sweep released, whose composition stays prepared
    /// for the next open: its extensions keep hearing the session meanwhile.
    released: Option(runtime.Session),
    /// The composition the runtime prepared without a kernel, for a turn
    /// that starts while the session holds none.
    prepared: Option(runtime.Prepared),
    /// A context read's composition request or rebuild is under way
    /// (albedo-suite).
    composing_context: Bool,
    /// Bumped at each model request and tool call; a rest timer armed under
    /// an older value is stale.
    rest_token: Int,
    home: String,
    self: Subject(message),
    history: Option(List(transcript.Entry)),
    /// No tool call in the transcript lacks its result: known once a turn
    /// ends cleanly, until the next turn starts. While False, admission scans
    /// the transcript for calls a crash cut off.
    results_settled: Bool,
    latest_usage: Option(usage.Metadata),
    /// The total cost of every call that the session made, as the request
    /// ledger totalled it. It belongs to the session and not to a call: it
    /// survives a reload that clears `latest_usage`, and a call that no turn
    /// committed still adds to it. Read it when a run ends.
    spent: Option(types.Cost),
    activity: turn.Activity,
    pending_switch: Option(PendingSwitch),
    history_rewritten: Bool,
    /// a retry resends the request already built, which can still read these.
    shaken: List(String),
    /// Admitted inputs whose receipts the store has not committed yet.
    admitting: Int,
    /// The run ended and its end is being committed; it holds the session
    /// until then.
    finishing: Bool,
    /// Agent close waits for cancellation and durable turn completion.
    pending_agent_close: Option(message),
    active_submissions: List(Submission),
    sequence: Int,
    events: event_buffer.Buffer,
    watchers: List(Watcher),
    /// What the kernel last told the model about itself (restored, lost,
    /// restarted), until a turn reads it; it waits in the inbox meanwhile
    /// (`session_namespace.set_notice`).
    notice: Option(KernelNotice),
    context: context_snapshot.Snapshot,
    pin: loop.Pin,
    /// Inputs evicted by the last prepared projection; the next live reload
    /// starts its pin at this baseline, even if its first turn compacts.
    prepared_head: Option(Int),
    last_touch: Int,
    /// While the kernel boots: boot attempts so far, and the work waiting for
    /// it, re-sent to the actor once the kernel is ready.
    booting: Option(#(Int, List(message))),
    boot_ticket: Option(admission.Ticket),
    boot_token: Int,
    /// Work parked until the previous workspace's kernel is confirmed stopped.
    workspace_reset: Option(List(message)),
    /// A remote workspace readiness probe running outside the actor.
    workspace_probe: Option(String),
    /// A `StartQueued` the actor sent itself and has not handled yet. Reads
    /// answered before it report the session preparing, not idle, so a
    /// client never hears that an input waiting to start is done.
    start_pending: Bool,
    releasing: Option(List(message)),
    checkpointing: Option(List(message)),
    closing: Bool,
    /// What this session answers to new input once it moved to another
    /// daemon (`moves.watch`), or None while it lives here.
    moved: Option(String),
    blocked_until: Int,
    /// Failed kernel startup waits for an explicit retry or workspace move.
    kernel_blocked: Bool,
    /// Why waiting inputs could not start a turn, until `blocked_until`.
    blocking: Option(String),
    safety_halted: Option(SafetyHalt),
    /// A child's failure letter waits briefly for its siblings' before its
    /// turn starts; the session reports itself preparing meanwhile.
    holding_failure: Bool,
    event_hold: Option(#(Int, process.Timer)),
    inbox_changed_during_run: Bool,
    /// People's waiting inputs held while they edit them, by input id, with
    /// the monotonic deadline of each hold. The queue stops at the first held
    /// row, so neither it nor what waits behind it is read until the hold ends.
    held: dict.Dict(String, Int),
    generation: String,
    tool_progress: tool_progress.Projection,
    progress_timer_token: Int,
    progress_timer: Option(process.Timer),
    live_activity: session_activity.Projection,
    announced_status: Option(session_activity.Status),
    /// What the stream last carried about the kernel and the extension
    /// sidebars. A client that keeps them needs no status read, so these are
    /// published only when they differ.
    announced_kernel: Option(view.KernelFacts),
    announced_glances: Option(List(selection.Glance)),
    /// The actor's own messages: ask for the next sidebar read, and report a
    /// kernel the port owner saw change.
    glances_due: message,
    kernel_changed: message,
    /// The pending sidebar timer, armed only while a client watches.
    glance_timer: Option(process.Timer),
    /// Text and thinking deltas held for the end of the frame, newest first,
    /// the timer that publishes them, when output was last published, and
    /// the actor's own message that publishes them.
    pending_output: List(view.Event),
    output_timer: Option(process.Timer),
    output_published_at: Int,
    publish_output: message,
    draft_timer: Option(process.Timer),
    flush_draft: message,
    /// Wraps what goes on after a write `write_then` queued.
    landed: fn(fn(State(message)) -> State(message)) -> message,
    /// Writes `write_then` queued whose `landed` step has not run yet, and
    /// captures waiting to read the store and the stream at one boundary.
    writing: Int,
    captures: List(fn(State(message)) -> Nil),
  )
}

/// Queues `write` on the store's writer and goes on; `landed` takes the
/// session up again with its result once the store has committed it, in the
/// order the writes were queued. Neither closure may capture the state: both
/// cross to the writer's process.
pub fn write_then(
  state: State(message),
  write: fn() -> a,
  landed: fn(State(message), a) -> State(message),
) -> State(message) {
  let #(self, wrap) = #(state.self, state.landed)
  store.query_then(runtime.ledger(state.host), fn(_) { write() }, fn(value) {
    process.send(self, wrap(landed(_, value)))
  })
  State(..state, writing: state.writing + 1)
}

/// Deltas reach a client at most once a frame; a terminal draws no faster.
const frame_ms = 16

/// How long unflushed text deltas wait before writing a recovery draft.
const draft_ms = 1000

/// Streaming clients are woken as each event is published. A text or thinking
/// delta after a quiet frame goes out at once; later ones wait for the frame
/// to end and go out merged. Every other event publishes the waiting deltas
/// first, so the stream keeps its order.
pub fn emit(state: State(message), event: view.Event) -> State(message) {
  case event {
    // Internal worker signals never receive public SSE sequence numbers.
    view.Checkpoint | view.ProviderStarted -> state
    view.Text(..) | view.Thinking(..) -> hold(state, event)
    view.Status(status) ->
      publish(
        State(..flush_output(state), announced_status: Some(status)),
        event,
      )
    _ -> publish(announce(state), event)
  }
}

fn hold(state: State(message), event: view.Event) -> State(message) {
  let event = case event {
    view.Text(run_id, message_id, text) ->
      view.Text(
        run_id,
        active_output.namespace(state.active_output, message_id),
        text,
      )
    view.Thinking(run_id, message_id, text, elapsed) ->
      view.Thinking(
        run_id,
        active_output.namespace(state.active_output, message_id),
        text,
        elapsed,
      )
    _ -> event
  }
  let now = albedo_clock.monotonic_ms()
  case state.pending_output, now - state.output_published_at >= frame_ms {
    [], True -> publish_output(State(..state, output_published_at: now), event)
    pending, _ -> {
      let timer = case state.output_timer {
        Some(timer) -> timer
        None ->
          albedo_clock.send_after(
            state.self,
            int.max(0, state.output_published_at + frame_ms - now),
            state.publish_output,
          )
      }
      State(
        ..state,
        pending_output: [event, ..pending],
        output_timer: Some(timer),
      )
    }
  }
}

/// Publish the deltas held for the frame, consecutive ones of the same kind
/// and message merged. Call it before anything that reads or retires the
/// active output.
pub fn flush_output(state: State(message)) -> State(message) {
  case state.pending_output {
    [] -> state
    pending -> {
      let _ = option.map(state.output_timer, process.cancel_timer)
      let state =
        State(
          ..state,
          pending_output: [],
          output_timer: None,
          output_published_at: albedo_clock.monotonic_ms(),
        )
      list.fold(merge(pending, []), state, publish_output)
    }
  }
}

/// Newest-first deltas, oldest first with neighbours of one message merged.
fn merge(
  newest: List(view.Event),
  merged: List(view.Event),
) -> List(view.Event) {
  case newest, merged {
    [], _ -> merged
    [view.Text(run, id, text), ..rest], [view.Text(r, i, later), ..others]
      if r == run && i == id
    -> merge(rest, [view.Text(run, id, text <> later), ..others])
    [view.Thinking(run, id, text, elapsed), ..rest],
      [view.Thinking(r, i, later, closed), ..others]
      if r == run && i == id
    ->
      merge(rest, [
        view.Thinking(run, id, text <> later, option.or(closed, elapsed)),
        ..others
      ])
    [event, ..rest], _ -> merge(rest, [event, ..merged])
  }
}

fn publish_output(state: State(message), event: view.Event) -> State(message) {
  case event {
    view.Text(run_id, message_id, text) -> {
      let output =
        active_output.observe(
          state.active_output,
          run_id,
          message_id,
          active_output_store.Text,
          text,
          None,
        )
      let state = arm_draft(State(..state, active_output: output))
      list.fold(chunks(text), announce_status(state), fn(state, text) {
        publish(state, view.Text(run_id, message_id, text))
      })
    }
    view.Thinking(run_id, message_id, text, elapsed) -> {
      let output =
        active_output.observe(
          state.active_output,
          run_id,
          message_id,
          active_output_store.Thinking,
          text,
          elapsed,
        )
      let pieces = chunks(text)
      let last = list.length(pieces) - 1
      pieces
      |> list.index_map(fn(text, index) { #(index, text) })
      |> list.fold(
        announce_status(State(..state, active_output: output)),
        fn(state, piece) {
          let #(index, text) = piece
          publish(
            state,
            view.Thinking(run_id, message_id, text, case index == last {
              True -> elapsed
              False -> None
            }),
          )
        },
      )
    }
    _ -> publish(state, event)
  }
}

/// Text in pieces of at most 32768 scalars; one piece when it has no more
/// bytes than that.
fn chunks(text: String) -> List(String) {
  case string.byte_size(text) <= 32_768 {
    True -> [text]
    False -> scalar_chunks(string.to_utf_codepoints(text), []) |> list.reverse
  }
}

fn arm_draft(state: State(message)) -> State(message) {
  case state.draft_timer, active_output.draft_dirty(state.active_output) {
    None, True ->
      State(
        ..state,
        draft_timer: Some(albedo_clock.send_after(
          state.self,
          draft_ms,
          state.flush_draft,
        )),
      )
    _, _ -> state
  }
}

fn scalar_chunks(
  scalars: List(UtfCodepoint),
  acc: List(String),
) -> List(String) {
  case scalars {
    [] -> acc
    _ ->
      scalar_chunks(list.drop(scalars, 32_768), [
        string.from_utf_codepoints(list.take(scalars, 32_768)),
        ..acc
      ])
  }
}

/// A status transition is observed at the same owner boundary as the event
/// that caused it. Repeated deltas do not allocate repeated status events.
pub fn announce(state: State(message)) -> State(message) {
  announce_status(flush_output(state))
}

/// What waits in the session's inbox, or its order, changed: a client showing
/// the queue reads it again (`queue.url`).
pub fn queue_changed(state: State(message)) -> State(message) {
  publish(state, view.Invalidate(view.StaleExtension, queue.url(state.info.id)))
}

fn announce_status(state: State(message)) -> State(message) {
  let status = current_status(state)
  case state.announced_status {
    Some(previous) if previous == status -> state
    _ ->
      publish(
        State(..state, announced_status: Some(status)),
        view.Status(status),
      )
  }
}

/// The kernel's facts changed: a job started or ended, or the kernel itself
/// attached, booted, or went stale. A client keeps its job count from this, so
/// it is published once per change and never on a timer.
pub fn announce_kernel(
  state: State(message),
  facts: view.KernelFacts,
) -> State(message) {
  case state.announced_kernel {
    Some(previous) if previous == facts -> state
    _ ->
      publish(State(..state, announced_kernel: Some(facts)), view.Kernel(facts))
  }
}

/// The extension sidebars changed; published once per change.
pub fn announce_glances(
  state: State(message),
  glances: List(selection.Glance),
) -> State(message) {
  case state.announced_glances {
    Some(previous) if previous == glances -> state
    _ ->
      publish(
        State(..state, announced_glances: Some(glances)),
        view.Glances(glances),
      )
  }
}

/// Another session's work, a vent, or a scheduled prompt changes a sidebar
/// with no event here to hang off, so a watching session re-reads them at this
/// pace. Nobody watching means nobody asks.
pub const glance_ms = 10_000

/// Keep asking for sidebar reads while a client watches the stream. A timer
/// already pending is left alone: a stream acknowledges every frame it
/// delivers, and rearming here would push the read past every keepalive.
pub fn watch_glances(state: State(message)) -> State(message) {
  case state.watchers, state.glance_timer {
    [], _ -> unwatch_glances(state)
    [_, ..], None ->
      State(
        ..state,
        glance_timer: Some(albedo_clock.send_after(
          state.self,
          glance_ms,
          state.glances_due,
        )),
      )
    [_, ..], Some(_) -> state
  }
}

/// The timer fired: the read that follows arms the next one.
pub fn glance_fired(state: State(message)) -> State(message) {
  State(..state, glance_timer: None)
}

/// The last client left: the session stops reading what nobody shows.
pub fn unwatch_glances(state: State(message)) -> State(message) {
  case state.glance_timer {
    None -> state
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      State(..state, glance_timer: None)
    }
  }
}

/// Whether automatic mail/job wakes are paused after a content/safety refusal
/// on the current provider, model, and cyber-access tier.
pub fn halted_for_safety(state: State(message)) -> Bool {
  case state.safety_halted {
    Some(halt) ->
      halt.provider == state.info.provider
      && halt.model == state.info.model
      && halt.cyber_access == state.info.cyber_access
    None -> False
  }
}

/// A zero deadline means no retry wait, even when monotonic time is negative.
pub fn retry_pending(deadline: Int, monotonic_now: Int) -> Bool {
  deadline != 0 && monotonic_now < deadline
}

pub fn current_status(state: State(message)) -> session_activity.Status {
  let blocking = case
    state.kernel_blocked
    || retry_pending(state.blocked_until, albedo_clock.monotonic_ms())
  {
    True -> state.blocking
    False -> None
  }
  session_activity.status(
    state.activity,
    state.booting != None
      || state.workspace_reset != None
      || state.holding_failure
      || state.event_hold != None
      || state.start_pending,
    blocking,
  )
}

fn publish(state: State(message), event: view.Event) -> State(message) {
  let seq = state.sequence + 1
  let encoded = view.encode(state.info.id, seq, event)
  let events = event_buffer.push(state.events, seq, encoded)
  let watchers =
    list.map(state.watchers, fn(watcher) {
      case watcher.notified {
        True -> watcher
        False -> {
          watcher.notify()
          Watcher(..watcher, notified: True)
        }
      }
    })
  let observed = view.observe(state.live_activity, event, usage.now())
  let committed_mail = case event {
    view.Input(outcome, _) ->
      outcome.receipt.delivery == Some(operations.Committed)
    view.Message(entry, _) -> entry.letter != None
    _ -> False
  }
  let observed = case committed_mail {
    True -> {
      let request =
        store.snapshot(runtime.ledger(state.host), fn(db) {
          mail.parent_request_in(db, state.info.id)
        })
      case request {
        Ok(request) -> session_activity.request(observed, request)
        Error(_) -> observed
      }
    }
    False -> observed
  }
  bus.activity(state.info.id, fn() {
    json.object([
      #("type", json.string("activity")),
      #(
        "data",
        json.object([
          #("session_id", json.string(state.info.id)),
          #(
            "cursor",
            json.object([
              #("generation", json.string(state.generation)),
              #("sequence", json.int(seq)),
            ]),
          ),
          #("status", view.status(current_status(state))),
          #(
            "current_progress",
            json.array(
              tool_progress.snapshots(state.tool_progress),
              view.progress,
            ),
          ),
          #("activity", view.activity(observed)),
        ]),
      ),
    ])
    |> json.to_string
  })
  State(
    ..state,
    sequence: seq,
    events: events,
    watchers: watchers,
    live_activity: observed,
  )
}

pub fn invalidate(
  state: State(message),
  kind: view.InvalidateKind,
  url: String,
) -> State(message) {
  emit(state, view.Invalidate(kind, url))
}

pub fn unprepared() -> context_snapshot.Snapshot {
  context_snapshot.pending(
    "runtime session has not prepared a provider request",
  )
}

/// What a turn composes from: the held kernel's, else the released one's,
/// else one prepared without a kernel, each only for the current workspace.
pub fn composition(state: State(message)) -> Option(runtime.Prepared) {
  let current = fn(prepared: runtime.Prepared) {
    case prepared.cwd == state.info.cwd {
      True -> Some(prepared)
      False -> None
    }
  }
  case state.kernel, state.released {
    Some(kernel), _ | None, Some(kernel) -> current(runtime.prepared(kernel))
    None, None -> option.then(state.prepared, current)
  }
}
