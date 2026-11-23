//// Provider quota readings, polled per account and recorded raw.
////
//// One poller for the whole daemon owns the schedule. Every account albedo
//// can see is polled on its own cadence: each OAuth account in a provider's
//// rotation pool, and each API-key profile whose base url names a feed. Zed is
//// the one provider Albedo reads itself: the core has no Zed feed, so its
//// accounts are polled for account-level edit-prediction usage. Never two
//// polls of one account at once; a limit at or above 80 percent, or one
//// resetting within fifteen minutes, moves that account onto the busy
//// cadence; a failure backs off. Credentials come from the same readers and
//// refreshers the request path uses, so polling refreshes tokens the way
//// requests do; Zed's account reading authenticates with the stored access
//// token as it stands, so polling renews no inference token.
////
//// Only readings are stored — percentages, windows, reset times, statuses and
//// errors exactly as the feed reported them, never anything derived. Phase 2
//// derives what it needs from these rows.

import albedo/accounts/quota_schedule as schedule
import albedo_clock
import albedo_ext_zed/quota as zed_quota
import albedo_process
import albedo_protect
import albedo_sdk/key_environment.{type KeyEnvironment}
import albedo_sdk/network
import albedo_sdk/network_context
import albedo_sdk/profiles as configuration
import albedo_sdk/settings
import albedo_sdk/store
import albedo_sdk/usage_feed.{type Limit, type Report, type Target}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import sqlight

/// The feed the poller polls through: the real one, or a fake in tests.
pub type Fetch =
  fn(String, json.Json, Int) -> Result(Report, String)

pub type Settings =
  schedule.Settings

const default_settings = schedule.Settings(600, 120, True)

/// `$ALBEDO_HOME/extensions.json` under `"quota"`, read like any extension's
/// settings, and re-read every round so changes apply without a restart.
fn load_settings() -> Settings {
  let decoder = {
    use poll_seconds <- decode.optional_field("pollSeconds", 600, decode.int)
    use busy_poll_seconds <- decode.optional_field(
      "busyPollSeconds",
      120,
      decode.int,
    )
    use enabled <- decode.optional_field("enabled", True, decode.bool)
    decode.success(schedule.Settings(poll_seconds, busy_poll_seconds, enabled))
  }
  settings.load("quota", decoder, default_settings)
  |> result.unwrap(default_settings)
  |> clamped
}

fn clamped(settings: Settings) -> Settings {
  let poll_seconds = int.clamp(settings.poll_seconds, 1, 86_400)
  schedule.Settings(
    poll_seconds,
    int.clamp(settings.busy_poll_seconds, 1, poll_seconds),
    settings.enabled,
  )
}

/// One account to poll, and the step its source runs after each report.
pub opaque type Watched {
  Watched(
    target: Target,
    heal: fn(String, String, List(Limit)) -> Nil,
    service: network.Service,
  )
}

/// The accounts this daemon can poll, with credentials refreshed the way
/// requests refresh them: every source's sign-in accounts, then each saved
/// profile the source of its extension maps to a feed.
fn enumerate(
  home: String,
  sources: List(#(String, usage_feed.Source)),
  keys: KeyEnvironment,
) -> List(Watched) {
  let accounts =
    list.flat_map(sources, fn(entry) {
      let source = entry.1
      network_context.routed(network.Extension(entry.0), fn() {
        Ok(source.accounts(home, keys))
      })
      |> result.unwrap([])
      |> list.map(Watched(_, source.heal, network.Extension(entry.0)))
    })
  let profiles =
    configuration.providers(home)
    |> result.unwrap([])
    |> list.filter_map(fn(profile) {
      use source <- result.try(list.key_find(sources, profile.extension))
      use route <- result.try(
        network.resolve(network.Extension(profile.extension))
        |> result.replace_error(Nil),
      )
      use target <- result.map(
        network_context.with_route(route, fn() {
          source.profile(home, profile.name, keys)
        }),
      )
      Watched(target, source.heal, network.Extension(profile.extension))
    })
  list.append(accounts, profiles)
}

// ---- the poller ---------------------------------------------------------

pub type Message {
  Tick(generation: Int)
  WorkerTimedOut(process.Pid)
  /// The account list, as a spawn saw it.
  Enumerated(pid: process.Pid, targets: List(Watched))
  /// One poll finished: the account key, whether it failed, and whether it
  /// is busy.
  Polled(
    key: String,
    pid: process.Pid,
    failed: Bool,
    busy: Bool,
    attempted_at: Int,
  )
  Down(process.Down)
}

type State {
  State(
    home: String,
    database: store.Store,
    fetch: Fetch,
    /// Every installed extension's quota source, with its extension's name.
    sources: List(#(String, usage_feed.Source)),
    settings: fn() -> Settings,
    worker_timeout_ms: Int,
    /// When each account polls; the rules live in `quota_schedule`.
    schedule: schedule.Schedule,
    /// What each scheduled account polls.
    watched: Dict(String, Watched),
    /// The process polling each account now, so a crash frees its slot.
    polls: Dict(process.Pid, String),
    self: Subject(Message),
    /// Cancel and replace the pending tick when an earlier deadline appears.
    timer: Option(process.Timer),
    generation: Int,
    /// The process listing accounts now, so a crash cannot wedge it.
    enumerating: Option(process.Pid),
    /// The runtime's key environment, for sources that poll key accounts.
    keys: KeyEnvironment,
  )
}

/// A provider's feed: the core's, except Zed, which the core has no feed for
/// and Albedo reads itself. Both are passed so the choice is a value, not a
/// hard-wired call.
pub fn feed(
  provider: String,
  credential: json.Json,
  now: Int,
  zed: fn(json.Json) -> Result(Report, String),
  core: Fetch,
) -> Result(Report, String) {
  case provider {
    "zed" -> zed(credential)
    _ -> core(provider, credential, now)
  }
}

/// One poller for the whole daemon. It starts with the daemon, restarts under
/// its supervisor, and polls each account it can see on its own cadence. The
/// daemon passes the core's feed; Zed is read here regardless.
pub fn start(
  home: String,
  database: store.Store,
  fetch: Fetch,
  sources: List(#(String, usage_feed.Source)),
  keys: KeyEnvironment,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  start_with(
    home,
    database,
    fn(provider, credential, now) {
      feed(provider, credential, now, zed_quota.fetch, fetch)
    },
    sources,
    keys,
    load_settings,
    120_000,
  )
}

/// Dependency-injected poller for isolated lifecycle tests.
pub fn start_with(
  home: String,
  database: store.Store,
  fetch: Fetch,
  sources: List(#(String, usage_feed.Source)),
  keys: KeyEnvironment,
  settings: fn() -> Settings,
  worker_timeout_ms: Int,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(30_000, fn(self) {
    albedo_process.label("albedo_quota", home)
    let timer = albedo_clock.send_after(self, 0, Tick(0))
    Ok(
      actor.initialised(State(
        home,
        database,
        fetch,
        sources,
        settings,
        worker_timeout_ms,
        schedule.new(),
        dict.new(),
        dict.new(),
        self,
        Some(timer),
        0,
        None,
        keys,
      ))
      |> actor.returning(self)
      |> actor.selecting(
        process.new_selector()
        |> process.select(self)
        |> process.select_monitors(Down),
      ),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// Runs the schedule's step for each message and starts what it asks for.
/// Answers from a worker the poller no longer owns, as after a timeout, are
/// dropped.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let settings = state.settings()
  let now = albedo_clock.system_ms()
  case message {
    Tick(generation) if generation != state.generation -> actor.continue(state)
    Tick(_) -> {
      let #(next, effects) = schedule.tick(state.schedule, settings, now)
      let state = State(..state, schedule: next, timer: None)
      let state = case settings.enabled {
        False -> State(..state, watched: dict.new())
        True -> state
      }
      list.fold(effects, state, fn(state, effect) {
        run_effect(state, effect, now, settings)
      })
      |> retick(settings)
    }
    WorkerTimedOut(pid) ->
      case owns_worker(state, pid) {
        False -> actor.continue(state)
        True -> {
          process.kill(pid)
          fell(state, pid, "quota worker timed out", now, settings)
          |> retick(settings)
        }
      }
    Enumerated(pid, _) if state.enumerating != Some(pid) -> actor.continue(state)
    Enumerated(_, targets) -> {
      let listed =
        list.map(targets, fn(watched) { #(key_of(watched.target), watched) })
      let next =
        schedule.enumerated(
          state.schedule,
          list.map(listed, fn(entry) { entry.0 }),
          now,
        )
      // A gone account still polling keeps what it polls until it finishes.
      let fresh = dict.from_list(listed)
      let kept =
        dict.filter(state.watched, fn(key, _) {
          dict.has_key(next.slots, key) && !dict.has_key(fresh, key)
        })
      let watched = dict.merge(kept, fresh)
      State(..state, schedule: next, watched:, enumerating: None)
      |> retick(settings)
    }
    Polled(key, pid, failed, busy, attempted_at) ->
      case dict.get(state.polls, pid) {
        Ok(polling) if polling == key ->
          finished(state, key, failed, busy, attempted_at, settings)
          |> retick(settings)
        _ -> actor.continue(state)
      }
    Down(process.ProcessDown(_, pid, _)) ->
      case owns_worker(state, pid) {
        False -> actor.continue(state)
        True ->
          fell(
            state,
            pid,
            "quota worker exited before reporting",
            now,
            settings,
          )
          |> retick(settings)
      }
    // The poller monitors processes only; a port is never one of them.
    Down(process.PortDown(_, _, _)) -> actor.continue(state)
  }
}

fn finished(
  state: State,
  key: String,
  failed: Bool,
  busy: Bool,
  attempted_at: Int,
  settings: Settings,
) -> State {
  let next =
    schedule.polled(state.schedule, key, failed, busy, attempted_at, settings)
  State(
    ..state,
    schedule: next,
    polls: dict.filter(state.polls, fn(_, polling) { polling != key }),
    watched: case dict.has_key(next.slots, key) {
      True -> state.watched
      False -> dict.delete(state.watched, key)
    },
  )
}

fn owns_worker(state: State, pid: process.Pid) -> Bool {
  state.enumerating == Some(pid) || dict.has_key(state.polls, pid)
}

/// A worker that crashed or timed out never answers: free its slot, record
/// why for a poll, and back the account off, so a crashing or hanging feed
/// cannot wedge the schedule.
fn fell(
  state: State,
  pid: process.Pid,
  message: String,
  now: Int,
  settings: Settings,
) -> State {
  case state.enumerating, dict.get(state.polls, pid) {
    Some(enumerating), _ if enumerating == pid -> {
      io.println_error("quota account discovery failed: " <> message)
      State(
        ..state,
        schedule: schedule.enumeration_ended(state.schedule),
        enumerating: None,
      )
    }
    _, Ok(key) -> {
      case dict.get(state.watched, key) {
        Ok(watched) -> {
          let _ =
            record(state.database, watched.target, None, [], Some(message), now)
          Nil
        }
        Error(Nil) -> Nil
      }
      finished(state, key, True, False, now, settings)
    }
    _, Error(Nil) -> state
  }
}

/// Account discovery and each poll run off the poller: a refresh may wait on
/// the network. Each worker has a deadline after which it is killed.
fn run_effect(
  state: State,
  effect: schedule.Effect,
  now: Int,
  settings: Settings,
) -> State {
  let self = state.self
  case effect {
    schedule.Enumerate -> {
      let home = state.home
      let sources = state.sources
      let keys = state.keys
      let pid =
        process.spawn_unlinked(fn() {
          process.send(
            self,
            Enumerated(process.self(), enumerate(home, sources, keys)),
          )
        })
      let _ = process.monitor(pid)
      let _ =
        albedo_clock.send_after(
          self,
          state.worker_timeout_ms * 5 / 2,
          WorkerTimedOut(pid),
        )
      State(..state, enumerating: Some(pid))
    }
    schedule.Poll(key) ->
      case dict.get(state.watched, key) {
        Error(Nil) -> finished(state, key, True, False, now, settings)
        Ok(watched) -> {
          let fetch = state.fetch
          let database = state.database
          let home = state.home
          let pid =
            process.spawn_unlinked(fn() {
              let #(failed, busy) = run(fetch, database, watched, home)
              process.send(self, Polled(key, process.self(), failed, busy, now))
            })
          let _ = process.monitor(pid)
          let _ =
            albedo_clock.send_after(
              self,
              state.worker_timeout_ms,
              WorkerTimedOut(pid),
            )
          State(..state, polls: dict.insert(state.polls, pid, key))
        }
      }
  }
}

/// Replace the timer as deadlines change; generations ignore already-delivered
/// ticks.
fn retick(state: State, settings: Settings) -> actor.Next(State, Message) {
  let _ = option.map(state.timer, process.cancel_timer)
  let generation = state.generation + 1
  let delay =
    next_delay(
      settings,
      albedo_clock.system_ms(),
      state.schedule.last_enumerated,
      state.schedule.enumerating,
      list.map(dict.values(state.schedule.slots), fn(slot) {
        #(slot.next_due, slot.polling)
      }),
    )
  let timer = albedo_clock.send_after(state.self, delay, Tick(generation))
  actor.continue(State(..state, timer: Some(timer), generation: generation))
}

/// In-flight work has its own deadline, not an overdue idle-poll deadline:
/// the soonest idle account or due discovery, at least 250 and at most the
/// ordinary cadence.
pub fn next_delay(
  config: Settings,
  now: Int,
  last_enumerated: Int,
  enumerating: Bool,
  accounts: List(#(Int, Bool)),
) -> Int {
  case config.enabled {
    False -> config.poll_seconds * 1000
    True -> {
      let idle =
        list.filter_map(accounts, fn(account) {
          case account.1 {
            True -> Error(Nil)
            False -> Ok(account.0)
          }
        })
      let due = case enumerating {
        True -> idle
        False -> [last_enumerated + config.poll_seconds * 1000, ..idle]
      }
      let delay = case list.reduce(due, int.min) {
        Error(Nil) -> config.poll_seconds * 1000
        Ok(when) -> when - now
      }
      int.clamp(delay, 250, config.poll_seconds * 1000)
    }
  }
}

/// Seconds until an account's next poll; see `quota_schedule.wait_seconds`.
pub fn wait_seconds(settings: Settings, failures: Int, busy: Bool) -> Int {
  schedule.wait_seconds(settings, failures, busy)
}

/// One poll of one account, off the poller: whatever comes back is recorded
/// exactly as it came, then the account's source heals from the report, and
/// the schedule hears whether it failed and whether the account is busy.
fn run(
  fetch: Fetch,
  database: store.Store,
  watched: Watched,
  home: String,
) -> #(Bool, Bool) {
  let target = watched.target
  let now = albedo_clock.system_ms()
  let fetched =
    albedo_protect.attempt(fn() {
      network_context.routed(watched.service, fn() {
        fetch(target.provider, target.credential, now)
      })
    })
    |> result.unwrap(Error("quota feed worker crashed"))
  case fetched {
    Ok(report) -> {
      record(database, target, report.plan, report.limits, report.error, now)
      watched.heal(home, target.label, report.limits)
      #(report.error != None, is_busy(report, now))
    }
    Error(message) -> {
      record(database, target, None, [], Some(message), now)
      #(True, False)
    }
  }
}

fn is_busy(report: Report, now: Int) -> Bool {
  list.any(report.limits, fn(limit) {
    case limit.used_percent {
      Some(used) if used >=. 80.0 -> True
      _ ->
        case limit.resets_at {
          Some(resets_at) ->
            resets_at > now && resets_at - now <= 15 * 60 * 1000
          None -> False
        }
    }
  })
}

// ---- the readings -------------------------------------------------------

/// One stored reading, exactly as the feed reported it.
pub type Sample {
  Sample(
    id: Int,
    /// The account's non-secret label.
    account: String,
    provider: String,
    /// The report plan: what 100 percent means can change with it.
    plan: Option(String),
    limit_id: String,
    label: String,
    used_percent: Option(Float),
    window_label: Option(String),
    window_seconds: Option(Int),
    resets_at: Option(Int),
    scope: Option(String),
    status: String,
    error: Option(String),
    observed_at: Int,
    source: String,
  )
}

const schema =
  "
CREATE TABLE IF NOT EXISTS quota_sample (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 account TEXT NOT NULL,
 provider TEXT NOT NULL,
 plan TEXT,
 limit_id TEXT NOT NULL DEFAULT '',
 label TEXT NOT NULL DEFAULT '',
 used_percent REAL,
 window_label TEXT,
 window_seconds INTEGER,
 resets_at INTEGER,
 scope TEXT,
 status TEXT NOT NULL DEFAULT '',
 error TEXT,
 observed_at INTEGER NOT NULL,
 source TEXT NOT NULL DEFAULT 'poll'
);
CREATE INDEX IF NOT EXISTS quota_sample_latest
 ON quota_sample(account, provider, limit_id, id);
CREATE INDEX IF NOT EXISTS quota_sample_report
 ON quota_sample(account, provider, id);
"

/// The table, before any session or poller starts.
pub fn initialise(database: store.Store) -> Result(Nil, String) {
  store.query(database, fn(db) {
    store.transaction(db, fn() { store.exec(db, schema) })
  })
}

/// Only readings: one row per limit the report carried, or one row carrying
/// the report's error when it carried none.
pub fn record(
  database: store.Store,
  target: Target,
  plan: Option(String),
  limits: List(Limit),
  error: Option(String),
  now: Int,
) -> Nil {
  let rows = case limits {
    [] -> [
      Row(
        target.label,
        target.provider,
        plan,
        "",
        "",
        None,
        None,
        None,
        None,
        None,
        "",
        error,
        now,
      ),
    ]
    _ ->
      list.map(limits, fn(limit) {
        Row(
          target.label,
          target.provider,
          plan,
          limit.id,
          limit.label,
          limit.used_percent,
          limit.window_label,
          limit.window_seconds,
          limit.resets_at,
          limit.scope,
          limit.status,
          error,
          now,
        )
      })
  }
  let outcome =
    store.query(database, fn(db) {
      list.try_each(rows, fn(row) { insert(db, row) })
    })
  case outcome {
    Ok(_) -> Nil
    Error(message) -> io.println_error("quota sample write failed: " <> message)
  }
}

type Row {
  Row(
    account: String,
    provider: String,
    plan: Option(String),
    limit_id: String,
    label: String,
    used_percent: Option(Float),
    window_label: Option(String),
    window_seconds: Option(Int),
    resets_at: Option(Int),
    scope: Option(String),
    status: String,
    error: Option(String),
    observed_at: Int,
  )
}

fn insert(db: sqlight.Connection, row: Row) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO quota_sample(account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source)
     VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'poll')",
    [
      sqlight.text(row.account),
      sqlight.text(row.provider),
      sqlight.nullable(sqlight.text, row.plan),
      sqlight.text(row.limit_id),
      sqlight.text(row.label),
      sqlight.nullable(sqlight.float, row.used_percent),
      sqlight.nullable(sqlight.text, row.window_label),
      sqlight.nullable(sqlight.int, row.window_seconds),
      sqlight.nullable(sqlight.int, row.resets_at),
      sqlight.nullable(sqlight.text, row.scope),
      sqlight.text(row.status),
      sqlight.nullable(sqlight.text, row.error),
      sqlight.int(row.observed_at),
    ],
  )
}

const sample_columns =
  "id, account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source"

fn sample_decoder() -> decode.Decoder(Sample) {
  use id <- decode.field(0, decode.int)
  use account <- decode.field(1, decode.string)
  use provider <- decode.field(2, decode.string)
  use plan <- decode.field(3, decode.optional(decode.string))
  use limit_id <- decode.field(4, decode.string)
  use label <- decode.field(5, decode.string)
  use used_percent <- decode.field(6, decode.optional(decode.float))
  use window_label <- decode.field(7, decode.optional(decode.string))
  use window_seconds <- decode.field(8, decode.optional(decode.int))
  use resets_at <- decode.field(9, decode.optional(decode.int))
  use scope <- decode.field(10, decode.optional(decode.string))
  use status <- decode.field(11, decode.string)
  use error <- decode.field(12, decode.optional(decode.string))
  use observed_at <- decode.field(13, decode.int)
  use source <- decode.field(14, decode.string)
  decode.success(Sample(
    id,
    account,
    provider,
    plan,
    limit_id,
    label,
    used_percent,
    window_label,
    window_seconds,
    resets_at,
    scope,
    status,
    error,
    observed_at,
    source,
  ))
}

/// Only the newest complete report per account/provider is current. Failed polls
/// replace current windows too; historical readings remain available via history.
pub fn latest(database: store.Store) -> Result(List(Sample), String) {
  store.read(database, "SELECT " <> sample_columns <> " FROM quota_sample s
     WHERE s.observed_at = (SELECT t.observed_at FROM quota_sample t
                           WHERE t.account = s.account AND t.provider = s.provider
                           ORDER BY t.id DESC LIMIT 1)
       AND s.id = (SELECT MAX(r.id) FROM quota_sample r
                   WHERE r.account = s.account AND r.provider = s.provider
                     AND r.limit_id = s.limit_id)
     ORDER BY s.account, s.provider, s.limit_id", [], sample_decoder())
}

pub type Filter {
  Everything
  Trail(provider: String, account: String, limit: String, since: Option(Int))
}

@external(erlang, "calendar", "rfc3339_to_system_time")
fn erlang_rfc3339_to_system_time(
  stamp: String,
  options: List(#(atom.Atom, atom.Atom)),
) -> Int

/// The history filter a request's parameters name: every reading, or one
/// account's limit when provider, account and limit all are given, from
/// `quota_since` when that is given too. Anything else is refused.
pub fn filter_from(
  parameters: List(#(String, String)),
) -> Result(Filter, String) {
  case
    list.key_find(parameters, "quota_provider"),
    list.key_find(parameters, "quota_account"),
    list.key_find(parameters, "quota_limit"),
    list.key_find(parameters, "quota_since")
  {
    Ok(provider), Ok(account), Ok(limit_id), Ok(since) ->
      case parse_rfc3339(since) {
        Ok(since_ms) -> Ok(Trail(provider, account, limit_id, Some(since_ms)))
        Error(_) -> Error("invalid quota_since")
      }
    Ok(provider), Ok(account), Ok(limit_id), Error(_) ->
      Ok(Trail(provider, account, limit_id, None))
    Error(_), Error(_), Error(_), Error(_) -> Ok(Everything)
    Error(_), Error(_), Error(_), Ok(_) ->
      Error(
        "quota_since requires quota_provider, quota_account, and quota_limit",
      )
    _, _, _, _ ->
      Error(
        "quota_provider, quota_account, and quota_limit must all be provided together",
      )
  }
}

pub fn parse_rfc3339(stamp: String) -> Result(Int, Nil) {
  let opts = [#(atom.create("unit"), atom.create("millisecond"))]
  case
    albedo_protect.attempt(fn() { erlang_rfc3339_to_system_time(stamp, opts) })
  {
    Ok(ms) -> Ok(ms)
    Error(_) -> Error(Nil)
  }
}

/// Readings newest-first with id keyset paging: `before` 0 starts at the
/// newest, any other value continues after that row id.
pub fn history(
  database: store.Store,
  filter: Filter,
  before: Int,
  limit: Int,
) -> Result(List(Sample), String) {
  case filter {
    Everything ->
      case before <= 0 {
        True ->
          store.read(
            database,
            "SELECT "
              <> sample_columns
              <> " FROM quota_sample ORDER BY id DESC LIMIT ?",
            [sqlight.int(limit)],
            sample_decoder(),
          )
        False ->
          store.read(
            database,
            "SELECT "
              <> sample_columns
              <> " FROM quota_sample WHERE id < ? ORDER BY id DESC LIMIT ?",
            [sqlight.int(before), sqlight.int(limit)],
            sample_decoder(),
          )
      }
    Trail(provider, account, limit_id, since) ->
      case since {
        None ->
          case before <= 0 {
            True ->
              store.read(
                database,
                "SELECT "
                  <> sample_columns
                  <> " FROM quota_sample WHERE account = ? AND provider = ? AND limit_id = ? ORDER BY id DESC LIMIT ?",
                [
                  sqlight.text(account),
                  sqlight.text(provider),
                  sqlight.text(limit_id),
                  sqlight.int(limit),
                ],
                sample_decoder(),
              )
            False ->
              store.read(
                database,
                "SELECT "
                  <> sample_columns
                  <> " FROM quota_sample WHERE account = ? AND provider = ? AND limit_id = ? AND id < ? ORDER BY id DESC LIMIT ?",
                [
                  sqlight.text(account),
                  sqlight.text(provider),
                  sqlight.text(limit_id),
                  sqlight.int(before),
                  sqlight.int(limit),
                ],
                sample_decoder(),
              )
          }
        Some(since_ms) ->
          case before <= 0 {
            True ->
              store.read(
                database,
                "SELECT "
                  <> sample_columns
                  <> " FROM quota_sample WHERE account = ? AND provider = ? AND limit_id = ? AND observed_at >= ? ORDER BY id DESC LIMIT ?",
                [
                  sqlight.text(account),
                  sqlight.text(provider),
                  sqlight.text(limit_id),
                  sqlight.int(since_ms),
                  sqlight.int(limit),
                ],
                sample_decoder(),
              )
            False ->
              store.read(
                database,
                "SELECT "
                  <> sample_columns
                  <> " FROM quota_sample WHERE account = ? AND provider = ? AND limit_id = ? AND observed_at >= ? AND id < ? ORDER BY id DESC LIMIT ?",
                [
                  sqlight.text(account),
                  sqlight.text(provider),
                  sqlight.text(limit_id),
                  sqlight.int(since_ms),
                  sqlight.int(before),
                  sqlight.int(limit),
                ],
                sample_decoder(),
              )
          }
      }
  }
}

fn key_of(target: Target) -> String {
  target.provider <> "/" <> target.label
}
