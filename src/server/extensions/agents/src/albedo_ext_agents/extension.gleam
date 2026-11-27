//// Agents for the model: spawn children, look up any session and read its
//// messages, stop and close your own children, and post progress. Talking is
//// `mail.submit`, from the mail extension this one requires. Every permission
//// is checked here against the calling session, which the daemon supplies;
//// python never names itself.

import albedo_bytes/scalars
import albedo_ext_agents/resources
import albedo_ext_agents/service
import albedo_ext_agents/sessions
import albedo_ext_agents/sidebar
import albedo_json
import albedo_sdk/capability
import albedo_sdk/extension
import albedo_sdk/family
import albedo_sdk/helper
import albedo_sdk/history as conversation
import albedo_sdk/hook
import albedo_sdk/host
import albedo_sdk/input
import albedo_sdk/kernel
import albedo_sdk/mail
import albedo_sdk/rpc
import albedo_sdk/service as http_service
import albedo_sdk/session_control as agents
import albedo_sdk/session_identity as identity
import albedo_sdk/sessions as session_facts
import albedo_sdk/storage
import albedo_sdk/worktree.{type Worktrees}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const instructions =
  "Agents are sessions you spawn to work in parallel; every call is async. A lead session can keep a few long-lived peers for distinct areas, reusing useful context and starting fresh when context is unrelated; the right set depends on the project. agents.self is your handle (id, name, depth, parent). Call await agents.models() once before spawning; every entry is provider/model, your own provider's included, and selecting one routes the child through that provider. Call await agents.models(cyber_access=\"daybreak_blue\") for only models that the currently resolved Codex account of each profile advertises as Blue; unknown account/catalog state raises an error, and the provider can still refuse at request time. Blue children require agents.self.spawn(..., model=\"provider/model\", cyber_access=\"daybreak_blue\"); children without that opt-in are standard. Within the same model tier and family, prefer the one with the newest version number or release date: later versions are generally better, while usually being no more expensive. This doesn't change what tier you pick for a task. If the user asks for a specific model, use that one. Optional effort selects a supported reasoning tier. Pass it when the task or loaded instructions specify a tier; otherwise omit it and let the harness choose rather than guessing from task difficulty. Then child = await agents.self.spawn(task, name=\"scout\", model=<one of models()>, effort=None, deliverable=None, evidence_bar=None, falsifier=None, verifier=None, cyber_access=None, worktree=False): it returns as soon as the child exists, and its answer arrives later as <mail> and wakes your next turn, so spawn independent children back to back and end your turn (verifier is an optional shell command that must exit 0 before the child can mail its parent or finish; await child.set_verifier(command) replaces it and set_verifier(None) clears it, so drop one that can no longer pass). Talk with await mail.submit(child, text). await agents.self.children() and siblings() return live snapshots (running, closed). running=False means no active turn; a new child may still be waiting for its kernel and have no transcript yet. It does not prove spawn failed; wait for its mail rather than cancelling it on that snapshot. await child.switch(model) returns {model: provider/model, pending: bool}; it switches your own child or peer at its next request without stopping its turn, replacing any pending switch, and mails you if late history projection fails. await child.cancel() stops its turn, and child.cancel(tree=True) the turns of everything beneath it; await agents.cancel_all(tree=True) stops every child you have, and their descendants, in one call, so use it when the user says to stop the swarm; await child.close() when you are done with it keeps its messages and files and frees its kernel. await agents.get(to) returns a live handle for \"parent\", a family name, or any session id. On any handle, await h.messages(seq=0, offset=0, limit=4000) reads a page of that session's messages from row seq on (content, next_offset) and await h.search_messages(pattern) finds rows by seq: any session may read any other, so you can see what a child or another session did without waiting for mail. await agents.sessions(query=\"\", cwd=None, limit=20, offset=0, open_only=True, top_level_only=False) lists open sessions, most recently active first, as snapshots that also carry cwd, model, last_active, and matches; with a query it keeps sessions whose title or name contains it or whose messages do, and matches holds up to 3 of each one's newest matching rows as {seq, preview} to read with messages(seq=...). cwd keeps one directory. open_only keeps sessions that are not closed, including idle ones; set open_only=False for history. top_level_only keeps sessions with no parent. Both apply before limit and offset. When something is slow, a job looks stuck, or you want to see what you, a child, or another session still have running on this machine, check with await resources.query(query=\"\", process=None, cwd=None, session=None) (e.g. await resources.query() for every session's live processes, await resources.query(\"cargo\"), or await resources.query(session=\"self\")): it returns a record with .processes, .sessions, .cpu_percent, and .memory_bytes, listing each matching live process (each session's kernel, its run jobs, and what they started) with the session id and job_id it belongs to (query matches the process name, command, or session name; process matches the process name or command; cwd filters by directory; session takes \"self\", \"parent\", a session name or id, or an agent handle). await agents.start(task, name, model, cwd=None, role=None, effort=None, worktree=False) starts a root peer you own, and await agents.set_role(text, id=None) labels one; failures raise AgentsError. Only the user deletes agents: if one should go, ask them. Children nest at most 3 deep and 12 open per parent; mail any session by id instead of nesting to reach it. Children share your workspace, so give two children the same files only if one only reads, or pass worktree=True (or a Worktree from worktrees.create() / worktrees.get()) to spawn(...) or start(...) to run the agent's kernel in its own isolated worktree. Every handle's .worktree holds that Worktree, or None. child.close() does not delete a worktree automatically: remove it explicitly with await worktrees.remove(child.worktree.id) once its work is merged."

pub fn extension() -> extension.Extension {
  extension.Extension(
    "agents",
    "Spawn child agents, watch your family, and close children you are done with.",
    ["mail"],
    [
      extension.ServicePlugin(http_service.json(65_536, service.dispatch)),
      extension.ToolPlugin(instructions, [], ["agents"], [
        #("agents", fn(context: host.Context, method, args) {
          handle(
            context.storage,
            context.inbox,
            context.letters,
            context.worktrees,
            context.session,
            context.progress,
            context.ask_moved,
            context.correspondents,
            context.control,
            context.kernel_resources,
            method,
            args,
          )
        }),
      ]),
      // The hook is cheap for roots with no requests and keeps prompt context stable.
      extension.OwnedManagedPlugin(prepare),
      // The client lists it under background jobs (albedo-suite).
      extension.GlancePlugin(sidebar.sidebar, sidebar.resource_url),
    ],
    // The family tables are core's: the daemon creates them.
    extension.no_initialise,
    tables: [],
    uses:,
  )
}

/// `host.Context.ask_moved`: the session, the path, and the JSON body.
type AskMoved =
  fn(String, String, String) -> Result(Option(dynamic.Dynamic), String)

fn prepare(
  preparation: extension.Preparation,
) -> Result(Option(extension.Owned), String) {
  let extension.Preparation(
    storage: db,
    letters:,
    session:,
    workspace:,
    worktrees:,
    ..,
  ) = preparation
  let context = case family.get(db, session) {
    Ok(Some(member)) -> doctrine(db, worktrees, member, workspace)
    _ ->
      case family.started_by(db, session) {
        Ok(Some(starter)) ->
          peer_doctrine(db, worktrees, session, starter, workspace)
        _ -> ""
      }
  }
  // It holds no resources, so its lifecycle is the empty contribution's.
  let managed =
    extension.Managed(
      ..extension.empty(),
      context: context,
      // The hook reads its handle and session from the context it is asked
      // with: a captured handle would be copied with every composition.
      hook: Some(fn(context, event) { answered(letters, context, event) }),
    )
  Ok(Some(extension.owned(managed, managed.adopt, managed.close)))
}

fn worktree_note(
  db: storage.Storage,
  worktrees: Worktrees,
  session: String,
  workspace: String,
) -> String {
  case worktrees.for_session(db, session, workspace) {
    Some(wt) ->
      " You are running in isolated "
      <> wt.kind
      <> " worktree \""
      <> wt.name
      <> "\" at "
      <> wt.workspace
      <> " (main repository: "
      <> wt.repo
      <> ")."
    None -> ""
  }
}

fn session_cwd(db: storage.Storage, session: String) -> String {
  session_facts.describe(db, [session])
  |> result.unwrap([])
  |> list.first
  |> result.map(fn(found) { found.workspace })
  |> result.unwrap("")
}

fn session_at(db: storage.Storage, cwd: String) -> Bool {
  session_facts.occupied(db, cwd) |> result.unwrap(False)
}

fn doctrine(
  db: storage.Storage,
  worktrees: Worktrees,
  member: identity.Member,
  workspace: String,
) -> String {
  "You are child agent \""
  <> member.name
  <> "\" of \""
  <> family.name_of(db, member.parent)
  <> "\", depth "
  <> string.inspect(member.depth)
  <> ". Your task arrived as <mail kind=\"task\">. When it is done, send your result with await mail.submit(\"parent\", result) — a short summary, with paths to anything large. To ask your parent a question or request clarification, use await mail.request(\"parent\", question). If a verifier command is set and you are blocked, report it with await mail.submit(\"parent\", blocker, blocker=True). A submission tells your parent the task is finished: do not send progress or an incomplete result that way. If you cannot finish, report it with blocker=True. If your turn ends before you send a reply, you will get up to three reminders, and if the turn after them also ends without a reply, your last message is forwarded to your parent marked unreviewed. For longer work, you can post await agents.progress(\"...\") occasionally; it updates the agents view without interrupting anyone. Mail from other agents is from peers rather than the user."
  <> worktree_note(db, worktrees, member.session, workspace)
}

fn peer_doctrine(
  db: storage.Storage,
  worktrees: Worktrees,
  session: String,
  starter: String,
  workspace: String,
) -> String {
  "You are peer agent \""
  <> family.name_of(db, session)
  <> "\", started by \""
  <> family.name_of(db, starter)
  <> "\" (session "
  <> starter
  <> "). Its tasks arrive as <mail kind=\"request\">. When one is done, answer with await mail.submit(\""
  <> starter
  <> "\", result) — a short summary, with paths to anything large. If your turn ends before you answer, you will get one reminder, and if the next turn also ends without an answer, your last message is forwarded to it marked unreviewed. Mail from other agents is from peers rather than the user."
  <> worktree_note(db, worktrees, session, workspace)
}

/// Keeps a child's turn going when it owes a reply or its parent's verifier
/// gate fails, and refuses `mail.submit` to the parent until the gate passes.
fn answered(
  letters: mail.Letters,
  context: hook.Context,
  event: hook.Event,
) -> hook.Verdict {
  let hook.Context(session:, storage: db, ..) = context
  case event {
    hook.Calling(call) if call.name == "mail.submit" -> {
      let decoder = {
        use to <- decode.field("to", decode.string)
        use blocker <- decode.optional_field("blocker", False, decode.bool)
        decode.success(#(to, blocker))
      }
      case
        decode.run(
          json.parse(call.arguments, decode.dynamic)
            |> result.unwrap(dynamic.nil()),
          decoder,
        )
      {
        Ok(#(to, False)) ->
          case family.resolve(db, session, to), family.get(db, session) {
            Ok(address), Ok(Some(member)) if address.session == member.parent ->
              case verify_child(db, session) {
                Ok(Nil) -> hook.proceed
                Error(detail) ->
                  hook.Verdict(
                    ..hook.proceed,
                    block: Some(
                      detail
                      <> "\n\nYou cannot submit task completion while the verifier is failing. Fix the failure, ask a question with await mail.request(\"parent\", <question>), or report a blocker with await mail.submit(\"parent\", <blocker>, blocker=True).",
                    ),
                  )
              }
            _, _ -> hook.proceed
          }
        _ -> hook.proceed
      }
    }
    hook.Stopping(held:, quieted:, awaiting:, ..) ->
      case letters.owed_requesters(db, session) {
        Ok([_, ..] as requesters) -> {
          let member = family.get(db, session)
          let parent = case member {
            Ok(Some(member)) -> Some(member.parent)
            _ -> None
          }
          case requesters, member {
            [only], Ok(Some(member)) if member.parent == only ->
              case awaiting {
                True -> hook.proceed
                False ->
                  case verify_child(db, session) {
                    Error(detail) ->
                      hook.Verdict(
                        ..hook.proceed,
                        block: Some(
                          detail
                          <> "\n\nFix the failure so the verifier exits 0, then send your result with await mail.submit(\"parent\", result).\nIf you need help from your parent, ask with await mail.request(\"parent\", <question>), or report a blocker with await mail.submit(\"parent\", <blocker>, blocker=True).",
                        ),
                      )
                    Ok(Nil) if held < reminders ->
                      hook.Verdict(
                        ..hook.proceed,
                        block: Some(child_reminder(held)),
                      )
                    Ok(Nil) -> hook.proceed
                  }
              }
            _, _ if awaiting || quieted || held > 0 -> hook.proceed
            _, _ -> {
              let uncrossed =
                list.filter(requesters, fn(requester) {
                  Some(requester) == parent
                  || letters.crossed(db, session, requester) != Ok(True)
                })
              case uncrossed {
                [] -> hook.proceed
                _ ->
                  hook.Verdict(
                    ..hook.proceed,
                    block: Some(
                      "You owe a reply to "
                      <> string.join(uncrossed, ", ")
                      <> ". Send it with await mail.submit(\"<id>\", result) before you finish.",
                    ),
                  )
              }
            }
          }
        }
        _ -> hook.proceed
      }
    _ -> hook.proceed
  }
}

/// How many times a session that still owes a reply is kept going before its
/// last words are forwarded as unreviewed.
const reminders = 3

/// What a child that stopped without answering is told. Weak models answer a
/// bare reminder with a progress note and stop, so it says what a submission
/// means and names the other ways to report.
fn child_reminder(held: Int) -> String {
  "You have not answered your parent yet (reminder "
  <> int.to_string(held + 1)
  <> " of "
  <> int.to_string(reminders)
  <> "). If the task is finished, send your result with await mail.submit(\"parent\", result). If it is not finished, keep working: a submission tells your parent you are done, so do not use it for progress (use await agents.progress(\"...\")). If you cannot continue, report that with await mail.submit(\"parent\", reason, blocker=True), or ask with await mail.request(\"parent\", question)."
}

fn verify_child(db: storage.Storage, session: String) -> Result(Nil, String) {
  case family.verifier(db, session) {
    Ok(Some(#(cwd, command))) -> run_verifier(cwd, command)
    _ -> Ok(Nil)
  }
}

/// Runs a verifier command in `cwd`, in its own process group, through
/// priv/python/albedo_verifier.py: it passes on exit 0, and otherwise fails
/// with the helper's bounded detail. The helper stops the command after its
/// own 300 s; the wait here only covers a helper that outlives that.
fn run_verifier(cwd: String, command: String) -> Result(Nil, String) {
  let request =
    json.object([#("cwd", json.string(cwd)), #("command", json.string(command))])
    |> json.to_string
  case helper.run("albedo_verifier.py", "verifier", request, 305_000) {
    helper.Exited(0, _) -> Ok(Nil)
    helper.Exited(_, output) -> Error(string.trim(output))
    helper.StartFailed(reason) -> Error(reason)
    helper.TimedOut -> Error("verifier timed out")
  }
}

fn handle(
  db: storage.Storage,
  inbox: input.Inbox,
  letters: mail.Letters,
  worktrees: Worktrees,
  session: String,
  progress: fn(String) -> Nil,
  ask_moved: AskMoved,
  correspondents: family.Correspondents,
  control: agents.Control,
  kernels: kernel.Resources,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, #(String, String)) {
  rpc.serve(
    method,
    args,
    fn(method, args) {
      dispatch(
        db,
        inbox,
        letters,
        worktrees,
        session,
        progress,
        ask_moved,
        correspondents,
        control,
        kernels,
        method,
        args,
      )
    },
    fn(message) { #("invalid", message) },
  )
}

fn cyber_arg(args: dynamic.Dynamic) -> Result(Option(String), String) {
  use intent <- result.try(rpc.args(
    args,
    decode.optional_field(
      "cyber_access",
      None,
      decode.optional(decode.string),
      decode.success,
    ),
    "cyber_access must be daybreak_blue or null",
  ))
  case intent {
    None | Some("daybreak_blue") -> Ok(intent)
    Some(_) -> Error("cyber_access must be daybreak_blue or null")
  }
}

type WorktreeRequest {
  NoWorktree
  AutoWorktree
  ExistingWorktree(String)
}

fn worktree_arg(args: dynamic.Dynamic) -> Result(WorktreeRequest, String) {
  let decoder =
    decode.one_of(
      decode.bool
        |> decode.map(fn(on) {
          case on {
            True -> AutoWorktree
            False -> NoWorktree
          }
        }),
      [
        decode.string
        |> decode.then(fn(id) {
          case id {
            "" -> decode.failure(NoWorktree, "Worktree")
            _ -> decode.success(ExistingWorktree(id))
          }
        }),
      ],
    )
  rpc.args(
    args,
    decode.optional_field(
      "worktree",
      NoWorktree,
      decode.optional(decoder) |> decode.map(option.unwrap(_, NoWorktree)),
      decode.success,
    ),
    "worktree must be a Worktree or bool",
  )
}

fn with_worktree(
  db: storage.Storage,
  worktrees: Worktrees,
  args: dynamic.Dynamic,
  name: String,
  caller: String,
  start: fn(String) -> Result(#(a, String), String),
) -> Result(a, String) {
  use request <- result.try(worktree_arg(args))
  let cwd =
    decode.run(
      args,
      decode.optional_field("cwd", "", decode.string, decode.success),
    )
    |> result.unwrap("")
  let base = case cwd {
    "" -> session_cwd(db, caller)
    _ -> cwd
  }
  use wt <- result.try(case request {
    NoWorktree -> Ok(None)
    AutoWorktree ->
      worktrees.create_for_agent(db, base, name, caller)
      |> result.map(Some)
    ExistingWorktree(id) ->
      worktrees.get(db, base, id)
      |> result.try(fn(wt) {
        case worktrees.running_occupant(db, wt) {
          Some(occupant) ->
            Error(
              "worktree "
              <> wt.id
              <> " already has a running session ("
              <> occupant
              <> ")",
            )
          None -> Ok(Some(wt))
        }
      })
  })
  case start(option.map(wt, fn(w) { w.workspace }) |> option.unwrap(cwd)) {
    Ok(#(value, session)) -> {
      use _ <- result.try(case wt {
        Some(w) -> worktrees.attach_session(db, w.id, session)
        None -> Ok(Nil)
      })
      Ok(value)
    }
    Error(error) -> {
      case request, wt {
        AutoWorktree, Some(w) ->
          case session_at(db, w.workspace) {
            True -> Nil
            False -> {
              let _ = worktrees.remove(db, base, w.id, True)
              Nil
            }
          }
        _, _ -> Nil
      }
      Error(error)
    }
  }
}

/// The optional `effort` a tool call asked for, lowercased.
fn requested_effort(args: dynamic.Dynamic) -> Result(Option(String), String) {
  use effort <- result.try(rpc.args(
    args,
    decode.optional_field(
      "effort",
      None,
      decode.optional(decode.string),
      decode.success,
    ),
    "effort must be a string",
  ))
  case effort {
    None -> Ok(None)
    Some(value) ->
      case string.trim(value) {
        "" -> Error("effort must be a non-empty string")
        value -> Ok(Some(string.lowercase(value)))
      }
  }
}

fn dispatch(
  db: storage.Storage,
  inbox: input.Inbox,
  letters: mail.Letters,
  worktrees: Worktrees,
  session: String,
  progress: fn(String) -> Nil,
  ask_moved: AskMoved,
  correspondents: family.Correspondents,
  control: agents.Control,
  kernels: kernel.Resources,
  method: String,
  args: dynamic.Dynamic,
) -> Result(json.Json, String) {
  case method {
    "agents.self" -> {
      use me <- result.try(family.get(db, session))
      let provider =
        conversation.get(db, session)
        |> result.map(fn(info) { info.provider })
        |> result.unwrap("")
      Ok(
        json.object(
          list.append(handle_fields(db, worktrees, session, me), [
            #("provider", json.string(provider)),
          ]),
        ),
      )
    }
    "agents.models" -> {
      use cyber_access <- result.try(cyber_arg(args))
      agents.models(control, session, cyber_access)
      |> result.map(fn(models) { json.array(models, json.string) })
    }
    "agents.start" -> {
      use task <- result.try(service.text(args, "task"))
      use name <- result.try(service.text(args, "name"))
      use model <- result.try(service.text(args, "model"))
      use effort <- result.try(requested_effort(args))
      let role =
        decode.run(
          args,
          decode.optional_field("role", "", decode.string, decode.success),
        )
        |> result.unwrap("")
      use started <- result.try(
        with_worktree(db, worktrees, args, name, session, fn(dir) {
          agents.start(
            control,
            agents.Peer(session, task, name, model, dir, role, effort),
          )
          |> result.map(fn(info) { #(info, info.id) })
        }),
      )
      Ok(handle_json(db, worktrees, started.id, None))
    }
    "agents.spawn" -> {
      use task <- result.try(service.text(args, "task"))
      use name <- result.try(service.text(args, "name"))
      use model <- result.try(service.text(args, "model"))
      use effort <- result.try(requested_effort(args))
      let verifier =
        decode.run(
          args,
          decode.optional_field("verifier", "", decode.string, decode.success),
        )
        |> result.unwrap("")
        |> string.trim
      use _ <- result.try(
        case
          string.trim(task),
          string.trim(model),
          scalars.length(verifier) <= 4096
        {
          "", _, _ -> Error("task is empty; say what the child should do")
          _, "", _ ->
            Error("model is required; pick one from await agents.models()")
          _, _, False -> Error("verifier is at most 4096 characters")
          _, _, True -> Ok(Nil)
        },
      )
      use cyber_access <- result.try(cyber_arg(args))
      use _ <- result.try(
        family.valid_name(name) |> result.map_error(family.name_text),
      )
      use member <- result.try(
        with_worktree(db, worktrees, args, name, session, fn(dir) {
          agents.spawn(
            control,
            agents.Child(
              session,
              name,
              task,
              model,
              effort,
              dir,
              verifier,
              cyber_access,
            ),
          )
          |> result.map(fn(member) { #(member, member.session) })
        }),
      )
      Ok(handle_json(db, worktrees, member.session, Some(member)))
    }
    "agents.get" -> {
      use to <- result.try(service.text(args, "to"))
      use destination <- result.try(family.locate(
        db,
        session,
        to,
        correspondents,
      ))
      case destination {
        identity.Here(address) -> {
          use member <- result.try(family.get(db, address.session))
          Ok(status_json(db, worktrees, control, address.session, member))
        }
        // Its handle names it; every call on it is refused (`elsewhere`).
        identity.There(address, _, _) ->
          Ok(
            json.object([
              #("id", json.string(address.session)),
              #("name", json.string(address.name)),
              #("depth", json.int(0)),
              #("parent", json.null()),
              #("running", json.bool(False)),
              #("closed", json.bool(False)),
            ]),
          )
      }
    }
    "agents.children" -> {
      use members <- result.try(family.children(db, session))
      Ok(json.array(members, member_status(db, worktrees, control, _)))
    }
    "agents.siblings" ->
      case family.get(db, session) {
        Ok(Some(me)) -> {
          use members <- result.try(family.children(db, me.parent))
          members
          |> list.filter(fn(member) { member.session != session })
          |> json.array(member_status(db, worktrees, control, _))
          |> Ok
        }
        _ -> Ok(json.array([], json.string))
      }
    "agents.switch" -> {
      use child <- result.try(own_target(db, session, correspondents, args))
      use <- moved_here(ask_moved, child, "switch", args)
      service.act(db, control, session, child, "switch", args)
    }
    "agents.close" -> {
      use child <- result.try(own_target(db, session, correspondents, args))
      use <- moved_here(ask_moved, child, "close", args)
      service.act(db, control, session, child, "close", args)
    }
    "agents.cancel" -> {
      use child <- result.try(own_target(db, session, correspondents, args))
      use <- moved_here(ask_moved, child, "cancel", args)
      service.act(db, control, session, child, "cancel", args)
    }
    "agents.cancel_all" -> {
      use tree <- result.try(service.tree_flag(args))
      use children <- result.try(family.children(db, session))
      service.stop_all(
        db,
        control,
        list.map(children, fn(member) { member.session }),
        tree,
      )
    }
    "agents.messages" -> {
      use target <- result.try(addressed(db, session, correspondents, args))
      use <- moved_here(ask_moved, target, "messages", args)
      service.act(db, control, session, target, "messages", args)
    }
    "agents.search_messages" -> {
      use target <- result.try(addressed(db, session, correspondents, args))
      use <- moved_here(ask_moved, target, "search_messages", args)
      service.act(db, control, session, target, "search_messages", args)
    }
    "agents.sessions" -> {
      use #(query, cwd, limit, offset, open_only, top_level_only) <- result.try(
        rpc.args(
          args,
          {
            use query <- decode.field("query", decode.string)
            use cwd <- decode.field("cwd", decode.string)
            use limit <- decode.field("limit", decode.int)
            use offset <- decode.field("offset", decode.int)
            use open_only <- decode.optional_field(
              "open_only",
              True,
              decode.bool,
            )
            use top_level_only <- decode.optional_field(
              "top_level_only",
              False,
              decode.bool,
            )
            decode.success(#(
              query,
              cwd,
              limit,
              offset,
              open_only,
              top_level_only,
            ))
          },
          "query and cwd must be strings; limit and offset integers; open_only and top_level_only booleans",
        ),
      )
      use found <- result.try(sessions.find(
        db,
        session,
        query,
        cwd,
        open_only,
        top_level_only,
        int.max(offset, 0),
        int.clamp(limit, 1, 100),
      ))
      json.array(found, found_json(db, worktrees, control, letters, _))
      |> Ok
    }
    "agents.resources" -> {
      let to =
        decode.run(
          args,
          decode.optional_field("to", "", decode.string, decode.success),
        )
        |> result.unwrap("")
        |> string.trim
      use owners <- result.try(case to {
        "" -> resources.all(db, kernels)
        "self" -> resources.one(db, kernels, session) |> result.map(list.wrap)
        _ -> {
          let id =
            family.resolve(db, session, to)
            |> result.map(fn(address) { address.session })
            |> result.unwrap(to)
          use owner <- result.try(resources.one(db, kernels, id))
          Ok([owner])
        }
      })
      Ok(json.array(owners, resources.to_json))
    }
    "agents.delete" ->
      Error(
        "only the user deletes agents, because deleting loses the child's work. Ask them; they can delete it from the session browser. close() keeps everything and frees its kernel.",
      )
    "agents.set_role" -> {
      use role <- result.try(service.text(args, "role"))
      let target =
        decode.run(
          args,
          decode.optional_field(
            "id",
            None,
            decode.optional(decode.string),
            decode.success,
          ),
        )
        |> result.unwrap(None)
        |> option.unwrap(session)
      use _ <- result.try(
        case target == session || family.owns(db, session, target) {
          True -> Ok(Nil)
          False ->
            Error("you can only set your own, a child, or a peer you started")
        },
      )
      family.set_role(db, target, role)
      |> result.map(fn(_) { json.bool(True) })
    }
    "agents.set_verifier" -> {
      use child <- result.try(service.text(args, "id"))
      use command <- result.try(rpc.args(
        args,
        decode.optional_field(
          "command",
          None,
          decode.optional(decode.string),
          decode.success,
        ),
        "command must be a string or null",
      ))
      use _ <- result.try(
        case family.remote(db, session, child, correspondents) {
          Ok(Some(stub)) -> Error(elsewhere(stub.name, stub.host))
          _ -> Ok(Nil)
        },
      )
      use _ <- result.try(case family.get(db, child) {
        Ok(Some(member)) if member.parent == session -> Ok(Nil)
        _ -> Error("only a child's parent can change its verifier")
      })
      use change <- result.try(case option.map(command, string.trim) {
        Some("") -> Error("verifier must be a non-empty str or None")
        Some(command) ->
          Ok(#(
            command,
            "Your parent set your verifier to `"
              <> command
              <> "`; it replaces any earlier one.",
          ))
        None ->
          Ok(#(
            "",
            "Your parent cleared your verifier; mail.submit to your parent and ending your turn are no longer checked.",
          ))
      })
      use _ <- result.try(family.set_verifier(db, child, change.0))
      use _ <- result.try(
        inbox.post(db, input.note(child, "agents", change.1, change.1))
        |> result.map_error(input.refused_text),
      )
      Ok(json.bool(True))
    }
    "agents.progress" -> {
      use note <- result.try(service.text(args, "text"))
      case string.trim(note), scalars.length(note) > 512 {
        "", _ -> Error("progress text is empty")
        _, True ->
          Error("progress is at most 512 characters; mail anything longer")
        _, False -> {
          progress(note)
          Ok(json.bool(True))
        }
      }
    }
    _ -> Error("unknown agents call " <> method)
  }
}

fn own_target(
  db: storage.Storage,
  session: String,
  correspondents: family.Correspondents,
  args: dynamic.Dynamic,
) -> Result(String, String) {
  use id <- result.try(service.text(args, "id"))
  case
    family.owns(db, session, id),
    family.remote(db, session, id, correspondents)
  {
    _, Ok(Some(stub)) -> Error(elsewhere(stub.name, stub.host))
    True, _ -> Ok(id)
    False, _ ->
      Error("you can only switch, cancel or close your own children or peers")
  }
}

/// The session `args.id` names, as mail would resolve it. Reading is open to
/// every session: families only narrow who may stop whom.
fn addressed(
  db: storage.Storage,
  session: String,
  correspondents: family.Correspondents,
  args: dynamic.Dynamic,
) -> Result(String, String) {
  use id <- result.try(service.text(args, "id"))
  use destination <- result.try(family.locate(db, session, id, correspondents))
  case destination {
    identity.Here(address) -> Ok(address.session)
    identity.There(address, _, host) -> Error(elsewhere(address.name, host))
  }
}

/// What a call on a relative that lives on another daemon answers: this one
/// can't reach that daemon (it reaches this one, not the other way round).
fn elsewhere(name: String, host: String) -> String {
  name
  <> " lives on "
  <> host
  <> ", which this daemon can't reach; ask from there"
}

/// Runs `op` on the daemon `target` moved to, with the caller's own
/// arguments, once the caller was authorized here as before; `here` when
/// the session still lives on this daemon.
fn moved_here(
  ask_moved: AskMoved,
  target: String,
  op: String,
  args: dynamic.Dynamic,
  here: fn() -> Result(json.Json, String),
) -> Result(json.Json, String) {
  case
    ask_moved(
      target,
      "/extensions/agents/sessions/" <> target <> "/" <> op,
      albedo_json.encode(args),
    )
  {
    Ok(None) -> here()
    Ok(Some(answer)) -> Ok(albedo_json.to_json(answer))
    Error(reason) -> Error(reason)
  }
}

fn parent_json(db: storage.Storage, id: String, depth: Int) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("name", json.string(family.name_of(db, id))),
    #("depth", json.int(depth - 1)),
  ])
}

fn handle_json(
  db: storage.Storage,
  worktrees: Worktrees,
  session: String,
  member: Option(identity.Member),
) -> json.Json {
  json.object(handle_fields(db, worktrees, session, member))
}

fn handle_fields(
  db: storage.Storage,
  worktrees: Worktrees,
  session: String,
  member: Option(identity.Member),
) -> List(#(String, json.Json)) {
  let #(name, depth, parent) = case member {
    Some(member) -> #(member.name, member.depth, Some(member.parent))
    None -> #(family.name_of(db, session), 0, None)
  }
  let cwd = session_cwd(db, session)
  [
    #("id", json.string(session)),
    #("name", json.string(name)),
    #("depth", json.int(depth)),
    #("parent", json.nullable(parent, parent_json(db, _, depth))),
    #(
      "cwd",
      json.nullable(
        case cwd {
          "" -> None
          _ -> Some(cwd)
        },
        json.string,
      ),
    ),
    #(
      "worktree",
      json.nullable(worktrees.for_session(db, session, cwd), worktree.to_json),
    ),
  ]
}

/// A handle with its live state; a root is never closed.
fn status_json(
  db: storage.Storage,
  worktrees: Worktrees,
  control: agents.Control,
  session: String,
  member: Option(identity.Member),
) -> json.Json {
  json.object(status_fields(db, worktrees, control, session, member))
}

fn status_fields(
  db: storage.Storage,
  worktrees: Worktrees,
  control: agents.Control,
  session: String,
  member: Option(identity.Member),
) -> List(#(String, json.Json)) {
  let running = agents.running(control, session)
  let closed = family.closed(db, session) |> result.unwrap(False)
  list.append(handle_fields(db, worktrees, session, member), [
    #("running", json.bool(running)),
    #("closed", json.bool(closed)),
  ])
}

/// A snapshot as `agents.sessions()` lists it: also where it works, on which
/// model, when it last answered (unix seconds), and why a query matched it.
fn found_json(
  db: storage.Storage,
  worktrees: Worktrees,
  control: agents.Control,
  letters: mail.Letters,
  found: sessions.Found,
) -> json.Json {
  let info = found.info
  let member = family.get(db, info.id) |> result.unwrap(None)
  json.object(list.append(
    status_fields(db, worktrees, control, info.id, member),
    list.append(
      [
        #("role", json.string(family.role(db, info.id) |> result.unwrap(""))),
        #(
          "started_by",
          json.nullable(
            family.started_by(db, info.id)
              |> result.unwrap(None),
            json.string,
          ),
        ),
        #("model", json.string(info.model)),
        #("last_active", json.nullable(info.last_assistant_at, json.int)),
        #(
          "matches",
          json.array(found.hits, fn(hit) {
            json.object([
              #("seq", json.int(hit.seq)),
              #("preview", json.string(hit.preview)),
            ])
          }),
        ),
      ],
      snapshot_fields(db, letters, info.id),
    ),
  ))
}

fn snapshot_fields(
  db: storage.Storage,
  letters: mail.Letters,
  session: String,
) -> List(#(String, json.Json)) {
  let owed = letters.owed_requesters(db, session) |> result.unwrap([])
  let awaiting =
    mail.requested(db, session)
    |> result.unwrap([])
    |> list.filter(fn(target) {
      letters.owes_reply(db, target, session) == Ok(True)
    })
  let #(pinned, context_tokens) = case conversation.context_use(db, session) {
    Ok(Some(found)) -> #(found.pinned, found.prompt_tokens)
    _ -> #(False, None)
  }
  [
    #("pinned", json.bool(pinned)),
    #("owed", json.int(list.length(owed))),
    #("awaiting", json.int(list.length(awaiting))),
    #("context_tokens", json.nullable(context_tokens, json.int)),
  ]
}

fn member_status(
  db: storage.Storage,
  worktrees: Worktrees,
  control: agents.Control,
  member: identity.Member,
) -> json.Json {
  status_json(db, worktrees, control, member.session, Some(member))
}

/// The host capabilities this extension uses: it spawns and controls sessions,
/// posts and reads their mail, gives children worktrees through the host's
/// worktree service, and reaches sessions
/// that moved to another daemon. It lists every session and a session's
/// children, reads and searches other sessions' messages, and reads where
/// every session's kernel and jobs run.
pub const uses = [
  capability.Correspondence,
  capability.History,
  capability.Inbox,
  capability.KernelResources,
  capability.Mail,
  capability.Remote,
  capability.SessionControl,
  capability.Sessions,
  capability.Worktrees,
]
