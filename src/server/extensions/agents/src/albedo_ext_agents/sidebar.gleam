//// The parent's open children for the chat sidebar (albedo-suite): one row
//// per child that is not closed, in creation order. A child whose stored
//// stage is mid-turn is active; one waiting for input stays listed, plain.
//// The stage is what the daemon persists at each turn boundary, so the
//// sidebar reads it without waking any child.

import albedo_sdk/extension
import albedo_sdk/family
import albedo_sdk/history as conversation
import albedo_sdk/page
import albedo_sdk/session_info
import gleam/list
import gleam/result
import gleam/uri

pub fn sidebar(sidebar: extension.Sidebar) -> Result(page.Glance, String) {
  use members <- result.try(family.children(sidebar.storage, sidebar.session))
  let open = list.filter(members, fn(member) { !member.closed })
  use rows <- result.map(
    list.try_map(open, fn(member) {
      use info <- result.map(conversation.get(sidebar.storage, member.session))
      case info.stage {
        session_info.Model | session_info.Tool ->
          page.Row(member.name, member.name, "working", page.Active, "")
        _ -> page.Row(member.name, member.name, "idle", page.Plain, "")
      }
    }),
  )
  page.Glance("agents", rows)
}

pub fn resource_url(session: String, _workspace: String) -> String {
  "/sessions/" <> uri.percent_encode(session)
}
