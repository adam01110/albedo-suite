//// A host context for route-level property tests of suite extensions: real
//// capability values over a temporary store, so a suite route can be called
//// the way the host calls it, and the fields a route under test does not read
//// get inert stand-ins.
////
//// The route under test is the one an extension declares in its ToolPlugin,
//// called as `#(namespace, route)`. A route that needs the store gets
//// `storage.host(ledger)`, which is unscoped, so a capability refusal cannot
//// stand in for the behaviour under test.

import albedo/kernel/resources
import albedo/session/command_state
import albedo/session/family as daemon_family
import albedo/session/inbox
import albedo/session/session_control
import albedo/storage/mail
import albedo/workspace/worktree
import albedo_sdk/host
import albedo_sdk/storage
import albedo_sdk/store
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}

/// A route as an extension declares it: its method namespace and handler.
pub type Handle =
  fn(host.Context, String, Dynamic) -> Result(json.Json, #(String, String))

/// A context for `session` working in `workspace`, over `ledger`.
pub fn context(
  ledger: store.Store,
  session: String,
  workspace: String,
) -> host.Context {
  host.Context(
    inbox.extension_inbox(),
    mail.letters(),
    session,
    workspace,
    [],
    worktree.capability([], []),
    [],
    fn(_) { Nil },
    fn(_, _, _) { Error("property tests read no shell output") },
    fn(_, _, _) { Error("property tests send no mail") },
    fn(_, _, _) { Ok(None) },
    daemon_family.correspondents(ledger),
    command_state.context(session),
    session_control.call,
    fn(_, _) { Error("property tests stage no media") },
    resources.capability(),
    worktree.origins(),
    storage.host(ledger),
  )
}

/// Calls `route` on a JSON argument, as the kernel's RPC boundary does.
pub fn call(
  route: Handle,
  context: host.Context,
  method: String,
  args: json.Json,
) -> Result(json.Json, #(String, String)) {
  let assert Ok(dynamic) = json.parse(json.to_string(args), decode.dynamic)
  route(context, method, dynamic)
}
