//// One coordinator per session. Workers own model/tool loops; clients never own workers.

import albedo/lifecycle/lifecycle
import albedo/workspace/locations
import albedo_sdk/accounts as account_pools
import albedo_sdk/family as families
import albedo_sdk/hosts
import albedo_sdk/input
import albedo_sdk/letter as mail_value
import albedo_sdk/session_control as agents
import albedo_sdk/session_info

import albedo_clock
import albedo_process/actor_call
import albedo_sqlite

import albedo/acp/acp
import albedo/acp/acp_attachments
import albedo/acp/acp_session
import albedo/commands/shell_commands
import albedo/composition/selection
import albedo/history/conversation
import albedo/history/history
import albedo/http/http_history
import albedo/kernel as python
import albedo/kernel/link
import albedo/model_loop/loop
import albedo/observation/active_output
import albedo/observation/bus
import albedo/observation/context_snapshot
import albedo/observation/event_buffer
import albedo/observation/events as view
import albedo/observation/tool_progress as tool_progress_state
import albedo/refusal.{type Refusal}
import albedo/runtime
import albedo/runtime/catalog as session_catalog
import albedo/runtime/state as runtime_state
import albedo/session/child_failure
import albedo/session/command_state
import albedo/session/compaction_action
import albedo/session/family
import albedo/session/inbox
import albedo/session/session/creation as session_creation
import albedo/session/session_activity
import albedo/session/session_configuration
import albedo/session/session_configure
import albedo/session/session_control
import albedo/session/session_extensions
import albedo/session/session_history
import albedo/session/session_last_call
import albedo/session/session_namespace
import albedo/session/session_naming
import albedo/session/session_prompt
import albedo/session/session_provider
import albedo/session/session_run
import albedo/session/session_salvage
import albedo/session/session_side_question
import albedo/session/session_state
import albedo/session/session_submission
import albedo/session/session_switch
import albedo/session/session_workspace
import albedo/session/side_question
import albedo/session/turn.{type Submission, Submission}
import albedo/storage/active_output_store
import albedo/storage/images
import albedo/storage/mail
import albedo/storage/operations
import albedo/storage/requests
import albedo/transfer/moves
import albedo/usage/cache_fade
import albedo/usage/session_cost
import albedo/usage/usage
import albedo/workspace/ssh
import albedo_model as types
import albedo_model/size
import albedo_process
import albedo_process/registry.{type Registry}
import albedo_protect
import albedo_sdk/auth_accounts
import albedo_sdk/command
import albedo_sdk/compaction
import albedo_sdk/extension
import albedo_sdk/history as stored_history
import albedo_sdk/location
import albedo_sdk/storage
import albedo_sdk/store
import albedo_sdk/transcript
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

/// What a turn resumed after a daemon restart tells the model, and the
/// transcript's marker for the restart.
const restart_text =
  "albedo restarted while this turn was running. Tool calls that were in flight are marked interrupted with an unknown outcome; check their effects before retrying anything, then continue the task."

fn restart_note() -> Submission {
  Submission(
    restart_text,
    restart_text,
    "daemon",
    turn.Note("daemon restart"),
    [],
    Some(mail.new_id()),
    None,
    None,
    [],
    None,
  )
}

const continue_prompt =
  "<system-notice>
continue your unfinished task, by resuming the most recent intent.
if interrupted mid-step, just pick it back up from where it stopped.
never pause to summarize progress, re-confirm the plan, or ask whether to proceed.
just continue.
</system-notice>"

pub type Session =
  Subject(Message)

/// A replay position belongs to exactly one session actor lifetime.
pub type Cursor {
  Cursor(generation: String, sequence: Int)
}

pub type Page {
  Page(cursor: Cursor, events: List(json.Json), snapshot: Option(Capture))
}

pub type Capture {
  Capture(
    info: conversation.Info,
    cursor: Cursor,
    status: session_activity.Status,
    pending_inputs: List(operations.Pending),
    input_order: Int,
    current_progress: List(tool_progress_state.Snapshot),
    history_high_water: Int,
    usage: Option(usage.Metadata),
    spent: Option(types.Cost),
    kernel: session_namespace.KernelObservation,
    activity: session_activity.Projection,
    created_at: Option(Int),
    activity_at: Option(Int),
    revision: Int,
    family: family.Facts,
    continuation_high_water: Int,
    automatic_name: String,
    configuration: session_configuration.Configuration,
    composition: runtime.CompositionObservation,
    workspace_change: Option(session_workspace.Pending),
    preview: conversation.Preview,
    active_output: List(active_output.Snapshot),
    side_question: Option(side_question.Exchange),
    shell_commands: List(shell_commands.Command),
  )
}

pub type Summary {
  Summary(
    cursor: Cursor,
    status: session_activity.Status,
    current_progress: List(tool_progress_state.Snapshot),
    activity: session_activity.Projection,
    usage: Option(usage.Metadata),
    spent: Option(types.Cost),
  )
}

/// The live facts a watching client keeps current: no configuration, no
/// history, and no composition read once the stream has published the
/// sidebars. What `GET /sessions/{id}/status` answers.
pub type StatusRead {
  StatusRead(
    id: String,
    cursor: Cursor,
    status: session_activity.Status,
    kernel: session_namespace.KernelObservation,
    usage: Option(usage.Metadata),
    spent: Option(types.Cost),
    cost_usd: Option(Float),
    glances: Option(List(selection.Glance)),
  )
}

pub type InputCancellation {
  Cancelled
  InterruptRequested
  SharedRunning
  NotPending
}

pub type Interruption {
  Interruption(
    run_id: Option(String),
    requested: Bool,
    cancelled_input_ids: List(String),
  )
}

/// What `/kernel restart` stopped: the kernel the session held (None when it
/// held none), its background jobs, and the cells that were still running.
pub type KernelRestart {
  KernelRestart(
    old_kernel_id: Option(String),
    stopped_jobs: List(String),
    ended_cells: List(String),
  )
}

/// What a sweep needs to decide whether this session's kernel can be released.
pub type Report {
  Report(
    running: Bool,
    kernel: Option(Int),
    history_loaded: Bool,
    idle_ms: Int,
    jobs: Int,
  )
}

pub type ModelSelection {
  ModelSelection(
    provider: String,
    model: String,
    protocol: types.Protocol,
    effort: Option(String),
  )
}

/// Why waiting inputs could not start a turn.
pub type SubmissionError {
  WorkspaceMissing(String)
  Rejected(String)
}

pub fn submission_error(error: SubmissionError) -> String {
  case error {
    WorkspaceMissing(path) -> "workspace not found: " <> path
    Rejected(message) -> message
  }
}

pub type Message {
  StartShell(String, String, Subject(Result(shell_commands.Command, Refusal)))
  StopShell(String, Subject(Result(shell_commands.Command, Refusal)))
  ShellChanged(shell_commands.Command, Subject(Nil))
  ShellEnded(
    String,
    shell_commands.Status,
    Option(Int),
    Option(String),
    Subject(Result(Nil, String)),
  )
  FlushAttached
  Resume
  /// An idle session started after a daemon restart because it waits on
  /// work that will wake it: its extensions hear its last turn call again.
  Rewarm
  /// Saved profiles were renamed, old name first.
  RenameProfiles(List(#(String, String)))
  ReadCapture(Subject(Result(Unobserved, Refusal)))
  CaptureIn(Option(sqlight.Connection), Subject(Result(Unobserved, Refusal)))
  ReadSummary(Subject(Summary))
  /// The live facts alone, for a client that keeps its history over the stream.
  ReadStatus(Subject(fn() -> Result(StatusRead, String)))
  /// The kernel's port owner saw its job facts change.
  KernelJobs
  /// A watching client is due a read of the extension sidebars.
  GlancesDue
  GlancesObserved(Result(runtime.CompositionObservation, String))
  /// See `extension.Session.awaited`.
  ReadAwaited(Subject(fn() -> Bool))
  /// The kernel handle, for a read that must wait on it outside the actor.
  ReadKernel(Subject(Option(python.Kernel)))
  /// A commit stored or withdrew a row in this session's inbox
  /// (`mail.register`): clients reread the queue, and a resting session
  /// starts a turn if a waiting row starts one.
  InboxChanged
  /// A move of this session finished; the words name where it went.
  MovedAway(String)
  SwitchModel(String, String, String, Subject(Result(Bool, String)))
  RequestBoundary(String, Subject(Result(Option(loop.Selection), String)))
  ChangeConfiguration(
    session_configuration.Version,
    session_configuration.Patch,
    Option(acp.Digest),
    Subject(Result(Unobserved, Refusal)),
  )
  InterruptCaptured(Option(String), Int, Subject(Result(Interruption, String)))
  Abort(String)
  DropQueued(List(String), Subject(Result(List(String), String)))
  ArrangeQueue(List(String), Subject(Result(Nil, String)))
  /// Hold a person's waiting message while they edit it, or renew the hold.
  HoldInput(String, Subject(Result(Nil, Refusal)))
  /// The hold on this input reached this deadline without a renewal.
  HoldLapsed(String, Int)
  ReleaseInput(String, Subject(Nil))
  /// Let the running turn end without user-facing output (`turn.quiet`).
  QuietTurn(Subject(Result(Nil, String)))
  /// Put an edited message in place of the waiting one under its id.
  EditInput(Submission, Subject(Result(Nil, Refusal)))
  /// A person's command-routed turn reached the inbox. It is the person acting
  /// again, so it clears a workspace block that mail, job wakes and notes wait out.
  UserTurnQueued
  CancelInput(
    String,
    Option(acp.Digest),
    Subject(Result(InputCancellation, Refusal)),
  )
  ReadCommands(
    Subject(
      Result(#(List(command.Command(command.Context)), command.Context), String),
    ),
  )
  ReadSelection(Subject(ModelSelection))
  ChangeWorkspace(
    session_workspace.Request,
    Subject(Result(session_workspace.Recorded, session_workspace.ChangeFailure)),
  )
  ApplyWorkspace(Subject(Result(Bool, String)))
  Interrupt(Subject(Bool))
  /// A model switch for this session. Profile defaults are saved separately.
  ChangeModel(
    String,
    Option(String),
    Option(String),
    Subject(Result(ModelSelection, String)),
  )
  ReadEffort(Subject(Result(json.Json, String)))
  ReadFast(
    Subject(Result(#(json.Json, session_configuration.Configuration), String)),
  )
  ChangeEffort(String, Subject(Result(json.Json, String)))
  ReadCompactAt(Subject(Result(json.Json, String)))
  ChangeCompactAt(Option(Int), Subject(Result(json.Json, String)))
  ExtensionChanged(String, Subject(Nil))
  ReadName(Subject(Result(json.Json, String)))
  AskSideQuestion(
    String,
    String,
    Subject(Result(side_question.Exchange, side_question.Refusal)),
  )
  SideQuestionFinished(
    String,
    session_run.Supervised(session_side_question.Answer),
  )
  CancelSideQuestion(
    String,
    Subject(Result(side_question.Exchange, side_question.Refusal)),
  )
  DismissSideQuestion(
    String,
    Bool,
    Subject(Result(side_question.Exchange, side_question.Refusal)),
  )
  ClaimSideContinuation(
    String,
    String,
    Subject(Result(side_question.Promotion, side_question.Refusal)),
  )
  SettleSideContinuation(String, String, Bool)
  GenerateTitle(Subject(Result(Nil, Refusal)))
  TitleFinished(Int, Result(String, String))
  /// The person's name for the session, or None to clear it.
  ChangeName(Option(String), Subject(Result(json.Json, String)))
  /// The model's name for the session.
  SuggestName(String, Subject(Result(json.Json, String)))
  StopJob(String, Subject(Result(Nil, command.StateError)))
  /// Report on the kernel's staleness, or (True) force its swap now.
  UpgradeKernel(Subject(Result(runtime.KernelUpgrade, Refusal)))
  UpgradeCompletion(
    Result(runtime.KernelUpgrade, String),
    Subject(Result(runtime.KernelUpgrade, Refusal)),
  )
  /// `/kernel restart`, by the user (None) or by the named agent that
  /// started this session.
  RestartKernel(Option(String), Subject(Result(KernelRestart, String)))
  /// The runtime stopped the old kernel, or says why it could not.
  KernelRestarted(
    Result(Nil, String),
    KernelRestart,
    Subject(Result(KernelRestart, String)),
  )
  Read(
    Option(Cursor),
    Subject(Result(#(Cursor, List(json.Json), Option(Unobserved)), Refusal)),
  )
  Watch(process.Pid, String, fn() -> Nil)
  Unwatch(process.Pid, String)
  Consumed(process.Pid, String, Cursor, Bool)
  Publish(String, view.Event, Subject(Bool))
  CatalogLoaded
  AgentProgress(String)
  ToolProgressDelta(String, Int, Int, Int, String, String, Subject(Bool))
  ToolProgressRunning(String, Int, Int, Int, String, String, Subject(Bool))
  ToolProgressReset(String, Int, Subject(Nil))
  ToolProgressFinish(String, String, Subject(Nil))
  ProgressFlush(Int)
  /// The frame's held text and thinking deltas are due.
  PublishOutput
  /// Unflushed text deltas are due for crash-recovery draft persistence.
  FlushDraft
  /// A debounced background Python state checkpoint is due.
  CheckpointKernel(Int)
  /// The background Python state checkpoint completed.
  Checkpointed
  /// Apply a persisted pending model switch on reload when idle.
  ApplyPendingSwitch
  /// Retry an interrupted initial title generation after a crash.
  ResumeTitle
  Commit(
    String,
    List(types.Input),
    conversation.Stage,
    Option(Int),
    Option(conversation.ToolIdentity),
    conversation.Follow,
    Subject(Result(#(Int, Option(Int)), String)),
    Subject(Nil),
  )
  CommitFits(
    String,
    List(transcript.ImageFit),
    Subject(Result(Int, String)),
    Subject(Nil),
  )
  /// The worker's stream broke for this reason after it showed output, and
  /// the turn goes on from that output.
  Salvage(
    String,
    String,
    Subject(Result(#(Int, List(types.Input)), String)),
    Subject(Nil),
  )
  /// A write `write_then` queued has committed; this goes on from it.
  Landed(fn(State) -> State)
  RecordContext(String, context_snapshot.Snapshot, Bool, Subject(Nil))
  ReportPin(String, Option(Int), Subject(Nil))
  /// The worker's turn call succeeded; the session's extensions hear it.
  /// Fire-and-forget, like the pin report.
  ReportSent(String, extension.SentCall, Subject(Nil))
  ReportShellDelivery(String, List(String), Subject(Nil))
  /// Live compaction progress; the prepared request clears it.
  ReportCompacting(String, compaction.ProgressUpdate, Subject(Nil))
  /// An extension asks for a background call; see `extension.Session`.
  CallInBackground(
    types.Request,
    requests.Prefix,
    Subject(Result(compaction.Answer, String)),
  )
  /// A background call's worker finished.
  BackgroundFinished(String, Int, Result(compaction.Answer, String))
  Compact(
    Option(String),
    Option(String),
    Subject(Result(turn.CompactionReport, Refusal)),
  )
  PersistCompaction(String, String)
  AdmitCompaction(
    String,
    Option(String),
    Subject(Result(operations.Receipt, Refusal)),
  )
  ReloadData(Subject(Result(session_extensions.Reloaded, String)))
  /// An extension asks for a refresh and gives its reason; see
  /// `extension.Session`.
  RefreshRequested(String)
  DrainSteering(
    String,
    Subject(Result(#(Int, List(types.Input)), String)),
    Subject(Nil),
  )
  ReadContext(Subject(context_snapshot.Snapshot))
  Finished(String, Result(Nil, loop.Failure))
  Down(process.Down)
  Idle(Subject(Report))
  /// An automatic release keeps a kernel whose save missed names; the sweep
  /// sends a lossy one while the kernel budget is pressed, as closing an
  /// agent always does.
  Release(Subject(Bool), automatic: Bool)
  ReleaseResting
  Released(
    runtime.Session,
    Result(python.Saved, String),
    Option(Subject(Bool)),
    automatic: Bool,
  )
  Deleted(Result(Nil, String), Subject(Result(Nil, String)))
  CloseAgent(Subject(Result(Nil, String)))
  ExpireState(Subject(Bool))
  EvictHistory(Subject(Bool))
  /// Queued behind a handler that dropped a large part of the state. An idle
  /// actor never collects on its own, so without this the dropped history and
  /// the binaries it references stay resident until the next message.
  Collect
  CollectQuiet
  Close(Subject(Nil))
  /// Stop the actor if nothing runs, waits, watches, or holds a live job or a
  /// running child, whose report will wake it. True when it stopped.
  Unload(Subject(Bool))
  ChildrenObserved(Message, Bool)
  /// Archive the whole transcript, cut it back before a user message, and
  /// stop, so each stream ends and its client reconnects to a reset.
  RewindHistory(
    String,
    Int,
    Option(String),
    Option(Int),
    Subject(Result(history.Rewound, Refusal)),
  )
  /// Summarize the rows from a user message on, for a rewind that keeps a
  /// summary. The worker answers the first subject with the text and the last
  /// row it covers; the second answers at once, whether the run started.
  StartSummary(
    Int,
    Option(String),
    Subject(Result(#(String, Int), String)),
    Subject(Result(Nil, Refusal)),
  )
  CloseForDeletion(Subject(Result(Nil, String)))
  ClaimDeletion(
    family.DeletionRequest,
    String,
    Int,
    Subject(Result(family.DeletionClaim, Refusal)),
  )
  /// The runtime answered this session's kernel request.
  KernelOpened(Int, Result(runtime.Session, python.Error))
  /// The runtime answered this session's request for a kernel-free composition.
  PreparedOpened(Int, Result(runtime.Prepared, python.Error))
  /// The runtime answered a context read's request for a kernel-free
  /// composition (albedo-suite); see `context_read`.
  ContextComposed(Result(runtime.Prepared, python.Error))
  /// A context read's rebuild of the last request finished (albedo-suite).
  ContextRebuilt(context_snapshot.Snapshot)
  /// The model wait a rest timer measured has passed; see `arm_rest`.
  RestKernel(String, Int)
  /// The kernel went unused for `idle_release_ms` since the timer `token`
  /// was armed; see `request_resting_release`.
  IdleKernel(Int)
  /// A run's worker asks for the kernel its next tool call runs in.
  AcquireKernel(String, Subject(Result(runtime.Session, String)))
  WorkspaceReset(session_workspace.Pending, Result(Nil, String))
  /// A workspace probe completed outside the actor; stale generations are ignored.
  WorkspaceReady(String, WorkspaceProbe, Result(Nil, String))
  /// Start a turn for what waits in the queue, now that the kernel is here.
  StartQueued
  /// The receipt goes to the first subject once the store commits it.
  AdmitOperation(
    operations.Request,
    Submission,
    Subject(Result(operations.Receipt, Refusal)),
    Subject(Admission),
  )
  /// Recheck the ACP lease at admission, inside its ordering authority.
  AdmitACP(
    operations.Request,
    Submission,
    acp.Digest,
    Subject(Result(operations.Receipt, Refusal)),
    Subject(Admission),
  )
  /// The store committed an admission; its receipt goes to the subject.
  AdmissionCommitted(
    Submission,
    Result(operations.Receipt, Refusal),
    Subject(Result(operations.Receipt, Refusal)),
  )
  PublishACPOverlay(
    acp.Digest,
    Int,
    Option(acp_session.Candidate),
    Subject(Result(Nil, acp_session.Failure)),
  )
}

pub type WorkspaceProbe {
  QueueStart
  ResumeStart
}

type State =
  session_state.State(Message)

/// Starting a session costs no Python process; the first run opens the kernel.
pub fn start(
  host: runtime.Runtime,
  info: conversation.Info,
  home: String,
) -> Result(Session, actor.StartError) {
  actor.new_with_initialiser(10_000, fn(self) {
    albedo_process.label("albedo_session", info.id)
    // The one write a start waits for: registration is ordered with deletion
    // claims on the writer. Orphaned shell commands end in the same turn.
    use interrupted <- result.try(
      store.query(runtime.ledger(host), fn(db) {
        use active <- result.try(operations.active_compaction_in(db, info.id))
        use _ <- result.try(
          family.open_in(db, info.id) |> result.map_error(refusal.explain),
        )
        live_register(info.id, self)
        use _ <- result.try(shell_commands.interrupt_orphans_in(db, info.id))
        use _ <- result.try(operations.interrupt_compactions_in(db, info.id))
        Ok(active)
      }),
    )
    let info = case interrupted {
      True -> session_info.Info(..info, stage: session_info.Interrupted)
      False -> info
    }
    // Watched before the read, so a move finishing in between still lands.
    moves.watch(info.id, fn(record) {
      process.send(self, MovedAway(moves.refusal(record).detail))
    })
    let moved =
      moves.moved(runtime.ledger(host), info.id)
      |> result.unwrap(None)
      |> option.map(fn(record) { moves.refusal(record).detail })
    use latest_usage <- result.try(conversation.load_usage(
      runtime.ledger(host),
      info.id,
    ))
    use spent <- result.try(conversation.load_spend(
      runtime.ledger(host),
      info.id,
    ))
    use captured <- result.try(
      conversation.capture(runtime.ledger(host), info.id)
      |> result.map_error(refusal.explain),
    )
    let recovered = case info.stage {
      session_info.Idle | session_info.Importing -> {
        active_output.finish_recovery(home, info.id, [])
        False
      }
      _ ->
        session_salvage.recover_crashed(
          runtime.ledger(host),
          home,
          info,
          captured.history_high_water,
        )
    }
    use captured <- result.try(case recovered {
      True ->
        conversation.capture(runtime.ledger(host), info.id)
        |> result.map_error(refusal.explain)
      False -> Ok(captured)
    })
    let saved_switch = case
      conversation.pending_switch(runtime.ledger(host), info.id)
    {
      Ok(found) -> found
      Error(reason) -> {
        io.println_error("pending switch load skipped: " <> reason)
        None
      }
    }
    let saved_side = case
      session_side_question.load(runtime.ledger(host), info.id)
    {
      Ok(found) -> found
      Error(reason) -> {
        io.println_error("side question load skipped: " <> reason)
        None
      }
    }
    let now_sys = albedo_clock.system_ms()
    let now_mono = albedo_clock.monotonic_ms()
    let active_holds = case
      mail.active_holds(runtime.ledger(host), info.id, now_sys)
    {
      Ok(rows) -> rows
      Error(reason) -> {
        io.println_error("active holds load skipped: " <> reason)
        []
      }
    }
    let max_hold = albedo_clock.delay_ms(hold_ms)
    let held_map =
      list.fold(active_holds, dict.new(), fn(acc, entry) {
        let #(id, until) = entry
        let remaining = int.clamp(until - now_sys, 1, max_hold)
        let deadline = now_mono + remaining
        let _ = process.send_after(self, remaining, HoldLapsed(id, deadline))
        dict.insert(acc, id, deadline)
      })
    use marker <- result.try(stored_history.acp_marker(
      storage.host(runtime.ledger(host)),
      info.id,
    ))
    use pinned <- result.try(conversation.prompt_pin(
      runtime.ledger(host),
      info.id,
    ))
    use prepared_head <- result.try(conversation.prepared_head(
      runtime.ledger(host),
      info.id,
    ))
    use shells <- result.try(shell_commands.pending(
      runtime.ledger(host),
      info.id,
    ))
    process.send(self, FlushAttached)
    case conversation.resumable(info.stage) {
      True -> process.send(self, Resume)
      False -> Nil
    }
    let activity = case info.stage {
      session_info.Idle -> turn.Resting
      _ -> turn.Interrupted
    }
    // A finished command's receipt waits in the inbox; one that finished
    // before this session loaded is posted now (once: its key is its id).
    list.each(shells, fn(command) {
      case command.status {
        shell_commands.Running -> Ok(False)
        _ ->
          mail.post_input(
            runtime.ledger(host),
            shell_commands.receipt(info.id, command),
          )
      }
    })
    // What waits in the inbox starts a turn once the session is up. A closed
    // agent leaves the letters it was sent there.
    let closed =
      families.closed(storage.host(runtime.ledger(host)), info.id) == Ok(True)
    use waiting <- result.try(inbox.waiting(
      runtime.ledger(host),
      info.id,
      [],
      closed,
    ))
    let unheld =
      list.take_while(waiting, fn(row) { !dict.has_key(held_map, row.id) })
    case turn.starts_turn(unheld) {
      False -> Nil
      True -> process.send(self, StartQueued)
    }
    case saved_switch, conversation.resumable(info.stage) {
      Some(_), False -> process.send(self, ApplyPendingSwitch)
      _, _ -> Nil
    }
    case captured.history_high_water > 0 {
      True -> process.send(self, ResumeTitle)
      False -> Nil
    }
    let generation = new_generation()
    let state =
      session_state.State(
        title_job: None,
        title_revision: 0,
        active_output: active_output.new(home, info.id, generation)
          |> active_output.set_high_water(captured.history_high_water),
        side_question: saved_side,
        shell_commands: shells,
        shell_worker: None,
        info: info,
        acp: option.is_some(marker),
        host: host,
        kernel: None,
        released: None,
        prepared: None,
        composing_context: False,
        rest_token: 0,
        home: home,
        self: self,
        history: None,
        results_settled: False,
        latest_usage: latest_usage,
        spent: spent,
        activity: activity,
        pending_switch: option.map(saved_switch, fn(p) {
          session_state.PendingSwitch(p.0, p.1, p.2)
        }),
        admitting: 0,
        finishing: False,
        pending_agent_close: None,
        active_submissions: [],
        sequence: 0,
        events: event_buffer.new(),
        watchers: [],
        notice: None,
        context: session_state.unprepared(),
        pin: case pinned {
          Some(#(prompt, head)) -> loop.Pinned(prompt, Some(head))
          None -> loop.Unpinned
        },
        prepared_head: prepared_head,
        last_touch: albedo_clock.monotonic_ms(),
        booting: None,
        boot_ticket: None,
        boot_token: 0,
        workspace_reset: None,
        workspace_probe: None,
        releasing: None,
        checkpointing: None,
        closing: False,
        blocked_until: 0,
        kernel_blocked: False,
        blocking: None,
        holding_failure: False,
        held: held_map,
        generation: generation,
        tool_progress: tool_progress_state.new(),
        progress_timer_token: 0,
        progress_timer: None,
        live_activity: session_activity.request(
          session_activity.new(usage.now()),
          captured.current_request,
        ),
        announced_status: None,
        announced_kernel: None,
        announced_glances: None,
        glances_due: GlancesDue,
        kernel_changed: KernelJobs,
        glance_timer: None,
        pending_output: [],
        output_timer: None,
        output_published_at: albedo_clock.monotonic_ms(),
        publish_output: PublishOutput,
        draft_timer: None,
        flush_draft: FlushDraft,
        landed: Landed,
        writing: 0,
        captures: [],
        moved: moved,
      )
    command_state.register(info.id, fn(op) {
      command_op(self, host, home, info.id, op)
    })
    bus.register_owner(
      info.id,
      process.self(),
      fn(text) { process.send(self, AgentProgress(text)) },
      fn() { process.send(self, CatalogLoaded) },
    )
    // Whoever stores a row in this session's inbox, it hears after the
    // commit.
    let actor_pid = process.self()
    mail.register(info.id, fn() {
      process.send(self, InboxChanged)
      process.is_alive(actor_pid)
    })
    Ok(
      actor.initialised(state)
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      ),
    )
  })
  |> actor.on_message(fn(state, message) {
    case message {
      CollectQuiet -> Nil
      _ -> activity(state.self, CollectQuiet)
    }
    handle(state, message)
  })
  |> actor.start
  |> result.map(fn(p) {
    process.unlink(p.pid)
    p.data
  })
}

/// Take these rows out of the session's queue for good and return the ones
/// it took. A person's input is cancelled, as `cancel_input` would; a row the
/// running turn already took is left alone.
pub fn drop_queued(
  session: Session,
  ids: List(String),
) -> Result(List(String), String) {
  actor_call.try_call(session, 15_000, DropQueued(ids, _))
  |> result.replace_error("the session did not answer")
  |> result.flatten
}

/// Put these waiting rows first in the session's queue, in this order; the
/// rest keep their order after them.
pub fn arrange_queue(
  session: Session,
  ids: List(String),
) -> Result(Nil, String) {
  actor_call.try_call(session, 15_000, ArrangeQueue(ids, _))
  |> result.replace_error("the session did not answer")
  |> result.flatten
}

/// Hold `input_id`, a person's message still waiting, while they edit it:
/// neither it nor what waits behind it is read until the edit is saved, the
/// hold is released, or `hold_ms` pass without asking again.
pub fn hold_input(session: Session, input_id: String) -> Result(Nil, Refusal) {
  actor_call.try_call(session, 15_000, HoldInput(input_id, _))
  |> result.replace_error(refusal.Unavailable("the session did not answer"))
  |> result.flatten
}

/// Let a held input be read again as it is.
pub fn release_input(
  session: Session,
  input_id: String,
) -> Result(Nil, String) {
  actor_call.try_call(session, 15_000, ReleaseInput(input_id, _))
  |> result.replace_error("the session did not answer")
}

/// Put `submission` in place of the person's message still waiting under its
/// id, and release any hold on it. Errors with `input_not_waiting` once the
/// session read it or it was cancelled.
pub fn edit_input(
  session: Session,
  submission: Submission,
) -> Result(Nil, Refusal) {
  actor_call.try_call(session, 15_000, EditInput(submission, _))
  |> result.replace_error(refusal.Unavailable("the session did not answer"))
  |> result.flatten
}

pub fn cancel_input(
  session: Session,
  input_id: String,
  digest: Option(acp.Digest),
) -> Result(InputCancellation, Refusal) {
  actor.call(session, 5000, CancelInput(input_id, digest, _))
}

/// This session's materialized command catalog and the context that runs them.
/// Answered through the kernel's session, so the list matches its bindings.
pub fn commands(
  session: Session,
) -> Result(#(List(command.Command(command.Context)), command.Context), String) {
  actor.call(session, 15_000, ReadCommands)
}

/// Current fast preference and provider/account/model support.
pub fn read_fast(session: Session) -> Result(json.Json, String) {
  read_fast_resource(session) |> result.map(fn(value) { value.0 })
}

/// The fast-mode body and validator captured together inside the session owner.
pub fn read_fast_resource(
  session: Session,
) -> Result(#(json.Json, session_configuration.Configuration), String) {
  actor_call.try_call(session, 30_000, ReadFast)
  |> result.replace_error("fast mode status unavailable")
  |> result.flatten
}

/// The window this session compacts against and where it comes from.
pub fn read_compact_at(session: Session) -> Result(json.Json, String) {
  actor_call.try_call(session, 5000, ReadCompactAt)
  |> result.replace_error("context window unavailable")
  |> result.flatten
}

pub fn interrupt(session: Session) -> Bool {
  actor.call(session, 5000, Interrupt)
}

/// The observed run and input prefix are the full scope of this request.
pub fn interrupt_captured(
  session: Session,
  run_id: Option(String),
  through_input_order: Int,
) -> Result(Interruption, String) {
  actor.call(session, 5000, InterruptCaptured(run_id, through_input_order, _))
}

pub fn capture(session: Session) -> Result(Capture, Refusal) {
  actor_call.try_call(session, 5000, ReadCapture)
  |> result.replace_error(refusal.Unavailable("session capture unavailable"))
  |> result.flatten
  |> result.try(fn(observe) { observe() })
}

/// Reload desired composition and wait for the runtime's actual result.
pub fn reload(session: Session) -> Result(session_extensions.Reloaded, String) {
  actor_call.try_call(session, 185_000, ReloadData)
  |> result.replace_error(
    "reload response unavailable; inspect session composition",
  )
  |> result.flatten
}

/// Capture collection facts without inspecting a kernel or composing plugins.
pub fn summary(session: Session) -> Result(Summary, String) {
  actor_call.try_call(session, 5000, ReadSummary)
  |> result.replace_error("session summary unavailable")
}

/// The live facts alone: what a watching client's footer draws.
pub fn status_read(session: Session) -> Result(StatusRead, String) {
  actor_call.try_call(session, 5000, ReadStatus)
  |> result.replace_error("session status unavailable")
  |> result.try(fn(observe) { observe() })
}

/// Queue a parent switch; False means it applied to an idle session now.
pub fn switch_model(
  session: Session,
  caller: String,
  provider: String,
  model: String,
) -> Result(Bool, String) {
  actor.call(session, 30_000, SwitchModel(caller, provider, model, _))
}

pub fn change_configuration(
  session: Session,
  expected: session_configuration.Version,
  patch: session_configuration.Patch,
  attachment: Option(acp.Digest),
) -> Result(Capture, Refusal) {
  actor.call(session, 30_000, ChangeConfiguration(
    expected,
    patch,
    attachment,
    _,
  ))
  |> result.try(fn(observe) { observe() })
}

/// Register one keyed follow for a streaming client. The callback runs in the
/// session process and must only notify; dead owners are dropped.
pub fn watch(
  session: Session,
  owner: process.Pid,
  key: String,
  notify: fn() -> Nil,
) -> Nil {
  process.send(session, Watch(owner, key, notify))
}

/// Stop one keyed follow and its monitor.
pub fn unwatch(session: Session, owner: process.Pid, key: String) -> Nil {
  process.send(session, Unwatch(owner, key))
}

/// A successful frame consumed this cursor. Timers can overtake a queued wake,
/// so only handling that wake rearms its notification.
pub fn consumed(
  session: Session,
  owner: process.Pid,
  key: String,
  cursor: Cursor,
  wake_consumed: Bool,
) -> Nil {
  process.send(session, Consumed(owner, key, cursor, wake_consumed))
}

/// Events after the fully consumed actor cursor. A reset returns a captured
/// session state; the HTTP owner reads history through its durable boundary.
pub fn read(session: Session, after: Option(Cursor)) -> Result(Page, Refusal) {
  use #(cursor, events, unobserved) <- result.try(
    actor.call(session, 5000, Read(after, _)),
  )
  case unobserved {
    None -> Ok(Page(cursor, events, None))
    Some(observe) ->
      observe()
      |> result.map(fn(capture) { Page(capture.cursor, [], Some(capture)) })
  }
}

/// Capture the latest prepared request without triggering model work.
/// An observed identity pins navigation to that request.
pub fn prepared_context(
  session: Session,
  expected: Option(String),
) -> Result(context_snapshot.Snapshot, Refusal) {
  let snapshot = actor.call(session, 5000, ReadContext)
  case expected, context_snapshot.identity(snapshot) {
    Some(id), actual if actual != Some(id) -> Error(refusal.ContextChanged)
    _, _ -> Ok(snapshot)
  }
}

fn context(session: Session) -> json.Json {
  actor.call(session, 5000, ReadContext) |> context_snapshot.summary
}

fn context_page(
  session: Session,
  section: String,
  page: Int,
) -> Result(json.Json, String) {
  actor.call(session, 5000, ReadContext)
  |> context_snapshot.page(section, page)
  |> result.map(fn(part) {
    json.object([
      #("snapshot_id", json.string(part.snapshot_id)),
      #("section_id", json.string(part.section_id)),
      #("page", json.int(part.page)),
      #("page_count", json.int(part.page_count)),
      #("text", json.string(part.text)),
      #("omitted", json.nullable(part.omitted, json.string)),
    ])
  })
}

/// Remove the saved variables after a session has stopped.
pub fn discard_state(home: String, id: String) -> Nil {
  case session_namespace.state_path(home, id) {
    Some(path) -> discard(path)
    None -> Nil
  }
}

pub fn claim_deletion(
  session: Session,
  request: family.DeletionRequest,
  token: String,
) -> Result(family.DeletionClaim, Refusal) {
  actor_call.try_call(session, 5000, ClaimDeletion(
    request,
    token,
    albedo_clock.monotonic_ms() + 5000,
    _,
  ))
  |> result.map_error(fn(error) {
    case error {
      actor_call.CalleeDown ->
        refusal.Unavailable("session owner stopped before deletion admission")
      actor_call.TimedOut ->
        refusal.Unavailable("deletion admission deadline reached")
    }
  })
  |> result.flatten
}

type ClosureEvent {
  Stopped
  StopAcknowledged(Result(Nil, String))
}

/// Wait for termination, not just the close acknowledgment. A timeout leaves
/// the durable row intact so deletion can report it as remaining.
pub fn close_for_deletion(
  session: Session,
  timeout_ms: Int,
) -> Result(Nil, String) {
  case process.subject_owner(session) {
    Error(_) -> Ok(Nil)
    Ok(owner) -> {
      let deadline = albedo_clock.monotonic_ms() + timeout_ms
      let monitor = process.monitor(owner)
      let reply = process.new_subject()
      process.send(session, CloseForDeletion(reply))
      let outcome =
        process.new_selector()
        |> process.select_map(reply, StopAcknowledged)
        |> process.select_specific_monitor(monitor, fn(_) { Stopped })
        |> process.selector_receive(timeout_ms)
      let stopped = case outcome {
        Error(_) -> Error("session did not stop before deletion deadline")
        Ok(Stopped) -> Ok(Nil)
        Ok(StopAcknowledged(Error(error))) -> Error(error)
        Ok(StopAcknowledged(Ok(_))) -> {
          let remaining = deadline - albedo_clock.monotonic_ms()
          case remaining <= 0 {
            True -> Error("session did not stop before deletion deadline")
            False ->
              process.new_selector()
              |> process.select_specific_monitor(monitor, fn(_) { Nil })
              |> process.selector_receive(remaining)
              |> result.replace_error(
                "session did not stop before deletion deadline",
              )
          }
        }
      }
      process.demonitor_process(monitor)
      stopped
    }
  }
}

/// Whether the session's actor still runs; an unloaded one stops before its
/// registry hears of it.
pub fn alive(session: Session) -> Bool {
  process.subject_owner(session)
  |> result.map(process.is_alive)
  |> result.unwrap(False)
}

/// Asks an idle session to take its kernel and let its extensions pick up
/// warming where a daemon restart left it.
pub fn rewarm(session: Session) -> Nil {
  process.send(session, Rewarm)
}

pub fn rename_profiles(
  session: Session,
  renames: List(#(String, String)),
) -> Nil {
  process.send(session, RenameProfiles(renames))
}

pub fn close(session: Session) -> Nil {
  actor.call(session, 30_000, Close)
}

/// Close an agent without deleting its transcript, files or saved namespace.
/// A timeout leaves cleanup running; the durable closed row blocks new mail.
pub fn close_agent(session: Session) -> Result(Nil, String) {
  actor_call.try_call(session, 100_000, CloseAgent)
  |> result.replace_error(
    "agent is closed but cleanup is unconfirmed; repeat close to reconcile",
  )
  |> result.flatten
}

/// Save a live kernel before confirmed shutdown, including one whose session
/// actor was lost. Reattachment must not start a fresh kernel in its place.
/// Run outside actors: both snapshotting and runtime shutdown can wait.
pub fn close_agent_kernel(
  host: runtime.Runtime,
  home: String,
  id: String,
  known: Option(runtime.Session),
) -> Result(Nil, String) {
  albedo_protect.guarded(fn() {
    use recorded <- result.try(link.lookup(runtime.ledger(host), id))
    let known =
      option.then(known, fn(kernel) {
        case runtime.alive(kernel) {
          True -> Some(kernel)
          False -> None
        }
      })
    case known, recorded {
      None, Some(record) -> runtime.reattach_session(host, id, record.cwd)
      _, _ -> Nil
    }
    let kernel = case known {
      Some(kernel) -> Some(kernel)
      None ->
        runtime.held_kernels(host)
        |> list.find(fn(entry) { entry.0 == id })
        |> result.map(fn(entry) { entry.1 })
        |> option.from_result
    }
    use _ <- result.try(case kernel {
      Some(kernel) ->
        case runtime.alive(kernel) {
          True ->
            session_namespace.save_state_within(
              home,
              id,
              kernel,
              session_namespace.close_state_timeout,
            )
            |> result.replace(Nil)
          False -> {
            use recorded <- result.try(link.lookup(runtime.ledger(host), id))
            case recorded {
              None -> Ok(Nil)
              Some(_) ->
                Error(
                  "agent is closed but its kernel owner stopped before saving; repeat close to reconcile",
                )
            }
          }
        }
      None -> {
        use recorded <- result.try(link.lookup(runtime.ledger(host), id))
        case recorded {
          Some(_) ->
            Error(
              "agent is closed but its recorded kernel could not be attached for saving; repeat close to reconcile",
            )
          None -> Ok(Nil)
        }
      }
    })
    runtime.delete_session(host, id)
  })
}

/// Whether this session holds a kernel, and how long since a client last spoke.
pub fn report(session: Session) -> Report {
  actor.call(session, 5000, Idle)
}

/// Delete the saved variables unless a kernel, turn or boot uses them now.
/// True when they were deleted.
pub fn expire_state(session: Session) -> Bool {
  actor_call.try_call(session, waiting: 5000, sending: ExpireState)
  |> result.unwrap(False)
}

/// Cut an idle session back to before the user message at `checkpoint`, after
/// copying all of it into the archived session `archive_id`. The actor stops on
/// success; the next lookup starts one that reads what is left.
pub fn rewind(
  session: Session,
  archive_id: String,
  checkpoint: Int,
  summary: Option(#(String, Int)),
) -> Result(history.Rewound, Refusal) {
  actor_call.try_call(session, 30_000, RewindHistory(
    archive_id,
    checkpoint,
    option.map(summary, fn(done) { done.0 }),
    option.map(summary, fn(done) { done.1 }),
    _,
  ))
  |> result.replace_error(refusal.Unavailable(
    "rewind response unavailable; inspect the session",
  ))
  |> result.flatten
}

/// The summary of what a rewind to `checkpoint` would remove, and the last row
/// it covers, which `rewind` checks is still the last. Nothing changes; the
/// session is only held while the model writes it.
pub fn summarize_tail(
  session: Session,
  checkpoint: Int,
  instructions: Option(String),
) -> Result(#(String, Int), Refusal) {
  let out = process.new_subject()
  use _ <- result.try(
    actor_call.try_call(session, 60_000, StartSummary(
      checkpoint,
      instructions,
      out,
      _,
    ))
    |> result.replace_error(refusal.Unavailable(
      "summary response unavailable; inspect the session",
    ))
    |> result.flatten,
  )
  case process.receive(out, 600_000) {
    Ok(outcome) -> outcome |> refusal.storage
    Error(Nil) ->
      Error(refusal.Unavailable("the summary went unanswered for ten minutes"))
  }
}

/// Drop an idle actor's reloadable transcript cache without touching its event
/// cursor or durable requests. Active runs always retain their prepared history.
pub fn evict_history(session: Session) -> Bool {
  actor.call(session, 5000, EvictHistory)
}

/// `write` for `write_then`, answering also the history's boundary right
/// after it: the session publishes the rows that commit wrote, not ones a
/// commit queued after it already added.
fn with_boundary(
  state: State,
  write: fn() -> Result(a, String),
) -> fn() -> Result(#(a, conversation.Snapshot), String) {
  let #(ledger, session) = #(runtime.ledger(state.host), state.info.id)
  fn() {
    use value <- result.try(write())
    use boundary <- result.try(conversation.committed_snapshot(ledger, session))
    Ok(#(value, boundary))
  }
}

fn answer(
  state: State,
  reply: Subject(a),
  value: a,
) -> actor.Next(State, Message) {
  process.send(reply, value)
  actor.continue(state)
}

fn tool_progress_delta(
  state: State,
  run_id: String,
  step: Int,
  attempt: Int,
  output_index: Int,
  name: String,
  fragment: String,
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, False)
    True -> {
      let was_enabled = tool_progress_state.enabled(state.tool_progress)
      let had_calls = tool_progress_state.has_calls(state.tool_progress)
      let tool_progress_state.Update(progress, snapshot, invalidates_progress) =
        tool_progress_state.update(
          state.tool_progress,
          generation: state.generation,
          run_id: run_id,
          step: step,
          attempt: attempt,
          output_index: output_index,
          incoming_name: name,
          fragment: fragment,
        )
      let overflow = was_enabled && !tool_progress_state.enabled(progress)
      let clear_previous = { invalidates_progress && had_calls } || overflow
      let state = apply_tool_progress(state, progress, snapshot, clear_previous)
      answer(state, reply, True)
    }
  }
}

fn tool_progress_running(
  state: State,
  run_id: String,
  step: Int,
  attempt: Int,
  output_index: Int,
  tool_call_id: String,
  name: String,
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, False)
    True -> {
      let had_calls = tool_progress_state.has_calls(state.tool_progress)
      let tool_progress_state.Update(progress, snapshot, invalidates_progress) =
        tool_progress_state.running(
          state.tool_progress,
          generation: state.generation,
          run_id: run_id,
          step: step,
          attempt: attempt,
          output_index: output_index,
          tool_call_id: tool_call_id,
          name: name,
        )
      let state =
        apply_tool_progress(
          session_state.State(
            ..state,
            activity: turn.started(state.activity, run_id, tool_call_id),
          ),
          progress,
          snapshot,
          invalidates_progress && had_calls,
        )
      answer(state, reply, True)
    }
  }
}

fn apply_tool_progress(
  state: State,
  progress: tool_progress_state.Projection,
  snapshot: Option(tool_progress_state.Snapshot),
  clear_previous: Bool,
) -> State {
  let state = case clear_previous {
    True -> invalidate_progress_timer(state)
    False -> state
  }
  let state = session_state.State(..state, tool_progress: progress)
  let state = case clear_previous {
    True -> session_state.emit(state, view.clear_tool_progress())
    False -> state
  }
  let state = case snapshot {
    Some(snapshot) ->
      session_state.emit(state, view.tool_progress_event(snapshot))
    None -> state
  }
  schedule_progress_flush(state)
}

fn tool_progress_reset(
  state: State,
  run_id: String,
  attempt: Int,
  reply: Subject(Nil),
) -> actor.Next(State, Message) {
  case turn.live(state.activity, run_id) {
    False -> answer(state, reply, Nil)
    True -> {
      let state = invalidate_progress_timer(state)
      let progress = tool_progress_state.reset_attempt(attempt)
      let state = session_state.State(..state, tool_progress: progress)
      answer(session_state.emit(state, view.clear_tool_progress()), reply, Nil)
    }
  }
}

fn tool_progress_finish(
  state: State,
  run_id: String,
  progress_id: String,
  reply: Subject(Nil),
) -> actor.Next(State, Message) {
  case turn.owner(state.activity, run_id) {
    None -> answer(state, reply, Nil)
    Some(_) -> {
      let progress =
        tool_progress_state.finish_call(state.tool_progress, progress_id)
      let state = session_state.State(..state, tool_progress: progress)
      answer(schedule_progress_flush(state), reply, Nil)
    }
  }
}

fn invalidate_progress_timer(state: State) -> State {
  let _ = case state.progress_timer {
    Some(timer) -> process.cancel_timer(timer)
    None -> process.TimerNotFound
  }
  session_state.State(
    ..state,
    progress_timer_token: state.progress_timer_token + 1,
    progress_timer: None,
  )
}

fn schedule_progress_flush(state: State) -> State {
  case
    tool_progress_state.has_dirty(state.tool_progress),
    state.progress_timer
  {
    False, Some(_) -> invalidate_progress_timer(state)
    False, None | True, Some(_) -> state
    True, None -> {
      let token = state.progress_timer_token + 1
      let timer = albedo_clock.send_after(state.self, 100, ProgressFlush(token))
      session_state.State(
        ..state,
        progress_timer_token: token,
        progress_timer: Some(timer),
      )
    }
  }
}

fn tool_progress_flush(state: State, token: Int) -> actor.Next(State, Message) {
  case state.progress_timer, state.progress_timer_token == token {
    Some(_), True -> {
      let #(progress, snapshots) =
        tool_progress_state.flush_dirty(state.tool_progress)
      let state =
        session_state.State(
          ..state,
          tool_progress: progress,
          progress_timer: None,
        )
      let state =
        list.fold(snapshots, state, fn(state, snapshot) {
          session_state.emit(state, view.tool_progress_event(snapshot))
        })
      actor.continue(state)
    }
    _, _ -> actor.continue(state)
  }
}

fn transition(
  reply: Subject(a),
  transition: #(State, a),
) -> actor.Next(State, Message) {
  process.send(reply, transition.1)
  actor.continue(transition.0)
}

/// Interrupt the live kernel, if there is one.
fn interrupt_kernel(state: State) -> Nil {
  case state.kernel {
    Some(kernel) -> runtime.interrupt(kernel)
    None -> Nil
  }
}

pub fn upgrade_kernel(
  session: Session,
) -> Result(runtime.KernelUpgrade, Refusal) {
  actor_call.try_call(session, 185_000, UpgradeKernel)
  |> result.replace_error(refusal.Unavailable(
    "kernel upgrade response unavailable; inspect the session kernel",
  ))
  |> result.flatten
}

fn begin_upgrade(
  state: State,
  reply: Subject(Result(runtime.KernelUpgrade, Refusal)),
) -> actor.Next(State, Message) {
  case busy(state) || uses_kernel_transition(state), state.booting {
    True, _ ->
      answer(
        state,
        reply,
        Error(refusal.Busy("session must be idle to upgrade the kernel")),
      )
    // A kernel or composition still on its way (a restart reattaching it, say)
    // is waited out: the upgrade runs once it arrives.
    False, Some(_) -> actor.continue(park_kernel(state, UpgradeKernel(reply)))
    False, None -> {
      let self = state.self
      runtime.upgrade_async(state.host, state.info.id, fn(outcome) {
        process.send(self, UpgradeCompletion(outcome, reply))
      })
      actor.continue(
        session_state.State(..state, booting: Some(#(1, [])))
        |> session_state.announce,
      )
    }
  }
}

fn upgraded_kernel(
  state: State,
  outcome: Result(runtime.KernelUpgrade, String),
  reply: Subject(Result(runtime.KernelUpgrade, Refusal)),
) -> actor.Next(State, Message) {
  let parked =
    option.map(state.booting, fn(value) { value.1 }) |> option.unwrap([])
  let state = session_state.State(..state, booting: None)
  let state = case outcome {
    Ok(report) -> session_namespace.upgrade(state, report)
    Error(_) -> state
  }
  let state =
    session_state.announce(state)
    |> session_state.invalidate(
      view.StaleSession,
      "/sessions/" <> state.info.id,
    )
  list.each(parked, process.send(state.self, _))
  process.send(state.self, StartQueued)
  answer(state, reply, refusal.storage(outcome))
}

/// Replace the session's kernel with an empty one, stopping what runs first.
/// `by` names the agent that asked, None for the user.
pub fn restart_kernel(
  session: Session,
  by: Option(String),
) -> Result(KernelRestart, String) {
  actor_call.try_call(session, 185_000, RestartKernel(by, _))
  |> result.replace_error(
    "kernel restart response unavailable; inspect the session kernel",
  )
  |> result.flatten
}

/// The restart report as the HTTP route and `/kernel restart` return it.
pub fn kernel_restart_json(report: KernelRestart) -> json.Json {
  json.object([
    #("old_kernel_id", json.nullable(report.old_kernel_id, json.string)),
    #(
      "stopped_jobs",
      json.array(list.take(report.stopped_jobs, 200), json.string),
    ),
    #(
      "ended_cells",
      json.array(list.take(report.ended_cells, 200), json.string),
    ),
  ])
}

/// Stops the running turn and cancels queued inputs as esc does, then
/// restarts once a boot, release or workspace move under way has settled.
fn begin_restart(
  state: State,
  by: Option(String),
  reply: Subject(Result(KernelRestart, String)),
) -> actor.Next(State, Message) {
  use <- bool.lazy_guard(state.closing, fn() {
    answer(state, reply, Error("session is closing"))
  })
  case operations.cancel(runtime.ledger(state.host), state.info.id) {
    Error(error) -> answer(state, reply, Error(error))
    Ok(cancelled) -> {
      let #(state, _) = stop_waiting(state, cancelled)
      case replacing_kernel(state) || state.booting != None {
        True -> actor.continue(park(state, RestartKernel(by, reply)))
        False -> restart_now(state, by, reply)
      }
    }
  }
}

/// Discards the saved variables and asks the runtime to stop the kernel; the
/// next turn boots an empty one. The reply waits for the stop.
fn restart_now(
  state: State,
  by: Option(String),
  reply: Subject(Result(KernelRestart, String)),
) -> actor.Next(State, Message) {
  let old = state.kernel
  let observed =
    option.then(old, fn(kernel) {
      runtime.kernel_observation(kernel) |> option.from_result
    })
  let jobs =
    option.map(observed, fn(observed) { observed.running_jobs })
    |> option.unwrap([])
  let _ = option.map(old, session_namespace.forget)
  discard_state(state.home, state.info.id)
  let #(state, cells) = session_namespace.restarted(state, jobs, by)
  let report =
    KernelRestart(
      option.map(observed, fn(observed) { observed.instance_id }),
      list.map(jobs, fn(job) { job.id }),
      cells,
    )
  let self = state.self
  // The restart and any later Open are sent by this actor, in that order.
  runtime.restart_session_async(state.host, state.info.id, fn(stopped) {
    process.send(self, KernelRestarted(stopped, report, reply))
  })
  actor.continue(
    session_state.State(
      ..state,
      kernel: None,
      released: None,
      context: session_state.unprepared(),
    )
    |> session_state.announce
    |> session_state.invalidate(
      view.StaleSession,
      "/sessions/" <> state.info.id,
    ),
  )
}

fn summary_state(state: State) -> Summary {
  Summary(
    Cursor(state.generation, state.sequence),
    session_state.current_status(state),
    tool_progress_state.snapshots(state.tool_progress),
    state.live_activity,
    state.latest_usage,
    state.spent,
  )
}

/// Footer facts without a composition read. The caller prices the durable
/// request ledger and finishes the kernel observation. `glances` is what the
/// stream last published; a caller that finds none observes the composition.
fn status_state(state: State) -> fn() -> Result(StatusRead, String) {
  let ledger = runtime.ledger(state.host)
  let kernel = session_namespace.kernel_observer(state)
  // Bind the facts, not `state`, so the transcript stays in the actor.
  let #(id, cursor, status, usage, spent, glances) = #(
    state.info.id,
    Cursor(state.generation, state.sequence),
    session_state.current_status(state),
    state.latest_usage,
    state.spent,
    state.announced_glances,
  )
  fn() {
    use observed <- result.map(kernel())
    StatusRead(
      id,
      cursor,
      status,
      observed,
      usage,
      spent,
      session_cost.total(ledger, id),
      glances,
    )
  }
}

/// Another session may have written the work ledger or a vent since the last
/// read; the observation runs off the actor because it queues behind kernel
/// boots. A change publishes itself on the stream.
fn glances_due(state: State) -> State {
  let state = session_state.glance_fired(state)
  let #(host, home, id, self) = #(
    state.host,
    state.home,
    state.info.id,
    state.self,
  )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        self,
        GlancesObserved(
          runtime.observe_composition(host, home, id)
          |> result.map_error(session_catalog.failure_text),
        ),
      )
    })
  session_state.watch_glances(state)
}

/// A capture finished by its caller with the session's composition and, when
/// it holds no kernel, what the runtime has loaded. The runtime observes
/// composition on worker slots that kernel boots share, and stops kernels
/// inline, so it can take seconds; the caller waits for it, never the actor.
type Unobserved =
  fn() -> Result(Capture, Refusal)

/// Queue reader admission in the caller, without retaining the actor's state.
fn capture_state(state: State) -> Result(Unobserved, Refusal) {
  let #(ledger, self) = #(runtime.ledger(state.host), state.self)
  Ok(fn() {
    use observe <- result.try(
      store.capture_snapshot(ledger, fn(db) {
        // A queued request can still use db after a timeout. Keep the exclusive
        // loan until the actor replies or dies, never recycle a live connection.
        case process.subject_owner(self) {
          Error(_) -> Error(refusal.Unavailable("session capture unavailable"))
          Ok(owner) -> {
            let monitor = process.monitor(owner)
            let reply = process.new_subject()
            process.send(self, CaptureIn(db, reply))
            let outcome =
              process.new_selector()
              |> process.select(reply)
              |> process.select_specific_monitor(monitor, fn(_) {
                Error(refusal.Unavailable("session capture unavailable"))
              })
              |> process.selector_receive_forever
            process.demonitor_process(monitor)
            outcome
          }
        }
      }),
    )
    observe()
  })
}

/// Capture metadata and live facts together while the caller holds its reader.
fn capture_in(
  state: State,
  db: Option(sqlight.Connection),
) -> Result(Unobserved, Refusal) {
  use durable <- result.try(case db {
    Some(db) -> conversation.capture_in(db, state.info.id)
    None -> conversation.capture(runtime.ledger(state.host), state.info.id)
  })
  let summary = summary_state(state)
  let shells =
    list.map(state.shell_commands, fn(c) {
      shell_commands.Command(..c, output: shell_commands.prefix(c.output, 4096))
    })
  use active_output <- result.try(active_output.capture(state.active_output))
  let side = state.side_question
  let kernel = session_namespace.kernel_observer(state)
  let #(host, home, id) = #(state.host, state.home, state.info.id)
  Ok(fn() {
    use kernel <- result.try(kernel() |> refusal.storage)
    use composition <- result.try(
      runtime.observe_composition(host, home, id)
      |> result.map_error(session_catalog.refuse),
    )
    Ok(Capture(
      durable.info,
      summary.cursor,
      summary.status,
      durable.pending_inputs,
      durable.input_order,
      summary.current_progress,
      durable.history_high_water,
      summary.usage,
      summary.spent,
      kernel,
      summary.activity,
      durable.created_at,
      durable.activity_at,
      durable.revision,
      durable.family,
      durable.continuation_high_water,
      durable.automatic_name,
      durable.configuration,
      composition,
      durable.workspace_change,
      durable.preview,
      active_output,
      side,
      shells,
    ))
  })
}

fn publish_active(state: State, event: view.Event) -> State {
  case event {
    // A retry starts new message identities; deltas of the failed attempt
    // are published under the old ones first.
    view.Retry(..) -> {
      let state = session_state.flush_output(state)
      session_state.emit(
        session_state.State(
          ..state,
          active_output: active_output.retry(state.active_output),
        ),
        event,
      )
    }
    _ -> session_state.emit(state, event)
  }
}

fn cleanup_registrations(id: String) -> Nil {
  command_state.forget(id)
  mail.forget(id)
  moves.unwatch(id)
  live_forget(id)
}

fn handle(
  state: State,
  message: Message,
) -> actor.Next(session_state.State(Message), Message) {
  // Anything a client sends counts as attention; a detached session goes quiet.
  // Listing sessions reads their summaries and is not attention.
  let state = case message {
    ReadCapture(..)
    | ReadStatus(..)
    | ChangeConfiguration(..)
    | GenerateTitle(..)
    | InterruptCaptured(..)
    | ReadCommands(..)
    | Interrupt(..)
    | CancelInput(..)
    | HoldInput(..)
    | ReleaseInput(..)
    | EditInput(..)
    | Read(..)
    | ReadContext(..)
    | ChangeModel(..)
    | Compact(..)
    | ReloadData(..)
    | ChangeWorkspace(..)
    | ApplyWorkspace(..) ->
      session_state.State(..state, last_touch: albedo_clock.monotonic_ms())
    _ -> state
  }
  // Runs end in finish_turn and background_finish, which follow at once; this
  // catches a turn that never started, such as one whose kernel failed to boot.
  // Read-only requests must not apply a pending workspace here: that path
  // acknowledges the move with a writer query and can queue behind storage.
  let state = case read_only(message) {
    True -> state
    False -> settle(state)
  }
  case message {
    StartShell(id, command, reply) -> start_shell(state, id, command, reply)
    StopShell(id, reply) -> {
      case state.shell_worker {
        Some(#(running, worker)) if running == id -> shell_commands.stop(worker)
        _ -> Nil
      }
      answer(
        state,
        reply,
        shell_commands.read(runtime.ledger(state.host), state.info.id, id),
      )
    }
    ShellEnded(id, status, code, error, reply) -> {
      case
        shell_commands.finish(
          runtime.ledger(state.host),
          state.info.id,
          id,
          status,
          code,
          error,
        )
      {
        Error(error) ->
          answer(
            session_state.emit(state, view.error(error)),
            reply,
            Error(error),
          )
        Ok(command) -> {
          let state =
            session_state.State(
              ..state,
              shell_worker: case state.shell_worker {
                Some(#(running, _)) if running == id -> None
                other -> other
              },
              shell_commands: [
                command,
                ..list.filter(state.shell_commands, fn(c) { c.id != command.id })
              ],
            )
            |> session_state.emit(view.ShellCommand(command))
            |> queue_shell(command)
            |> flush_attached
          answer(state, reply, Ok(Nil))
        }
      }
    }
    ShellChanged(command, reply) -> {
      let worker = case state.shell_worker {
        Some(#(id, _))
          if id == command.id && command.status != shell_commands.Running
        -> None
        other -> other
      }
      let state =
        session_state.State(..state, shell_worker: worker, shell_commands: [
          command,
          ..list.filter(state.shell_commands, fn(c) { c.id != command.id })
        ])
        |> session_state.emit(view.ShellCommand(command))
        |> queue_shell(command)
        |> flush_attached
      answer(state, reply, Nil)
    }
    FlushAttached -> actor.continue(flush_attached(state))
    ReadCapture(reply) -> answer(state, reply, capture_state(state))
    CaptureIn(db, reply) ->
      actor.continue(answer_captures(
        session_state.State(..state, captures: [
          fn(state) {
            let captured = capture_in(state, db)
            // The capture lane's reader owns db; finalize the statements
            // this actor left on it before the loan ends, so the reader's
            // close is complete.
            case db {
              Some(db) -> albedo_sqlite.release(db)
              None -> Nil
            }
            process.send(reply, captured)
          },
          ..state.captures
        ]),
      ))
    ReadSummary(reply) -> answer(state, reply, summary_state(state))
    ReadStatus(reply) -> answer(state, reply, status_state(state))
    KernelJobs ->
      actor.continue(
        request_resting_release(state) |> session_namespace.announce_kernel,
      )
    WorkspaceReset(pending, outcome) ->
      actor.continue(workspace_reset(state, pending, outcome))
    GlancesDue -> actor.continue(glances_due(state))
    GlancesObserved(result) ->
      actor.continue(case result {
        Error(_) -> state
        Ok(observed) -> session_state.announce_glances(state, observed.glances)
      })
    ReadAwaited(reply) -> answer(state, reply, awaited_observer(state))
    ReadKernel(reply) ->
      answer(
        state,
        reply,
        option.map(state.kernel, fn(session) { session.kernel }),
      )
    InboxChanged -> actor.continue(inbox_changed(state))
    MovedAway(detail) ->
      actor.continue(
        session_state.State(..session_naming.cancel(state), moved: Some(detail)),
      )
    SwitchModel(caller, provider, model, reply) -> {
      let #(state, changed) =
        session_switch.queue(state, caller, provider, model)
      answer(state, reply, changed)
    }
    RequestBoundary(id, reply) -> {
      case turn.live(state.activity, id) {
        False -> answer(state, reply, Error("stale run"))
        True -> {
          let #(state, selection) = session_switch.apply_pending(state)
          answer(arm_rest(state, id), reply, Ok(selection))
        }
      }
    }
    ChangeConfiguration(expected, patch, attachment, reply) -> {
      // Recheck ownership in the actor: the lease can expire after HTTP validation.
      case option.map(attachment, acp_attachments.holds(state.info.id, _)) {
        Some(False) -> answer(state, reply, Error(refusal.AttachmentLost))
        _ -> {
          let #(state, changed) =
            session_configure.change(
              state,
              session_configure.Conditional(expected, patch),
            )
          case changed {
            Error(error) -> answer(state, reply, Error(error))
            Ok(_) -> answer(state, reply, capture_state(state))
          }
        }
      }
    }
    Resume -> actor.continue(begin_workspace_probe(state, ResumeStart))
    Rewarm ->
      case busy(state) || queue_starts(state) {
        True -> actor.continue(state)
        False ->
          // Rewarming rebuilds the last request, which needs only the
          // composition a turn would start from.
          case turn_or_park(state, Rewarm) {
            Error(state) -> actor.continue(state)
            Ok(state) -> actor.continue(restore_last_call(state))
          }
      }
    RenameProfiles(renames) -> {
      let previous = state.info.provider
      let state = session_history.rename_profiles(state, renames)
      case state.info.provider == previous {
        True -> actor.continue(state)
        False -> {
          let base = "/sessions/" <> state.info.id
          bus.invalidate(["/sessions", base], [state.info.id], False)
          actor.continue(
            state |> session_state.invalidate(view.StaleSession, base),
          )
        }
      }
    }
    KernelOpened(token, result) ->
      case token == state.boot_token {
        True ->
          actor.continue(kernel_opened(
            session_state.State(..state, boot_ticket: None),
            result,
          ))
        False -> actor.continue(state)
      }
    PreparedOpened(token, result) ->
      case token == state.boot_token {
        True ->
          actor.continue(prepared_opened(
            session_state.State(..state, boot_ticket: None),
            result,
          ))
        False -> actor.continue(state)
      }
    ContextComposed(result) -> actor.continue(context_composed(state, result))
    ContextRebuilt(snapshot) -> actor.continue(context_rebuilt(state, snapshot))
    AcquireKernel(id, reply) -> acquire_kernel(state, id, reply)
    RestKernel(id, token) ->
      case token == state.rest_token && turn.live(state.activity, id) {
        // A tool call or the next request armed a newer timer.
        False -> actor.continue(state)
        True ->
          case restable(state, id, token), state.kernel {
            True, Some(kernel) ->
              actor.continue(release_kernel(state, kernel, None, True))
            // Work still running or a transition: look again.
            _, _ -> {
              rest_later(state.self, id, token)
              actor.continue(state)
            }
          }
      }
    IdleKernel(token) ->
      case
        token == state.rest_token,
        uses_kernel_transition(state) || state.booting != None
      {
        // A turn, a cell or a job ending since armed a newer timer.
        False, _ -> actor.continue(state)
        // A swap or boot under way: look again once it settles.
        True, True -> {
          let _ = albedo_clock.send_after(state.self, 1000, IdleKernel(token))
          actor.continue(state)
        }
        True, False -> begin_release(state, None, True)
      }
    WorkspaceReady(token, purpose, result) ->
      actor.continue(workspace_ready(state, token, purpose, result))
    StartQueued -> actor.continue(start_queued(state))
    AdmitOperation(operation, submission, committed, reply) ->
      admit_operation(state, operation, submission, committed, reply)
    AdmitACP(operation, submission, digest, committed, reply) ->
      case acp_attachments.holds(state.info.id, digest), editor_ready(state) {
        False, _ -> answer(state, reply, Decided(Error(refusal.AttachmentLost)))
        True, Error(reason) -> answer(state, reply, Decided(Error(reason)))
        True, Ok(_) ->
          admit_operation(state, operation, submission, committed, reply)
      }
    AdmissionCommitted(submission, result, committed) ->
      admission_committed(state, submission, result, committed)
    PublishACPOverlay(digest, generation, candidate, reply) -> {
      let pending =
        acp_attachments.read(state.info.id).0.readiness != acp_attachments.Ready
      case
        candidate,
        pending,
        busy(state) || state.booting != None || replacing_kernel(state)
      {
        None, False, _ -> answer(state, reply, Ok(Nil))
        _, _, True -> answer(state, reply, Error(acp_session.Busy))
        _, _, False -> {
          let published = case candidate {
            Some(candidate) ->
              acp_session.publish(
                runtime.ledger(state.host),
                state.info.id,
                digest,
                generation,
                candidate,
              )
            None ->
              case acp_attachments.holds(state.info.id, digest) {
                True -> Ok(Nil)
                False -> Error(acp_session.AttachmentChanged)
              }
          }
          case published {
            Error(reason) -> answer(state, reply, Error(reason))
            Ok(_) -> {
              let #(state, outcome) =
                session_extensions.reload(state, "editor MCP overlay replaced")
              case outcome {
                Ok(_) -> {
                  acp_attachments.reloaded(state.info.id)
                  process.send(state.self, StartQueued)
                  answer(
                    session_state.State(..state, blocked_until: 0),
                    reply,
                    Ok(Nil),
                  )
                }
                Error(reason) ->
                  answer(state, reply, Error(acp_session.ReloadFailed(reason)))
              }
            }
          }
        }
      }
    }
    Abort(id) ->
      case turn.owner(state.activity, id) {
        Some(run) if run.cancelled -> {
          // The Cancel-time interrupt may have landed on an idle kernel,
          // before the turn reached a tool; a stalled actor can delay this
          // Abort past a tool gate, so interrupt whatever runs now too.
          interrupt_kernel(state)
          kill(run.pid)
          finish_run(state, run, Error(loop.RunFailed("cancelled")))
        }
        _ -> actor.continue(state)
      }
    DropQueued(ids, reply) -> {
      let #(state, dropped) = drop_queued_in(state, ids)
      answer(state, reply, dropped)
    }
    ArrangeQueue(ids, reply) -> {
      let #(state, arranged) = arrange_queue_in(state, ids)
      answer(state, reply, arranged)
    }
    HoldInput(id, reply) -> {
      let #(state, held) = hold_input_in(state, id)
      answer(state, reply, held)
    }
    HoldLapsed(id, deadline) ->
      case dict.get(state.held, id) {
        Ok(held) if held == deadline ->
          actor.continue(release_input_in(state, id))
        _ -> actor.continue(state)
      }
    ReleaseInput(id, reply) -> answer(release_input_in(state, id), reply, Nil)
    QuietTurn(reply) ->
      answer(state, reply, case turn.quiet(state.activity) {
        True -> Ok(Nil)
        False -> Error("no turn is running")
      })
    EditInput(submission, reply) -> {
      let #(state, edited) = edit_input_in(state, submission)
      answer(state, reply, edited)
    }
    UserTurnQueued ->
      actor.continue(start_queued(
        session_state.State(..state, kernel_blocked: False),
      ))
    ReadCommands(reply) -> {
      let host = state.host
      let id = state.info.id
      let cwd = state.info.cwd
      runtime.peek_commands_async(host, id, cwd, process.send(reply, _))
      actor.continue(state)
    }
    ReadSelection(reply) -> answer(state, reply, model_selection(state.info))
    CancelInput(id, digest, reply) -> {
      case
        acp_session.authorize_cancellation(
          runtime.ledger(state.host),
          state.info.id,
          digest,
        )
      {
        Ok(_) -> actor.continue(cancel_input_in(state, id, reply))
        Error(reason) -> answer(state, reply, Error(reason))
      }
    }
    InterruptCaptured(run_id, through_order, reply) -> {
      case
        operations.cancel_through(
          runtime.ledger(state.host),
          state.info.id,
          through_order,
        )
      {
        Error(error) -> answer(state, reply, Error(error))
        Ok(cancelled) -> {
          let state = session_naming.cancel_through(state, through_order)
          let requested = case interruptible_run(state), run_id {
            Some(run), Some(id) if run.id == id -> {
              interrupt_kernel(state)
              let _ = albedo_clock.send_after(state.self, 2500, Abort(run.id))
              True
            }
            _, _ -> False
          }
          let state = case requested {
            True ->
              session_state.State(
                ..clear_tool_progress(state),
                activity: cancel_turn(state),
              )
            False -> state
          }
          let state =
            session_submission.refresh_ids(state, cancelled)
            |> session_state.queue_changed
            |> session_state.announce
          answer(state, reply, Ok(Interruption(run_id, requested, cancelled)))
        }
      }
    }
    Interrupt(reply) -> {
      let state = session_naming.cancel_initial(state)
      case operations.cancel(runtime.ledger(state.host), state.info.id) {
        Error(error) ->
          answer(session_state.emit(state, view.error(error)), reply, False)
        Ok(cancelled) -> interrupt_waiting(state, cancelled, reply)
      }
    }
    ChangeWorkspace(request, reply) -> {
      let state = stirred(state)
      let recorded = case
        busy(state) || uses_kernel_transition(state) || state.booting != None
      {
        True ->
          Error(
            session_workspace.Native(refusal.Busy(
              "session must be idle to change workspace",
            )),
          )
        False -> {
          use destination <- result.try(
            locations.workspace(request.destination)
            |> result.map_error(session_workspace.Destination),
          )
          session_workspace.record(
            runtime.ledger(state.host),
            session_workspace.Request(
              ..request,
              session: state.info.id,
              destination: location.to_string(destination),
            ),
          )
          |> result.map_error(session_workspace.Native)
        }
      }
      let state = case recorded {
        Ok(_) -> workspace_changed(state)
        Error(_) -> state
      }
      answer(state, reply, recorded)
    }
    ApplyWorkspace(reply) -> {
      case busy(state) || state.booting != None {
        True -> answer(state, reply, Ok(False))
        False -> {
          case apply_workspace_state(state) {
            Error(#(state, error)) -> answer(state, reply, Error(error))
            Ok(state) ->
              case state.workspace_reset {
                Some(_) -> actor.continue(park(state, ApplyWorkspace(reply)))
                None -> answer(state, reply, Ok(True))
              }
          }
        }
      }
    }
    ChangeModel(model, provider_name, effort, reply) -> {
      let #(state, outcome) =
        session_configure.change(
          stirred(state),
          session_configure.SelectModel(model, provider_name, effort),
        )
      answer(
        state,
        reply,
        result.map(outcome, fn(_) { model_selection(state.info) })
          |> result.map_error(refusal.explain),
      )
    }

    UpgradeKernel(reply) -> begin_upgrade(state, reply)
    UpgradeCompletion(outcome, reply) -> upgraded_kernel(state, outcome, reply)
    RestartKernel(by, reply) -> begin_restart(state, by, reply)
    KernelRestarted(stopped, report, reply) ->
      answer(state, reply, result.replace(stopped, report))
    ReadFast(reply) -> {
      let value = {
        use body <- result.try(session_provider.read_fast(state))
        use configuration <- result.map(
          store.snapshot(
            runtime.ledger(state.host),
            session_configuration.read_in(_, state.info.id),
          ),
        )
        #(body, configuration)
      }
      answer(state, reply, value)
    }
    ReadEffort(reply) ->
      answer(state, reply, session_provider.read_effort(state))
    ChangeEffort(level, reply) -> {
      let #(state, changed) =
        session_configure.change(
          stirred(state),
          session_configure.SelectEffort(level),
        )
      answer(
        state,
        reply,
        result.map(changed, fn(saved) {
          let assert Some(effort) = saved.effort
          json.object([
            #("effort", json.string(effort)),
            #("message", json.string("reasoning effort set to " <> effort)),
          ])
        })
          |> result.map_error(refusal.explain),
      )
    }
    ReadCompactAt(reply) ->
      answer(state, reply, session_provider.read_compact_at(state))
    ChangeCompactAt(tokens, reply) -> {
      let #(state, changed) =
        session_configure.change(
          stirred(state),
          session_configure.SelectContextWindow(tokens),
        )
      answer(
        state,
        reply,
        result.map(changed, fn(saved) {
          let message = case saved.context_window {
            Some(window) ->
              "context window for this session set to "
              <> int.to_string(window)
              <> " tokens"
            None ->
              "restored the model's default context window for this session"
          }
          json.object([
            #("context_window", json.nullable(saved.context_window, json.int)),
            #("message", json.string(message)),
          ])
        })
          |> result.map_error(refusal.explain),
      )
    }

    ExtensionChanged(url, reply) ->
      answer(
        session_state.invalidate(state, view.StaleExtension, url),
        reply,
        Nil,
      )
    ReadName(reply) -> answer(state, reply, session_naming.read(state))
    AskSideQuestion(id, question, reply) -> ask_side(state, id, question, reply)
    SideQuestionFinished(id, outcome) -> finish_side(state, id, outcome)
    CancelSideQuestion(id, reply) -> {
      case state.side_question {
        Some(exchange) if exchange.id == id -> {
          let exchange = case exchange.progress {
            side_question.Running(worker, stop) -> {
              turn.cancel_call(worker, stop)
              side_question.Exchange(
                ..exchange,
                progress: side_question.Cancelled,
              )
            }
            _ -> exchange
          }
          answer(publish_side(state, exchange), reply, Ok(exchange))
        }
        _ -> answer(state, reply, Error(side_question.NotFound))
      }
    }
    DismissSideQuestion(id, dismissed, reply) -> {
      case side_question.dismiss(state.side_question, id, dismissed) {
        Error(reason) -> answer(state, reply, Error(reason))
        Ok(exchange) ->
          answer(publish_side(state, exchange), reply, Ok(exchange))
      }
    }
    ClaimSideContinuation(id, target, reply) -> {
      case side_question.claim(state.side_question, id, target) {
        Error(reason) -> answer(state, reply, Error(reason))
        Ok(#(exchange, promotion)) -> {
          let _ =
            session_side_question.save(
              runtime.ledger(state.host),
              state.info.id,
              exchange,
            )
          answer(
            session_state.State(..state, side_question: Some(exchange)),
            reply,
            Ok(promotion),
          )
        }
      }
    }
    SettleSideContinuation(id, target, created) -> {
      case state.side_question {
        Some(exchange) if exchange.id == id ->
          actor.continue(publish_side(
            state,
            side_question.settle(exchange, target, created),
          ))
        _ -> actor.continue(state)
      }
    }
    GenerateTitle(reply) -> {
      let #(state, started) = session_naming.regenerate(state, TitleFinished)
      answer(state, reply, started)
    }
    TitleFinished(revision, outcome) ->
      actor.continue(session_naming.finish(
        state,
        revision,
        outcome,
        synced_spend,
      ))
    ChangeName(name, reply) -> {
      let #(state, changed) = session_naming.select(state, name)
      answer(state, reply, changed)
    }
    SuggestName(name, reply) -> {
      let #(state, suggested) = session_naming.suggest(state, name)
      answer(state, reply, suggested)
    }

    ReloadData(reply) ->
      case replacing_kernel(state) {
        True -> actor.continue(park(state, ReloadData(reply)))
        False ->
          transition(
            reply,
            session_extensions.reload(state, "session data reloaded"),
          )
      }
    RefreshRequested(reason) ->
      case replacing_kernel(state) {
        True -> actor.continue(park(state, RefreshRequested(reason)))
        False ->
          actor.continue(session_extensions.refresh_requested(state, reason))
      }
    PersistCompaction(id, response) -> {
      persist_compaction(state, id, response)
      actor.continue(state)
    }
    AdmitCompaction(id, strategy, reply) -> {
      let request = compaction_action.request(id, state.info.id, strategy)
      let admitted = {
        use previous <- result.try(operations.check(
          runtime.ledger(state.host),
          request,
        ))
        case previous {
          Some(receipt) -> Ok(#(receipt, False))
          None -> {
            use _ <- result.try(case state.closing || busy(state) {
              True -> Error(refusal.Busy("session must be idle to compact"))
              False -> Ok(Nil)
            })
            store.query(runtime.ledger(state.host), fn(db) {
              operations.admit_compaction_in(
                db,
                request,
                compaction_action.receipt(id, state.info.id, "running", None),
                fn(db) { family.open_in(db, request.target) },
              )
            })
          }
        }
      }
      case admitted {
        Error(error) -> answer(state, reply, Error(error))
        Ok(#(receipt, False)) -> answer(state, reply, Ok(receipt))
        Ok(#(receipt, True)) -> {
          process.send(reply, Ok(receipt))
          handle(state, Compact(strategy, Some(id), process.new_subject()))
        }
      }
    }
    Compact(strategy, action_id, reply) ->
      case state.closing || busy(state) {
        True -> {
          finish_compaction(
            state,
            action_id,
            reply,
            Error(refusal.Busy("session must be idle to compact")),
          )
          actor.continue(state)
        }
        False ->
          // Compaction needs the composition, not a kernel.
          case turn_or_park(state, Compact(strategy, action_id, reply)) {
            Error(state) -> actor.continue(state)
            Ok(state) -> compact(state, strategy, action_id, reply)
          }
      }
    StopJob(id, reply) ->
      case state.kernel {
        Some(kernel) ->
          answer(
            state,
            reply,
            runtime.stop_job(kernel, id)
              |> result.map_error(fn(error) {
                case error {
                  python.JobNotFound -> command.JobNotFound
                  python.StopFailed(detail) -> command.Other(detail)
                }
              }),
          )
        // A kernel is released only with no live job, so none runs now.
        None -> answer(state, reply, Error(command.JobNotFound))
      }
    Watch(owner, key, notify) -> {
      let watchers = case
        list.any(state.watchers, fn(watcher) {
          watcher.owner == owner && watcher.key == key
        })
      {
        True -> state.watchers
        False -> {
          let monitor = process.monitor(owner)
          [
            session_state.Watcher(owner, key, monitor, notify, False),
            ..state.watchers
          ]
        }
      }
      actor.continue(session_state.watch_glances(
        session_state.State(..state, watchers: watchers),
      ))
    }
    Unwatch(owner, key) -> {
      let watchers =
        list.filter(state.watchers, fn(watcher) {
          case watcher.owner == owner && watcher.key == key {
            True -> {
              process.demonitor_process(watcher.monitor)
              False
            }
            False -> True
          }
        })
      actor.continue(session_state.watch_glances(
        session_state.State(..state, watchers: watchers),
      ))
    }
    Consumed(owner, key, cursor, wake_consumed) -> {
      let watchers = case
        cursor.generation == state.generation
        && cursor.sequence >= 0
        && cursor.sequence <= state.sequence
      {
        False -> state.watchers
        True ->
          list.map(state.watchers, fn(watcher) {
            case watcher.owner == owner && watcher.key == key {
              False -> watcher
              True -> {
                let notified = watcher.notified && !wake_consumed
                case !notified && cursor.sequence < state.sequence {
                  True -> {
                    watcher.notify()
                    session_state.Watcher(..watcher, notified: True)
                  }
                  False -> session_state.Watcher(..watcher, notified: notified)
                }
              }
            }
          })
      }
      actor.continue(session_state.watch_glances(
        session_state.State(..state, watchers: watchers),
      ))
    }
    Read(after, reply) -> {
      let cursor = Cursor(state.generation, state.sequence)
      let replay = case after {
        Some(after) if after.generation == state.generation ->
          event_buffer.since(state.events, after.sequence, state.sequence)
        _ -> Error(Nil)
      }
      let page = case replay {
        Ok(events) -> Ok(#(cursor, events, None))
        Error(_) ->
          capture_state(state)
          |> result.map(fn(observe) { #(cursor, [], Some(observe)) })
      }
      answer(state, reply, page)
    }

    CatalogLoaded -> {
      let url = "/sessions/" <> state.info.id <> "/catalog"
      bus.invalidate([url], [state.info.id], False)
      actor.continue(session_state.invalidate(state, view.StaleCatalog, url))
    }
    AgentProgress(text) ->
      actor.continue(session_state.emit(
        state,
        view.Note(mail.new_id(), "agent", text, None),
      ))
    Publish(id, event, reply) ->
      case turn.live(state.activity, id) {
        True ->
          case event {
            view.ProviderStarted ->
              answer(
                session_state.State(
                  ..state,
                  activity: turn.committed(
                    state.activity,
                    id,
                    session_info.Idle,
                  ),
                )
                  |> session_state.announce,
                reply,
                True,
              )
            view.Compacted(observed, evicted, summary) -> {
              let activity = case turn.running(state.activity) {
                Some(
                  turn.Run(work: turn.Compaction(action_id, reply, report), ..) as run,
                ) ->
                  turn.Running(
                    turn.Run(
                      ..run,
                      work: turn.Compaction(
                        action_id,
                        reply,
                        turn.CompactionReport(
                          ..report,
                          observation: Some(turn.CompactionObservation(
                            observed,
                            evicted,
                            summary,
                          )),
                        ),
                      ),
                    ),
                  )
                _ -> state.activity
              }
              answer(
                session_state.emit(
                  session_state.State(..state, activity: activity),
                  event,
                ),
                reply,
                True,
              )
            }
            _ -> answer(publish_active(state, event), reply, True)
          }
        False -> answer(state, reply, False)
      }
    ToolProgressDelta(id, step, attempt, output_index, name, fragment, reply) ->
      tool_progress_delta(
        state,
        id,
        step,
        attempt,
        output_index,
        name,
        fragment,
        reply,
      )
    ToolProgressRunning(
      id,
      step,
      attempt,
      output_index,
      tool_call_id,
      name,
      reply,
    ) ->
      tool_progress_running(
        state,
        id,
        step,
        attempt,
        output_index,
        tool_call_id,
        name,
        reply,
      )
    ToolProgressReset(id, attempt, reply) ->
      tool_progress_reset(state, id, attempt, reply)
    ToolProgressFinish(id, progress_id, reply) ->
      tool_progress_finish(state, id, progress_id, reply)
    ProgressFlush(token) -> tool_progress_flush(state, token)
    PublishOutput ->
      actor.continue(session_state.flush_output(
        session_state.State(..state, output_timer: None),
      ))
    FlushDraft ->
      actor.continue(
        session_state.State(
          ..state,
          draft_timer: None,
          active_output: active_output.flush_text(state.active_output),
        ),
      )
    CheckpointKernel(token) -> {
      case
        token == state.rest_token
        && turn.running(state.activity) == None
        && !uses_kernel_transition(state)
        && state.booting == None
        && !state.closing
        && option.map(state.kernel, runtime.live_work) == Some(Ok(0)),
        state.kernel
      {
        True, Some(kernel) -> {
          let #(home, id, self) = #(state.home, state.info.id, state.self)
          let _ =
            process.spawn_unlinked(fn() {
              let _ =
                albedo_protect.attempt(fn() {
                  session_namespace.save_state_within(
                    home,
                    id,
                    kernel,
                    session_namespace.close_state_timeout,
                  )
                })
              process.send(self, Checkpointed)
            })
          actor.continue(session_state.State(..state, checkpointing: Some([])))
        }
        _, _ -> actor.continue(state)
      }
    }
    Checkpointed -> {
      let parked = option.unwrap(state.checkpointing, [])
      list.each(parked, process.send(state.self, _))
      actor.continue(session_state.State(..state, checkpointing: None))
    }
    ApplyPendingSwitch -> {
      case turn.running(state.activity) != None || state.booting != None {
        True -> actor.continue(state)
        False -> {
          let #(state, _) = session_switch.apply_pending(state)
          actor.continue(state)
        }
      }
    }
    ResumeTitle ->
      actor.continue(session_naming.resume_initial(state, TitleFinished))
    Commit(
      id,
      [],
      stage,
      _,
      _,
      conversation.Follow(None, None, None, _, []),
      answer,
      ack,
    ) -> {
      // The worker's move to the model after its tools' results saves
      // nothing new: a restart resumes a turn left at Tool or Model alike,
      // so the stage reaches the store with the response's own commit.
      process.send(ack, Nil)
      case turn.owner(state.activity, id) {
        Some(_) -> {
          process.send(answer, Ok(#(usage.now(), None)))
          actor.continue(
            session_state.State(
              ..state,
              activity: turn.committed(state.activity, id, stage),
            ),
          )
        }
        _ -> {
          process.send(answer, Error("stale run"))
          actor.continue(state)
        }
      }
    }
    Commit(id, inputs, stage, thought_ms, tool, follow, answer, ack) -> {
      process.send(ack, Nil)
      case turn.owner(state.activity, id) {
        Some(_) -> {
          // Completed tool results are saved even when cancellation was requested.
          let #(ledger, session, provider) = #(
            runtime.ledger(state.host),
            state.info.id,
            Some(state.info.provider),
          )
          session_state.write_then(
            state,
            with_boundary(state, fn() {
              conversation.commit_response(
                ledger,
                session,
                inputs,
                stage,
                provider,
                thought_ms,
                id,
                tool,
                follow,
              )
            }),
            fn(state, written) {
              process.send(
                answer,
                result.map(written, fn(written) { written.0 }),
              )
              case written {
                Ok(#(#(timestamp, _), boundary)) ->
                  session_history.remember_response_committed(
                    session_state.State(
                      ..state,
                      activity: turn.committed(state.activity, id, stage),
                    ),
                    inputs,
                    timestamp,
                    thought_ms,
                    boundary,
                    follow.phase,
                  )
                  |> remember_usage(follow.usage)
                Error(_) -> state
              }
            },
          )
          |> actor.continue
        }
        _ -> {
          process.send(answer, Error("stale run"))
          actor.continue(state)
        }
      }
    }
    Salvage(id, reason, answer, ack) -> {
      process.send(ack, Nil)
      case turn.owner(state.activity, id) {
        Some(run) if !run.cancelled -> {
          let #(state, write) =
            session_salvage.gather(state, run, session_salvage.CutOff(reason))
          session_state.write_then(state, write, fn(state, written) {
            process.send(
              answer,
              result.map(written, fn(salvaged) {
                option.map(salvaged, fn(salvaged) {
                  #(salvaged.timestamp, salvaged.inputs)
                })
                |> option.unwrap(#(0, []))
              }),
            )
            session_salvage.remember(state, written |> result.unwrap(None))
          })
          |> actor.continue
        }
        _ -> {
          process.send(answer, Ok(#(0, [])))
          actor.continue(state)
        }
      }
    }
    CommitFits(id, fits, answer, ack) -> {
      process.send(ack, Nil)
      case turn.owner(state.activity, id) {
        Some(_) -> {
          let #(ledger, session, provider) = #(
            runtime.ledger(state.host),
            state.info.id,
            state.info.provider,
          )
          session_state.write_then(
            state,
            with_boundary(state, fn() {
              conversation.commit_fits(ledger, session, fits, provider)
            }),
            fn(state, written) {
              process.send(
                answer,
                result.map(written, fn(outcome) { outcome.0 }),
              )
              case written {
                Ok(#(timestamp, boundary)) ->
                  session_history.remember_fits(
                    state,
                    fits,
                    timestamp,
                    boundary,
                  )
                Error(_) -> state
              }
            },
          )
          |> actor.continue
        }
        None -> {
          process.send(answer, Error("stale run"))
          actor.continue(state)
        }
      }
    }
    Landed(continue) -> {
      let state =
        continue(session_state.State(..state, writing: state.writing - 1))
      actor.continue(answer_captures(state))
    }
    // The running turn takes what steers it from the inbox at each step; what
    // waits for the turn to end stays there and starts the next one.
    DrainSteering(id, answer, ack) -> {
      process.send(ack, Nil)
      let exclusive = turn.exclusive(state.active_submissions)
      let #(state, taken) = case turn.live(state.activity, id) {
        False -> #(state, Error(Nil))
        True ->
          case take_queued(state, turn.steering(_, exclusive)) {
            Ok(queued) -> #(state, Ok(queued))
            // An unreadable inbox steers nothing this step.
            Error(error) -> #(
              session_state.emit(state, view.error(error)),
              Ok([]),
            )
          }
      }
      case taken {
        Error(_) -> {
          process.send(answer, Error("cancelled"))
          actor.continue(state)
        }
        Ok([]) -> {
          process.send(answer, Ok(#(0, [])))
          actor.continue(state)
        }
        Ok(queued) -> {
          let inputs = session_submission.inputs(queued)
          let #(ledger, session, provider, cwd) = #(
            runtime.ledger(state.host),
            state.info.id,
            Some(state.info.provider),
            state.info.cwd,
          )
          let letters = turn.letters(queued)
          let commits = session_submission.commits(queued, 0)
          let shells = session_submission.shells(queued, 0)
          // The drained rows join the run now; a failed commit leaves them
          // waiting in the inbox.
          let drained =
            session_state.State(
              ..state,
              active_submissions: list.append(state.active_submissions, queued),
            )
          drained
          |> session_state.write_then(
            with_boundary(drained, fn() {
              conversation.commit_operations(
                ledger,
                session,
                inputs,
                session_info.Model,
                provider,
                letters,
                commits,
                shells,
                session_submission.kinds(queued, 0),
                id,
                cwd,
                [],
              )
            }),
            fn(state, written) {
              process.send(
                answer,
                result.map(written, fn(outcome) { #(outcome.0, inputs) }),
              )
              case written {
                Error(_) ->
                  session_state.State(
                    ..state,
                    active_submissions: list.filter(
                      state.active_submissions,
                      fn(active) { !list.contains(queued, active) },
                    ),
                  )
                Ok(#(timestamp, boundary)) ->
                  session_history.remember_committed(
                    state,
                    inputs,
                    timestamp,
                    boundary,
                  )
                  |> session_submission.emit(queued, timestamp)
                  |> session_submission.membership(id)
                  |> publish_steered_shells(shells, id, timestamp)
                  |> session_namespace.notice_read(queued)
                  |> session_state.queue_changed
              }
            },
          )
          |> actor.continue
        }
      }
    }

    ReportPin(id, head, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id), head, state.pin {
        True, Some(head), loop.Pinned(prompt, _) ->
          actor.continue(
            session_state.State(
              ..prepared(state, head),
              pin: loop.Pinned(prompt, Some(head)),
            ),
          )
        True, Some(head), loop.Unpinned -> actor.continue(prepared(state, head))
        True, None, loop.Pinned(..) -> {
          let #(ledger, session) = #(runtime.ledger(state.host), state.info.id)
          session_state.write_then(
            state,
            fn() { conversation.clear_prompt_pin(ledger, session) },
            fn(state, cleared) {
              case cleared {
                Ok(_) ->
                  session_state.State(
                    ..state,
                    pin: loop.Unpinned,
                    prepared_head: None,
                  )
                Error(error) ->
                  session_state.emit(
                    state,
                    view.error(
                      "compaction finished but the pinned system prompt could not be released: "
                      <> error,
                    ),
                  )
              }
            },
          )
          |> actor.continue
        }
        _, _, _ -> actor.continue(state)
      }
    }
    ReportShellDelivery(id, texts, reply) -> {
      let state = case turn.live(state.activity, id) {
        False -> state
        True ->
          case
            conversation.acknowledge_shells(
              runtime.ledger(state.host),
              state.info.id,
              texts,
            )
          {
            Error(error) ->
              session_state.emit(
                state,
                view.error("shell delivery acknowledgment failed: " <> error),
              )
            Ok(commands) ->
              list.fold(commands, state, fn(state, command) {
                session_state.emit(state, view.ShellCommand(command))
              })
          }
      }
      answer(state, reply, Nil)
    }
    ReportSent(id, call, reply) -> {
      process.send(reply, Nil)
      case turn.live(state.activity, id) {
        True -> observe(state, extension.CallSent(call))
        False -> Nil
      }
      actor.continue(state)
    }
    ReportCompacting(id, update, reply) -> {
      process.send(reply, Nil)
      actor.continue(
        session_state.State(
          ..state,
          activity: turn.progress(state.activity, id, update, usage.now()),
        )
        |> session_state.announce,
      )
    }
    CallInBackground(request, prefix, reply) ->
      actor.continue(start_background(state, request, prefix, reply))
    BackgroundFinished(id, started, outcome) ->
      case turn.owner(state.activity, id) {
        Some(turn.Run(work: turn.Background(reply), ..) as run) -> {
          // The call is a row now. Read what it added before the client is told.
          let state = synced_spend(state)
          let state = case run.cancelled, outcome {
            False, Ok(_) -> rewarmed(state, started)
            _, _ -> state
          }
          background_finish(state, run, reply, outcome)
        }
        _ -> actor.continue(state)
      }
    RecordContext(id, snapshot, compacted, reply) ->
      answer(
        case turn.live(state.activity, id) {
          True -> {
            let was = turn.running(state.activity)
            let activity = turn.clear_compaction(state.activity, id)
            let state =
              session_state.State(..state, context: snapshot, activity:)
            let state = case was == turn.running(activity) {
              True -> state
              False -> session_state.announce(state)
            }
            case compacted {
              True -> elide_compacted_images(state)
              False -> state
            }
            |> session_state.invalidate(
              view.StaleContext,
              "/sessions/" <> state.info.id <> "/context",
            )
          }
          False -> state
        },
        reply,
        Nil,
      )
    ReadContext(reply) -> {
      let #(state, snapshot) = context_read(state)
      answer(state, reply, snapshot)
    }
    Finished(id, outcome) ->
      case turn.owner(state.activity, id) {
        Some(run) -> finish_run(state, run, outcome)
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(_, pid, _)) -> {
      let state =
        session_state.State(
          ..state,
          watchers: list.filter(state.watchers, fn(watcher) {
            watcher.owner != pid
          }),
        )
        |> session_state.watch_glances
      case turn.running(state.activity) {
        Some(run) if run.pid == pid ->
          case run.work {
            turn.Background(reply) ->
              background_finish(
                state,
                run,
                reply,
                Error("background call worker stopped"),
              )
            turn.Summary(_, _, reply) ->
              summary_finish(
                state,
                run,
                reply,
                Error("the summary worker stopped"),
              )
            _ ->
              finish_run(
                state,
                run,
                Error(loop.RunFailed(
                  "worker stopped; execution may have had effects",
                )),
              )
          }
        _ -> actor.continue(state)
      }
    }
    Down(_) -> actor.continue(state)
    Idle(reply) -> {
      let #(kernel, jobs) = case state.kernel {
        Some(kernel) -> #(
          option.from_result(runtime.kernel_pid(kernel)),
          runtime.job_count(kernel),
        )
        None -> #(None, 0)
      }
      // Live background jobs keep their kernel: releasing it would kill work
      // the session still owes a wake for, so the reaper counts them.
      answer(
        state,
        reply,
        Report(
          uses_kernel(state),
          kernel,
          state.history != None,
          albedo_clock.monotonic_ms() - state.last_touch,
          jobs,
        ),
      )
    }
    // Expiry decides on reports taken earlier in its sweep; deciding again
    // here, where boots start, keeps the file for one begun since.
    ExpireState(reply) ->
      case state.kernel, uses_kernel(state) {
        None, False -> {
          discard_state(state.home, state.info.id)
          answer(state, reply, True)
        }
        _, _ -> answer(state, reply, False)
      }
    Release(reply, automatic) -> begin_release(state, Some(reply), automatic)
    ReleaseResting -> begin_release(state, None, True)
    Released(kernel, saved, reply, automatic) -> {
      let parked = option.unwrap(state.releasing, [])
      case session_namespace.may_release(saved, automatic:) {
        False -> {
          list.each(parked, process.send(state.self, _))
          release_answer(
            session_state.State(..state, releasing: None),
            reply,
            False,
          )
        }
        True -> {
          session_namespace.forget(kernel)
          // Reset and any subsequent Open are sent by this actor, in that order.
          runtime.reset_session_async(state.host, state.info.id)
          process.send(state.self, Collect)
          list.each(parked, process.send(state.self, _))
          release_answer(
            session_state.State(
              ..state,
              kernel: None,
              released: Some(kernel),
              releasing: None,
              // A turn resting on its model still sends the request this
              // snapshot shows (albedo-suite); only a resting session drops it.
              context: case turn.running(state.activity) {
                Some(_) -> state.context
                None -> session_state.unprepared()
              },
            )
              |> session_namespace.noted(session_namespace.released_text(
                saved,
                "nothing was attached",
              )),
            reply,
            True,
          )
        }
      }
    }
    EvictHistory(reply) ->
      case turn.running(state.activity) {
        Some(_) -> answer(state, reply, False)
        None -> {
          let evicted = state.history != None
          process.send(state.self, Collect)
          answer(
            session_state.State(..state, history: None)
              |> forget_recomputed_context,
            reply,
            evicted,
          )
        }
      }
    Collect -> {
      collect()
      actor.continue(state)
    }
    CollectQuiet -> {
      quiet(state.self, CollectQuiet)
      actor.continue(state)
    }
    ClaimDeletion(request, token, deadline, reply) -> {
      let claimed = case
        !request.subtree && { busy(state) || state.booting != None }
      {
        True -> Error(refusal.Busy("session must be idle to delete"))
        False ->
          family.claim_deletion(
            runtime.ledger(state.host),
            request,
            token,
            deadline,
          )
      }
      answer(state, reply, claimed)
    }
    CloseAgent(reply) -> {
      use <- bool.lazy_guard(
        state.closing || state.pending_agent_close != None,
        fn() {
          answer(
            state,
            reply,
            Error("agent is closed; cleanup is still pending"),
          )
        },
      )
      let cancelled =
        operations.cancel(runtime.ledger(state.host), state.info.id)
      use <- bool.lazy_guard(result.is_error(cancelled), fn() {
        answer(state, reply, Error("could not cancel agent inputs"))
      })
      let #(state, _) = stop_waiting(state, result.unwrap(cancelled, []))
      use <- bool.lazy_guard(
        turn.running(state.activity) != None || state.finishing,
        fn() {
          actor.continue(
            session_state.State(
              ..state,
              pending_agent_close: Some(CloseAgent(reply)),
            ),
          )
        },
      )
      case replacing_kernel(state) || state.booting != None {
        True -> actor.continue(park(state, CloseAgent(reply)))
        False -> {
          let state = session_naming.cancel(state)
          cancel_side_worker(state)
          stop_shell_worker(state)
          let #(home, host, id, kernel, self) = #(
            state.home,
            state.host,
            state.info.id,
            state.kernel,
            state.self,
          )
          let _ =
            process.spawn_unlinked(fn() {
              let stopped = close_agent_kernel(host, home, id, kernel)
              process.send(self, Deleted(stopped, reply))
            })
          actor.continue(session_state.State(..state, closing: True))
        }
      }
    }
    CloseForDeletion(reply) -> {
      let state = withdraw_boot(state)
      let state = session_naming.cancel(state)
      cancel_side_worker(state)
      stop_shell_worker(state)
      let state =
        session_state.State(
          ..state,
          booting: None,
          activity: cancel_turn(state),
        )
      case turn.running(state.activity) {
        Some(run) -> {
          interrupt_kernel(state)
          kill(run.pid)
        }
        None -> Nil
      }
      let #(host, id, self) = #(state.host, state.info.id, state.self)
      let _ =
        process.spawn_unlinked(fn() {
          process.send(self, Deleted(runtime.delete_session(host, id), reply))
        })
      actor.continue(session_state.State(..state, closing: True))
    }
    Deleted(outcome, reply) -> {
      case outcome {
        Error(error) ->
          answer(
            session_state.State(..state, closing: False),
            reply,
            Error(error),
          )
        Ok(_) -> {
          active_output_store.revoke(state.home, state.info.id)
          cleanup_registrations(state.info.id)
          account_pools.forget_session(state.info.id)
          wake_watchers(state)
          process.send(reply, Ok(Nil))
          actor.stop()
        }
      }
    }
    Close(reply) -> {
      let _ = option.map(state.draft_timer, process.cancel_timer)
      let state = session_naming.cancel(state)
      cancel_side_worker(state)
      stop_shell_worker(state)
      case turn.running(state.activity) {
        Some(run) -> {
          let state = session_state.flush_output(state)
          let _ = active_output.flush_text(state.active_output)
          interrupt_kernel(state)
          kill(run.pid)
          forget(state)
        }
        None -> close_idle(state)
      }
      wake_watchers(state)
      process.send(reply, Nil)
      actor.stop()
    }
    Unload(_) | StartSummary(..) | RewindHistory(..) ->
      check_children(state, message)
    ChildrenObserved(work, children_busy) ->
      finish_idle_work(state, work, children_busy)
  }
}

pub fn start_shell_command(
  worker: Session,
  id: String,
  command: String,
) -> Result(shell_commands.Command, Refusal) {
  actor_call.try_call(worker, 5000, StartShell(id, command, _))
  |> result.replace_error(refusal.Unavailable("shell_command_unavailable"))
  |> result.flatten
}

pub fn stop_shell_command(
  worker: Session,
  id: String,
) -> Result(shell_commands.Command, Refusal) {
  actor_call.try_call(worker, 5000, StopShell(id, _))
  |> result.replace_error(refusal.Unavailable("shell_command_unavailable"))
  |> result.flatten
}

fn stop_shell_worker(state: State) -> Nil {
  case state.shell_worker {
    Some(#(_, worker)) -> shell_commands.stop(worker)
    None -> Nil
  }
}

fn start_shell(
  state: State,
  id: String,
  command: String,
  reply: Subject(Result(shell_commands.Command, Refusal)),
) -> actor.Next(State, Message) {
  let #(closing, resetting, cwd, session_id) = #(
    state.closing,
    state.workspace_reset != None,
    state.info.cwd,
    state.info.id,
  )
  let admitted =
    shell_commands.admit(
      runtime.ledger(state.host),
      state.info.id,
      id,
      command,
      fn(db) {
        use _ <- result.try(family.open_in(db, session_id))
        case closing || resetting || cwd == "" {
          True -> Error(refusal.Unavailable("shell_command_unavailable"))
          False ->
            case location.parse(cwd) {
              Ok(location.Local(_)) -> Ok(Nil)
              _ -> Error(refusal.ShellCommandRemoteUnsupported)
            }
        }
      },
    )
  case admitted {
    Error(error) -> answer(state, reply, Error(error))
    Ok(#(command, False)) -> answer(state, reply, Ok(command))
    Ok(#(command, True)) -> {
      let #(ledger, session, self) = #(
        runtime.ledger(state.host),
        state.info.id,
        state.self,
      )
      let notify = fn(command) {
        actor_call.try_call(self, 5000, ShellChanged(command, _))
        |> result.replace_error("session did not acknowledge shell output")
      }
      let ended = fn(status, code, error) {
        actor_call.try_call(self, 5000, ShellEnded(id, status, code, error, _))
      }
      let failed = fn(error) {
        // Whatever was captured is flushed before the outcome is recorded.
        let _ = shell_commands.sync(ledger, session, id)
        case ended(shell_commands.Failed, None, Some(error)) {
          // No actor is left to own the outcome. A replacement actor also
          // reconciles running records before admitting any new command.
          Error(actor_call.CalleeDown) -> {
            let _ =
              shell_commands.finish(
                ledger,
                session,
                id,
                shell_commands.Interrupted,
                None,
                Some(error),
              )
            Nil
          }
          _ -> Nil
        }
      }
      let receive = fn(text) {
        use frame <- result.try(shell_commands.decode_frame(text))
        case frame {
          shell_commands.Output(text, truncated) -> {
            use command <- result.try(shell_commands.append(
              ledger,
              session,
              id,
              text,
              truncated,
            ))
            notify(command)
          }
          shell_commands.Ended(status, code, error) -> {
            use _ <- result.try(shell_commands.sync(ledger, session, id))
            ended(status, code, error)
            |> result.replace_error(
              "session did not acknowledge shell completion",
            )
            |> result.flatten
          }
        }
      }
      let worker =
        shell_commands.start(state.info.cwd, command.command, receive, failed)
      answer(
        session_state.State(
          ..state,
          shell_commands: [command, ..state.shell_commands],
          shell_worker: Some(#(id, worker)),
        )
          |> session_state.emit(view.ShellCommand(command)),
        reply,
        Ok(command),
      )
    }
  }
}

/// A finished command's receipt waits in the inbox like any input: a running
/// turn reads it at its next step, and a resting session writes it into its
/// transcript at once (`flush_attached`).
fn queue_shell(state: State, command: shell_commands.Command) -> State {
  case command.status {
    shell_commands.Running -> state
    _ ->
      case
        mail.post_input(
          runtime.ledger(state.host),
          shell_commands.receipt(state.info.id, command),
        )
      {
        Error(refused) ->
          session_state.emit(
            state,
            view.error(
              "shell receipt not queued: " <> input.refused_text(refused),
            ),
          )
        Ok(_) -> state
      }
  }
}

fn publish_steered_shells(
  state: State,
  shells: List(#(Int, String)),
  run_id: String,
  timestamp: Int,
) -> State {
  let ids = list.map(shells, fn(shell) { shell.1 })
  let state =
    session_state.State(
      ..state,
      shell_commands: list.filter(state.shell_commands, fn(command) {
        !list.contains(ids, command.id)
      }),
    )
  list.fold(ids, state, fn(state, id) {
    case shell_commands.read(runtime.ledger(state.host), state.info.id, id) {
      Error(error) ->
        session_state.emit(state, view.error(refusal.explain(error)))
      Ok(command) ->
        state
        |> session_state.emit(
          view.Message(
            http_history.Entry(
              ..http_history.shell_entry(command, Some(timestamp)),
              turn_id: Some(run_id),
            ),
            [],
          ),
        )
        |> session_state.emit(view.ShellCommand(command))
    }
  })
}

/// A resting session writes the rows waiting in its inbox to be attached
/// (shell receipts, a moved session's notes) into its transcript at once. It
/// never starts a model turn.
fn flush_attached(state: State) -> State {
  flush(state, turn.attached)
}

/// The rows `pick` chooses, written into the transcript while the session
/// rests.
fn flush(state: State, pick: fn(List(turn.Queued)) -> List(String)) -> State {
  case turn.running(state.activity), state.closing {
    None, False ->
      case take_queued(state, pick) {
        Error(error) -> session_state.emit(state, view.error(error))
        Ok([]) -> state
        Ok(attached) ->
          list.fold(attached, state, flush_one)
          |> session_state.queue_changed
      }
    _, _ -> state
  }
}

fn flush_one(state: State, receipt: Submission) -> State {
  case receipt.source, receipt.submission_id {
    turn.Note(origin), Some(id) ->
      case
        conversation.commit_note(
          runtime.ledger(state.host),
          state.info.id,
          id,
          receipt.text,
          note_kind(origin, receipt.display),
          state.info.provider,
        )
      {
        Error(error) -> session_state.emit(state, view.error(error))
        Ok(timestamp) ->
          session_history.remember(state, [types.User(receipt.text)], timestamp)
      }
    _, _ -> flush_receipt(state, receipt)
  }
}

/// The kind of the row a note from `origin` is written as: the kernel's
/// notices show nothing, every other note shows its `display`.
fn note_kind(origin: String, display: String) -> transcript.Kind {
  case origin == session_namespace.notice_origin {
    True -> transcript.Notice
    False -> transcript.Note(origin, display)
  }
}

fn flush_receipt(state: State, receipt: Submission) -> State {
  case receipt.source {
    turn.Shell(id) ->
      case
        conversation.commit_shell(
          runtime.ledger(state.host),
          state.info.id,
          id,
          state.info.provider,
        )
      {
        Error(error) -> session_state.emit(state, view.error(error))
        Ok(committed) ->
          session_state.State(
            ..state,
            history: None,
            shell_commands: list.filter(state.shell_commands, fn(c) {
              c.id != committed.id
            }),
          )
          |> session_state.emit(
            view.Message(http_history.shell_entry(committed, None), []),
          )
          |> session_state.emit(view.ShellCommand(committed))
      }
    _ -> state
  }
}

fn check_children(state: State, work: Message) -> actor.Next(State, Message) {
  case occupied(state) {
    True -> finish_idle_work(state, work, True)
    False -> {
      let #(host, id, self) = #(state.host, state.info.id, state.self)
      let _ =
        process.spawn_unlinked(fn() {
          process.send(self, ChildrenObserved(work, children_working(host, id)))
        })
      actor.continue(state)
    }
  }
}

fn finish_idle_work(
  state: State,
  work: Message,
  children_busy: Bool,
) -> actor.Next(State, Message) {
  // The actor may have admitted new work while the family was observed.
  case work {
    Unload(reply) ->
      case children_busy || occupied(state) || state.watchers != [] {
        True -> answer(state, reply, False)
        // Unloading is automatic: it keeps a kernel an idle release would.
        False ->
          case
            save_on_close(state)
            |> option.map(session_namespace.may_release(_, automatic: True))
          {
            Some(False) -> answer(state, reply, False)
            _ -> {
              forget(state)
              process.send(reply, True)
              actor.stop()
            }
          }
      }
    StartSummary(checkpoint, instructions, out, ack) ->
      case children_busy || occupied(state) {
        True ->
          answer(
            state,
            ack,
            Error(refusal.Busy("session must be idle to rewind")),
          )
        False ->
          // A summary needs the composition, not a kernel.
          case
            turn_or_park(
              state,
              StartSummary(checkpoint, instructions, out, ack),
            )
          {
            Error(state) -> actor.continue(state)
            Ok(state) ->
              start_summary(state, checkpoint, instructions, out, ack)
          }
      }
    RewindHistory(archive_id, checkpoint, summary, expected_last, reply) ->
      case children_busy || occupied(state) {
        True ->
          answer(
            state,
            reply,
            Error(refusal.Busy("session must be idle to rewind")),
          )
        False ->
          case
            history.rewind(
              runtime.ledger(state.host),
              runtime.followers(state.host),
              state.info.id,
              archive_id,
              checkpoint,
              summary,
              expected_last,
            )
          {
            Error(error) -> answer(state, reply, Error(error))
            Ok(rewound) -> {
              let base = "/sessions/" <> state.info.id
              bus.invalidate(
                [
                  "/sessions",
                  base,
                  base <> "/context",
                  base <> "/context-window",
                ],
                [state.info.id, archive_id],
                False,
              )
              close_idle(state)
              wake_watchers(state)
              process.send(reply, Ok(rewound))
              actor.stop()
            }
          }
      }
    _ -> actor.continue(state)
  }
}

/// This session's own work prevents stopping. Children are checked off-actor.
fn occupied(state: State) -> Bool {
  let jobs = option.map(state.kernel, runtime.job_count) |> option.unwrap(0)
  busy(state)
  || state.shell_commands != []
  || state.shell_worker != None
  || state.booting != None
  || uses_kernel_transition(state)
  || jobs > 0
}

/// Stop an idle session, keeping its kernel's variables first: a clean stop is
/// the other moment they are worth saving.
fn close_idle(state: State) -> Nil {
  let _ = save_on_close(state)
  forget(state)
}

/// The save of the kernel's variables before the session stops, if it has one.
fn save_on_close(state: State) -> Option(Result(python.Saved, String)) {
  option.map(state.kernel, session_namespace.save_state_within(
    state.home,
    state.info.id,
    _,
    session_namespace.close_state_timeout,
  ))
}

/// Wake every stream watching this stopping session, so each ends now rather
/// than at its next keepalive and its client reconnects to what serves next.
fn wake_watchers(state: State) -> Nil {
  list.each(state.watchers, fn(watcher) { watcher.notify() })
}

fn forget(state: State) -> Nil {
  runtime.forget_session_async(state.host, state.info.id)
  cleanup_registrations(state.info.id)
}

/// `/kernel restart <session>`: the user may name any session, the model only
/// its own children and peers. The registry reaches the other session.
fn restart_another(
  db: store.Store,
  id: String,
  to: String,
  caller: command.Caller,
) -> Result(json.Json, String) {
  use address <- result.try(families.resolve(storage.host(db), id, to))
  let by = case caller {
    command.UserCall -> Ok(None)
    command.ModelCall ->
      case families.owns(storage.host(db), id, address.session) {
        True -> Ok(Some(families.name_of(storage.host(db), id)))
        False ->
          Error(
            "you can only restart the kernels of your own children or peers",
          )
      }
  }
  use by <- result.try(by)
  case session_control.call(agents.RestartKernel(address.session, by)) {
    Ok(agents.RestartedKernel(report)) -> Ok(report)
    Ok(_) -> Error("kernel restart answered unexpectedly")
    Error(reason) -> Error(reason)
  }
}

/// The registered command state seam: one operation in, session state out.
///
/// Runs on whichever process invoked the command (the kernel's host-call
/// process or an HTTP request process), so every branch that reads session
/// state is one actor call that reuses the ordinary message handlers instead
/// of duplicating their logic.
fn command_op(
  session: Session,
  host: runtime.Runtime,
  home: String,
  id: String,
  op: command.StateOp,
) -> Result(json.Json, command.StateError) {
  case op {
    command.ModelGet ->
      Ok(selection_json(actor.call(session, 5000, ReadSelection)))
    command.ModelSelect(model, provider, effort) ->
      actor.call(session, 5000, ChangeModel(model, provider, effort, _))
      |> result.map(selection_json)
      |> result.map_error(command.Other)
    command.EffortGet ->
      actor.call(session, 5000, ReadEffort)
      |> result.map_error(command.Other)
    command.EffortSelect(level) ->
      actor.call(session, 5000, ChangeEffort(level, _))
      |> result.map_error(command.Other)
    command.ExtensionChanged(url) -> {
      actor.call(session, 5000, ExtensionChanged(url, _))
      Ok(json.null())
    }
    command.NameGet ->
      actor.call(session, 5000, ReadName)
      |> result.map_error(command.Other)
    command.NameSelect(name) ->
      actor.call(session, 5000, ChangeName(name, _))
      |> result.map_error(command.Other)
    command.NameSuggest(name) ->
      actor.call(session, 5000, SuggestName(name, _))
      |> result.map_error(command.Other)
    command.CompactAtGet ->
      read_compact_at(session)
      |> result.map_error(command.Other)
    command.CompactAtSet(tokens) ->
      actor.call(session, 5000, ChangeCompactAt(tokens, _))
      |> result.map_error(command.Other)
    command.ContextSummary -> Ok(context(session))
    // Switching strategy reloads the session's extensions first.
    command.Compact(strategy) ->
      compact_session(session, strategy)
      |> result.map_error(refusal.explain)
      |> result.map(fn(report) {
        json.object([
          #("state", json.string(report.state)),
          #("strategy", json.nullable(report.effective_strategy, json.string)),
          #(
            "message",
            json.string(case report.failure {
              Some(reason) -> reason
              None -> "Compaction " <> report.state
            }),
          ),
        ])
      })
      |> result.map_error(command.Other)
    command.Refresh ->
      reload(session)
      |> result.map(fn(reloaded) {
        json.object([
          #("reloaded", json.string("session")),
          #("warnings", json.array(reloaded.warnings, json.string)),
        ])
      })
      |> result.map_error(command.Other)
    // Catalog fetches read no session state, so they stay off the actor.
    command.ReloadCatalogs ->
      runtime.reload_catalogs(host, id)
      |> result.map(catalogs_json)
      |> result.map_error(command.Other)
    command.Accounts ->
      auth_accounts.account_overview(
        home,
        runtime.logins(host),
        runtime.key_environment(host),
      )
      |> result.map_error(command.Other)
    command.ContextPage(section, page) ->
      context_page(session, section, page)
      |> result.map_error(command.Other)
    // Only a user invocation submits a turn, so this post is the person acting
    // again: it clears a workspace block instead of waiting for one.
    command.Submit(display, text, client) ->
      inbox.post(
        runtime.ledger(host),
        id,
        "command",
        Submission(
          display,
          text,
          client,
          turn.Chat,
          [],
          Some(mail.new_id()),
          None,
          None,
          [],
          None,
        ),
      )
      |> result.map(fn(_) { process.send(session, UserTurnQueued) })
      |> result.replace(json.object([#("submitted", json.bool(True))]))
      |> result.map_error(command.Other)
    command.QueueRead(limit, project) ->
      inbox.items(runtime.ledger(host), id, limit)
      |> result.map(fn(read) { project(read.0, read.1) })
      |> result.map_error(command.Other)
    command.QueueDrop(ids) ->
      drop_queued(session, ids)
      |> result.map(fn(dropped) {
        json.object([#("dropped", json.array(dropped, json.string))])
      })
      |> result.map_error(command.Other)
    command.QueueArrange(ids) ->
      arrange_queue(session, ids)
      |> result.replace(json.object([#("arranged", json.bool(True))]))
      |> result.map_error(command.Other)
    command.QuietTurn ->
      actor_call.try_call(session, 15_000, QuietTurn)
      |> result.replace_error("the session did not answer")
      |> result.flatten
      |> result.replace(json.object([#("quiet", json.bool(True))]))
      |> result.map_error(command.Other)
    command.KernelReport ->
      capture(session)
      |> result.map_error(refusal.explain)
      |> result.map(fn(captured) {
        json.object([
          #(
            "state",
            json.string(runtime_state.kernel_state_name(captured.kernel.state)),
          ),
          #(
            "instance_id",
            json.nullable(captured.kernel.instance_id, json.string),
          ),
          #("build", json.nullable(captured.kernel.build, json.string)),
          #(
            "live_job_count",
            json.nullable(captured.kernel.live_job_count, json.int),
          ),
        ])
      })
      |> result.map_error(command.Other)
    command.KernelUpgrade ->
      upgrade_kernel(session)
      |> result.map_error(refusal.explain)
      |> result.map(fn(report) {
        json.object([
          #("state", json.string(report.state)),
          #("warnings", json.array(report.warnings, json.string)),
          #("failure", json.nullable(report.failure, json.string)),
        ])
      })
      |> result.map_error(command.Other)
    command.KernelRestart ->
      restart_kernel(session, None)
      |> result.map(kernel_restart_json)
      |> result.map_error(command.Other)
    command.KernelRestartOf(to, caller) ->
      restart_another(runtime.ledger(host), id, to, caller)
      |> result.map_error(command.Other)
    command.KernelJobs(project) ->
      capture(session)
      |> result.map_error(refusal.explain)
      |> result.try(fn(captured) {
        case captured.kernel.running_jobs {
          Some(jobs) -> Ok(project(jobs, captured.kernel.live_job_count))
          None -> Error("kernel job observation unavailable")
        }
      })
      |> result.map_error(command.Other)
    command.KernelStopJob(id) ->
      actor.call(session, 5000, StopJob(id, _))
      |> result.map(fn(_) { json.object([#("stopped", json.bool(True))]) })
    command.KernelRead(read) ->
      actor_call.try_call(session, 5000, ReadKernel)
      |> result.replace_error(command.SessionUnavailable)
      |> result.try(read)
  }
}

/// `{"reloaded": [catalog, ..], "failed": {catalog: error, ..}}`.
fn catalogs_json(outcomes: List(#(String, Result(Nil, String)))) -> json.Json {
  let #(reloaded, failed) =
    list.fold_right(outcomes, #([], []), fn(acc, outcome) {
      case outcome {
        #(name, Ok(_)) -> #([json.string(name), ..acc.0], acc.1)
        #(name, Error(error)) -> #(acc.0, [#(name, json.string(error)), ..acc.1])
      }
    })
  json.object([
    #("reloaded", json.preprocessed_array(reloaded)),
    #("failed", json.object(failed)),
  ])
}

fn model_selection(info: conversation.Info) -> ModelSelection {
  ModelSelection(info.provider, info.model, info.protocol, info.effort)
}

fn selection_json(selection: ModelSelection) -> json.Json {
  json.object([
    #("provider", json.string(selection.provider)),
    #("model", json.string(selection.model)),
    #("protocol", json.string(conversation.protocol(selection.protocol))),
    #("effort", json.nullable(selection.effort, json.string)),
  ])
}

/// A turn needs a kernel in the workspace: a local folder that still exists,
/// or, when a kernel must boot, a host albedo can reach. A host still being
/// probed after a moment is left to the kernel's boot, which waits for the
/// probe and reports its failure; one known to need a sign-in or to be out
/// of reach is refused.
fn check_workspace_ready(state: State) -> Result(Nil, SubmissionError) {
  check_workspace_ready_values(
    state.host,
    state.info.id,
    state.info.cwd,
    state.kernel != None,
  )
}

fn check_workspace_ready_values(
  host: runtime.Runtime,
  session_id: String,
  cwd: String,
  kernel_held: Bool,
) -> Result(Nil, SubmissionError) {
  case location.parse(cwd) {
    // A kernel the session holds (attached, or reattaching through its
    // outbox) needs nothing from here: a dropped connection is its bridge's
    // to recover, and a host only matters again once that gives up.
    Ok(location.Remote(..)) if kernel_held -> Ok(Nil)
    Ok(location.Remote(..) as at) ->
      case location.ssh_target(at) {
        Error(Nil) -> Ok(Nil)
        Ok(target) -> {
          // A record can be attached even when provisioning a new bundle fails.
          use <- bool.guard(
            python.recorded_for(runtime.ledger(host), session_id),
            Ok(Nil),
          )
          case ssh.ready(target, 3000) {
            Ok(_) | Error(hosts.Warming) -> Ok(Nil)
            // The turn waits blocked with ssh's words, and a sign-in (the
            // tui's ctrl+l) lets the next try through.
            Error(failure) -> Error(Rejected(hosts.describe(target, failure)))
          }
        }
      }
    _ ->
      case lifecycle.directory(cwd) {
        True -> Ok(Nil)
        False -> Error(WorkspaceMissing(cwd))
      }
  }
}

fn kill(pid: process.Pid) -> Nil {
  process.kill(pid)
}

fn collect() -> Nil {
  let _ = garbage_collect()
  Nil
}

/// Marks the actor active. One timer follows a burst: messages only mark it
/// dirty and never add timers. The flags live in the process dictionary, so
/// marking costs no state update on every message.
fn activity(subject: Subject(Message), message: Message) -> Nil {
  let _ = put_flag(AlbedoSessionDirty, True)
  case get_flag(AlbedoSessionCollecting) == dynamic.bool(True) {
    True -> Nil
    False -> {
      let _ = put_flag(AlbedoSessionCollecting, True)
      later(subject, message)
    }
  }
}

/// The burst timer fired. Wait for another quiet period when messages arrived
/// since. Otherwise hibernate, which collects the heap.
fn quiet(subject: Subject(Message), message: Message) -> Nil {
  case erase_flag(AlbedoSessionDirty) == dynamic.bool(True) {
    True -> later(subject, message)
    False -> {
      let _ = erase_flag(AlbedoSessionCollecting)
      let _ = hibernate()
      Nil
    }
  }
}

fn later(subject: Subject(Message), message: Message) -> Nil {
  let _ = albedo_clock.send_after(subject, 100, message)
  Nil
}

/// The session actor's process dictionary keys.
type Flag {
  AlbedoSessionDirty
  AlbedoSessionCollecting
}

@external(erlang, "erlang", "put")
fn put_flag(key: Flag, value: Bool) -> Dynamic

@external(erlang, "erlang", "get")
fn get_flag(key: Flag) -> Dynamic

@external(erlang, "erlang", "erase")
fn erase_flag(key: Flag) -> Dynamic

@external(erlang, "erlang", "hibernate")
fn hibernate() -> Dynamic

@external(erlang, "erlang", "garbage_collect")
fn garbage_collect() -> Bool

/// Live session actors by id. A session registers itself when it starts and is
/// forgotten when it closes, so a registry that restarts after a crash adopts
/// the sessions still running instead of starting a second actor for one.
/// The table is `albedo_sessions`.
fn live_sessions() -> Registry(String, Session) {
  registry.new(atom.create("albedo_sessions"))
}

fn live_register(session: String, subject: Session) -> Nil {
  registry.register(live_sessions(), session, subject)
}

fn live_forget(session: String) -> Nil {
  registry.forget(live_sessions(), session)
}

fn live_find(session: String) -> Result(Session, Nil) {
  registry.lookup(live_sessions(), session)
}

fn owner_alive(session: Session) -> Bool {
  case process.subject_owner(session) {
    Ok(pid) -> process.is_alive(pid)
    Error(_) -> False
  }
}

/// The session's actor when one is already running, so nobody starts another.
pub fn live(id: String) -> Option(Session) {
  case live_find(id) {
    Ok(session) ->
      case owner_alive(session) {
        True -> Some(session)
        False -> None
      }
    Error(_) -> None
  }
}

/// Delete a kernel state file and the saved job book (`.jobs.json`,
/// robot-docs/kernel.md) that goes with it.
fn discard(path: String) -> Nil {
  let _ = delete_file(path)
  let _ = delete_file(path <> ".jobs.json")
  Nil
}

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Dynamic

fn prepare_submission(
  state: State,
) -> Result(#(State, runtime.Prepared, extension.Upstream), SubmissionError) {
  use _ <- result.try(
    editor_ready(state)
    |> result.map_error(fn(error) {
      Rejected(case error {
        refusal.OverlayReattachRequired | refusal.OverlayReloadFailed ->
          refusal.failure(error).code
        _ -> refusal.explain(error)
      })
    }),
  )
  use #(state, client) <- result.try(
    session_provider.configured_client(state) |> result.map_error(Rejected),
  )
  let #(state, _) = session_namespace.ready(state)
  case session_state.composition(state) {
    Some(prepared) -> Ok(#(state, prepared, client))
    None -> Error(Rejected("the session python kernel is not ready"))
  }
}

/// Whether a turn can start now. It needs only the composition, since it
/// acquires its kernel at its first tool call, unless it owes results for calls
/// a crash interrupted, which only the kernel can recover.
fn turn_ready(state: State) -> #(State, Bool) {
  let #(state, kernel) = session_namespace.ready(state)
  case kernel, session_state.composition(state) {
    Some(_), Some(_) -> #(state, True)
    kernel, composition ->
      case owes_results(state) {
        True -> #(state, kernel != None)
        False -> #(state, composition != None)
      }
  }
}

fn owes_results(state: State) -> Bool {
  !state.results_settled && session_history.unanswered(state) != []
}

/// `kernel_or_park` for a turn: the state when it can start now, else `work`
/// parked until the composition, or the kernel a turn owes results to, is here.
fn turn_or_park(state: State, work: Message) -> Result(State, State) {
  case state.closing, uses_kernel_transition(state) {
    True, _ -> Error(state)
    _, True -> Error(park(state, work))
    _, False ->
      case turn_ready(state) {
        #(state, True) -> Ok(state)
        #(state, False) ->
          case option.is_none(state.booting) && !owes_results(state) {
            True -> Error(request_composition(state, work))
            False -> Error(park(state, work))
          }
      }
  }
}

/// Asks the runtime for the session's composition without a kernel, parking
/// `work` in `booting` until it arrives.
fn request_composition(state: State, work: Message) -> State {
  let self = state.self
  let token = state.boot_token + 1
  let ticket =
    runtime.prepare_session_request(
      state.host,
      state.info.id,
      state.info.cwd,
      fn(result) { process.send(self, PreparedOpened(token, result)) },
    )
  session_state.State(
    ..state,
    booting: Some(#(1, [work])),
    boot_ticket: option.from_result(ticket),
    boot_token: token,
  )
  |> session_state.announce
}

fn prepared_opened(
  state: State,
  result: Result(runtime.Prepared, python.Error),
) -> State {
  case state.booting, result {
    None, Ok(prepared) -> session_state.State(..state, prepared: Some(prepared))
    None, Error(_) -> state
    Some(_), Error(error) -> kernel_opened(state, Error(error))
    Some(#(_, parked)), Ok(prepared) ->
      session_state.State(..state, prepared: Some(prepared), booting: None)
      |> session_prompt.reconcile_prompt
      |> warn(runtime.prepared_warnings(prepared))
      |> run_parked(parked)
  }
}

/// Answers a run's worker with the kernel for its next tool call and the
/// notice the kernel's arrival left, booting or adopting one if none is held.
fn acquire_kernel(
  state: State,
  id: String,
  reply: Subject(Result(runtime.Session, String)),
) -> actor.Next(State, Message) {
  let state = session_state.State(..state, rest_token: state.rest_token + 1)
  case turn.live(state.activity, id) && !state.closing {
    False -> answer(state, reply, Error(acquire_refused))
    True ->
      case state.kernel {
        // A stale bundle is swapped between turns, not under one; a kernel
        // being released or reset is waited out.
        Some(kernel) ->
          case runtime.alive(kernel) && !uses_kernel_transition(state) {
            True -> hand_kernel(state, kernel, reply)
            False -> acquire_parked(state, id, reply)
          }
        None -> acquire_parked(state, id, reply)
      }
  }
}

fn acquire_parked(
  state: State,
  id: String,
  reply: Subject(Result(runtime.Session, String)),
) -> actor.Next(State, Message) {
  case kernel_or_park(state, AcquireKernel(id, reply)) {
    Error(state) -> actor.continue(state)
    Ok(state) ->
      case state.kernel {
        Some(kernel) -> hand_kernel(state, kernel, reply)
        None -> answer(state, reply, Error(acquire_refused))
      }
  }
}

/// Adopting loaded the history the running worker already holds; the actor
/// drops its copy again.
fn hand_kernel(
  state: State,
  kernel: runtime.Session,
  reply: Subject(Result(runtime.Session, String)),
) -> actor.Next(State, Message) {
  answer(session_state.State(..state, history: None), reply, Ok(kernel))
}

const acquire_refused = "the turn ended before its python kernel was ready"

/// How long a turn waits on its model before its idle kernel is released.
/// Releasing at once cost a fast tool loop 132 ms per step; at 3 s a fast loop
/// never releases.
const rest_ms = 3000

/// A turn about to wait on its model releases its kernel if the wait outlasts
/// `rest_ms`; its next tool call reacquires one. A tool call or the next
/// request makes the timer stale.
fn arm_rest(state: State, id: String) -> State {
  case state.kernel {
    Some(_) -> {
      let token = state.rest_token + 1
      let _ =
        albedo_clock.send_after(state.self, rest_ms, RestKernel(id, token))
      session_state.State(..state, rest_token: token)
    }
    None -> state
  }
}

/// Checks a turn's kernel again while its model wait lasts.
fn rest_later(self: Subject(Message), id: String, token: Int) -> Nil {
  let _ = albedo_clock.send_after(self, 1000, RestKernel(id, token))
  Nil
}

/// The resting release's guards, for a kernel under a live turn waiting on
/// its model since the timer `token` was armed.
fn restable(state: State, id: String, token: Int) -> Bool {
  token == state.rest_token
  && turn.live(state.activity, id)
  && !uses_kernel_transition(state)
  && state.booting == None
  && option.map(state.kernel, runtime.live_work) == Some(Ok(0))
}

/// Refuses the kernel requests a cancelled run left parked, so its worker
/// stops now instead of when the kernel arrives.
fn refuse_acquires(state: State) -> State {
  let refuse = fn(parked: List(Message)) {
    list.filter(parked, fn(work) {
      case work {
        AcquireKernel(_, reply) -> {
          process.send(reply, Error(acquire_refused))
          False
        }
        _ -> True
      }
    })
  }
  session_state.State(
    ..state,
    booting: option.map(state.booting, fn(boot) { #(boot.0, refuse(boot.1)) }),
    releasing: option.map(state.releasing, refuse),
    checkpointing: option.map(state.checkpointing, refuse),
  )
  |> withdraw_unused_boot
}

/// The state when a live kernel is here; otherwise `work` is parked until one
/// arrives and the state that asked for it comes back as the error.
fn kernel_or_park(state: State, work: Message) -> Result(State, State) {
  case state.closing, uses_kernel_transition(state) {
    True, _ -> Error(state)
    _, True -> Error(park(state, work))
    _, False ->
      case session_namespace.ready(state) {
        #(state, Some(_)) -> Ok(state)
        #(state, None) -> Error(park(state, work))
      }
  }
}

/// Whether a turn is waiting for the kernel to boot before it can start.
fn waiting_turn(state: State) -> Bool {
  case state.booting {
    Some(#(_, parked)) ->
      list.contains(parked, StartQueued) || list.contains(parked, Resume)
    None -> False
  }
}

/// Running, or booting a kernel that restores the saved state.
fn uses_kernel(state: State) -> Bool {
  turn.running(state.activity) != None
  || state.booting != None
  || uses_kernel_transition(state)
}

fn uses_kernel_transition(state: State) -> Bool {
  replacing_kernel(state) || state.closing || state.checkpointing != None
}

/// Whether a release or workspace reset is replacing the kernel. Each ends by
/// setting the kernel itself (a release keeps the handle it began with), which
/// would undo a reload applied meanwhile, so reloads park until it ends.
fn replacing_kernel(state: State) -> Bool {
  state.workspace_reset != None || state.releasing != None
}

/// Running a turn, or about to once the kernel is up.
fn busy(state: State) -> Bool {
  turn.running(state.activity) != None || waiting_turn(state)
}

/// Keep `work` for when the kernel is ready, asking for one if nobody has.
fn park(state: State, work: Message) -> State {
  case state.checkpointing {
    Some(parked) ->
      session_state.State(
        ..state,
        checkpointing: Some(case list.contains(parked, work) {
          True -> parked
          False -> list.append(parked, [work])
        }),
      )
    None ->
      case state.releasing {
        Some(parked) ->
          session_state.State(
            ..state,
            releasing: Some(case list.contains(parked, work) {
              True -> parked
              False -> list.append(parked, [work])
            }),
          )
        None -> park_workspace(state, work)
      }
  }
}

fn park_workspace(state: State, work: Message) -> State {
  case state.workspace_reset {
    Some(parked) ->
      session_state.State(
        ..state,
        workspace_reset: Some(case list.contains(parked, work) {
          True -> parked
          False -> list.append(parked, [work])
        }),
      )
    None -> park_kernel(state, work)
  }
}

fn park_kernel(state: State, work: Message) -> State {
  case state.booting {
    Some(#(attempts, parked)) ->
      case list.contains(parked, work) {
        True -> state
        False ->
          session_state.State(
            ..state,
            booting: Some(#(attempts, list.append(parked, [work]))),
          )
      }
    None -> {
      let state = request_kernel(state)
      session_state.State(..state, booting: Some(#(1, [work])))
    }
  }
  |> session_state.announce
}

fn request_kernel(state: State) -> State {
  let self = state.self
  // A released session waking is what spares are kept for.
  case state.released {
    Some(_) -> runtime.want_spares(state.host)
    None -> Nil
  }
  let token = state.boot_token + 1
  let ticket =
    runtime.open_session_request(
      state.host,
      state.info.id,
      state.info.cwd,
      fn(result) { process.send(self, KernelOpened(token, result)) },
    )
  session_state.State(
    ..state,
    boot_ticket: option.from_result(ticket),
    boot_token: token,
  )
}

/// The kernel arrived or failed. Parked work runs again on success; a lost
/// kernel is reset and asked for once more; any other failure fails only the
/// parked work. Queued letters are not lost: they stay undelivered, and the
/// dispatcher offers them again.
/// Adopting revives saved variables only for a session with history, so the
/// transcript is asked what it holds first.
fn adopt(state: State, kernel: runtime.Session) -> State {
  let held =
    conversation.held(runtime.ledger(state.host), state.info.id)
    |> result.unwrap(conversation.Held(False, False))
  session_namespace.adopt(state, kernel, held)
  |> session_prompt.reconcile_prompt
}

/// Records the head a prepared request reported. It moves when compaction
/// does, and is saved then, so a pin made after a restart starts at it.
fn prepared(state: State, head: Int) -> State {
  let moved = state.prepared_head != Some(head)
  let state = session_state.State(..state, prepared_head: Some(head))
  let #(ledger, session) = #(runtime.ledger(state.host), state.info.id)
  case moved {
    False -> state
    True ->
      session_state.write_then(
        state,
        fn() { conversation.save_prepared_head(ledger, session, head) },
        fn(state, saved) {
          case saved {
            Ok(_) -> state
            Error(error) ->
              session_state.emit(
                state,
                view.error(
                  "the prepared request head could not be saved: " <> error,
                ),
              )
          }
        },
      )
  }
}

/// Shows what preparing the session's composition warned about.
fn warn(state: State, warnings: List(String)) -> State {
  list.fold(warnings, state, fn(state, warning) {
    session_state.emit(state, view.note("daemon", "Warning: " <> warning))
  })
}

fn kernel_opened(
  state: State,
  result: Result(runtime.Session, python.Error),
) -> State {
  case state.booting, result {
    None, Ok(kernel) ->
      case state.kernel {
        None -> adopt(state, kernel)
        // The held kernel is gone, so this arrival is its replacement: adopt
        // it, so its notice reaches the model, instead of dropping both the
        // kernel and the story about what the swap ended.
        Some(existing) ->
          case runtime.alive(existing) {
            False -> adopt(state, kernel)
            // An arrival nobody asked for while a live kernel serves: the
            // runtime still holds it for the session's next open.
            True -> state
          }
      }
    None, Error(_) -> state
    Some(#(attempts, parked)), Error(python.Lost) if attempts < 2 -> {
      runtime.reset_session_async(state.host, state.info.id)
      let state = request_kernel(state)
      session_state.State(..state, booting: Some(#(attempts + 1, parked)))
    }
    Some(#(_, parked)), Ok(kernel) -> {
      adopt(session_state.State(..state, booting: None), kernel)
      |> warn(runtime.warnings(kernel))
      |> run_parked(parked)
    }
    Some(#(attempts, parked)), Error(error) ->
      case attempts < 2 && stale_composition(error) {
        // Composition inputs moved while the kernel prepared, as when a
        // generated title renames the session; preparing again sees the new
        // inputs, while a real startup problem still pauses the inputs.
        True -> {
          let state = request_kernel(state)
          session_state.State(..state, booting: Some(#(attempts + 1, parked)))
        }
        False -> boot_failed(state, parked, error)
      }
  }
}

fn stale_composition(error: python.Error) -> Bool {
  case error {
    python.Unavailable(message) | python.Invalid(message) ->
      string.contains(message, "composition inputs changed during")
    _ -> False
  }
}

fn boot_failed(
  state: State,
  parked: List(Message),
  error: python.Error,
) -> State {
  let why =
    "could not start the session python kernel: "
    <> case error {
      python.Unavailable(message) | python.Invalid(message) -> message
      python.Lost -> "the kernel exited while starting"
      python.Busy | python.Detached -> "the kernel is busy"
    }
  list.fold(
    parked,
    session_state.State(..state, booting: None),
    fn(state, work) {
      case work {
        StartQueued ->
          blocked_queued(
            state,
            why
              <> "; queued inputs are retained. Fix the startup problem and send another message, or use /cd to change workspace",
            None,
          )
        Resume ->
          session_state.State(..state, activity: turn.Resting)
          |> session_state.emit(view.error(why))
        Compact(_, action_id, reply) -> {
          finish_compaction(
            state,
            action_id,
            reply,
            Error(refusal.Unavailable(why)),
          )
          state
        }
        AcquireKernel(_, reply) -> {
          process.send(reply, Error(why))
          state
        }
        UpgradeKernel(reply) -> {
          process.send(reply, Error(refusal.Unavailable(why)))
          state
        }
        // Nothing booted, so the restart has only saved variables to drop.
        RestartKernel(_, _) | CloseAgent(_) -> {
          process.send(state.self, work)
          state
        }
        StartSummary(_, _, _, ack) -> {
          process.send(ack, Error(refusal.Unavailable(why)))
          state
        }
        AskSideQuestion(_, _, reply) -> {
          process.send(reply, Error(side_question.NoContext(why)))
          state
        }
        _ -> state
      }
    },
  )
}

/// Turns start here and now, so no status read can fall between the kernel
/// or composition arriving and its turn starting; work that answers a caller
/// is handled as a message again.
fn run_parked(state: State, parked: List(Message)) -> State {
  list.fold(parked, state, fn(state, work) {
    case work {
      StartQueued -> start_queued(state)
      Resume -> resume(state)
      other -> {
        process.send(state.self, other)
        state
      }
    }
  })
}

/// What waits in the inbox could not start a turn: its people's inputs say
/// why, and the session tries again in 15 s.
fn failed_queued(state: State, error: String) -> State {
  let _ = albedo_clock.send_after(state.self, 15_000, StartQueued)
  blocked_queued(state, error, Some(albedo_clock.monotonic_ms() + 15_000))
}

/// Blocks what waits in the inbox. Without `retry_at` it waits for the person
/// to act again or for a workspace move instead of retrying on a timer.
fn blocked_queued(state: State, error: String, retry_at: Option(Int)) -> State {
  let state = session_state.State(..state, active_submissions: [])
  let waiting =
    queued(state)
    |> result.map(list.map(_, fn(row: turn.Queued) { row.id }))
    |> result.unwrap([])
  let _ = operations.block(runtime.ledger(state.host), waiting, error)
  session_state.emit(
    session_state.State(
      ..state,
      blocked_until: option.unwrap(retry_at, 0),
      kernel_blocked: retry_at == None,
      blocking: Some(error),
    ),
    view.error("waiting inputs are blocked: " <> error),
  )
  |> session_submission.refresh_ids(waiting)
}

/// A session that ends still owing replies sends each requester the last words
/// of the turn that ended, marked unreviewed. Letters already queued here mean
/// it is not done yet.
fn answer_parent(
  state: State,
  run_id: String,
  outcome: Result(Nil, loop.Failure),
) -> #(State, Option(fn() -> List(Result(mail_value.Letter, String)))) {
  let db = runtime.ledger(state.host)
  let owed = case queue_starts(state) {
    True -> []
    False -> mail.owed_requesters(db, state.info.id) |> result.unwrap([])
  }
  case owed {
    [] -> #(state, None)
    requesters -> {
      let #(state, words) = last_words(state, run_id)
      let #(session, name) = #(
        state.info.id,
        families.name_of(storage.host(db), state.info.id),
      )
      let #(kind, body) = case outcome, words {
        Ok(_), Some(text) -> #(mail_value.Answer(unreviewed: True), text)
        Ok(_), None -> #(
          mail_value.Answer(unreviewed: True),
          "(finished without writing anything)",
        )
        Error(failure), _ -> {
          let reason = child_failure.reason(failure)
          #(
            mail_value.Stopped(name, reason),
            child_failure.format(reason, words),
          )
        }
      }
      #(
        state,
        Some(fn() {
          list.map(requesters, fn(requester) {
            mail.post(
              db,
              mail.new_id(),
              requester,
              Some(session),
              name,
              kind,
              body,
            )
          })
        }),
      )
    }
  }
}

/// Says why an answer to a requester was not posted; one that was reaches its
/// requester once it commits.
fn answered(
  state: State,
  posted: List(Result(mail_value.Letter, String)),
) -> State {
  list.fold(posted, state, fn(state, posted) {
    case posted {
      Ok(_) -> state
      Error(error) ->
        session_state.emit(
          state,
          view.error("could not answer requester: " <> error),
        )
    }
  })
}

/// The newest assistant text `run_id` wrote.
fn last_words(state: State, run_id: String) -> #(State, Option(String)) {
  #(
    state,
    conversation.last_assistant_text(
      runtime.ledger(state.host),
      state.info.id,
      run_id,
    )
      |> result.unwrap(None),
  )
}

/// Whether this session's durable family member has been closed.
fn family_closed(state: State) -> Result(Bool, String) {
  families.closed(storage.host(runtime.ledger(state.host)), state.info.id)
}

/// Why the session's provider would refuse one of the submission's images,
/// so it is turned away before the transcript keeps it rather than failing
/// every request after.
fn refused_image(
  state: State,
  submission: Submission,
) -> #(State, Option(String)) {
  case submission.images {
    [] -> #(state, None)
    images ->
      case session_provider.configured_client(state) {
        // Without a provider the turn is refused on its own when it starts.
        Error(_) -> #(state, None)
        Ok(#(state, client)) -> #(
          state,
          list.find_map(images, fn(image) {
            types.image_refusal(client.images, image) |> option.to_result(Nil)
          })
            |> option.from_result,
        )
      }
  }
}

/// The resumed turn reads the restart notice first, ahead of everything that
/// waited in the inbox.
fn resume(state: State) -> State {
  case
    inbox.post_first(
      runtime.ledger(state.host),
      state.info.id,
      "daemon",
      restart_note(),
    )
  {
    Error(error) ->
      failed_queued(session_state.State(..state, activity: turn.Resting), error)
    Ok(_) ->
      session_state.State(..state, activity: turn.Resting)
      |> open_queued(turn.opening)
  }
}

/// The plugin has committed its new projection. Clean up before the next
/// provider request, while the session actor serializes transcript writes.
fn elide_compacted_images(state: State) -> State {
  let elided = case context_snapshot.retained_tool_calls(state.context) {
    Some(calls) ->
      images.elide_evicted(runtime.ledger(state.host), state.info.id, calls)
    None -> Ok(0)
  }
  case elided {
    Ok(0) -> state
    Ok(_) -> session_state.State(..state, history: None)
    Error(error) ->
      session_state.emit(state, view.error("image cleanup skipped: " <> error))
  }
}

/// Wait for the compaction worker's observed outcome without retrying the action.
pub fn compact_session(
  session: Session,
  strategy: Option(String),
) -> Result(turn.CompactionReport, Refusal) {
  actor_call.try_call(session, 185_000, Compact(strategy, None, _))
  |> result.replace_error(refusal.Unavailable(
    "compaction response unavailable; inspect session context",
  ))
  |> result.flatten
}

fn compact(
  state: State,
  strategy: Option(String),
  action_id: Option(String),
  reply: Subject(Result(turn.CompactionReport, Refusal)),
) -> actor.Next(State, Message) {
  // The switch keeps its state even when compaction then fails: the runtime
  // already runs the new extension set.
  let #(state, selected) = case busy(state) {
    True -> #(state, Error("session must be idle to compact"))
    False -> select_strategy(state, strategy)
  }
  let state = recompose(state)
  let report =
    turn.CompactionReport(
      selection_applied: strategy != None && result.is_ok(selected),
      effective_strategy: option.then(
        session_state.composition(state),
        runtime.compaction_name,
      ),
      state: "failed",
      observation: None,
      failure: None,
    )
  let prepared = {
    use _ <- result.try(selected)
    use _ <- result.try(case turn.running(state.activity) {
      Some(_) -> Error("session must be idle to compact")
      None -> Ok(Nil)
    })
    use #(state, kernel, client) <- result.try(
      prepare_submission(state) |> result.map_error(submission_error),
    )
    use strategy <- result.try(case runtime.compaction_name(kernel) {
      Some(strategy) -> Ok(strategy)
      None -> Error("no compaction strategy is enabled")
    })
    use state <- result.try(session_history.ensure_history(state))
    use history <- result.try(projected_entries(state))
    use _ <- result.try(case history {
      [] -> Error("no conversation history to compact")
      _ -> Ok(Nil)
    })
    let run_id = mail.new_id()
    use _ <- result.try(
      store.query(runtime.ledger(state.host), fn(db) {
        store.transaction(db, fn() {
          operations.begin_turn_in(
            db,
            state.info.id,
            run_id,
            usage.now(),
            Some(state.info.cwd),
          )
        })
      }),
    )
    Ok(#(state, kernel, client, strategy, history, run_id))
  }
  case prepared {
    Error(error) -> {
      finish_compaction(
        state,
        action_id,
        reply,
        Ok(turn.CompactionReport(..report, failure: Some(error))),
      )
      actor.continue(state)
    }
    Ok(#(state, kernel, client, strategy, history, run_id)) ->
      actor.continue(start_worker(
        state,
        kernel,
        client,
        session_run.Given(history),
        turn.Compaction(
          action_id,
          reply,
          turn.CompactionReport(..report, effective_strategy: Some(strategy)),
        ),
        run_id,
      ))
  }
}

/// The session's composition, prepared again when a selection change dropped
/// it and no kernel carries one. The change itself already waited on the
/// runtime, so waiting for the composition it built adds little.
fn recompose(state: State) -> State {
  case session_state.composition(state) {
    Some(_) -> state
    None -> {
      case runtime.prepare_session(state.host, state.info.id, state.info.cwd) {
        Ok(prepared) -> session_state.State(..state, prepared: Some(prepared))
        _ -> state
      }
    }
  }
}

/// A named strategy becomes the session's own compaction extension, so the
/// projection it saves is the one every later request reads.
fn select_strategy(
  state: State,
  strategy: Option(String),
) -> #(State, Result(Nil, String)) {
  case strategy {
    None -> #(state, Ok(Nil))
    Some(name) ->
      case runtime.extension_summaries(state.host, state.info.id) {
        Error(error) -> #(state, Error(error))
        Ok(summaries) -> {
          let strategies =
            list.filter(summaries, fn(summary) {
              list.contains(summary.plugins, "compaction")
            })
          case list.find(strategies, fn(summary) { summary.name == name }) {
            Ok(_) -> {
              let #(state, outcome) =
                session_extensions.change(
                  state,
                  selection.SetSession(name, True),
                )
              let state = case outcome {
                Error(_) -> state
                Ok(_) -> {
                  let base = "/sessions/" <> state.info.id
                  bus.invalidate(
                    [base, base <> "/configuration", base <> "/catalog"],
                    [state.info.id],
                    False,
                  )
                  state
                  |> session_state.invalidate(
                    view.StaleSettings,
                    base <> "/configuration",
                  )
                  |> session_state.invalidate(
                    view.StaleCatalog,
                    base <> "/catalog",
                  )
                }
              }
              #(state, result.replace(outcome, Nil))
            }
            Error(_) -> #(
              state,
              Error(
                "unknown compaction strategy "
                <> name
                <> "; available: "
                <> string.join(
                  list.map(strategies, fn(summary) { summary.name }),
                  ", ",
                ),
              ),
            )
          }
        }
      }
  }
}

fn prepare_turn_pipeline(
  state: State,
  submissions: List(Submission),
) -> Result(#(State, Opening), #(State, SubmissionError)) {
  use state <- result.try(case turn.running(state.activity) {
    Some(_) -> Ok(state)
    None ->
      apply_workspace_state(state)
      |> result.map_error(fn(failure) { #(failure.0, Rejected(failure.1)) })
  })
  use #(state, kernel, client) <- result.try(
    prepare_submission(state) |> result.map_error(fn(err) { #(state, err) }),
  )
  // `turn_ready` holds the turn for a kernel when calls need recovering.
  let recovered = case state.kernel {
    Some(_) if state.results_settled -> []
    Some(held) ->
      session_history.recover_pending(
        state.host,
        session_history.unanswered(state),
        held,
        client.images,
      )
    None -> []
  }
  let accepted =
    list.append(
      list.map(recovered, fn(result) { result.0 }),
      session_submission.inputs(submissions),
    )
  let run_id = mail.new_id()
  let #(ledger, session, provider, cwd) = #(
    runtime.ledger(state.host),
    state.info.id,
    Some(state.info.provider),
    state.info.cwd,
  )
  let letters = turn.letters(submissions)
  let commits = session_submission.commits(submissions, list.length(recovered))
  let shells = session_submission.shells(submissions, list.length(recovered))
  let outcomes =
    list.filter_map(recovered, fn(result) {
      case result.0 {
        types.ToolOutput(id, _, _) -> Ok(#(id, result.1))
        _ -> Error(Nil)
      }
    })
  let commit = fn() {
    conversation.commit_operations(
      ledger,
      session,
      accepted,
      session_info.Model,
      provider,
      letters,
      commits,
      shells,
      session_submission.kinds(submissions, list.length(recovered)),
      run_id,
      cwd,
      outcomes,
    )
  }
  // The turn holds its rows now; they leave the inbox with the commit the
  // worker waits for, and stay there if it fails.
  let state =
    session_state.State(
      ..state,
      active_submissions: submissions,
      blocked_until: 0,
      kernel_blocked: False,
    )
  Ok(#(
    state,
    Opening(
      kernel,
      client,
      run_id,
      submissions,
      accepted,
      with_boundary(state, commit),
    ),
  ))
}

/// A turn ready to start: what its worker runs on, and the write that
/// commits its inputs before the worker may begin.
type Opening {
  Opening(
    kernel: runtime.Prepared,
    client: extension.Upstream,
    run_id: String,
    submissions: List(Submission),
    accepted: List(types.Input),
    commit: fn() -> Result(#(Int, conversation.Snapshot), String),
  )
}

/// Starts the turn's worker and queues the commit of its inputs; the worker
/// waits for that commit, so the session goes on answering meanwhile.
fn start_turn(state: State, opening: Opening) -> State {
  let Opening(kernel, client, run_id, submissions, accepted, commit) = opening
  start_worker(
    state,
    kernel,
    client,
    session_run.ThroughOpening,
    turn.Turn(None),
    run_id,
  )
  |> session_state.write_then(commit, fn(state, committed) {
    opened(state, run_id, submissions, accepted, committed)
  })
}

/// The turn's inputs are committed: its worker may begin. A failed commit
/// ends the worker before it did anything and puts the inputs back.
fn opened(
  state: State,
  run_id: String,
  submissions: List(Submission),
  accepted: List(types.Input),
  committed: Result(#(Int, conversation.Snapshot), String),
) -> State {
  case committed, turn.owner(state.activity, run_id) {
    Ok(#(timestamp, boundary)), run -> {
      let activity = case run {
        Some(run) -> turn.Running(turn.open(run, boundary.upper))
        None -> state.activity
      }
      session_state.State(..state, activity: activity)
      |> session_namespace.notice_read(submissions)
      |> session_history.remember_committed(accepted, timestamp, boundary)
      |> session_submission.emit(submissions, timestamp)
      |> session_state.queue_changed
      |> session_state.announce
    }
    Error(error), Some(run) -> {
      process.demonitor_process(run.monitor)
      kill(run.pid)
      bus.running(state.info.id, False)
      session_state.State(..state, activity: turn.Resting)
      |> failed_queued(error)
      |> session_state.announce
    }
    Error(_), None -> state
  }
}

fn editor_ready(state: State) -> Result(Nil, Refusal) {
  use <- bool.guard(!state.acp, Ok(Nil))
  let ledger = runtime.ledger(state.host)
  use selected <- result.try(
    selection.enabled(
      ledger,
      runtime.installed(state.host),
      runtime.base_defaults(state.host),
      state.info.id,
    )
    |> refusal.storage,
  )
  let enabled = list.any(selected, fn(item) { item.name == "editor-mcp" })
  use <- bool.guard(!enabled, Ok(Nil))
  use _ <- result.try(acp_session.ready(ledger, state.info.id, enabled))
  use marker <- result.try(
    stored_history.acp_marker(storage.host(ledger), state.info.id)
    |> refusal.storage,
  )
  acp_session.resolve_overlay(marker, state.info.id, enabled)
  |> result.replace(Nil)
}

fn turn_state(
  run: turn.Run,
  outcome: Result(Nil, String),
) -> operations.TurnState {
  case run.cancelled, outcome {
    True, _ -> operations.Interrupted
    _, Error(_) -> operations.Failed
    _, Ok(_) -> operations.Completed
  }
}

fn finish_run(
  state: State,
  run: turn.Run,
  failure: Result(Nil, loop.Failure),
) -> actor.Next(State, Message) {
  let outcome = result.map_error(failure, loop.failure_message)
  case run.work {
    // A background call holds the session like a compaction run does, but
    // commits nothing and never reaches the transcript.
    turn.Background(reply) ->
      background_finish(
        state,
        run,
        reply,
        result.replace(
          outcome,
          compaction.Answer(None, Error(compaction.empty_summary)),
        ),
      )
    turn.Summary(_, _, reply) -> summary_finish(state, run, reply, outcome)
    _ -> finish_turn(state, run, failure)
  }
}

fn finish_turn(
  state: State,
  run: turn.Run,
  failure: Result(Nil, loop.Failure),
) -> actor.Next(State, Message) {
  use <- bool.guard(state.finishing, actor.continue(state))
  let outcome = result.map_error(failure, loop.failure_message)
  process.demonitor_process(run.monitor)
  // A session closing for deletion keeps nothing of the turn.
  let state = case run.work, run.cancelled, outcome {
    _, _, _ if state.closing -> state
    turn.Turn(..), True, Error(_) ->
      salvage(state, run, session_salvage.Stopped)
    turn.Turn(..), False, Error(error) ->
      salvage(state, run, session_salvage.Failed(error))
    _, _, _ -> state
  }
  let ledger = runtime.ledger(state.host)
  let completion =
    conversation.RunCompletion(
      state.info.id,
      run.id,
      turn.final_stage(run, outcome),
      turn_state(run, outcome),
    )
  // The run holds the session until its end is durable, so nothing starts
  // behind a turn the store still calls running.
  session_state.State(..state, finishing: True)
  |> session_state.write_then(
    fn() { conversation.finish_turn(ledger, completion) },
    fn(state, persisted) {
      // Its requesters' answers are posted before the session reads idle, so
      // whoever waits on it sees them once it does.
      let #(state, answers) = case run.work, run.cancelled, persisted {
        turn.Turn(..), False, Ok(_) -> answer_parent(state, run.id, failure)
        _, _, _ -> #(state, None)
      }
      case answers {
        None -> finished_turn(state, run, outcome, persisted)
        Some(post) ->
          session_state.write_then(state, post, fn(state, posted) {
            answered(state, posted) |> finished_turn(run, outcome, persisted)
          })
      }
    },
  )
  |> actor.continue
}

fn finished_turn(
  state: State,
  run: turn.Run,
  outcome: Result(Nil, String),
  persisted: Result(Int, String),
) -> State {
  // The calls of the run are rows now, so the store knows their cost: read the
  // total once more, so a call that no committed response followed still reaches
  // a client.
  let state = synced_spend(state)
  let state = session_state.State(..state, finishing: False)
  let state = clear_tool_progress(session_state.flush_output(state))
  let state =
    session_state.State(
      ..state,
      activity: turn.Resting,
      active_output: active_output.retire(state.active_output),
    )
    |> follow_up
  let #(state, _) = session_switch.apply_pending(state)
  bus.running(state.info.id, False)
  let state =
    session_state.State(
      ..state,
      results_settled: case run.work, run.cancelled, outcome, persisted {
        turn.Turn(..), False, Ok(_), Ok(_) -> True
        _, _, _, _ -> state.results_settled
      },
    )
  let state = case run.work, run.cancelled, outcome, persisted {
    _, _, _, Error(error) ->
      session_state.emit(
        state,
        view.Failure(Some(run.id), view.TurnPersistenceFailed, error),
      )
    _, True, _, Ok(_) -> state
    _, _, Error(error), _ ->
      session_state.emit(
        state,
        view.Failure(Some(run.id), view.TurnFailed, error),
      )
    // Compaction makes no provider request, so the footer's last real
    // usage is stale, and the estimate of the strategy replaces it. The total
    // cost of the session is not a measurement of a call, so it stays.
    turn.Compaction(..), _, Ok(_), Ok(_) -> {
      case context_snapshot.request_size(state.context) {
        Some(total) -> {
          let metadata =
            usage.Metadata(
              state.info.model,
              usage.now(),
              Some(usage.Tokens(
                size.total_tokens(total),
                0,
                None,
                None,
                None,
                None,
                None,
              )),
              None,
              None,
              None,
              Some(total),
            )
          session_state.emit(
            session_state.State(..state, latest_usage: Some(metadata)),
            view.CostedUsage(
              Some(metadata),
              state.spent,
              session_cost.total(runtime.ledger(state.host), state.info.id),
            ),
          )
        }
        None -> state
      }
    }
    _, _, _, _ -> state
  }
  let state = case run.cancelled, outcome {
    False, Ok(_) -> state
    _, _ ->
      session_state.emit(
        state,
        view.CostedUsage(
          state.latest_usage,
          state.spent,
          session_cost.total(runtime.ledger(state.host), state.info.id),
        ),
      )
  }
  case run.work {
    turn.Compaction(action_id, reply, report) -> {
      let failure = case persisted, run.cancelled, outcome {
        Error(error), _, _ -> Some(error)
        _, True, _ -> Some("compaction interrupted")
        _, _, Error(error) -> Some(error)
        _, _, Ok(_) -> None
      }
      finish_compaction(
        state,
        action_id,
        reply,
        Ok(
          turn.CompactionReport(
            ..report,
            state: case failure, report.observation {
              Some(_), _ -> "failed"
              None, Some(_) -> "compacted"
              None, None -> "unchanged"
            },
            failure: failure,
          ),
        ),
      )
    }
    _ -> Nil
  }
  let state = case run.work, persisted {
    turn.Turn(..), Ok(_) -> {
      let ids = turn.operations(state.active_submissions)
      state
      |> session_submission.refresh_ids(ids)
      |> session_state.emit(view.TurnCompleted(
        run.id,
        turn_state(run, outcome),
        ids,
      ))
    }
    _, _ -> state
  }
  let state =
    session_state.State(..state, active_submissions: [])
    |> session_state.announce
  report_end(state, run)
  process.send(state.self, Collect)
  start_queued(state) |> request_resting_release
}

/// Released now: live kernels are near the memory budget, or this one holds
/// more than its memory cap, which only a new process gives back.
fn when_release_allowed(state: State, answer: fn(Bool) -> Nil) -> Nil {
  case option.map(state.kernel, runtime.bloated) {
    Some(True) -> answer(True)
    _ -> runtime.when_pressed(state.host, answer)
  }
}

/// How long a resting session keeps a kernel it no longer uses: past the
/// pause between one person's prompts, short enough that a crowd of idle
/// agents holds none.
const idle_release_ms = 120_000

/// How long a resting session waits after settling before checkpointing its
/// Python namespace in the background.
const checkpoint_idle_ms = 2000

/// Arms both a background namespace checkpoint after `checkpoint_idle_ms` and
/// an idle release after `idle_release_ms` (or at once under memory pressure)
/// when the kernel is resting with no live work.
fn request_resting_release(state: State) -> State {
  case
    state.kernel,
    turn.running(state.activity),
    state.releasing == None
    && state.checkpointing == None
    && option.map(state.kernel, runtime.live_work) == Some(Ok(0))
  {
    Some(_), None, True -> {
      let token = state.rest_token + 1
      let self = state.self
      let _ =
        albedo_clock.send_after(
          self,
          checkpoint_idle_ms,
          CheckpointKernel(token),
        )
      let _ = albedo_clock.send_after(self, idle_release_ms, IdleKernel(token))
      when_release_allowed(state, fn(available) {
        case available {
          True -> process.send(self, ReleaseResting)
          False -> Nil
        }
      })
      session_state.State(..state, rest_token: token)
    }
    _, _, _ -> state
  }
}

/// Commits what a stopped or failed turn left unfinished.
fn salvage(
  state: State,
  run: turn.Run,
  ending: session_salvage.Ending,
) -> State {
  let #(state, write) = session_salvage.gather(state, run, ending)
  let run_id = run.id
  session_state.write_then(state, write, fn(state, written) {
    case written {
      Ok(salvaged) -> session_salvage.remember(state, salvaged)
      Error(error) ->
        session_state.emit(
          state,
          view.Failure(Some(run_id), view.SalvageFailed, error),
        )
    }
  })
}

/// An extension's background call starts only while nothing else holds the
/// session; otherwise the caller hears why. The request is complete, so it
/// needs no kernel: a released one does not stop it.
fn start_background(
  state: State,
  request: types.Request,
  prefix: requests.Prefix,
  reply: Subject(Result(compaction.Answer, String)),
) -> State {
  let refused = fn(state, reason) {
    process.send(reply, Error(reason))
    state
  }
  case turn.running(state.activity) {
    Some(_) -> refused(state, "the session is busy")
    None ->
      case session_provider.configured_client(state) {
        Ok(#(primed, client)) ->
          session_run.start_background(
            primed,
            client,
            request,
            prefix,
            reply,
            BackgroundFinished,
          )
          |> session_state.announce
        Error(error) -> refused(state, error)
      }
  }
}

/// A background call ended. It never touched the transcript, so nothing
/// commits and nothing is announced; its caller gets the outcome, and the
/// submissions it held back start now.
fn background_finish(
  state: State,
  run: turn.Run,
  reply: Subject(Result(compaction.Answer, String)),
  outcome: Result(compaction.Answer, String),
) -> actor.Next(State, Message) {
  process.demonitor_process(run.monitor)
  process.send(reply, case run.cancelled {
    True -> Error("cancelled")
    False -> outcome
  })
  let state =
    session_state.State(..state, activity: turn.Resting)
    |> follow_up
    |> session_state.announce
  let #(state, _) = session_switch.apply_pending(state)
  actor.continue(start_queued(state))
}

/// A summary worker ended. It answers its caller itself, so only a worker
/// that died without answering is reported here. Like a background call it
/// commits nothing; the submissions it held back start now.
fn summary_finish(
  state: State,
  run: turn.Run,
  reply: Subject(Result(#(String, Int), String)),
  outcome: Result(Nil, String),
) -> actor.Next(State, Message) {
  process.demonitor_process(run.monitor)
  // The summary is a provider call, so it added to the total cost of the
  // session.
  let state = synced_spend(state)
  case outcome {
    Error(reason) ->
      process.send(
        reply,
        Error(case run.cancelled {
          True -> "cancelled"
          False -> reason
        }),
      )
    Ok(_) -> Nil
  }
  let state =
    session_state.State(..state, activity: turn.Resting)
    |> follow_up
    |> session_state.announce
  let #(state, _) = session_switch.apply_pending(state)
  actor.continue(start_queued(state))
}

/// Start the worker that summarizes the rows from `checkpoint` on, which must
/// begin with a user message. Its history is just that tail.
fn start_summary(
  state: State,
  checkpoint: Int,
  instructions: Option(String),
  out: Subject(Result(#(String, Int), String)),
  ack: Subject(Result(Nil, Refusal)),
) -> actor.Next(State, Message) {
  let prepared = {
    use #(state, kernel, client) <- result.try(
      prepare_submission(state)
      |> result.map_error(fn(error) {
        refusal.Unavailable(submission_error(error))
      }),
    )
    use sources <- result.try(
      conversation.load_sources(runtime.ledger(state.host), state.info.id)
      |> refusal.storage,
    )
    let tail = list.filter(sources, fn(row) { row.source.seq >= checkpoint })
    use last <- result.try(case tail {
      [first, ..] if first.source.seq == checkpoint ->
        case transcript.row_class(first.entry.input) {
          "user" ->
            Ok(list.fold(tail, checkpoint, fn(_, row) { row.source.seq }))
          _ -> Error(refusal.CheckpointNotFound)
        }
      _ -> Error(refusal.CheckpointNotFound)
    })
    use inputs <- result.try(
      list.map(tail, fn(row) { row.entry })
      |> session_history.tag_unknown_provider(state.info.provider)
      |> list.reverse
      |> Some
      |> session_history.projected_entries(
        state.info.provider,
        state.info.protocol,
      )
      |> result.map_error(fn(error) {
        refusal.Unavailable("cannot prepare model history: " <> error)
      }),
    )
    Ok(#(state, kernel, client, inputs, last))
  }
  case prepared {
    Error(error) -> answer(state, ack, Error(error))
    Ok(#(state, kernel, client, inputs, last)) -> {
      process.send(ack, Ok(Nil))
      actor.continue(
        session_run.start(
          stirred(state),
          kernel,
          client,
          session_run.Given(inputs),
          turn.Summary(instructions, last, out),
          mail.new_id(),
          run_messages(),
        )
        |> session_state.announce,
      )
    }
  }
}

/// A background call repeats the session's last turn call, so the provider's
/// cache clock starts over from it, warm or cold: the cached count fades from
/// there now, and clients receive the steps that changed. The caller synced the
/// spend first, so the frame carries the cost of the call.
fn rewarmed(state: State, started: Int) -> State {
  case state.latest_usage {
    Some(usage.Metadata(cache: Some(fade), ..) as metadata) -> {
      let fade = cache_fade.reanchor(fade, started, usage.now())
      let metadata = usage.Metadata(..metadata, cache: Some(fade))
      case
        conversation.record_usage(
          runtime.ledger(state.host),
          state.info.id,
          metadata,
        )
      {
        Ok(_) ->
          session_state.emit(
            session_state.State(..state, latest_usage: Some(metadata)),
            view.CostedUsage(
              Some(metadata),
              state.spent,
              session_cost.total(runtime.ledger(state.host), state.info.id),
            ),
          )
        Error(_) -> state
      }
    }
    _ -> state
  }
}

/// A run ended. The actor read the total as each committed response landed, so
/// this read is for the calls that committed nothing: a failed attempt, a
/// background call, a summary. Read the total and tell a client when it changed.
fn synced_spend(state: State) -> State {
  let spent = spend_of(state)
  case spent == state.spent {
    True -> state
    False ->
      session_state.emit(
        session_state.State(..state, spent: spent),
        view.CostedUsage(
          state.latest_usage,
          spent,
          session_cost.total(runtime.ledger(state.host), state.info.id),
        ),
      )
  }
}

/// The total that the ledger holds for the session, per basis. The rows are the
/// record, and the ledger adds each call's figures into the total as it writes
/// them, so there is nothing else to read. A store that cannot be read says so,
/// and leaves the total that the actor already knew.
fn spend_of(state: State) -> Option(types.Cost) {
  case conversation.load_spend(runtime.ledger(state.host), state.info.id) {
    Ok(spent) -> spent
    Error(error) -> {
      io.println_error(
        "spend read failed for session " <> state.info.id <> ": " <> error,
      )
      state.spent
    }
  }
}

/// A run that held the session ended: its extensions hear that a turn
/// ended, or that a compaction rewrote the history.
fn report_end(state: State, run: turn.Run) -> Nil {
  case run.work {
    turn.Turn(..) -> observe(state, extension.TurnEnded(run.cancelled))
    turn.Compaction(_, _, turn.CompactionReport(observation: Some(_), ..)) ->
      observe(state, extension.Compacted)
    turn.Compaction(..) -> Nil
    turn.Background(_) | turn.Summary(..) -> Nil
  }
}

/// Tells the extensions the last turn call, rebuilt, so warming picks up
/// where the restart left it.
fn restore_last_call(state: State) -> State {
  case session_last_call.restore(state) {
    #(state, Some(#(call, pings))) -> {
      observe(state, extension.Restored(call, pings))
      state
    }
    #(state, None) -> state
  }
}

/// Any new activity, which the session's extensions hear.
fn stirred(state: State) -> State {
  observe(state, extension.Stirred)
  state
}

/// Tells the extensions this session composed about one of its events, those
/// of a released kernel too: its composition outlives it.
fn observe(state: State, event: extension.SessionEvent) -> Nil {
  case session_state.composition(state) {
    Some(kernel) ->
      runtime.observe(
        kernel,
        background_handle(state.info.id, state.self),
        event,
      )
    None -> Nil
  }
}

/// What an observer may ask of this session. It travels to the observer, so
/// it captures the actor's subject, never the state and its transcript.
fn background_handle(id: String, self: Session) -> extension.Session {
  extension.Session(
    id,
    fn(request, prefix) {
      case
        actor_call.try_call(self, 600_000, CallInBackground(request, prefix, _))
      {
        Ok(outcome) -> outcome
        Error(actor_call.TimedOut) ->
          Error("the background call went unanswered for ten minutes")
        Error(actor_call.CalleeDown) -> Error("the session stopped")
      }
    },
    fn(reason) { process.send(self, RefreshRequested(reason)) },
    fn() {
      actor_call.try_call(self, 5000, ReadAwaited)
      |> result.map(fn(observe) { observe() })
      |> result.unwrap(False)
    },
  )
}

/// Whether work that will wake this session is under way: a job of its own,
/// or one of its children's.
fn awaited_observer(state: State) -> fn() -> Bool {
  let #(host, id) = #(state.host, state.info.id)
  let held =
    option.map(state.kernel, fn(kernel) {
      runtime.kernel_observation(kernel)
      |> result.map(python.awaits_jobs)
      |> result.unwrap(False)
    })
  fn() {
    let own = case held {
      Some(jobs) -> jobs
      None -> runtime.awaiting_jobs(host, id)
    }
    own || children_working(host, id)
  }
}

/// Whether an open child of `id`, or one beneath it, has work under way that
/// ends in a report: a turn, or a job its idle session waits on. A child
/// between turns waiting on its build is still working for its parent.
fn children_working(host: runtime.Runtime, id: String) -> Bool {
  case families.children(storage.host(runtime.ledger(host)), id) {
    Ok(children) ->
      list.any(children, fn(child) {
        !child.closed
        && {
          bus.is_running(child.session)
          || runtime.awaiting_jobs(host, child.session)
          || children_working(host, child.session)
        }
      })
    Error(_) -> False
  }
}

fn start_queued(state: State) -> State {
  use <- bool.lazy_guard(
    state.pending_agent_close != None
      && turn.running(state.activity) == None
      && !state.finishing,
    fn() {
      let _ = option.map(state.pending_agent_close, process.send(state.self, _))
      session_state.State(..state, pending_agent_close: None)
    },
  )
  let state =
    flush_attached(session_state.State(..state, holding_failure: False))
  case turn.running(state.activity) {
    Some(_) -> state
    None ->
      case
        state.kernel_blocked
        || session_state.retry_pending(
          state.blocked_until,
          albedo_clock.monotonic_ms(),
        )
      {
        True -> state
        False -> start_waiting(state)
      }
  }
}

fn start_waiting(state: State) -> State {
  case state.booting {
    Some(_) -> start_waiting_in_workspace(state)
    None ->
      case apply_workspace_state(state) {
        Error(#(state, error)) -> failed_queued(state, error)
        Ok(state) -> start_waiting_in_workspace(state)
      }
  }
}

fn start_waiting_in_workspace(state: State) -> State {
  // `kernel_or_park` asks for a kernel as a side effect, so it only runs when
  // its answer is kept: a Gleam `case` evaluates both subjects before
  // matching, so parking behind a False `starts_turn` started a swap whose
  // arriving kernel was then dropped with no notice, killing the old kernel
  // and the wakes it still owed.
  case queue_starts(state) {
    False -> state
    True ->
      // Remote readiness can wait for SSH. Probe outside the actor so status,
      // capture, and summary requests continue to be answered while it waits.
      begin_workspace_probe(state, QueueStart)
  }
}

fn begin_workspace_probe(state: State, purpose: WorkspaceProbe) -> State {
  case workspace_probe_target(state), state.workspace_probe {
    None, _ ->
      finish_workspace_probe(
        state,
        purpose,
        check_workspace_ready(state) |> result.map_error(submission_error),
      )
    Some(_), Some(_) -> state
    Some(_), None -> {
      let token = new_generation()
      let self = state.self
      let host = state.host
      let session_id = state.info.id
      let cwd = state.info.cwd
      let kernel_held = state.kernel != None
      let _ =
        process.spawn_unlinked(fn() {
          let result =
            check_workspace_ready_values(host, session_id, cwd, kernel_held)
            |> result.map_error(submission_error)
          process.send(self, WorkspaceReady(token, purpose, result))
        })
      session_state.State(..state, workspace_probe: Some(token))
    }
  }
}

fn workspace_probe_target(state: State) -> Option(String) {
  case location.parse(state.info.cwd), state.kernel {
    Ok(location.Remote(..) as at), None ->
      case location.ssh_target(at) {
        Ok(target) -> Some(target)
        Error(_) -> None
      }
    _, _ -> None
  }
}

fn finish_workspace_probe(
  state: State,
  purpose: WorkspaceProbe,
  outcome: Result(Nil, String),
) -> State {
  let state = session_state.State(..state, workspace_probe: None)
  case outcome, purpose {
    Error(error), QueueStart ->
      blocked_queued(
        state,
        error
          <> "; queued inputs are retained. Restore the workspace or use /cd to select an existing directory, then send another message to retry",
        None,
      )
    Ok(Nil), QueueStart -> start_in_workspace(state)
    Error(error), ResumeStart ->
      failed_queued(session_state.State(..state, activity: turn.Resting), error)
    Ok(Nil), ResumeStart ->
      case turn_or_park(state, Resume) {
        Error(state) -> state
        Ok(state) -> resume(state)
      }
  }
}

fn workspace_ready(
  state: State,
  token: String,
  purpose: WorkspaceProbe,
  outcome: Result(Nil, String),
) -> State {
  case state.workspace_probe, state.closing {
    Some(current), False if current == token ->
      finish_workspace_probe(state, purpose, outcome)
    _, _ -> state
  }
}

fn start_in_workspace(state: State) -> State {
  case turn_or_park(state, StartQueued) {
    Error(state) -> state
    Ok(state) -> open_queued(state, turn.opening)
  }
}

/// Starts a turn with the rows `pick` chooses from the inbox; with none, the
/// session rests.
fn open_queued(
  state: State,
  pick: fn(List(turn.Queued)) -> List(String),
) -> State {
  case take_queued(state, pick) {
    Error(error) -> failed_queued(state, error)
    Ok([]) -> state
    Ok(batch) ->
      case prepare_turn_pipeline(state, batch) {
        Error(#(state, err)) -> failed_queued(state, submission_error(err))
        Ok(#(state, opening)) -> start_turn(state, opening)
      }
  }
}

fn start_worker(
  state: State,
  kernel: runtime.Prepared,
  client: extension.Upstream,
  history: session_run.History,
  work: turn.Work,
  run_id: String,
) -> State {
  bus.running(state.info.id, True)
  let state = stirred(state)
  session_run.start(
    state,
    kernel,
    client,
    history,
    work,
    run_id,
    run_messages(),
  )
  |> session_state.announce
}

/// Usage a committed model response carried becomes the session's latest. The
/// call's row is in the ledger by now, so the total is read here too: a turn can
/// run for hours, and a client must see what it has spent while it runs, not
/// only once it ends.
fn remember_usage(
  state: session_state.State(Message),
  metadata: Option(usage.Metadata),
) -> session_state.State(Message) {
  case metadata {
    None -> state
    Some(metadata) -> {
      let state =
        session_state.State(
          ..state,
          latest_usage: Some(metadata),
          context: context_snapshot.with_usage(state.context, metadata),
          spent: spend_of(state),
        )
      session_state.emit(
        state,
        view.CostedUsage(
          Some(metadata),
          state.spent,
          session_cost.total(runtime.ledger(state.host), state.info.id),
        ),
      )
    }
  }
}

/// The messages a run's worker sends this actor.
fn run_messages() -> session_run.Messages(Message) {
  session_run.Messages(
    Publish,
    ToolProgressDelta,
    ToolProgressRunning,
    ToolProgressReset,
    ToolProgressFinish,
    Commit,
    CommitFits,
    Salvage,
    RecordContext,
    DrainSteering,
    ReportPin,
    ReportSent,
    ReportShellDelivery,
    ReportCompacting,
    Finished,
    Collect,
    AcquireKernel,
    RequestBoundary,
  )
}

fn projected_entries(state: State) -> Result(List(transcript.Entry), String) {
  session_history.projected_entries(
    state.history,
    state.info.provider,
    state.info.protocol,
  )
  |> result.map_error(fn(error) { "cannot prepare model history: " <> error })
}

/// Commit the desired destination for the captured family before kernel work.
pub fn change_workspace(
  session: Session,
  request: session_workspace.Request,
) -> Result(session_workspace.Recorded, session_workspace.ChangeFailure) {
  actor.call(session, 20_000, ChangeWorkspace(request, _))
}

/// Apply a recorded destination, or report that an existing run still owns it.
pub fn apply_workspace(session: Session) -> Result(Bool, String) {
  actor.call(session, 20_000, ApplyWorkspace)
}

fn workspace_changed(state: State) -> State {
  bus.invalidate(
    [
      "/sessions/" <> state.info.id,
      "/sessions/" <> state.info.id <> "/configuration",
    ],
    [state.info.id],
    False,
  )
  state
  |> session_state.invalidate(view.StaleSession, "/sessions/" <> state.info.id)
  |> session_state.invalidate(
    view.StaleSettings,
    "/sessions/" <> state.info.id <> "/configuration",
  )
}

fn apply_workspace_state(state: State) -> Result(State, #(State, String)) {
  case uses_kernel_transition(state) {
    True -> Ok(state)
    False -> apply_pending_workspace(state)
  }
}

fn apply_pending_workspace(state: State) -> Result(State, #(State, String)) {
  use pending <- result.try(
    store.snapshot(runtime.ledger(state.host), fn(db) {
      session_workspace.pending_in(db, state.info.id)
    })
    |> result.map_error(fn(error) { #(state, error) }),
  )
  case pending {
    None -> Ok(state)
    Some(pending) -> {
      use _ <- result.try(
        locations.workspace(pending.desired)
        |> result.map_error(fn(error) { #(state, error.detail) }),
      )
      case pending.desired == state.info.cwd {
        True -> finish_workspace(state, pending, False)
        False -> {
          let #(host, id, self) = #(state.host, state.info.id, state.self)
          let _ =
            process.spawn_unlinked(fn() {
              process.send(
                self,
                WorkspaceReset(pending, runtime.delete_session(host, id)),
              )
            })
          Ok(
            session_state.State(..state, workspace_reset: Some([]))
            |> session_state.announce,
          )
        }
      }
    }
  }
}

fn workspace_reset(
  state: State,
  pending: session_workspace.Pending,
  outcome: Result(Nil, String),
) -> State {
  let parked = option.unwrap(state.workspace_reset, [])
  let state = session_state.State(..state, workspace_reset: None)
  let applied = case outcome {
    Error(error) -> Error(#(state, error))
    Ok(_) -> {
      let _ = option.map(state.kernel, session_namespace.forget)
      discard_state(state.home, state.info.id)
      finish_workspace(
        session_state.State(
          ..state,
          kernel: None,
          released: None,
          prepared: None,
          context: session_state.unprepared(),
        )
          |> session_namespace.set_notice(
            Some(session_state.KernelNotice(session_namespace.lost_notice, True)),
          ),
        pending,
        True,
      )
    }
  }
  case applied {
    Ok(state) -> {
      list.each(parked, process.send(state.self, _))
      process.send(state.self, StartQueued)
      state |> follow_up |> session_state.announce
    }
    Error(#(state, error)) ->
      list.fold(parked, state, fn(state, message) {
        case message {
          ApplyWorkspace(reply) -> {
            process.send(reply, Error(error))
            state
          }
          StartQueued -> failed_queued(state, error)
          Compact(_, action_id, reply) -> {
            finish_compaction(
              state,
              action_id,
              reply,
              Error(refusal.Unavailable(error)),
            )
            state
          }
          _ -> {
            process.send(state.self, message)
            state
          }
        }
      })
      |> session_state.announce
  }
}

fn finish_workspace(
  state: State,
  pending: session_workspace.Pending,
  reset_namespace: Bool,
) -> Result(State, #(State, String)) {
  let ledger = runtime.ledger(state.host)
  use applied <- result.try(
    session_workspace.applied(ledger, state.info.id, pending)
    |> result.map_error(fn(error) { #(state, error) }),
  )
  case applied {
    False -> Ok(state)
    True -> {
      // Inputs a missing folder blocked try the new one now, not when
      // their 15 s retry comes round.
      case queue_starts(state) {
        False -> Nil
        True -> process.send(state.self, StartQueued)
      }
      let state =
        session_state.State(
          ..state,
          info: session_info.Info(..state.info, cwd: pending.desired),
          blocked_until: 0,
          kernel_blocked: False,
        )
        |> workspace_changed
      Ok(case reset_namespace {
        False -> state
        True ->
          session_state.emit(
            state,
            view.note(
              "workspace",
              "workspace changed; python variables were cleared, the transcript is intact",
            ),
          )
      })
    }
  }
}

/// Whether a message must bypass normal turn and workspace-move settlement.
fn read_only(message: Message) -> Bool {
  case message {
    SideQuestionFinished(..)
    | CancelSideQuestion(..)
    | DismissSideQuestion(..)
    | ClaimSideContinuation(..)
    | SettleSideContinuation(..)
    | CollectQuiet
    | ShellEnded(_, _, _, _, _)
    | ShellChanged(_, _)
    | StopShell(_, _)
    | StartShell(_, _, _)
    | FlushAttached
    | ReadCapture(_)
    | CaptureIn(_, _)
    | Released(..)
    | Deleted(_, _)
    | ChildrenObserved(_, _)
    | WorkspaceReset(_, _)
    | ReadSummary(_)
    | ReadStatus(_)
    | ReadAwaited(_)
    | ReadKernel(_)
    | ReadCommands(_)
    | ReadSelection(_)
    | ReadEffort(_)
    | ReadFast(_)
    | ReadCompactAt(_)
    | ExtensionChanged(..)
    | ReadName(_)
    | Read(_, _)
    | ReadContext(_)
    | QuietTurn(_)
    | Idle(_) -> True
    _ -> False
  }
}

/// A busy session makes the move it owes an ancestor when its run ends.
fn settle(state: State) -> State {
  case busy(state) || state.booting != None {
    True -> state
    False -> follow_up(state)
  }
}

/// Failed application leaves the destination durable. Turn admission reports
/// the failure before using an old kernel; a later attempt may apply it.
fn follow_up(state: State) -> State {
  case apply_workspace_state(state) {
    Ok(state) -> state
    Error(#(state, _)) -> state
  }
}

/// Admission commits before kernel or provider preparation begins. The
/// session decides at once and the store commits the receipt off the actor:
/// the caller waits for that commit while the session and its store live.
pub fn admit_durable(
  worker: Session,
  operation: operations.Request,
  submission: Submission,
) -> Result(operations.Receipt, Refusal) {
  let committed = process.new_subject()
  actor.call(worker, 15_000, AdmitOperation(operation, submission, committed, _))
  |> admitted(worker, committed)
}

pub fn admit_acp(
  worker: Session,
  operation: operations.Request,
  submission: Submission,
  digest: acp.Digest,
) -> Result(operations.Receipt, Refusal) {
  let committed = process.new_subject()
  actor.call(worker, 15_000, AdmitACP(
    operation,
    submission,
    digest,
    committed,
    _,
  ))
  |> admitted(worker, committed)
}

/// What the session decided about an input before any write.
pub opaque type Admission {
  Decided(Result(operations.Receipt, Refusal))
  /// The receipt arrives on the caller's subject once this store commits it.
  Committing(store.Store)
}

fn admitted(
  admission: Admission,
  worker: Session,
  committed: Subject(Result(operations.Receipt, Refusal)),
) -> Result(operations.Receipt, Refusal) {
  case admission {
    Decided(result) -> result
    Committing(ledger) -> {
      let assert Ok(owner) = process.subject_owner(worker)
      store.await_delivery(ledger, committed, owner)
      |> result.replace_error(refusal.AdmissionInterrupted)
      |> result.flatten
    }
  }
}

pub fn publish_acp_overlay(
  worker: Session,
  digest: acp.Digest,
  generation: Int,
  candidate: Option(acp_session.Candidate),
) -> Result(Nil, acp_session.Failure) {
  actor_call.try_call(worker, 15_000, PublishACPOverlay(
    digest,
    generation,
    candidate,
    _,
  ))
  |> result.map_error(fn(_) { acp_session.Uncertain })
  |> result.flatten
}

pub fn continuation(client: String, operation_id: String) -> Submission {
  Submission(
    "",
    continue_prompt,
    client,
    turn.Continue,
    [],
    Some(operation_id),
    Some(operation_id),
    None,
    [],
    None,
  )
}

fn admit_operation(
  state: State,
  operation: operations.Request,
  submission: Submission,
  committed: Subject(Result(operations.Receipt, Refusal)),
  reply: Subject(Admission),
) -> actor.Next(State, Message) {
  let db = runtime.ledger(state.host)
  case operations.check(db, operation) {
    Error(error) -> answer(state, reply, Decided(Error(error)))
    Ok(Some(receipt)) -> answer(state, reply, Decided(Ok(receipt)))
    Ok(None) -> {
      let #(state, image_error) = refused_image(state, submission)
      // Preparation saved the files for a local workspace; the actor orders
      // this check after any workspace change that won the race.
      let remote_files =
        submission.files != []
        && case location.parse(state.info.cwd) {
          Ok(location.Remote(..)) -> True
          _ -> False
        }
      let refusal = case
        remote_files,
        image_error,
        turn.admit(state.activity, submission)
      {
        True, _, _ ->
          Some(session_creation.rejection(
            refusal.AttachmentWorkspaceUnsupported,
          ))
        _, Some(reason), _ ->
          Some(operations.Rejection(409, "image_rejected", reason))
        _, _, turn.Reject(turn.Oversized) ->
          Some(operations.Rejection(
            413,
            "input_too_large",
            "prompt or activation exceeds its bounded size",
          ))
        _, _, _ -> None
      }
      case refusal {
        Some(reason) -> {
          operations.reject_then(db, operation, reason, process.send(
            committed,
            _,
          ))
          answer(state, reply, Committing(db))
        }
        None -> {
          let self = state.self
          let session = state.info.id
          operations.admit_pending_then(
            db,
            operation,
            fn(db) {
              case inbox.insert(db, session, "you", submission) {
                Ok(True) -> Ok(Nil)
                Ok(False) -> Error(refusal.QueueFull)
                Error(error) -> Error(refusal.Unavailable(error))
              }
            },
            202,
            "",
            fn(result) {
              process.send(
                self,
                AdmissionCommitted(submission, result, committed),
              )
            },
          )
          answer(
            session_state.State(..state, admitting: state.admitting + 1),
            reply,
            Committing(db),
          )
        }
      }
    }
  }
}

/// A committed admission waits in the inbox unless a cancellation that ran
/// after its commit (an interrupt, a close) already dropped it there.
fn admission_committed(
  state: State,
  submission: Submission,
  result: Result(operations.Receipt, Refusal),
  committed: Subject(Result(operations.Receipt, Refusal)),
) -> actor.Next(State, Message) {
  let state = session_state.State(..state, admitting: state.admitting - 1)
  let state = case result {
    Error(_) -> state
    Ok(receipt) -> {
      let id = receipt.operation.id
      let held = turn.holds_letter(state.active_submissions, id)
      case operations.input_outcome(runtime.ledger(state.host), id), held {
        Ok(Some(outcome)), False
          if outcome.receipt.delivery == Some(operations.Awaiting)
        -> {
          let state =
            session_naming.maybe_start(
              state,
              submission,
              outcome.acceptance_order,
              TitleFinished,
            )
          process.send(state.self, StartQueued)
          session_state.State(..state, kernel_blocked: case submission.source {
            turn.Chat | turn.Continue -> False
            _ -> state.kernel_blocked
          })
          |> session_state.emit(view.Input(
            outcome,
            Some(session_submission.display(submission)),
          ))
          |> session_state.queue_changed
          |> session_state.announce
        }
        _, _ -> state
      }
    }
  }
  process.send(committed, result)
  actor.continue(answer_captures(state))
}

fn answer_captures(state: State) -> State {
  case state.writing == 0 && state.admitting == 0, state.captures {
    True, [_, ..] as waiting -> {
      let state =
        session_state.flush_output(session_state.State(..state, captures: []))
      list.each(list.reverse(waiting), fn(capture) { capture(state) })
      state
    }
    _, _ -> state
  }
}

fn interrupt_waiting(
  state: State,
  cancelled: List(String),
  reply: Subject(Bool),
) -> actor.Next(State, Message) {
  let #(state, stopped) = stop_waiting(state, cancelled)
  answer(state, reply, stopped)
}

/// Cancels the running turn, or the one waiting for the kernel to start
/// what waits in the inbox; the Bool says whether there was any. The caller
/// already cancelled a person's waiting inputs (`cancelled`); every other
/// row stays in the inbox and can start a later turn.
fn stop_waiting(state: State, cancelled: List(String)) -> #(State, Bool) {
  let waiting = cancelled != [] || waiting_turn(state) || queue_starts(state)
  let state = session_submission.refresh_ids(state, cancelled)
  case interruptible_run(state), waiting {
    None, True -> {
      let state = clear_tool_progress(state)
      #(
        session_state.State(
          ..state,
          // A finishing run still reports its inputs when its end lands.
          active_submissions: case state.finishing {
            True -> state.active_submissions
            False -> []
          },
          blocked_until: 0,
          kernel_blocked: False,
          workspace_probe: None,
          booting: option.map(state.booting, fn(boot) {
            #(
              boot.0,
              list.filter(boot.1, fn(work) {
                work != StartQueued && work != Resume
              }),
            )
          }),
        )
          |> withdraw_unused_boot
          |> session_state.queue_changed
          |> session_state.announce,
        True,
      )
    }
    None, False -> #(state, False)
    Some(run), _ -> {
      interrupt_kernel(state)
      let _ = albedo_clock.send_after(state.self, 2500, Abort(run.id))
      #(
        session_state.State(
          ..clear_tool_progress(refuse_acquires(state)),
          blocked_until: 0,
          kernel_blocked: False,
          activity: cancel_turn(state),
        )
          |> session_state.queue_changed
          |> session_state.announce,
        True,
      )
    }
  }
}

/// A cancelled turn may share preparation with commands still parked here.
fn withdraw_unused_boot(state: State) -> State {
  case state.booting, state.boot_ticket {
    Some(#(_, [])), Some(_) -> withdraw_boot(state)
    _, _ -> state
  }
}

fn withdraw_empty_queue_boot(state: State) -> State {
  case queue_starts(state), turn.running(state.activity) {
    False, None ->
      session_state.State(
        ..state,
        booting: option.map(state.booting, fn(boot) {
          #(
            boot.0,
            list.filter(boot.1, fn(work) {
              work != StartQueued && work != Resume
            }),
          )
        }),
      )
      |> withdraw_unused_boot
    _, _ -> state
  }
}

fn withdraw_boot(state: State) -> State {
  case state.boot_ticket {
    Some(ticket) -> runtime.cancel_request_ticket(ticket)
    None -> Nil
  }
  session_state.State(
    ..state,
    booting: None,
    boot_ticket: None,
    boot_token: state.boot_token + 1,
  )
}

/// The run an interrupt can still stop. Once its end is being committed the
/// outcome is fixed, so the run has already ended for an interrupt.
fn interruptible_run(state: State) -> Option(turn.Run) {
  case state.finishing {
    True -> None
    False -> turn.running(state.activity)
  }
}

/// The running turn cancelled, keeping the tools of the calls the model was
/// still writing for the turn's salvage.
fn cancel_turn(state: State) -> turn.Activity {
  turn.cancel(
    state.activity,
    tool_progress_state.generating(state.tool_progress),
  )
}

fn clear_tool_progress(state: State) -> State {
  let had_calls = tool_progress_state.has_calls(state.tool_progress)
  let state = invalidate_progress_timer(state)
  let state =
    session_state.State(
      ..state,
      tool_progress: tool_progress_state.clear(state.tool_progress),
    )
  case had_calls {
    False -> state
    True -> session_state.emit(state, view.clear_tool_progress())
  }
}

fn new_generation() -> String {
  crypto.strong_random_bytes(16) |> bit_array.base64_url_encode(False)
}

fn release_answer(
  state: State,
  reply: Option(Subject(Bool)),
  released: Bool,
) -> actor.Next(State, Message) {
  case reply {
    Some(reply) -> answer(state, reply, released)
    None -> actor.continue(state)
  }
}

fn begin_release(
  state: State,
  reply: Option(Subject(Bool)),
  automatic: Bool,
) -> actor.Next(State, Message) {
  let settled = !uses_kernel_transition(state) && state.booting == None
  case state.kernel, turn.running(state.activity) {
    // Only published facts: unknown work retains the kernel without calling its owner.
    Some(kernel), None ->
      case settled && runtime.live_work(kernel) == Ok(0) {
        True -> actor.continue(release_kernel(state, kernel, reply, automatic))
        False -> release_answer(state, reply, False)
      }
    // A resting session that never opened a kernel still drops the request
    // it prepared, as a release would.
    None, None if settled ->
      session_state.State(..state, context: session_state.unprepared())
      |> release_answer(reply, False)
    _, _ -> release_answer(state, reply, False)
  }
}

/// Saves the namespace outside the actor and answers `Released`; work that
/// needs the kernel meanwhile parks behind `releasing`.
fn release_kernel(
  state: State,
  kernel: runtime.Session,
  reply: Option(Subject(Bool)),
  automatic: Bool,
) -> State {
  let #(home, id, self) = #(state.home, state.info.id, state.self)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        self,
        Released(
          kernel,
          albedo_protect.guarded(fn() {
            session_namespace.save_state(home, id, kernel)
          }),
          reply,
          automatic,
        ),
      )
    })
  session_state.State(..state, releasing: Some([]))
}

/// The prepared request a client reads at rest. A released session holds none
/// (its actor keeps no request sections), so the last turn call is rebuilt from
/// the transcript, as the cache warmer does after a restart, and kept until the
/// next release or history eviction so a polling client does not rebuild it.
/// The rebuild projects the whole history and can outlast a reader's wait, so
/// it runs beside the actor and readers see a pending snapshot until it lands
/// (albedo-suite). A session without a composition, as after a daemon
/// restart, asks for one first.
fn context_read(state: State) -> #(State, context_snapshot.Snapshot) {
  case
    context_snapshot.identity(state.context),
    turn.running(state.activity),
    state.kernel
  {
    None, None, None ->
      case state.composing_context, session_state.composition(state) {
        True, _ -> #(state, rebuilding_context())
        False, Some(composition) -> #(
          rebuild_context(state, composition),
          rebuilding_context(),
        )
        False, None -> {
          let self = state.self
          runtime.prepare_session_async(
            state.host,
            state.info.id,
            state.info.cwd,
            fn(result) { process.send(self, ContextComposed(result)) },
          )
          #(
            session_state.State(..state, composing_context: True),
            rebuilding_context(),
          )
        }
      }
    _, _, _ -> #(state, state.context)
  }
}

fn rebuilding_context() -> context_snapshot.Snapshot {
  context_snapshot.pending("rebuilding the last request; reading again shortly")
}

/// Rebuilds the last request, or previews the first, in a process of its own
/// that answers with `ContextRebuilt`. The worker's copy of the state is its
/// own: the history it loads and any credentials it refreshes go with it.
fn rebuild_context(state: State, composition: runtime.Prepared) -> State {
  let self = state.self
  process.spawn_unlinked(fn() {
    process.send(self, ContextRebuilt(rebuilt_context(state, composition)))
  })
  session_state.State(..state, composing_context: True)
}

fn rebuilt_context(
  state: State,
  composition: runtime.Prepared,
) -> context_snapshot.Snapshot {
  case session_last_call.restore_context(state) {
    #(state, Some(#(request, observation, protocol))) -> {
      let rebuilt =
        context_snapshot.from_request(
          Some(usage.now()),
          state.info.provider,
          conversation.protocol(protocol),
          protocol,
          request,
          observation,
        )
      case state.latest_usage {
        Some(metadata) -> context_snapshot.with_usage(rebuilt, metadata)
        None -> rebuilt
      }
    }
    #(state, None) -> preview_context(state, composition)
  }
}

/// What a session that has sent nothing would send first: its instructions
/// and tools around an empty conversation (albedo-suite). Kept like a rebuilt
/// request until the first turn records the real one. A session whose last
/// turn used another model stays pending: an empty conversation would
/// misstate it.
fn preview_context(
  state: State,
  composition: runtime.Prepared,
) -> context_snapshot.Snapshot {
  let unsent = fn(reason) {
    context_snapshot.pending("cannot preview the first request: " <> reason)
  }
  case requests.last_turn(runtime.ledger(state.host), state.info.id) {
    Ok(None) ->
      case session_provider.configured_client(state) {
        Error(reason) -> unsent(reason)
        Ok(#(state, upstream)) ->
          case
            loop.rebuild_observed(
              state.host,
              composition,
              state.info.model,
              upstream.resolved_effort,
              state.pin,
              upstream,
              [],
              None,
            )
          {
            Error(reason) -> unsent(reason)
            Ok(#(request, _, observation)) ->
              context_snapshot.from_request(
                Some(usage.now()),
                state.info.provider,
                conversation.protocol(upstream.protocol),
                upstream.protocol,
                request,
                observation,
              )
          }
      }
    _ ->
      context_snapshot.pending(
        "no provider request to rebuild: the last turn used another model or provider",
      )
  }
}

/// Keeps a rebuilt snapshot unless a turn, a kernel or another snapshot came
/// meanwhile, and has readers read again.
fn context_rebuilt(state: State, snapshot: context_snapshot.Snapshot) -> State {
  let state = session_state.State(..state, composing_context: False)
  case
    context_snapshot.identity(state.context),
    turn.running(state.activity),
    state.kernel
  {
    None, None, None -> session_state.State(..state, context: snapshot)
    _, _, _ -> state
  }
  |> session_state.invalidate(
    view.StaleContext,
    "/sessions/" <> state.info.id <> "/context",
  )
}

/// Keeps the composition a context read asked for, unless a kernel or turn
/// brought one meanwhile, and has readers read again.
fn context_composed(
  state: State,
  result: Result(runtime.Prepared, python.Error),
) -> State {
  let state = session_state.State(..state, composing_context: False)
  case result, session_state.composition(state) {
    Ok(prepared), None if prepared.cwd == state.info.cwd ->
      session_state.State(..state, prepared: Some(prepared))
    _, _ -> state
  }
  |> session_state.invalidate(
    view.StaleContext,
    "/sessions/" <> state.info.id <> "/context",
  )
}

/// A snapshot rebuilt for a session without a kernel goes with its history.
fn forget_recomputed_context(state: State) -> State {
  case state.kernel {
    None -> session_state.State(..state, context: session_state.unprepared())
    Some(_) -> state
  }
}

/// The rows waiting in this session's inbox that its running turn has not
/// taken, as the queue's rules see them. A closed agent's letters and job
/// notices are left out: it reads none of them.
fn queued(state: State) -> Result(List(turn.Queued), String) {
  inbox.waiting(
    runtime.ledger(state.host),
    state.info.id,
    turn.letters(state.active_submissions),
    family_closed(state) == Ok(True),
  )
  |> result.map(
    list.take_while(_, fn(row) { !dict.has_key(state.held, row.id) }),
  )
}

/// Someone stored or withdrew a row in this session's inbox: clients read the
/// queue again, and a resting session starts a turn when a waiting row starts
/// one. A session that moved away leaves its rows to the dispatcher, which
/// settles them. Children that fail together land in one turn: a resting
/// parent waits briefly after a failure letter so its siblings' join it.
fn inbox_changed(state: State) -> State {
  let state = session_state.queue_changed(state)
  case state.moved, state.holding_failure, turn.running(state.activity) {
    Some(_), _, _ -> {
      mail.waiting()
      flush(state, turn.left_behind)
    }
    None, True, _ -> state
    None, False, None ->
      case failure_waits(state) {
        True -> {
          let _ =
            albedo_clock.send_after(state.self, failure_hold_ms, StartQueued)
          session_state.State(..state, holding_failure: True)
          |> session_state.announce
        }
        False -> start_queued(state)
      }
    None, False, Some(_) -> start_queued(state)
  }
}

/// How long an idle parent waits for more of its children to report failure.
const failure_hold_ms = 400

/// Whether a child's failure letter waits in the inbox.
fn failure_waits(state: State) -> Bool {
  queued(state)
  |> result.unwrap([])
  |> list.any(fn(row) {
    case row.kind {
      mail_value.Stopped(..) -> True
      _ -> False
    }
  })
}

/// Whether a row waiting in the inbox starts a turn.
fn queue_starts(state: State) -> Bool {
  queued(state) |> result.map(turn.starts_turn) |> result.unwrap(False)
}

/// The waiting rows `pick` chooses, as submissions, in queue order.
fn take_queued(
  state: State,
  pick: fn(List(turn.Queued)) -> List(String),
) -> Result(List(Submission), String) {
  use queued <- result.try(queued(state))
  inbox.take(runtime.ledger(state.host), state.info.id, pick(queued))
}

/// Rows waiting in the inbox that this session never took are dropped there
/// too; those its running turn took are not. A dropped row with a receipt is
/// cancelled, and its clients hear so.
fn drop_queued_in(
  state: State,
  ids: List(String),
) -> #(State, Result(List(String), String)) {
  let ledger = runtime.ledger(state.host)
  let taken = turn.letters(state.active_submissions)
  let dropped = {
    use waiting <- result.try(mail.still_waiting(
      ledger,
      state.info.id,
      list.filter(ids, fn(id) { !list.contains(taken, id) }),
    ))
    use _ <- result.try(operations.cancel_inputs(ledger, state.info.id, waiting))
    use _ <- result.map(
      store.query(ledger, mail.drop_in(_, state.info.id, waiting)),
    )
    waiting
  }
  case dropped {
    Error(error) -> #(state, Error(error))
    Ok(dropped) -> #(
      state
        |> session_submission.refresh_ids(dropped)
        |> withdraw_empty_queue_boot
        |> session_state.queue_changed
        |> session_state.announce,
      Ok(dropped),
    )
  }
}

/// How long a hold on a person's waiting message lasts unless they ask again.
pub const hold_ms = 30_000

fn hold_input_in(state: State, id: String) -> #(State, Result(Nil, Refusal)) {
  case waiting_message(state, id) {
    Error(reason) -> #(state, Error(reason))
    Ok(Nil) -> {
      let _ =
        mail.hold(
          runtime.ledger(state.host),
          state.info.id,
          id,
          albedo_clock.system_ms() + albedo_clock.delay_ms(hold_ms),
        )
      let deadline = albedo_clock.monotonic_ms() + hold_ms
      let _ =
        albedo_clock.send_after(state.self, hold_ms, HoldLapsed(id, deadline))
      #(
        session_state.State(
          ..state,
          held: dict.insert(state.held, id, deadline),
        )
          |> session_state.queue_changed,
        Ok(Nil),
      )
    }
  }
}

fn release_input_in(state: State, id: String) -> State {
  let _ = mail.release_hold(runtime.ledger(state.host), state.info.id, id)
  session_state.State(..state, held: dict.delete(state.held, id))
  |> inbox_changed
}

fn edit_input_in(
  state: State,
  submission: Submission,
) -> #(State, Result(Nil, Refusal)) {
  let id = option.unwrap(submission.submission_id, "")
  let edited = {
    use _ <- result.try(waiting_message(state, id))
    use replaced <- result.try(
      inbox.replace(runtime.ledger(state.host), state.info.id, submission)
      |> refusal.storage,
    )
    case replaced {
      True -> Ok(Nil)
      False -> Error(refusal.InputNotWaiting)
    }
  }
  case edited {
    // A hold the edit could not use stays until it is released or lapses.
    Error(refusal.InputNotWaiting) | Error(refusal.InputNotEditable) | Ok(_) -> #(
      release_input_in(state, id),
      edited,
    )
    Error(_) -> #(state, edited)
  }
}

/// Whether `id` is a person's typed message still waiting in this session's
/// inbox, one its running turn has not taken.
fn waiting_message(state: State, id: String) -> Result(Nil, Refusal) {
  use rows <- result.try(
    inbox.waiting(
      runtime.ledger(state.host),
      state.info.id,
      turn.letters(state.active_submissions),
      False,
    )
    |> refusal.storage,
  )
  case list.find(rows, fn(row) { row.id == id }) {
    Ok(turn.Queued(kind: mail_value.Input(mail_value.Typed), ..)) -> Ok(Nil)
    Ok(_) -> Error(refusal.InputNotEditable)
    Error(_) -> Error(refusal.InputNotWaiting)
  }
}

/// The inbox orders the queue; the session reads it in that order.
fn arrange_queue_in(
  state: State,
  ids: List(String),
) -> #(State, Result(Nil, String)) {
  let ledger = runtime.ledger(state.host)
  case store.query(ledger, mail.arrange_in(_, state.info.id, ids)) {
    Error(error) -> #(state, Error(error))
    Ok(_) -> #(session_state.queue_changed(state), Ok(Nil))
  }
}

fn cancel_input_in(
  state: State,
  id: String,
  reply: Subject(Result(InputCancellation, Refusal)),
) -> State {
  let ledger = runtime.ledger(state.host)
  let taken = turn.letters(state.active_submissions)
  let waiting = case list.contains(taken, id) {
    True -> Ok([])
    False -> mail.still_waiting(ledger, state.info.id, [id])
  }
  case waiting {
    Error(error) -> {
      process.send(reply, Error(refusal.Unavailable(error)))
      state
    }
    Ok([_, ..]) ->
      case operations.cancel_inputs(ledger, state.info.id, [id]) {
        Error(error) -> {
          process.send(reply, Error(refusal.Unavailable(error)))
          state
        }
        Ok(_) -> {
          process.send(reply, Ok(Cancelled))
          state
          |> session_submission.refresh_ids([id])
          |> withdraw_empty_queue_boot
          |> session_state.queue_changed
          |> session_state.announce
        }
      }
    Ok([]) ->
      case interruptible_run(state), state.active_submissions {
        // The turn's opening commit is still on the writer: once it lands,
        // the input is the open turn's or back in the queue, so decide then.
        // A write queued now lands after it.
        Some(run), [submission]
          if submission.operation_id == Some(id) && !run.opened
        ->
          session_state.write_then(state, fn() { Nil }, fn(state, _) {
            cancel_input_in(state, id, reply)
          })
        Some(run), [submission] if submission.operation_id == Some(id) -> {
          interrupt_kernel(state)
          let _ = albedo_clock.send_after(state.self, 2500, Abort(run.id))
          process.send(reply, Ok(InterruptRequested))
          session_state.State(..state, activity: cancel_turn(state))
          |> session_state.announce
        }
        Some(_), submissions -> {
          let shared =
            list.any(submissions, fn(submission) {
              submission.operation_id == Some(id)
            })
          process.send(
            reply,
            Ok(case shared {
              True -> SharedRunning
              False -> NotPending
            }),
          )
          state
        }
        _, _ -> {
          process.send(reply, Ok(NotPending))
          state
        }
      }
  }
}

pub fn generate_title(session: Session) -> Result(Nil, Refusal) {
  actor_call.try_call(session, 5000, GenerateTitle)
  |> result.replace_error(refusal.Unavailable("session unavailable"))
  |> result.flatten
}

pub fn ask_side_question(
  worker: Session,
  id: String,
  question: String,
) -> Result(side_question.Exchange, side_question.Refusal) {
  actor_call.try_call(worker, 5000, AskSideQuestion(id, question, _))
  |> result.unwrap(Error(side_question.Unavailable))
}

pub fn cancel_side_question(
  worker: Session,
  id: String,
) -> Result(side_question.Exchange, side_question.Refusal) {
  actor_call.try_call(worker, 5000, CancelSideQuestion(id, _))
  |> result.unwrap(Error(side_question.Unavailable))
}

pub fn dismiss_side_question(
  worker: Session,
  id: String,
  dismissed: Bool,
) -> Result(side_question.Exchange, side_question.Refusal) {
  actor_call.try_call(worker, 5000, DismissSideQuestion(id, dismissed, _))
  |> result.unwrap(Error(side_question.Unavailable))
}

pub fn claim_side_continuation(
  worker: Session,
  id: String,
  target: String,
) -> Result(side_question.Promotion, side_question.Refusal) {
  actor_call.try_call(worker, 5000, ClaimSideContinuation(id, target, _))
  |> result.unwrap(Error(side_question.Unavailable))
}

pub fn settle_side_continuation(
  worker: Session,
  id: String,
  target: String,
  created: Bool,
) -> Nil {
  process.send(worker, SettleSideContinuation(id, target, created))
}

fn publish_side(state: State, exchange: side_question.Exchange) -> State {
  case state.side_question == Some(exchange) {
    True -> state
    False -> {
      let _ =
        session_side_question.save(
          runtime.ledger(state.host),
          state.info.id,
          exchange,
        )
      session_state.emit(
        session_state.State(..state, side_question: Some(exchange)),
        view.SideQuestion(exchange),
      )
    }
  }
}

fn cancel_side_worker(state: State) -> Nil {
  case state.side_question {
    Some(side_question.Exchange(
      progress: side_question.Running(worker, stop),
      ..,
    )) -> turn.cancel_call(worker, stop)
    _ -> Nil
  }
}

fn finish_side(
  state: State,
  id: String,
  outcome: session_run.Supervised(session_side_question.Answer),
) -> actor.Next(State, Message) {
  let state = synced_spend(state)
  case state.side_question {
    Some(exchange) if exchange.id == id ->
      case exchange.progress {
        side_question.Running(..) -> {
          let progress = case outcome {
            session_run.Done(Ok(answer)) ->
              side_question.Answered(
                answer.text,
                answer.checkpoint,
                side_question.NotContinued,
              )
            session_run.Done(Error(reason)) -> side_question.Failed(reason)
            session_run.Stopped ->
              side_question.Failed("side question cancelled or timed out")
          }
          actor.continue(publish_side(
            state,
            side_question.Exchange(..exchange, progress:),
          ))
        }
        _ -> actor.continue(state)
      }
    _ -> actor.continue(state)
  }
}

fn ask_side(
  state: State,
  id: String,
  question: String,
  reply: Subject(Result(side_question.Exchange, side_question.Refusal)),
) -> actor.Next(State, Message) {
  use <- bool.lazy_guard(state.closing || state.moved != None, fn() {
    answer(
      state,
      reply,
      Error(side_question.NoContext("send a message first in an open session")),
    )
  })
  case side_question.admit(state.side_question, id, question) {
    Error(reason) -> answer(state, reply, Error(reason))
    Ok(side_question.Replayed(exchange)) -> answer(state, reply, Ok(exchange))
    Ok(side_question.Admitted) ->
      case session_state.composition(state) {
        None ->
          case
            stored_history.snapshot(
              storage.host(runtime.ledger(state.host)),
              state.info.id,
            )
          {
            Ok(transcript.Snapshot(upper: upper, ..)) if upper > 0 ->
              case
                option.is_none(state.booting) && !uses_kernel_transition(state)
              {
                True ->
                  actor.continue(request_composition(
                    state,
                    AskSideQuestion(id, question, reply),
                  ))
                False ->
                  actor.continue(park(
                    state,
                    AskSideQuestion(id, question, reply),
                  ))
              }
            _ ->
              answer(
                state,
                reply,
                Error(side_question.NoContext(
                  "send a message first to prepare conversation context",
                )),
              )
          }
        Some(prepared) -> {
          let capture =
            session_side_question.Capture(
              state.host,
              state.home,
              state.info,
              prepared,
              state.pin,
            )
          let #(worker, stop) =
            session_side_question.start(
              capture,
              question,
              state.self,
              SideQuestionFinished(id, _),
            )
          let exchange =
            side_question.Exchange(
              id,
              question,
              usage.now(),
              False,
              side_question.Running(worker, stop),
            )
          answer(publish_side(state, exchange), reply, Ok(exchange))
        }
      }
  }
}

/// Admission returns before the worker finishes. The durable receipt owns
/// recovery, so losing this caller does not cancel accepted compaction.
pub fn admit_compaction(
  session: Session,
  id: String,
  strategy: Option(String),
) -> Result(operations.Receipt, Refusal) {
  actor_call.try_call(session, 5000, AdmitCompaction(id, strategy, _))
  |> result.replace_error(refusal.Unavailable(
    "compaction admission response unavailable; read the action receipt",
  ))
  |> result.flatten
}

fn finish_compaction(
  state: State,
  action_id: Option(String),
  reply: Subject(Result(turn.CompactionReport, Refusal)),
  outcome: Result(turn.CompactionReport, Refusal),
) -> Nil {
  case action_id {
    None -> process.send(reply, outcome)
    Some(id) -> {
      let #(status, report) = case outcome {
        Ok(report) -> #("completed", Some(report))
        Error(error) -> #(
          "completed",
          Some(turn.CompactionReport(
            selection_applied: False,
            effective_strategy: None,
            state: "failed",
            observation: None,
            failure: Some(refusal.explain(error)),
          )),
        )
      }
      persist_compaction(
        state,
        id,
        compaction_action.receipt(id, state.info.id, status, report),
      )
    }
  }
}

/// Retry only the terminal write. The running receipt holds the admission
/// slot until this succeeds; owner death uses the existing interruption path.
fn persist_compaction(state: State, id: String, response: String) -> Nil {
  case
    store.query(runtime.ledger(state.host), fn(db) {
      operations.finish_compaction_in(db, id, response)
    })
  {
    Ok(_) -> Nil
    Error(_) -> {
      let _ =
        albedo_clock.send_after(
          state.self,
          1000,
          PersistCompaction(id, response),
        )
      Nil
    }
  }
}
