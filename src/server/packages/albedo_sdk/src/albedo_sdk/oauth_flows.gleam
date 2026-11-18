//// The provider sign-in service. The host creates one `Service`, starts it,
//// and passes it to whatever starts, reads, answers, or cancels a sign-in.
//// Nothing finds the service by name.
////
//// One owner process serializes admission, input, cancellation, and
//// completion. Each sign-in runs in a flow process that owns its loopback
//// callback listener and asks the owner to store its credential. The owner
//// keeps durable records in `oauth-logins.json` under the settings lock:
//// only a keyed digest of the submitted intent and safe flow metadata,
//// never submitted values. A restart keeps the records but not the flows.

import albedo_bytes/digest
import albedo_bytes/ids
import albedo_clock
import albedo_file
import albedo_json
import albedo_oauth/listener
import albedo_protect
import albedo_sdk/auth_accounts
import albedo_sdk/credential_store
import albedo_sdk/http_api
import albedo_sdk/network
import albedo_sdk/network_context
import albedo_sdk/oauth.{type Account, type Keep, type Login}
import albedo_sdk/settings_store
import albedo_web/etag
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri

/// How long a sign-in waits for the browser or a pasted code.
const flow_timeout_ms = 300_000

/// What the browser shows when a sign-in's redirect reaches the listener.
const pages =
  listener.Pages(
    title: "albedo",
    completed: "Authentication completed. You can close this window and return to albedo.",
    failed: "Authentication failed. Return to albedo for details.",
  )

/// How long a caller waits for the owner, which may be queued behind
/// durable writes on a slow disk.
const call_ms = 60_000

/// How long a finished sign-in stays readable.
const retain_ms = 900_000

/// How long the owner waits for a new flow to publish its url.
const start_ms = 10_000

/// The most sign-ins that may be active at once.
const capacity = 8

/// A failure as `#(HTTP status, code, detail)`.
pub type Failure =
  #(Int, String, String)

/// The handle to one running sign-in service.
pub opaque type Service {
  Service(owner: Subject(Message))
}

/// Start a sign-in service, linked to the caller. The host starts one and
/// passes the handle to its consumers. Every request is guarded, so the
/// owner does not crash on a failed request or unreadable storage.
pub fn start() -> Result(Service, actor.StartError) {
  actor.new_with_initialiser(5000, fn(owner) {
    let selector =
      process.new_selector()
      |> process.select(owner)
      |> process.select_monitors(Stopped)
      |> process.select_other(fn(_) { Ignored })
    actor.initialised(Owner(owner, dict.new()))
    |> actor.selecting(selector)
    |> actor.returning(Service(owner))
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Start sign-in `id` for `provider`, or return the one already started for
/// the same intent. `login` is the provider's declaration, `None` when no
/// extension names it. `keep` stores the credential when the login's resolver
/// supplies one. `first_profile` names the model and protocol of the
/// profile a model sign-in creates when no profile uses its extension (see
/// `auth_accounts.joined`); the flow asks it outside the settings lock, and
/// only then. Returns whether it was created, and its JSON.
pub fn start_identified(
  service: Service,
  home: String,
  id: String,
  provider: String,
  login: Option(Login),
  keep: Option(Keep),
  intent: String,
  first_profile: FirstProfile,
) -> Result(#(Bool, String), Failure) {
  call(service, Create(
    home,
    id,
    provider,
    login,
    keep,
    intent,
    first_profile,
    _,
  ))
}

/// The model and protocol a first profile of a sign-in's extension starts
/// with, `None` when there is none to offer.
pub type FirstProfile =
  fn() -> Option(#(String, String))

/// How a completed sign-in joins its service's profiles: not at all (a
/// service sign-in, or one a resolver keeps), or as a model sign-in with the
/// first profile to create when no profile uses the extension.
type Join {
  NoJoin
  Joins(first: Option(#(String, String)))
}

/// Read sign-in `id` as JSON, describing its accounts through `logins`.
pub fn get_identified(
  service: Service,
  home: String,
  id: String,
  logins: List(Login),
) -> Result(String, Failure) {
  call(service, Read(home, id, logins, _))
}

/// Submit a pasted code or callback URL to sign-in `id`. `match` is the
/// flow ETag precondition. Returns the accepted flow's JSON, or a failure
/// for stale input.
pub fn input_identified(
  service: Service,
  home: String,
  id: String,
  match: String,
  text: String,
  logins: List(Login),
) -> Result(String, Failure) {
  call(service, Input(home, id, match, text, logins, _))
}

/// Show `identity` and wait until the person types `confirm`, before a
/// `Device` sign-in returns its credential. Call it from the sign-in's own
/// completion: nothing is stored unless it returns `Ok`, and a cancelled or
/// expired sign-in never confirms.
pub fn confirm(identity: String) -> Result(Nil, String) {
  case flow_context() {
    None -> Error("Confirmation requires a sign-in flow")
    Some(FlowContext(owner:, direct:, id:)) -> {
      let monitor = process.monitor(owner)
      let reply = process.new_subject()
      process.send(direct, Confirming(id, process.self(), identity, reply))
      let answer =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(call_ms)
      process.demonitor_process(monitor)
      case answer {
        Ok(Ok(remaining)) -> {
          // Input accepted while the sign-in was still waiting reached this
          // process before the reply, so it is dropped: only input sent to
          // the confirming state confirms.
          drain_input()
          await_confirmation(remaining)
        }
        Ok(Error(Nil)) -> Error("Sign-in ended")
        Error(Nil) -> Error("Confirmation unavailable")
      }
    }
  }
}

fn drain_input() -> Nil {
  case
    process.new_selector()
    |> oauth.select_input(fn(_) { Nil })
    |> process.selector_receive(0)
  {
    Ok(Nil) -> drain_input()
    Error(Nil) -> Nil
  }
}

/// Wait at most `remaining` ms, the time the sign-in has left.
fn await_confirmation(remaining: Int) -> Result(Nil, String) {
  case
    process.new_selector()
    |> oauth.select_input(fn(text) { text })
    |> process.selector_receive(int.max(remaining, 0))
  {
    Ok("confirm") -> Ok(Nil)
    Ok(_) -> await_confirmation(remaining)
    Error(Nil) -> Error("Confirmation expired")
  }
}

/// The sign-in a `Device` completion runs for, kept in its process.
type FlowContext {
  FlowContext(owner: Pid, direct: Subject(Message), id: String)
}

fn flow_context() -> Option(FlowContext) {
  let context = get_flow(flow_key())
  case context == atom.to_dynamic(atom.create("undefined")) {
    True -> None
    False -> Some(coerce(context))
  }
}

fn flow_key() -> Atom {
  atom.create("albedo_oauth_flow")
}

@external(erlang, "erlang", "get")
fn get_flow(key: Atom) -> Dynamic

@external(erlang, "erlang", "put")
fn put_flow(key: Atom, context: FlowContext) -> Dynamic

@external(erlang, "gleam_stdlib", "identity")
fn coerce(value: a) -> b

/// Cancel sign-in `id` and return its JSON.
pub fn cancel_identified(
  service: Service,
  home: String,
  id: String,
  logins: List(Login),
) -> Result(String, Failure) {
  call(service, Cancel(home, id, logins, _))
}

pub opaque type Message {
  Create(
    home: String,
    id: String,
    provider: String,
    login: Option(Login),
    keep: Option(Keep),
    intent: String,
    first_profile: FirstProfile,
    reply: Subject(Result(#(Bool, String), Failure)),
  )
  Read(
    home: String,
    id: String,
    logins: List(Login),
    reply: Subject(Result(String, Failure)),
  )
  Input(
    home: String,
    id: String,
    match: String,
    text: String,
    logins: List(Login),
    reply: Subject(Result(String, Failure)),
  )
  Cancel(
    home: String,
    id: String,
    logins: List(Login),
    reply: Subject(Result(String, Failure)),
  )
  /// A flow's credential, to commit with its completion.
  Store(
    id: String,
    home: String,
    store: String,
    credential: Dict(String, Dynamic),
    account: fn(Dynamic) -> Account,
    keep: Option(Keep),
    join: Join,
    reply: Subject(Result(String, Failure)),
  )
  /// A flow's terminal outcome. The flow waits for the reply, so a read
  /// never mistakes mailbox delay for a sign-in that stopped.
  Settled(id: String, status: Status, reply: Subject(Nil))
  Progressed(id: String, status: Status)
  /// A flow's identity to confirm before its credential is kept.
  Confirming(
    id: String,
    flow: Pid,
    identity: String,
    reply: Subject(Result(Int, Nil)),
  )
  Forget(id: String)
  Stopped(process.Down)
  Ignored
}

/// What a flow reports about itself.
type Status {
  Waiting(String)
  Exchanging(String)
  Done(String)
  Failed(String)
}

/// How a new flow started, sent once to the owner.
type Started {
  /// The url to open, with the instructions a device flow shows.
  Ready(url: String, instructions: Option(String))
  /// The provider refused to authorize this attempt.
  Refused(String)
  StartFailed(String)
}

type Owner {
  Owner(direct: Subject(Message), flows: Dict(String, Active))
}

type Active {
  /// `confirmed` once the person typed `confirm` for a confirming record.
  Active(home: String, pid: Pid, record: Record, confirmed: Bool)
}

/// A sign-in's durable record in `oauth-logins.json`.
type Record {
  Record(
    id: String,
    provider: String,
    intent: String,
    url: Option(String),
    state: String,
    progress: String,
    instructions: String,
    expires: Int,
    account_ids: List(String),
    failure: Option(String),
    terminal_at: Option(Int),
    retain_until: Option(Int),
    /// Set while an identity awaits confirmation; it changes the ETag.
    confirmation: Option(String),
  )
}

// ---- callers ---------------------------------------------------------------

fn call(
  service: Service,
  message: fn(Subject(Result(a, Failure))) -> Message,
) -> Result(a, Failure) {
  let outcome = case process.subject_owner(service.owner) {
    Error(Nil) -> Error("sign-in service stopped")
    Ok(owner) -> {
      let reply = process.new_subject()
      // The owner serializes durable writes, so on a slow disk a request may
      // queue behind them. The bound only keeps a stuck owner from hanging it.
      let monitor = process.monitor(owner)
      process.send(service.owner, message(reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) {
          Error("sign-in service stopped")
        })
        |> process.selector_receive(call_ms)
      process.demonitor_process(monitor)
      case answer {
        Ok(answer) -> answer
        Error(Nil) -> Error("it did not answer within 60 s")
      }
    }
  }
  case outcome {
    Ok(result) -> result
    Error(reason) ->
      Error(#(
        503,
        "auth_unavailable",
        "Provider sign-in service is unavailable: " <> reason,
      ))
  }
}

// ---- owner -----------------------------------------------------------------

fn handle(owner: Owner, message: Message) -> actor.Next(Owner, Message) {
  let flows = case message {
    Create(home, id, provider, login, keep, intent, first_profile, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() {
          create(owner, home, id, provider, login, keep, intent, first_profile)
        })
      process.send(reply, answer)
      flows
    }
    Read(home, id, logins, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() {
          use #(record, current) <- result.try(identified(owner, home, id))
          use encoded <- result.map(encode_login(home, record, logins))
          #(encoded, current)
        })
      process.send(reply, answer)
      flows
    }
    Input(home, id, match, text, logins, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() { input(owner, home, id, match, text, logins) })
      process.send(reply, answer)
      flows
    }
    Cancel(home, id, logins, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() { cancel(owner, home, id, logins) })
      process.send(reply, answer)
      flows
    }
    Store(id, home, store, credential, account, keep, join, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() {
          store_credential(
            owner,
            id,
            home,
            store,
            credential,
            account,
            keep,
            join,
          )
        })
      process.send(reply, answer)
      flows
    }
    Settled(id, status, reply) -> {
      let flows = update(owner, id, status)
      process.send(reply, Nil)
      flows
    }
    Progressed(id, status) -> update(owner, id, status)
    Confirming(id, flow, identity, reply) -> {
      let #(answer, flows) =
        guard(owner.flows, fn() { confirming(owner, id, flow, identity) })
      process.send(reply, result.replace_error(answer, Nil))
      flows
    }
    Forget(id) -> dict.delete(owner.flows, id)
    Stopped(process.ProcessDown(pid:, ..)) -> stopped(owner, pid)
    Stopped(process.PortDown(..)) | Ignored -> owner.flows
  }
  actor.continue(Owner(..owner, flows:))
}

/// Run one request. A failure, or a crash in the storage it touches, leaves
/// the flows as they were.
fn guard(
  flows: Dict(String, Active),
  run: fn() -> Result(#(a, Dict(String, Active)), Failure),
) -> #(Result(a, Failure), Dict(String, Active)) {
  case albedo_protect.attempt(run) {
    Ok(Ok(#(answer, next))) -> #(Ok(answer), next)
    Ok(Error(failure)) -> #(Error(failure), flows)
    Error(_) -> #(Error(storage_unavailable), flows)
  }
}

const storage_unavailable = #(
  503,
  "auth_unavailable",
  "Provider sign-in storage is unavailable.",
)

fn ensure(
  condition: Bool,
  failure: Failure,
  next: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  case condition {
    True -> next()
    False -> Error(failure)
  }
}

/// A flow's next record after `status`. A terminal record never changes.
fn update(owner: Owner, id: String, status: Status) -> Dict(String, Active) {
  case dict.get(owner.flows, id) {
    Ok(Active(home:, pid:, record:, ..) as active) -> {
      let next = case status {
        // Completion and credential publish share one commit.
        Done(_) -> record
        Failed(reason) -> {
          log_failure(record, reason)
          failed_record(owner, record, "Provider authorization failed.")
        }
        Waiting(text) ->
          Record(..record, state: "waiting", progress: bounded(text, 4096))
        Exchanging(text) ->
          Record(..record, state: "exchanging", progress: bounded(text, 4096))
      }
      case terminal(record) {
        True -> owner.flows
        False ->
          case persisted(home, id, next) {
            Ok(stored) ->
              dict.insert(owner.flows, id, Active(..active, record: stored))
            Error(Nil) -> {
              process.kill(pid)
              owner.flows
            }
          }
      }
    }
    Error(Nil) -> owner.flows
  }
}

/// Publish the identity a live flow asks the person to confirm, and answer
/// the time its sign-in has left.
fn confirming(
  owner: Owner,
  id: String,
  flow: Pid,
  identity: String,
) -> Result(#(Int, Dict(String, Active)), Failure) {
  use active <- result.try(case dict.get(owner.flows, id) {
    Ok(active) if active.pid == flow -> Ok(active)
    _ -> Error(login_ended)
  })
  use <- ensure(
    !terminal(active.record) && active.record.expires > albedo_clock.system_ms(),
    login_ended,
  )
  let next =
    Record(
      ..active.record,
      state: "confirming",
      progress: bounded(identity, 1024),
      instructions: "Verify this is your Zed account. Type confirm to save it, or cancel. Nothing is saved before confirmation.",
      confirmation: Some(ids.random_hex(16)),
    )
  use stored <- result.map(
    persisted(active.home, id, next)
    |> result.replace_error(storage_unavailable),
  )
  #(
    stored.expires - albedo_clock.system_ms(),
    dict.insert(owner.flows, id, Active(..active, record: stored)),
  )
}

const login_ended = #(409, "login_ended", "Provider sign-in has ended.")

fn stopped(owner: Owner, pid: Pid) -> Dict(String, Active) {
  dict.map_values(owner.flows, fn(id, active) {
    case active.pid == pid && !terminal(active.record) {
      False -> active
      True -> {
        let next =
          failed_record(owner, active.record, "Provider sign-in stopped.")
        case persisted(active.home, id, next) {
          Ok(stored) -> Active(..active, record: stored)
          Error(Nil) -> active
        }
      }
    }
  })
}

type Admission {
  Existing
  New(record: Record, login: Login)
}

fn create(
  owner: Owner,
  home: String,
  id: String,
  provider: String,
  login: Option(Login),
  keep: Option(Keep),
  intent: String,
  first_profile: FirstProfile,
) -> Result(#(#(Bool, String), Dict(String, Active)), Failure) {
  use admission <- result.try(
    locked(home, fn() {
      use all <- result.try(records(home))
      use current <- result.try(prune(all))
      use digest <- result.try(intent_digest(home, intent))
      case dict.get(current, id) {
        Ok(stored) -> {
          use stored <- result.try(decode_record(stored))
          use <- ensure(stored.intent == digest, #(
            409,
            "id_conflict",
            "Login identity has another intent.",
          ))
          Ok(Existing)
        }
        Error(Nil) -> {
          use <- fresh_identity(id)
          use <- ensure(!dict.has_key(all, id), identity_expired)
          use active <- result.try(active_count(current))
          use <- ensure(active < capacity, #(
            429,
            "login_capacity",
            "Too many provider sign-ins are active.",
          ))
          let unknown = #(400, "provider_unknown", "Unknown sign-in provider.")
          use login <- result.try(option.to_result(login, unknown))
          use <- ensure(login.provider == provider, unknown)
          let record =
            Record(
              id:,
              provider:,
              intent: digest,
              url: None,
              state: "waiting",
              progress: "Waiting for authorization.",
              instructions: "Paste the callback URL if the browser cannot reach the daemon.",
              expires: albedo_clock.system_ms() + flow_timeout_ms,
              account_ids: [],
              failure: None,
              terminal_at: None,
              retain_until: None,
              confirmation: None,
            )
          write_records(home, dict.insert(current, id, encode_record(record)))
          Ok(New(record, login))
        }
      }
    }),
  )
  case admission {
    Existing -> {
      let logins = option.map(login, fn(login) { [login] }) |> option.unwrap([])
      use #(record, flows) <- result.try(identified(owner, home, id))
      use encoded <- result.map(encode_login(home, record, logins))
      #(#(False, encoded), flows)
    }
    New(record, login) -> {
      let owner_pid = process.self()
      let ready = process.new_subject()
      let save = fn(store, credential, account) {
        let join = case login.kind, keep {
          oauth.Model, None ->
            Joins(case profile_uses(home, login.provider) {
              True -> None
              False -> first_profile()
            })
          _, _ -> NoJoin
        }
        store_with_owner(
          owner_pid,
          owner.direct,
          id,
          home,
          store,
          credential,
          account,
          keep,
          join,
        )
      }
      let pid =
        process.spawn_unlinked(fn() {
          let service = case provider {
            "mcp:" <> _ -> network.Mcp
            name -> network.Extension(name)
          }
          case network.resolve(service) {
            Ok(route) ->
              network_context.with_route(route, fn() {
                run_flow(owner_pid, owner.direct, id, login, save, ready)
              })
            Error(reason) -> {
              process.send(ready, StartFailed(reason))
              report(owner_pid, owner.direct, id, Failed(reason))
            }
          }
        })
      process.monitor(pid)
      let started = case process.receive(ready, start_ms) {
        Ok(Ready(url, instructions)) ->
          case string.byte_size(url) <= 4096 {
            True ->
              Record(..record, url: Some(url), instructions: case instructions {
                Some(text) -> bounded(text, 4096)
                None -> record.instructions
              })
            False -> {
              process.kill(pid)
              failed_record(
                owner,
                record,
                "Provider authorization URL is invalid.",
              )
            }
          }
        Ok(Refused(reason)) ->
          finish(
            owner,
            Record(
              ..record,
              state: "failed",
              failure: Some(bounded(reason, 4096)),
            ),
          )
        Ok(StartFailed(reason)) -> {
          let failure = case login.callback, reason {
            oauth.Device(..), reason if reason != "" -> bounded(reason, 4096)
            _, _ -> "Could not open the provider callback listener."
          }
          finish(
            owner,
            Record(..record, state: "failed", failure: Some(failure)),
          )
        }
        Error(Nil) -> {
          process.kill(pid)
          finish(
            owner,
            Record(
              ..record,
              state: "failed",
              failure: Some("Provider sign-in did not start."),
            ),
          )
        }
      }
      case persisted(home, id, started) {
        Error(Nil) -> {
          process.kill(pid)
          Error(storage_unavailable)
        }
        Ok(published) -> {
          let flows =
            dict.insert(owner.flows, id, Active(home, pid, published, False))
          use encoded <- result.map(encode_login(home, published, [login]))
          #(#(True, encoded), flows)
        }
      }
    }
  }
}

/// Sign-in `id`'s current record, settled against the live flow: one past
/// its deadline expires, one whose flow stopped fails, and one no flow
/// serves fails as interrupted by a restart. A finished sign-in leaves the
/// live set.
fn identified(
  owner: Owner,
  home: String,
  id: String,
) -> Result(#(Record, Dict(String, Active)), Failure) {
  use record <- result.map(
    locked(home, fn() {
      use all <- result.try(records(home))
      case dict.get(all, id) {
        Error(Nil) -> {
          use <- fresh_identity(id)
          Error(#(404, "login_unknown", "Unknown provider sign-in."))
        }
        Ok(stored) -> {
          use stored <- result.try(decode_record(stored))
          case terminal(stored) {
            True ->
              case stored.retain_until {
                Some(until) -> {
                  use <- ensure(
                    until > albedo_clock.system_ms(),
                    identity_expired,
                  )
                  Ok(stored)
                }
                None -> Error(storage_unavailable)
              }
            False -> {
              let next = case dict.get(owner.flows, id) {
                Ok(Active(home: active_home, pid:, ..)) if active_home == home ->
                  case stored.expires > albedo_clock.system_ms() {
                    False -> {
                      process.kill(pid)
                      finish(
                        owner,
                        Record(
                          ..stored,
                          state: "expired",
                          failure: Some("Provider sign-in expired."),
                          progress: "",
                        ),
                      )
                    }
                    True ->
                      case process.is_alive(pid) {
                        True -> stored
                        False ->
                          failed_record(
                            owner,
                            stored,
                            "Provider sign-in stopped.",
                          )
                      }
                  }
                _ ->
                  finish(
                    owner,
                    Record(
                      ..stored,
                      state: "failed",
                      failure: Some("daemon_restarted"),
                      progress: "",
                    ),
                  )
              }
              case next == stored {
                True -> Nil
                False ->
                  write_records(home, dict.insert(all, id, encode_record(next)))
              }
              Ok(next)
            }
          }
        }
      }
    }),
  )
  #(record, case terminal(record) {
    True -> dict.delete(owner.flows, id)
    False -> owner.flows
  })
}

fn input(
  owner: Owner,
  home: String,
  id: String,
  match: String,
  text: String,
  logins: List(Login),
) -> Result(#(String, Dict(String, Active)), Failure) {
  use #(record, current) <- result.try(identified(owner, home, id))
  use value <- result.try(encode_login(home, record, logins))
  use <- ensure(match != "", #(
    428,
    "precondition_required",
    "If-Match is required",
  ))
  use <- ensure(match == etag.strong(value), #(
    412,
    "precondition_failed",
    "login flow changed",
  ))
  let confirmation = record.state == "confirming"
  use <- ensure(record.state == "waiting" || confirmation, #(
    409,
    "login_not_waiting",
    "login flow is not waiting for input",
  ))
  use <- ensure(!confirmation || text == "confirm", #(
    400,
    "confirmation_required",
    "Type confirm to save this account",
  ))
  case dict.get(current, id), confirmation {
    Ok(active), False -> {
      oauth.send_input(active.pid, text)
      Ok(#(value, current))
    }
    Ok(active), True -> {
      use consumed <- result.try(persist(
        home,
        id,
        Record(..record, state: "exchanging"),
      ))
      oauth.send_input(active.pid, text)
      use encoded <- result.map(encode_login(home, consumed, logins))
      #(
        encoded,
        dict.insert(
          current,
          id,
          Active(..active, record: consumed, confirmed: True),
        ),
      )
    }
    Error(Nil), _ -> Error(storage_unavailable)
  }
}

fn cancel(
  owner: Owner,
  home: String,
  id: String,
  logins: List(Login),
) -> Result(#(String, Dict(String, Active)), Failure) {
  use #(record, current) <- result.try(identified(owner, home, id))
  case terminal(record) {
    True -> {
      use encoded <- result.map(encode_login(home, record, logins))
      #(encoded, current)
    }
    False -> {
      let cancelled =
        finish(
          owner,
          Record(..record, state: "cancelled", progress: "", failure: None),
        )
      use _ <- result.try(persist(home, id, cancelled))
      case dict.get(current, id) {
        Ok(active) -> process.kill(active.pid)
        Error(Nil) -> Nil
      }
      use encoded <- result.map(encode_login(home, cancelled, logins))
      #(encoded, dict.delete(current, id))
    }
  }
}

/// Commit a flow's credential with its completion, in one settings group.
fn store_credential(
  owner: Owner,
  id: String,
  home: String,
  store: String,
  credential: Dict(String, Dynamic),
  account: fn(Dynamic) -> Account,
  keep: Option(Keep),
  join: Join,
) -> Result(#(String, Dict(String, Active)), Failure) {
  use active <- result.try(case dict.get(owner.flows, id) {
    Ok(active) if active.home == home -> Ok(active)
    _ -> Error(storage_unavailable)
  })
  use completed <- result.map(
    locked(home, fn() {
      use records <- result.try(records(home))
      use stored <- result.try(
        dict.get(records, id) |> result.replace_error(storage_unavailable),
      )
      use flow <- result.try(decode_record(stored))
      use <- ensure(
        !terminal(flow) && flow.expires > albedo_clock.system_ms(),
        login_ended,
      )
      use <- ensure(option.is_none(flow.confirmation) || active.confirmed, #(
        409,
        "confirmation_required",
        "Account confirmation is required",
      ))
      let value = to_map(credential)
      let raw_id = account(value).id
      use <- ensure(raw_id != "", storage_unavailable)
      let creds = settings_store.read_dynamic(home, "creds.json")
      let #(public_id, next_creds) = case keep {
        Some(keep) -> #(store, keep(creds, value))
        None -> signed_in(creds, store, value, account, raw_id, flow.provider)
      }
      // A new account joins its service's profiles in the same commit; a
      // sign-in again keeps the account's id and place.
      let config = case join, known_account(creds, store, public_id) {
        Joins(first), False ->
          Some(auth_accounts.joined(
            settings_store.read_dynamic(home, "config.json"),
            next_creds,
            store,
            flow.provider,
            public_id,
            first,
          ))
        _, _ -> None
      }
      let next =
        finish(
          owner,
          Record(
            ..flow,
            state: "complete",
            progress: "",
            failure: None,
            account_ids: [public_id],
          ),
        )
      settings_store.commit_group(
        home,
        dict.from_list([
          #("creds.json", next_creds),
          #(
            "oauth-logins.json",
            to_map(dict.insert(records, id, encode_record(next))),
          ),
          ..case config {
            Some(config) -> [#("config.json", config)]
            None -> []
          }
        ]),
      )
      Ok(next)
    }),
  )
  let public_id = list.first(completed.account_ids) |> result.unwrap("")
  #(
    public_id,
    dict.insert(owner.flows, id, Active(..active, record: completed)),
  )
}

// ---- one flow --------------------------------------------------------------

type Save =
  fn(String, Dict(String, Dynamic), fn(Dynamic) -> Account) ->
    Result(String, String)

fn run_flow(
  owner: Pid,
  direct: Subject(Message),
  id: String,
  login: Login,
  save: Save,
  ready: Subject(Started),
) -> Nil {
  watch_owner(owner)
  let _ = put_flow(flow_key(), FlowContext(owner:, direct:, id:))
  let settle = fn(status) { report(owner, direct, id, status) }
  case login.callback {
    oauth.Device(start) ->
      case albedo_protect.attempt(start) {
        Ok(Ok(#(url, instructions, complete))) -> {
          process.send(ready, Ready(url, Some(instructions)))
          complete_with(login, save, settle, fn() {
            complete(fn(text) { settle(Waiting(text)) })
          })
        }
        Ok(Error(reason)) -> process.send(ready, StartFailed(reason))
        Error(crash) ->
          process.send(ready, StartFailed("sign-in failed: " <> crash))
      }
    oauth.Callback(host:, port:, path:, fixed:) -> {
      let callbacks = process.new_subject()
      case listener.listen(port:, fixed:, path:, pages:, callbacks:) {
        Error(listener.ListenError(reason)) ->
          process.send(
            ready,
            StartFailed(
              "could not listen for the "
              <> login.provider
              <> " sign-in callback on 127.0.0.1:"
              <> int.to_string(port)
              <> " ("
              <> atom.to_string(reason)
              <> ")",
            ),
          )
        Ok(open) -> {
          let verifier = digest.base64_url(crypto.strong_random_bytes(64))
          let grant =
            oauth.Grant(
              redirect: "http://"
                <> host
                <> ":"
                <> int.to_string(listener.port(open))
                <> path,
              state: ids.random_hex(16),
              verifier:,
              challenge: digest.base64_url(
                digest.sha256(bit_array.from_string(verifier)),
              ),
              issuer: None,
            )
          case login.authorize(grant) {
            Error(reason) -> {
              listener.close(open)
              process.send(ready, Refused(reason))
            }
            Ok(url) -> {
              process.send(ready, Ready(url, None))
              let timeout = process.new_subject()
              albedo_clock.send_after(timeout, flow_timeout_ms, TimedOut)
              let outcome = wait(grant.state, callbacks, timeout)
              listener.close(open)
              case outcome {
                Error(reason) -> settle(Failed(reason))
                Ok(#(code, issuer)) -> {
                  settle(Exchanging("exchanging authorization code"))
                  complete_with(login, save, settle, fn() {
                    login.exchange(
                      oauth.Grant(..grant, issuer:),
                      code,
                      fn(text) { settle(Exchanging(text)) },
                    )
                  })
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Run the step that yields the credential, then store it.
fn complete_with(
  login: Login,
  save: Save,
  settle: fn(Status) -> Nil,
  run: fn() -> Result(Dict(String, Dynamic), String),
) -> Nil {
  case albedo_protect.attempt(run) {
    Ok(Ok(credential)) ->
      case save(login.store, credential, login.account) {
        Ok(label) -> settle(Done(label))
        Error(reason) -> settle(Failed(reason))
      }
    Ok(Error(reason)) -> settle(Failed(reason))
    Error(crash) -> settle(Failed("sign-in failed: " <> crash))
  }
}

/// End the calling flow when the owner stops.
fn watch_owner(owner: Pid) -> Nil {
  let flow = process.self()
  process.spawn(fn() {
    let owner_monitor = process.monitor(owner)
    let flow_monitor = process.monitor(flow)
    let ended =
      process.new_selector()
      |> process.select_specific_monitor(owner_monitor, fn(_) { True })
      |> process.select_specific_monitor(flow_monitor, fn(_) { False })
      |> process.selector_receive_forever
    case ended {
      True -> process.kill(flow)
      False -> Nil
    }
  })
  Nil
}

fn report(
  owner: Pid,
  direct: Subject(Message),
  id: String,
  status: Status,
) -> Nil {
  case status {
    Done(_) | Failed(_) -> {
      // Keep the flow alive until the owner has published its terminal fact.
      let monitor = process.monitor(owner)
      let reply = process.new_subject()
      process.send(direct, Settled(id, status, reply))
      process.new_selector()
      |> process.select(reply)
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive_forever
      process.demonitor_process(monitor)
    }
    Waiting(_) | Exchanging(_) -> process.send(direct, Progressed(id, status))
  }
}

fn store_with_owner(
  owner: Pid,
  direct: Subject(Message),
  id: String,
  home: String,
  store: String,
  credential: Dict(String, Dynamic),
  account: fn(Dynamic) -> Account,
  keep: Option(Keep),
  join: Join,
) -> Result(String, String) {
  let monitor = process.monitor(owner)
  let reply = process.new_subject()
  process.send(
    direct,
    Store(id, home, store, credential, account, keep, join, reply),
  )
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(stored) {
      result.replace_error(stored, "Could not store provider account.")
    })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error("Sign-in owner stopped.")
    })
    |> process.selector_receive(call_ms)
  process.demonitor_process(monitor)
  case answer {
    Ok(answer) -> answer
    Error(Nil) -> Error("Provider account storage timed out.")
  }
}

type Event {
  Callback(Dict(String, String))
  Pasted(String)
  TimedOut
}

/// The browser callback and a pasted code race; the first valid one wins.
/// Returns the code and the issuer the response named.
fn wait(
  state: String,
  callbacks: Subject(Dict(String, String)),
  timeout: Subject(Event),
) -> Result(#(String, Option(String)), String) {
  let event =
    process.new_selector()
    |> process.select_map(callbacks, Callback)
    |> process.select(timeout)
    |> oauth.select_input(Pasted)
    |> process.selector_receive_forever
  case event {
    Callback(query) ->
      case dict.get(query, "error") {
        Ok(error) ->
          case dict.get(query, "state") |> result.unwrap(state) == state {
            True ->
              Error(
                "authorization failed: "
                <> {
                  dict.get(query, "error_description") |> result.unwrap(error)
                },
              )
            False -> wait(state, callbacks, timeout)
          }
        Error(Nil) ->
          case dict.get(query, "code"), dict.get(query, "state") {
            Ok(code), Ok(returned) if code != "" && returned == state ->
              Ok(#(code, dict.get(query, "iss") |> option.from_result))
            _, _ -> wait(state, callbacks, timeout)
          }
      }
    Pasted(text) -> {
      let issuer = input_issuer(text)
      case parse_input(text) {
        #("", _) -> Error("missing authorization code")
        #(code, "") -> Ok(#(code, issuer))
        #(code, returned) if returned == state -> Ok(#(code, issuer))
        _ -> Error("oauth state mismatch")
      }
    }
    TimedOut -> Error("sign-in timed out waiting for the browser")
  }
}

/// A pasted redirect url, `code#state`, a query string, or a bare code, as
/// its code and state.
fn parse_input(text: String) -> #(String, String) {
  let text = string.trim(text)
  case uri.parse(text) {
    Ok(uri.Uri(scheme: Some(_), host: Some(_), query: Some(query), ..)) ->
      query_pair(query)
    _ ->
      case string.split_once(text, "#") {
        Ok(pair) -> pair
        Error(Nil) ->
          case string.contains(text, "code=") {
            False -> #(text, "")
            True -> query_pair(trim_leading(text))
          }
      }
  }
}

fn query_pair(query: String) -> #(String, String) {
  let fields = listener.parse_query(query)
  #(
    dict.get(fields, "code") |> result.unwrap(""),
    dict.get(fields, "state") |> result.unwrap(""),
  )
}

/// The `iss` a pasted callback url or query string carries (RFC 9207).
fn input_issuer(text: String) -> Option(String) {
  let text = string.trim(text)
  let query = case uri.parse(text) {
    Ok(uri.Uri(scheme: Some(_), host: Some(_), query: Some(query), ..)) -> query
    _ -> trim_leading(text)
  }
  listener.parse_query(query) |> dict.get("iss") |> option.from_result
}

fn trim_leading(text: String) -> String {
  case text {
    "?" <> rest | "#" <> rest -> trim_leading(rest)
    _ -> text
  }
}

// ---- records ---------------------------------------------------------------

fn terminal(record: Record) -> Bool {
  list.contains(["complete", "failed", "cancelled", "expired"], record.state)
}

fn failed_record(owner: Owner, record: Record, reason: String) -> Record {
  let expired = record.expires <= albedo_clock.system_ms()
  finish(
    owner,
    Record(
      ..record,
      state: case expired {
        True -> "expired"
        False -> "failed"
      },
      failure: Some(case expired {
        True -> "Provider sign-in expired."
        False -> reason
      }),
      progress: "",
    ),
  )
}

/// A terminal record, retained for a while and then dropped from the live set.
fn finish(owner: Owner, record: Record) -> Record {
  albedo_clock.send_after(owner.direct, retain_ms, Forget(record.id))
  let now = albedo_clock.system_ms()
  Record(..record, terminal_at: Some(now), retain_until: Some(now + retain_ms))
}

const identity_expired = #(
  410,
  "identity_expired",
  "Login identity has expired.",
)

/// A sign-in identity must be a current UUIDv7 no older than the retention.
fn fresh_identity(
  id: String,
  next: fn() -> Result(a, Failure),
) -> Result(a, Failure) {
  let now = albedo_clock.system_ms()
  case http_api.validate_id(id, now) {
    Ok(Nil) -> {
      // A UUIDv7's first 48 bits are its creation time in milliseconds.
      let created = case string.split(id, "-") {
        [low, high, ..] -> int.base_parse(low <> high, 16) |> result.unwrap(0)
        _ -> 0
      }
      use <- ensure(created >= now - retain_ms, identity_expired)
      next()
    }
    Error(http_api.IdentityExpired) -> Error(identity_expired)
    Error(http_api.IdentityInvalid) | Error(http_api.IdentityFuture) ->
      Error(#(
        400,
        "identity_invalid",
        "Login identity must be a current UUIDv7.",
      ))
  }
}

fn bounded(text: String, max: Int) -> String {
  string.to_utf_codepoints(text)
  |> list.take(max)
  |> string.from_utf_codepoints
}

/// Kept out of the API, which only says the sign-in failed.
fn log_failure(record: Record, reason: String) -> Nil {
  log_warning("provider sign-in ~ts (~ts) failed: ~tp", [
    record.id,
    record.provider,
    reason,
  ])
}

fn decode_record(value: Dynamic) -> Result(Record, Failure) {
  decode.run(value, {
    use id <- decode.field("id", decode.string)
    use provider <- decode.field("provider", decode.string)
    use intent <- decode.field("intent", decode.string)
    use url <- decode.field("url", decode.optional(decode.string))
    use state <- decode.field("state", decode.string)
    use progress <- decode.field("progress", decode.string)
    use instructions <- decode.field("instructions", decode.string)
    use expires <- decode.field("expires", decode.int)
    use account_ids <- decode.field("account_ids", decode.list(decode.string))
    use failure <- decode.field("failure", decode.optional(decode.string))
    use terminal_at <- decode.optional_field(
      "terminal_at",
      None,
      decode.map(decode.int, Some),
    )
    use retain_until <- decode.optional_field(
      "retain_until",
      None,
      decode.map(decode.int, Some),
    )
    use confirmation <- decode.optional_field(
      "confirmation_revision",
      None,
      decode.map(decode.string, Some),
    )
    decode.success(Record(
      id:,
      provider:,
      intent:,
      url:,
      state:,
      progress:,
      instructions:,
      expires:,
      account_ids:,
      failure:,
      terminal_at:,
      retain_until:,
      confirmation:,
    ))
  })
  |> result.replace_error(storage_unavailable)
}

fn encode_record(record: Record) -> Dynamic {
  let optional = fn(value, encode) {
    option.map(value, encode) |> option.unwrap(null())
  }
  [
    #("id", dynamic.string(record.id)),
    #("provider", dynamic.string(record.provider)),
    #("intent", dynamic.string(record.intent)),
    #("url", optional(record.url, dynamic.string)),
    #("state", dynamic.string(record.state)),
    #("progress", dynamic.string(record.progress)),
    #("instructions", dynamic.string(record.instructions)),
    #("expires", dynamic.int(record.expires)),
    #("account_ids", dynamic.list(list.map(record.account_ids, dynamic.string))),
    #("failure", optional(record.failure, dynamic.string)),
  ]
  |> list.append(
    [
      #("terminal_at", record.terminal_at),
      #("retain_until", record.retain_until),
    ]
    |> list.filter_map(fn(field) {
      option.map(field.1, fn(value) { #(field.0, dynamic.int(value)) })
      |> option.to_result(Nil)
    }),
  )
  |> list.append(confirmation_field(record))
  |> dict.from_list
  |> to_map
}

/// The sign-in as clients see it, with the saved accounts it created.
fn encode_login(
  home: String,
  record: Record,
  logins: List(Login),
) -> Result(String, Failure) {
  use accounts <- result.map(
    locked(home, fn() { Ok(account_projection(home, logins)) }),
  )
  let created =
    list.filter(accounts, fn(account) {
      case decode.run(account, decode.at(["id"], decode.string)) {
        Ok(id) -> list.contains(record.account_ids, id)
        Error(_) -> False
      }
    })
  let failure = case record.failure {
    Some(detail) ->
      to_map(
        dict.from_list([
          #("code", dynamic.string("sign_in_" <> record.state)),
          #("detail", dynamic.string(detail)),
        ]),
      )
    None -> null()
  }
  dict.from_list([
    #("id", dynamic.string(record.id)),
    #("provider", dynamic.string(record.provider)),
    #("url", option.map(record.url, dynamic.string) |> option.unwrap(null())),
    #("state", dynamic.string(record.state)),
    #("instructions", dynamic.string(record.instructions)),
    #("progress", dynamic.string(record.progress)),
    #("failure", failure),
    #("expires_at", dynamic.string(albedo_clock.format_rfc3339(record.expires))),
    #("accounts", dynamic.list(created)),
    ..confirmation_field(record)
  ])
  |> to_map
  |> albedo_json.encode
}

fn confirmation_field(record: Record) -> List(#(String, Dynamic)) {
  case record.confirmation {
    Some(revision) -> [#("confirmation_revision", dynamic.string(revision))]
    None -> []
  }
}

fn null() -> Dynamic {
  atom.to_dynamic(atom.create("null"))
}

/// A string-keyed dict as the JSON object value the settings store encodes.
fn to_map(fields: Dict(String, Dynamic)) -> Dynamic {
  dict.to_list(fields)
  |> list.map(fn(field) { #(dynamic.string(field.0), field.1) })
  |> dynamic.properties
}

// ---- storage ---------------------------------------------------------------

fn locked(home: String, run: fn() -> Result(a, Failure)) -> Result(a, Failure) {
  case settings_store.lock(home, fn() { Ok(run()) }, fn(_) { Error(Nil) }) {
    Ok(result) -> result
    Error(_) -> Error(storage_unavailable)
  }
}

/// Every record in `oauth-logins.json`, keyed by sign-in id.
fn records(home: String) -> Result(Dict(String, Dynamic), Failure) {
  let path = home <> "/oauth-logins.json"
  case private_file(path) {
    Ok(None) -> Ok(dict.new())
    Ok(Some(size)) if size <= 2_097_152 -> {
      use bytes <- result.try(
        read_file(path) |> result.replace_error(storage_unavailable),
      )
      use value <- result.try(
        albedo_json.decode(bytes) |> result.replace_error(storage_unavailable),
      )
      decode.run(value, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error(storage_unavailable)
    }
    _ -> Error(storage_unavailable)
  }
}

fn write_records(home: String, records: Dict(String, Dynamic)) -> Nil {
  settings_store.commit_group(
    home,
    dict.from_list([#("oauth-logins.json", to_map(records))]),
  )
}

/// Write `record` unless the stored one already finished. Recovery can
/// publish a committed terminal record before a failed caller observes it,
/// and a late progress or stop report cannot reverse that fact.
fn persist(
  home: String,
  id: String,
  record: Record,
) -> Result(Record, Failure) {
  locked(home, fn() {
    use all <- result.try(records(home))
    case dict.get(all, id) {
      Ok(stored) -> {
        use stored <- result.try(decode_record(stored))
        case terminal(stored) {
          True -> Ok(stored)
          False -> {
            write_records(home, dict.insert(all, id, encode_record(record)))
            Ok(record)
          }
        }
      }
      Error(Nil) -> {
        write_records(home, dict.insert(all, id, encode_record(record)))
        Ok(record)
      }
    }
  })
}

/// `persist`'s record, or an error when the login file is unavailable.
fn persisted(home: String, id: String, record: Record) -> Result(Record, Nil) {
  case albedo_protect.attempt(fn() { persist(home, id, record) }) {
    Ok(Ok(stored)) -> Ok(stored)
    _ -> Error(Nil)
  }
}

/// Drop finished records past their retention.
fn prune(
  records: Dict(String, Dynamic),
) -> Result(Dict(String, Dynamic), Failure) {
  let now = albedo_clock.system_ms()
  dict.to_list(records)
  |> list.try_map(fn(entry) {
    use #(finished, retain_until) <- result.map(retention(entry.1))
    #(entry, !finished || retain_until > now)
  })
  |> result.map(fn(entries) {
    list.filter_map(entries, fn(entry) {
      case entry.1 {
        True -> Ok(entry.0)
        False -> Error(Nil)
      }
    })
    |> dict.from_list
  })
}

fn active_count(records: Dict(String, Dynamic)) -> Result(Int, Failure) {
  dict.values(records)
  |> list.try_map(retention)
  |> result.map(list.count(_, fn(entry) { !entry.0 }))
}

/// Whether a stored record finished, and until when it is retained.
fn retention(value: Dynamic) -> Result(#(Bool, Int), Failure) {
  use state <- result.try(
    decode.run(value, decode.at(["state"], decode.string))
    |> result.replace_error(storage_unavailable),
  )
  case list.contains(["complete", "failed", "cancelled", "expired"], state) {
    False -> Ok(#(False, 0))
    True ->
      decode.run(value, decode.at(["retain_until"], decode.int))
      |> result.map(fn(until) { #(True, until) })
      |> result.replace_error(storage_unavailable)
  }
}

/// The keyed digest of a submitted intent. Its key is created on first use.
fn intent_digest(home: String, intent: String) -> Result(String, Failure) {
  let path = home <> "/.oauth-intent-key"
  use key <- result.map(case private_file(path) {
    Ok(None) -> {
      let key = crypto.strong_random_bytes(32)
      case
        albedo_file.write_private(path, key) == Ok(Nil) && sync_directory(home)
      {
        True -> Ok(key)
        False -> Error(storage_unavailable)
      }
    }
    Ok(Some(32)) -> read_file(path) |> result.replace_error(storage_unavailable)
    _ -> Error(storage_unavailable)
  })
  digest.hex(digest.hmac_sha256(bit_array.from_string(intent), key))
}

/// The size of `path` when it is a regular file only its owner can read,
/// `None` when it does not exist, and an error when it exists any other way.
fn private_file(path: String) -> Result(Option(Int), Nil) {
  case read_link_info(path) {
    Error(reason) ->
      case decode.run(reason, atom.decoder()) == Ok(atom.create("enoent")) {
        True -> Ok(None)
        False -> Error(Nil)
      }
    Ok(info) -> {
      // The fields of OTP's `#file_info{}` record.
      let fields = {
        use size <- decode.subfield([1], decode.int)
        use kind <- decode.subfield([2], atom.decoder())
        use mode <- decode.subfield([7], decode.int)
        decode.success(#(size, kind, mode))
      }
      case decode.run(info, fields) {
        Ok(#(size, kind, mode)) ->
          case
            kind == atom.create("regular") && int.bitwise_and(mode, 0o077) == 0
          {
            True -> Ok(Some(size))
            False -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    }
  }
}

fn sync_directory(home: String) -> Bool {
  let modes = [
    atom.create("read"),
    atom.create("raw"),
    atom.create("directory"),
  ]
  case open_file(home, modes) {
    Ok(device) -> {
      let synced = sync_file(device) == atom.create("ok")
      let _ = close_file(device)
      synced
    }
    Error(_) -> False
  }
}

// ---- natives ---------------------------------------------------------------

fn signed_in(
  creds: Dynamic,
  store: String,
  credential: Dynamic,
  account: fn(Dynamic) -> Account,
  raw_id: String,
  provider: String,
) -> #(String, Dynamic) {
  auth_accounts.signed_in(creds, store, credential, account, raw_id, provider)
}

/// Whether `creds` already holds the account with public ID `id` under
/// `store`.
fn known_account(creds: Dynamic, store: String, id: String) -> Bool {
  case credential_store.object(creds) {
    Ok(creds) ->
      credential_store.values(settings_store.object("accounts", creds), store)
      |> list.any(fn(value) {
        credential_store.text(value, "_albedo_account_id") == Ok(id)
      })
    Error(_) -> False
  }
}

/// Whether a saved profile uses `extension`, read without the settings lock:
/// the commit decides again under it.
fn profile_uses(home: String, extension: String) -> Bool {
  case credential_store.config(home) {
    Ok(config) ->
      case
        dict.get(config, "providers") |> result.try(credential_store.object)
      {
        Ok(profiles) ->
          dict.values(profiles)
          |> list.any(fn(profile) {
            decode.run(
              profile,
              decode.optional_field(
                "extension",
                "openai",
                decode.string,
                decode.success,
              ),
            )
            == Ok(extension)
          })
        Error(_) -> False
      }
    Error(_) -> False
  }
}

fn account_projection(home: String, logins: List(Login)) -> List(Dynamic) {
  auth_accounts.saved_accounts(home, logins)
}

@external(erlang, "file", "read_link_info")
fn read_link_info(path: String) -> Result(Dynamic, Dynamic)

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

type Device

@external(erlang, "file", "open")
fn open_file(path: String, modes: List(Atom)) -> Result(Device, Dynamic)

@external(erlang, "file", "sync")
fn sync_file(device: Device) -> Atom

@external(erlang, "file", "close")
fn close_file(device: Device) -> Dynamic

@external(erlang, "logger", "warning")
fn log_warning(format: String, arguments: List(String)) -> Nil
