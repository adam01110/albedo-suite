//// Converse's fixed AWS endpoint policy prevents the shared E2E provider
//// from producing native history. A fake runtime provider and explicit home
//// exercise the real queue/configuration boundaries without auth or HTTP.

import albedo/daemon/active_output
import albedo/daemon/conversation
import albedo/daemon/event_buffer
import albedo/daemon/family
import albedo/daemon/mail
import albedo/daemon/session_activity
import albedo/daemon/session_configuration as config
import albedo/daemon/session_configure
import albedo/daemon/session_history
import albedo/daemon/session_state
import albedo/daemon/session_switch
import albedo/daemon/store
import albedo/daemon/tool_progress
import albedo/daemon/transcript
import albedo/daemon/turn
import albedo/harness/extension
import albedo/harness/extensions/bedrock/converse_wire
import albedo/harness/loop
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should

const origin = "fixture-origin"

const target = "fixture-target"

const refused =
  "cannot switch model: history is incompatible with Bedrock Converse replay"

fn item(details: String) -> types.Input {
  let assert Ok(item) =
    json.parse(
      "{\"role\":\"assistant\",\"content\":\"answer\",\"tool_calls\":[{\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}],\"reasoning_details\":["
        <> details
        <> "]}",
      types.replay_decoder(types.ChatCompletions),
    )
  types.Replay(item)
}

fn native(block: String) -> types.Input {
  item(
    "{\"type\":\"bedrock_converse\",\"model\":\"fixture-origin\",\"blocks\":["
    <> block
    <> "]}",
  )
}

fn reasoning() -> types.Input {
  native(
    "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"thought\",\"signature\":\"SECRET-SIGNATURE\"}}}",
  )
}

fn metadata() -> types.Input {
  native(
    "{\"toolUse\":{\"toolUseId\":\"c\",\"name\":\"lookup\",\"input\":{},\"future\":\"SECRET-METADATA\"}}",
  )
}

pub fn replay_precheck_keeps_encoder_portability_rules_test() -> Nil {
  converse_wire.validate_replay(target, []) |> should.equal(Ok(Nil))
  let portable = [
    types.User("go"),
    types.Assistant("plain"),
    native("{\"text\":\"native plain\"}"),
    native(
      "{\"toolUse\":{\"toolUseId\":\"c\",\"name\":\"lookup\",\"input\":{}}}",
    ),
    item("{\"signature\":\"legacy untyped\"}"),
    types.ToolOutput("c", "result", []),
  ]
  converse_wire.validate_replay(target, portable) |> should.equal(Ok(Nil))
  list.each(
    [
      reasoning(),
      metadata(),
      native(
        "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"unsigned\"}}}",
      ),
      native("{\"futureOpaque\":\"SECRET-OPAQUE\"}"),
    ],
    fn(input) {
      converse_wire.validate_replay(origin, [input])
      |> should.equal(Ok(Nil))
      converse_wire.validate_replay(target, [input])
      |> result.is_error
      |> should.be_true
    },
  )
}

fn fake_provider() -> extension.Extension {
  extension.Extension(
    "bedrock",
    "credential-free fixture",
    [],
    [
      extension.ModelProviderPlugin(
        extension.ModelProvider("bedrock", fn(context) {
          Some(
            Ok(extension.Upstream(
              endpoint: "fixture",
              protocol: context.protocol,
              stream: fn(_, _) {
                panic as "preflight must never call a provider"
              },
              explain: fn(_) { None },
              account: fn() { None },
              cache_marks: fn(_) { [] },
              images: types.any_images,
            )),
          )
        }),
      ),
    ],
    extension.no_initialise,
  )
}

fn state(home: String, host: runtime.Runtime) -> session_state.State(Nil) {
  let info =
    conversation.Info(
      "child",
      "fixture",
      home,
      "converse",
      origin,
      types.ChatCompletions,
      conversation.Idle,
      None,
      None,
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.create(ledger, info)
  let assert Ok(_) =
    conversation.create(ledger, conversation.Info(..info, id: "parent"))
  session_state.State(
    active_output: active_output.new(home, info.id, "fixture"),
    info: info,
    host: host,
    kernel: None,
    released: None,
    home: home,
    self: process.new_subject(),
    history: Some([]),
    latest_usage: None,
    activity: turn.Resting,
    pending_switch: None,
    steering: [],
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
    workspace_reset: None,
    releasing: None,
    closing: False,
    blocked_until: 0,
    kernel_blocked: False,
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
  )
}

fn fixture(home: String, check: fn(session_state.State(Nil)) -> Nil) -> Nil {
  let assert Ok(host) =
    runtime.start_with_extensions(home <> "/fixture.db", [fake_provider()])
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) = mail.initialise(ledger)
  check(state(home, host))
  runtime.stop(host)
}

fn saved(state: session_state.State(Nil)) -> config.Configuration {
  let assert Ok(saved) =
    store.snapshot(runtime.ledger(state.host), config.read_in(_, state.info.id))
  saved
}

fn history(state: session_state.State(Nil)) -> List(transcript.Entry) {
  let assert Ok(entries) =
    conversation.load_entries(runtime.ledger(state.host), state.info.id)
  entries
}

fn remember(
  state: session_state.State(Nil),
  inputs: List(types.Input),
) -> session_state.State(Nil) {
  let assert Ok(timestamp) =
    conversation.commit_from(
      runtime.ledger(state.host),
      state.info.id,
      inputs,
      conversation.Idle,
      Some(state.info.provider),
    )
  session_history.remember_response(state, inputs, timestamp, None)
}

pub fn incompatible_queue_leaves_configuration_and_notes_unchanged_test() -> Nil {
  use home <- with_home
  use state <- fixture(home)
  list.each([reasoning(), metadata()], fn(input) {
    let state = remember(state, [input, types.ToolOutput("c", "result", [])])
    let before = saved(state)
    let rows = history(state)
    let settings = settings_bytes(home)
    let #(rejected, outcome) =
      session_switch.queue(state, "parent", "converse", target)
    outcome |> should.equal(Error(refused))
    rejected |> should.equal(state)
    saved(rejected) |> should.equal(before)
    history(rejected) |> should.equal(rows)
    settings_bytes(home) |> should.equal(settings)
  })
}

pub fn manual_and_direct_apply_refuse_before_defaults_or_note_commit_test() -> Nil {
  use home <- with_home
  use state <- fixture(home)
  let state =
    remember(state, [
      reasoning(),
      metadata(),
      types.ToolOutput("c", "result", []),
    ])
  let before = saved(state)
  let rows = history(state)
  let settings = settings_bytes(home)
  list.each(
    [
      session_configure.SelectModel(target, None, None, True),
      session_configure.SwitchModel(
        target,
        "converse",
        "must not save this note",
        1,
      ),
    ],
    fn(request) {
      let #(kept, outcome) = session_configure.change(state, request)
      outcome |> should.equal(Error(refused))
      kept |> should.equal(state)
      saved(kept) |> should.equal(before)
      history(kept) |> should.equal(rows)
      settings_bytes(home) |> should.equal(settings)
    },
  )
}

pub fn queued_empty_history_revalidates_native_output_at_apply_time_test() -> Nil {
  use home <- with_home
  use state <- fixture(home)
  // Hold at the existing queue boundary, without booting a Python kernel.
  let state = session_state.State(..state, booting: Some(#(1, [])))
  let before = saved(state)
  let #(queued, outcome) =
    session_switch.queue(state, "parent", "converse", target)
  outcome |> should.equal(Ok(True))
  queued.pending_switch |> should.not_equal(None)
  saved(queued) |> should.equal(before)
  history(queued) |> should.equal([])
  let loaded =
    remember(queued, [reasoning(), types.ToolOutput("c", "result", [])])
  let loaded = session_state.State(..loaded, booting: None)
  let rows = history(loaded)
  let #(kept, selection) = session_switch.apply_pending(loaded)
  selection |> should.equal(None)
  kept.pending_switch |> should.equal(None)
  kept.info |> should.equal(state.info)
  saved(kept) |> should.equal(before)
  history(kept) |> should.equal(rows)
  // The unloaded-history path must also see the newest durable rows.
  let #(unloaded, selection) =
    session_switch.apply_pending(session_state.State(..loaded, history: None))
  selection |> should.equal(None)
  saved(unloaded) |> should.equal(before)
  history(unloaded) |> should.equal(rows)
  let assert Ok(letters) = mail.pending(runtime.ledger(state.host), 10)
  list.length(letters) |> should.equal(2)
  list.each(letters, fn(letter) {
    string.contains(letter.body, refused) |> should.be_true
    string.contains(letter.body, "kept its previous model") |> should.be_true
    string.contains(letter.body, "SECRET") |> should.be_false
  })
}

pub fn same_model_native_reasoning_and_tool_metadata_switch_still_applies_test() -> Nil {
  use home <- with_home
  use state <- fixture(home)
  let state =
    remember(state, [
      reasoning(),
      metadata(),
      types.ToolOutput("c", "result", []),
    ])
  let before = saved(state)
  let #(changed, outcome) =
    session_switch.queue(state, "parent", "converse", origin)
  outcome |> should.equal(Ok(False))
  changed.info.model |> should.equal(origin)
  saved(changed).revision |> should.equal(before.revision + 1)
  list.length(history(changed)) |> should.equal(4)
  Nil
}

pub fn untyped_and_plaintext_history_accept_cross_model_and_other_modes_are_unchanged_test() -> Nil {
  use home <- with_home
  use state <- fixture(home)
  let state =
    remember(state, [
      native("{\"text\":\"portable\"}"),
      item("{\"signature\":\"legacy untyped\"}"),
      types.ToolOutput("c", "result", []),
    ])
  let #(changed, outcome) =
    session_switch.queue(state, "parent", "converse", target)
  outcome |> should.equal(Ok(False))
  saved(changed).model |> should.equal(target)
  // API selection alone must not apply Converse replay policy to other tags.
  let state = remember(changed, [reasoning()])
  list.each(["messages", "legacy", "other"], fn(profile) {
    // Keep native replay in the same profile's projection so this checks the
    // API/extension gate, not portable transfer between different profiles.
    let assert Some(entries) = state.history
    let same_profile =
      session_state.State(
        ..state,
        info: conversation.Info(..state.info, provider: profile),
        history: Some(
          list.map(entries, fn(entry) {
            transcript.Entry(..entry, provider: Some(profile))
          }),
        ),
      )
    session_configure.validate_switch(same_profile, target, profile)
    |> result.is_ok
    |> should.be_true
  })
}

@external(erlang, "albedo_bedrock_replay_preflight_test_support", "with_home")
fn with_home(run: fn(String) -> Nil) -> Nil

@external(erlang, "albedo_bedrock_replay_preflight_test_support", "settings_bytes")
fn settings_bytes(home: String) -> String
