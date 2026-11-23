//// Session status against a model of the documented phases and blocking rule.
//// A client reads a status from the live stream and from the status resource;
//// the phase must follow the activity and the boot, workspace and failure
//// holds, and a blocking reason must appear exactly while the session is
//// blocked, whether the block is the kernel's (sticky, albedo-suite) or the
//// 15 s retry wait. Generated event sequences are applied to a reference
//// model and replayed through the real state functions.

import albedo/model_loop/loop
import albedo/observation/active_output
import albedo/observation/event_buffer
import albedo/observation/events as view
import albedo/observation/tool_progress
import albedo/runtime
import albedo/session/session_activity
import albedo/session/session_state
import albedo/session/turn
import albedo_clock
import albedo_model as types
import albedo_sdk/compaction
import albedo_sdk/session_info
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import proptest
import qcheck

const run_id = "run-fixture"

const kernel_error =
  "could not start the session python kernel: the kernel exited while starting"

const retry_error = "waiting inputs are blocked: provider refused"

/// The retry wait a `RetryBlocks` event arms: long enough that no run can
/// outlast it, and far from its boundary.
const retry_ms = 600_000

pub type Work {
  TurnWork
  CompactionWork
  BackgroundWork
  SummaryWork
}

pub type RunModel {
  RunModel(
    cancelled: Bool,
    work: Work,
    stage: Option(session_info.Stage),
    compaction: Bool,
  )
}

/// The fields `current_status` may read: the activity in outline, the three
/// holds that make the session prepare, and the block.
pub type Model {
  Model(
    run: Option(RunModel),
    booting: Bool,
    workspace_reset: Bool,
    holding_failure: Bool,
    kernel_blocked: Bool,
    blocking: Option(String),
    retry_ms: Int,
    composing: Bool,
  )
}

pub type Event {
  TurnStart
  TurnStageModel
  TurnStageTool
  TurnEnd
  Interrupt
  CompactionBegins
  BackgroundStarts
  SummaryStarts
  CompactionStarts
  KernelBlocks
  KernelUnblocks
  RetryBlocks
  RetryExpires
  BlocksCleared
  BootStarts
  BootEnds
  ResetStarts
  ResetEnds
  FailureHeld
  FailureReleased
  ContextReadStarts
  ContextReadEnds
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn event() -> qcheck.Generator(Event) {
  qcheck.from_weighted_generators(#(6, pick([TurnStart, TurnEnd, TurnEnd])), [
    #(1, pick([TurnStageModel, TurnStageTool])),
    #(2, pick([Interrupt, CompactionBegins])),
    #(1, pick([BackgroundStarts, SummaryStarts, CompactionStarts])),
    #(2, pick([KernelBlocks, KernelUnblocks, RetryBlocks, RetryExpires])),
    #(1, pick([BlocksCleared, BootStarts, BootEnds, ResetStarts, ResetEnds])),
    #(1, pick([FailureHeld, FailureReleased])),
    #(1, pick([ContextReadStarts, ContextReadEnds])),
  ])
}

fn history() -> qcheck.Generator(List(Event)) {
  qcheck.generic_list(event(), qcheck.bounded_int(0, 14))
}

fn initial() -> Model {
  Model(
    run: None,
    booting: False,
    workspace_reset: False,
    holding_failure: False,
    kernel_blocked: False,
    blocking: None,
    retry_ms: 0,
    composing: False,
  )
}

/// A run started by the session, with nothing known about its work yet.
fn fresh(work: Work) -> RunModel {
  RunModel(cancelled: False, work: work, stage: None, compaction: False)
}

fn skip(model: Model) -> Model {
  proptest.bump("skipped")
  model
}

fn apply(model: Model, event: Event) -> Model {
  case event {
    TurnStart ->
      case model.run {
        None -> Model(..model, run: Some(fresh(TurnWork)))
        Some(_) -> skip(model)
      }
    TurnStageModel ->
      case model.run {
        Some(run) ->
          Model(
            ..model,
            run: Some(RunModel(..run, stage: Some(session_info.Model))),
          )
        None -> skip(model)
      }
    TurnStageTool ->
      case model.run {
        Some(run) ->
          Model(
            ..model,
            run: Some(RunModel(..run, stage: Some(session_info.Tool))),
          )
        None -> skip(model)
      }
    TurnEnd ->
      case model.run {
        Some(_) -> Model(..model, run: None)
        None -> skip(model)
      }
    Interrupt ->
      case model.run {
        Some(run) -> Model(..model, run: Some(RunModel(..run, cancelled: True)))
        None -> skip(model)
      }
    CompactionBegins ->
      case model.run {
        Some(run) ->
          Model(..model, run: Some(RunModel(..run, compaction: True)))
        None -> skip(model)
      }
    BackgroundStarts ->
      case model.run {
        None -> Model(..model, run: Some(fresh(BackgroundWork)))
        Some(_) -> skip(model)
      }
    SummaryStarts ->
      case model.run {
        None -> Model(..model, run: Some(fresh(SummaryWork)))
        Some(_) -> skip(model)
      }
    CompactionStarts ->
      case model.run {
        None -> Model(..model, run: Some(fresh(CompactionWork)))
        Some(_) -> skip(model)
      }
    // A failed boot or a failed workspace probe blocks for good: no retry
    // timer, until a person acts or the workspace moves.
    KernelBlocks ->
      Model(
        ..model,
        kernel_blocked: True,
        retry_ms: 0,
        blocking: Some(kernel_error),
      )
    // The person acts again: the sticky block lifts and the reason stays
    // until the next block replaces it.
    KernelUnblocks -> Model(..model, kernel_blocked: False)
    // A 15 s retry wait: not sticky, and it overwrites the reason.
    RetryBlocks ->
      Model(
        ..model,
        kernel_blocked: False,
        retry_ms: retry_ms,
        blocking: Some(retry_error),
      )
    RetryExpires -> Model(..model, retry_ms: 0)
    // A workspace move or a cleared block forgets the block and its reason.
    BlocksCleared ->
      Model(..model, kernel_blocked: False, retry_ms: 0, blocking: None)
    BootStarts -> Model(..model, booting: True)
    BootEnds -> Model(..model, booting: False)
    ResetStarts -> Model(..model, workspace_reset: True)
    ResetEnds -> Model(..model, workspace_reset: False)
    FailureHeld -> Model(..model, holding_failure: True)
    FailureReleased -> Model(..model, holding_failure: False)
    ContextReadStarts -> Model(..model, composing: True)
    ContextReadEnds -> Model(..model, composing: False)
  }
}

fn replay(events: List(Event)) -> Model {
  list.fold(events, initial(), apply)
}

/// The run the model describes, built as the actor would hold it.
fn run_of(run: RunModel) -> turn.Run {
  let work = case run.work {
    TurnWork -> turn.Turn(run.stage)
    CompactionWork -> turn.Compaction(None, process.new_subject(), report())
    BackgroundWork -> turn.Background(process.new_subject())
    SummaryWork -> turn.Summary(None, 0, process.new_subject())
  }
  turn.Run(
    id: run_id,
    pid: process.self(),
    monitor: process.monitor(process.self()),
    cancelled: run.cancelled,
    stop: turn.latch(),
    work: work,
    started: None,
    cut_off: [],
    opened: True,
    compaction: case run.compaction {
      True ->
        Some(compaction.Progress(
          strategy: "hierarchical",
          stage: compaction.Preparing,
          completed: 0,
          total: None,
          active: 0,
          started_at: 0,
        ))
      False -> None
    },
  )
}

fn report() -> turn.CompactionReport {
  turn.CompactionReport(
    selection_applied: False,
    effective_strategy: None,
    state: "idle",
    observation: None,
    failure: None,
  )
}

fn with_run(
  base: session_state.State(Nil),
  model: Model,
  now: Int,
) -> session_state.State(Nil) {
  session_state.State(
    ..base,
    activity: case model.run {
      Some(run) -> turn.Running(run_of(run))
      None -> turn.Resting
    },
    booting: case model.booting {
      True -> Some(#(1, []))
      False -> None
    },
    workspace_reset: case model.workspace_reset {
      True -> Some([])
      False -> None
    },
    holding_failure: model.holding_failure,
    kernel_blocked: model.kernel_blocked,
    blocking: model.blocking,
    blocked_until: case model.retry_ms {
      0 -> 0
      ms -> now + ms
    },
    composing_context: model.composing,
  )
}

/// The session is blocked while the kernel is blocked or its retry wait has
/// not run out. The model keeps waits far from their deadline, so the wall
/// clock cannot move either way during a case.
fn blocked(model: Model) -> Bool {
  model.kernel_blocked || model.retry_ms != 0
}

fn expected_phase(model: Model) -> String {
  case model.run {
    None ->
      case model.booting || model.workspace_reset || model.holding_failure {
        True -> "preparing"
        False -> "idle"
      }
    Some(run) ->
      case run.cancelled, run.compaction, run.work {
        True, _, _ -> "interrupting"
        False, True, _ -> "compacting"
        False, False, CompactionWork -> "compacting"
        False, False, BackgroundWork -> "generating"
        False, False, SummaryWork -> "generating"
        False, False, TurnWork ->
          case run.stage {
            Some(session_info.Tool) -> "running"
            Some(_) -> "generating"
            None -> "preparing"
          }
      }
  }
}

/// What a status tells a client: phase spelling, run, interrupt flag,
/// blocking reason, and whether a compaction is under way.
pub type Summary {
  Summary(
    phase: String,
    run_id: Option(String),
    interrupt_requested: Bool,
    blocking_reason: Option(String),
    compacting: Bool,
  )
}

fn summarize(status: session_activity.Status) -> Summary {
  Summary(
    phase: session_activity.phase_name(status.phase),
    run_id: status.run_id,
    interrupt_requested: status.interrupt_requested,
    blocking_reason: status.blocking_reason,
    compacting: case status.compaction {
      Some(_) -> True
      None -> False
    },
  )
}

fn model_summary(model: Model) -> Summary {
  Summary(
    phase: expected_phase(model),
    run_id: case model.run {
      Some(_) -> Some(run_id)
      None -> None
    },
    interrupt_requested: case model.run {
      Some(run) -> run.cancelled
      None -> False
    },
    blocking_reason: case blocked(model) {
      True -> model.blocking
      False -> None
    },
    compacting: case model.run {
      Some(run) -> run.compaction
      None -> False
    },
  )
}

/// A base state with nothing set: the fields status never reads are the
/// fixture's, and every case rebuilds them.
fn base_state(home: String, host: runtime.Runtime) -> session_state.State(Nil) {
  let info =
    session_info.Info(
      "fixture",
      "fixture",
      home,
      "fixture",
      "fixture-model",
      types.ChatCompletions,
      session_info.Idle,
      None,
      None,
      False,
      None,
    )
  session_state.State(
    title_job: None,
    title_revision: 0,
    active_output: active_output.new(home, info.id, "fixture"),
    side_question: None,
    shell_commands: [],
    shell_worker: None,
    info: info,
    acp: False,
    host: host,
    kernel: None,
    released: None,
    prepared: None,
    composing_context: False,
    rest_token: 0,
    home: home,
    self: process.new_subject(),
    history: None,
    results_settled: False,
    latest_usage: None,
    spent: None,
    activity: turn.Resting,
    pending_switch: None,
    history_rewritten: False,
    shaken: [],
    admitting: 0,
    finishing: False,
    pending_agent_close: None,
    active_submissions: [],
    sequence: 0,
    events: event_buffer.new(),
    watchers: [],
    notice: None,
    context: session_state.unprepared(),
    pin: loop.Unpinned,
    prepared_head: None,
    last_touch: 0,
    booting: None,
    boot_ticket: None,
    boot_token: 0,
    workspace_reset: None,
    workspace_probe: None,
    start_pending: False,
    releasing: None,
    checkpointing: None,
    closing: False,
    moved: None,
    blocked_until: 0,
    kernel_blocked: False,
    blocking: None,
    holding_failure: False,
    held: dict.new(),
    generation: "fixture",
    tool_progress: tool_progress.new(),
    progress_timer_token: 0,
    progress_timer: None,
    live_activity: session_activity.new(0),
    announced_status: None,
    announced_kernel: None,
    announced_glances: None,
    glances_due: Nil,
    kernel_changed: Nil,
    glance_timer: None,
    pending_output: [],
    output_timer: None,
    output_published_at: 0,
    publish_output: Nil,
    draft_timer: None,
    flush_draft: Nil,
    landed: fn(_) { Nil },
    writing: 0,
    captures: [],
  )
}

/// The status document as a client reads it.
pub type Document {
  Document(
    phase: String,
    run_id: Option(String),
    interrupt_requested: Bool,
    reason: Option(Reason),
    compaction: Option(Progress),
  )
}

pub type Reason {
  Reason(code: String, detail: String)
}

pub type Progress {
  Progress(strategy: String, stage: String, completed: Int, active: Int)
}

fn reason_decoder() -> decode.Decoder(Reason) {
  use code <- decode.field("code", decode.string)
  use detail <- decode.field("detail", decode.string)
  decode.success(Reason(code, detail))
}

fn progress_decoder() -> decode.Decoder(Progress) {
  use strategy <- decode.field("strategy", decode.string)
  use stage <- decode.field("stage", decode.string)
  use completed <- decode.field("completed", decode.int)
  use active <- decode.field("active", decode.int)
  decode.success(Progress(strategy, stage, completed, active))
}

fn document_decoder() -> decode.Decoder(Document) {
  use phase <- decode.field("phase", decode.string)
  use run_id <- decode.field("run_id", decode.optional(decode.string))
  use interrupt_requested <- decode.field("interrupt_requested", decode.bool)
  use reason <- decode.field(
    "blocking_reason",
    decode.optional(reason_decoder()),
  )
  use compaction <- decode.field(
    "compaction",
    decode.optional(progress_decoder()),
  )
  decode.success(Document(
    phase,
    run_id,
    interrupt_requested,
    reason,
    compaction,
  ))
}

fn decode_document(status: session_activity.Status) -> Document {
  case json.parse(json.to_string(view.status(status)), document_decoder()) {
    Ok(document) -> document
    Error(_) -> panic as { "the status document does not decode" }
  }
}

/// The status a session reports for a case.
fn status_of(
  base: session_state.State(Nil),
  model: Model,
  now: Int,
) -> session_activity.Status {
  session_state.current_status(with_run(base, model, now))
}

fn expect(label: String, found: a, expected: a) -> Nil {
  case found == expected {
    True -> Nil
    False ->
      panic as {
        label
        <> ": expected "
        <> string.inspect(expected)
        <> ", found "
        <> string.inspect(found)
      }
  }
}

pub fn main() -> Nil {
  let home =
    "/tmp/albedo-proptest-session-status-" <> int.to_string(proptest.unique())
  proptest.write_file(home <> "/.keep", <<>>, 0)
  let assert Ok(host) = runtime.start_with_extensions(home <> "/fixture.db", [])
  let base = base_state(home, host)

  proptest.check("status matches the model", 200, history(), fn(events) {
    let model = replay(events)
    let found = summarize(status_of(base, model, albedo_clock.monotonic_ms()))
    let expected = model_summary(model)
    proptest.bump(found.phase)
    expect(
      "status differs from the model: " <> string.inspect(events),
      found,
      expected,
    )
  })

  proptest.check(
    "status invariants hold for every history",
    200,
    history(),
    fn(events) {
      let model = replay(events)
      let status = status_of(base, model, albedo_clock.monotonic_ms())
      let phase = session_activity.phase_name(status.phase)
      let holds =
        model.booting || model.workspace_reset || model.holding_failure
      // Idle means the session has nothing to do: no run and no hold.
      case phase, model.run, holds {
        "idle", None, False -> Nil
        "idle", _, _ ->
          panic as { "idle while busy: " <> string.inspect(events) }
        "preparing", None, True -> Nil
        "preparing", Some(RunModel(work: TurnWork, stage: None, ..)), _ -> Nil
        "preparing", _, _ ->
          panic as { "preparing without a reason: " <> string.inspect(events) }
        _, None, _ ->
          panic as { "a phase without a run: " <> string.inspect(events) }
        _, Some(_), _ -> Nil
      }
      // Only a running session names its run, and only a cancelled one asks
      // for an interrupt.
      case status.run_id, model.run {
        Some(id), Some(_) ->
          expect("unexpected run id: " <> string.inspect(events), id, run_id)
        None, None -> Nil
        None, Some(_) ->
          panic as {
            "a running session named no run: " <> string.inspect(events)
          }
        Some(_), None ->
          panic as {
            "a resting session named a run: " <> string.inspect(events)
          }
      }
      case status.interrupt_requested, phase {
        True, "interrupting" | False, "interrupting" -> Nil
        True, other ->
          panic as {
            "interrupt requested while "
            <> other
            <> ": "
            <> string.inspect(events)
          }
        False, _ -> Nil
      }
      // A client that reads no blocking reason must be able to start a turn,
      // and a blocked session that knows why must say it.
      case status.blocking_reason, blocked(model) {
        None, False -> Nil
        None, True ->
          case model.blocking {
            None -> proptest.bump("blocked_without_reason")
            Some(_) ->
              panic as { "a block lost its reason: " <> string.inspect(events) }
          }
        Some(_), True -> proptest.bump("blocked")
        Some(_), False ->
          panic as { "a reason without a block: " <> string.inspect(events) }
      }
      Nil
    },
  )

  proptest.check(
    "unblocking restores the status the session had before",
    200,
    history(),
    fn(events) {
      // Start from a session that is not blocked, whatever the history left.
      let before =
        list.fold(events, initial(), apply)
        |> fn(model) { Model(..model, retry_ms: 0, kernel_blocked: False) }
      let now = albedo_clock.monotonic_ms()
      // Block it the way a failed boot does, then unblock it the way a
      // person's next message does.
      let blocked_model = apply(before, KernelBlocks)
      let after = apply(blocked_model, KernelUnblocks)
      let before_status = summarize(status_of(base, before, now))
      let blocked_status = summarize(status_of(base, blocked_model, now))
      let after_status = summarize(status_of(base, after, now))
      proptest.bump("unblock")
      // The block shows up as a reason and nothing else.
      expect(
        "blocking changed more than the reason: " <> string.inspect(events),
        blocked_status,
        Summary(..before_status, blocking_reason: Some(kernel_error)),
      )
      expect(
        "unblocking did not restore the status: " <> string.inspect(events),
        after_status,
        before_status,
      )
    },
  )

  proptest.check(
    "a context read in flight leaves the status unchanged",
    100,
    history(),
    fn(events) {
      let model = replay(events)
      let now = albedo_clock.monotonic_ms()
      proptest.bump("context_read")
      expect(
        "a context read changed the status: " <> string.inspect(events),
        summarize(status_of(base, Model(..model, composing: True), now)),
        summarize(status_of(base, model, now)),
      )
    },
  )

  proptest.check(
    "fields the status does not read never change it",
    100,
    history(),
    fn(events) {
      let model = replay(events)
      let now = albedo_clock.monotonic_ms()
      let state = with_run(base, model, now)
      let idle =
        session_activity.Status(session_activity.Idle, None, False, None, None)
      let noisy =
        session_state.State(
          ..state,
          title_revision: 7,
          rest_token: 3,
          boot_token: 1,
          sequence: 9,
          admitting: 2,
          writing: 1,
          results_settled: True,
          acp: True,
          generation: "other",
          last_touch: 99,
          prepared_head: Some(3),
          closing: True,
          moved: Some("elsewhere"),
          finishing: True,
          announced_status: Some(idle),
          live_activity: session_activity.new(1234),
          held: dict.from_list([#("input", 1)]),
          progress_timer_token: 5,
          output_published_at: 4,
        )
      proptest.bump("noisy")
      expect(
        "an unrelated field changed the status: " <> string.inspect(events),
        summarize(session_state.current_status(noisy)),
        summarize(session_state.current_status(state)),
      )
    },
  )

  proptest.check(
    "the status document carries the documented fields",
    200,
    history(),
    fn(events) {
      let model = replay(events)
      let status = status_of(base, model, albedo_clock.monotonic_ms())
      let document = decode_document(status)
      let expected = model_summary(model)
      let phases = [
        "idle",
        "preparing",
        "interrupting",
        "compacting",
        "generating",
        "running",
      ]
      proptest.bump("document_" <> document.phase)
      case list.contains(phases, document.phase) {
        True -> Nil
        False ->
          panic as {
            "undocumented phase in the status document: " <> document.phase
          }
      }
      expect(
        "the document differs from the status: " <> string.inspect(events),
        #(document.phase, document.run_id, document.interrupt_requested),
        #(expected.phase, expected.run_id, expected.interrupt_requested),
      )
      case document.reason, expected.blocking_reason {
        None, None -> Nil
        Some(Reason(code, detail)), Some(reason) ->
          expect(
            "the blocking reason differs: " <> string.inspect(events),
            #(code, detail),
            #("inputs_blocked", reason),
          )
        _, _ ->
          panic as {
            "the blocking reason presence differs: " <> string.inspect(events)
          }
      }
      case document.compaction, expected.compacting {
        Some(_), True | None, False -> Nil
        _, _ ->
          panic as {
            "the compaction window differs: " <> string.inspect(events)
          }
      }
    },
  )

  proptest.check(
    "retry_pending holds at its boundary",
    1,
    qcheck.return(Nil),
    fn(_) {
      // A zero deadline means no wait at all, even when monotonic time is
      // negative; otherwise the wait lasts until the deadline.
      list.each([-2, -1, 0, 1, 2], fn(deadline) {
        list.each([-2, -1, 0, 1, 2], fn(now) {
          let expected = deadline != 0 && now < deadline
          proptest.bump(case expected {
            True -> "pending"
            False -> "past"
          })
          expect(
            "retry_pending("
              <> int.to_string(deadline)
              <> ", "
              <> int.to_string(now)
              <> ")",
            session_state.retry_pending(deadline, now),
            expected,
          )
        })
      })
      let assert True =
        session_state.retry_pending(
          1_000_000_000_000,
          albedo_clock.monotonic_ms(),
        )
      Nil
    },
  )

  runtime.stop(host)
  proptest.remove_tree(home)
}
