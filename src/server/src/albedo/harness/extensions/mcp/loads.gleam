//// The configured MCP servers each lazy session loaded (albedo-suite): one
//// row per server name, kept until the session is deleted, so the sidebar
//// shows servers that are loaded and those that were loaded earlier. The
//// configuration bounds the names, so a session holds few rows.

import albedo/harness/sdk/page
import albedo/harness/sdk/storage
import albedo/transfer
import albedo_clock
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/uri
import sqlight

pub type Load {
  Load(server: String, loaded: Bool)
}

const schema =
  "
CREATE TABLE IF NOT EXISTS mcp_loads (
 session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 server TEXT NOT NULL,
 loaded INTEGER NOT NULL,
 first_at INTEGER NOT NULL,
 last_at INTEGER NOT NULL,
 PRIMARY KEY(session, server)
) WITHOUT ROWID;
"

pub fn initialise(handle: storage.Storage) -> Result(Nil, String) {
  storage.query(handle, storage.exec(_, schema))
}

/// `adapter` carrying moved sessions' load history too.
pub fn transferred(adapter: transfer.Adapter) -> transfer.Adapter {
  transfer.Adapter(..adapter, tables: [
    transfer.Table("mcp_loads", 1, "session IN (SELECT id FROM transfer_scope)"),
    ..adapter.tables
  ])
}

pub fn forget(db: sqlight.Connection, session: String) -> Result(Nil, String) {
  storage.forget_session(db, ["mcp_loads"], session)
}

/// Notes that `server` was loaded or unloaded; a server keeps the place its
/// first load gave it.
pub fn record(
  handle: storage.Storage,
  session: String,
  server: String,
  loaded: Bool,
) -> Result(Nil, String) {
  let now = albedo_clock.system_seconds()
  storage.write(
    handle,
    "INSERT INTO mcp_loads(session,server,loaded,first_at,last_at) VALUES(?,?,?,?,?) ON CONFLICT(session,server) DO UPDATE SET loaded=excluded.loaded,last_at=excluded.last_at",
    [
      sqlight.text(session),
      sqlight.text(server),
      sqlight.bool(loaded),
      sqlight.int(now),
      sqlight.int(now),
    ],
  )
}

/// A new manager starts with nothing loaded, so earlier loads become
/// history.
pub fn reset(handle: storage.Storage, session: String) -> Result(Nil, String) {
  storage.write(
    handle,
    "UPDATE mcp_loads SET loaded=0 WHERE session=? AND loaded=1",
    [sqlight.text(session)],
  )
}

/// The session's servers in the order it first loaded them.
pub fn list(
  handle: storage.Storage,
  session: String,
) -> Result(List(Load), String) {
  storage.read(
    handle,
    "SELECT server,loaded FROM mcp_loads WHERE session=? ORDER BY first_at,server LIMIT 256",
    [sqlight.text(session)],
    {
      use server <- decode.field(0, decode.string)
      use loaded <- decode.field(1, sqlight.decode_bool())
      decode.success(Load(server, loaded))
    },
  )
}

/// Loaded servers are active; unloaded ones stay listed, plain.
pub fn sidebar(
  handle: storage.Storage,
  session: String,
  _workspace: String,
) -> Result(page.Glance, String) {
  use items <- result.map(list(handle, session))
  page.Glance(
    "mcp",
    list.map(items, fn(item) {
      case item.loaded {
        True -> page.Row(item.server, item.server, "loaded", page.Active, "")
        False -> page.Row(item.server, item.server, "unloaded", page.Plain, "")
      }
    }),
  )
}

pub fn resource_url(session: String, _workspace: String) -> String {
  "/sessions/" <> uri.percent_encode(session) <> "/catalog?kind=mcp"
}
