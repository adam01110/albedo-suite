//// Session-scoped durable questions; terminal transitions have one winner.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import sqlight

pub type Item {
  Item(
    id: Int,
    session: String,
    question: String,
    options: List(String),
    status: String,
    answer: String,
    revision: Int,
  )
}

const columns = "id,session,question,options,status,answer,revision"

const schema =
  "CREATE TABLE IF NOT EXISTS questions (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 session TEXT NOT NULL,
 question TEXT NOT NULL,
 options TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','answered','cancelled')),
 answer TEXT NOT NULL DEFAULT '',
 revision INTEGER NOT NULL DEFAULT 1
); CREATE INDEX IF NOT EXISTS questions_session ON questions(session,status);"

pub fn initialise(storage: store.Store) -> Result(Nil, String) {
  store.query(storage, store.exec(_, schema))
}

fn decoder() -> decode.Decoder(Item) {
  use id <- decode.field(0, decode.int)
  use session <- decode.field(1, decode.string)
  use question <- decode.field(2, decode.string)
  use options <- decode.field(3, decode.string)
  use status <- decode.field(4, decode.string)
  use answer <- decode.field(5, decode.string)
  use revision <- decode.field(6, decode.int)
  use options <- decode.then({
    case json.parse(options, decode.list(decode.string)) {
      Ok(options) -> decode.success(options)
      Error(_) -> decode.failure([], "stored question options")
    }
  })
  decode.success(Item(id, session, question, options, status, answer, revision))
}

fn one(items: List(Item)) -> Result(Item, String) {
  list.first(items)
  |> result.replace_error("question not found or already changed")
}

pub fn pending(
  storage: store.Store,
  session: String,
) -> Result(List(Item), String) {
  store.read(
    storage,
    "SELECT "
      <> columns
      <> " FROM questions WHERE session=? AND status='pending' ORDER BY id LIMIT 32",
    [sqlight.text(session)],
    decoder(),
  )
}

pub fn get(
  storage: store.Store,
  session: String,
  id: Int,
) -> Result(Item, String) {
  store.read(
    storage,
    "SELECT " <> columns <> " FROM questions WHERE session=? AND id=?",
    [sqlight.text(session), sqlight.int(id)],
    decoder(),
  )
  |> result.try(one)
}

pub fn ask(
  storage: store.Store,
  session: String,
  question: String,
  options: List(String),
) -> Result(Item, String) {
  case
    string.trim(question) == ""
    || string.byte_size(question) > 4096
    || list.length(options) > 16
    || !list.all(options, fn(x) {
      string.trim(x) != "" && string.byte_size(x) <= 512
    })
  {
    True ->
      Error(
        "question must be nonempty and <=4096 bytes; at most 16 nonempty options of <=512 bytes",
      )
    False ->
      store.query(storage, fn(db) {
        // The count and insert share the store owner, bounding a session's inbox.
        store.rows(
          db,
          "INSERT INTO questions(session,question,options) SELECT ?,?,? WHERE (SELECT COUNT(*) FROM questions WHERE session=? AND status='pending') < 32 RETURNING "
            <> columns,
          [
            sqlight.text(session),
            sqlight.text(question),
            sqlight.text(json.to_string(json.array(options, json.string))),
            sqlight.text(session),
          ],
          decoder(),
        )
        |> result.try(one)
      })
  }
}

pub fn finish(
  storage: store.Store,
  current: Item,
  status: String,
  answer: String,
) -> Result(Item, String) {
  case
    current.status != "pending"
    || string.byte_size(answer) > 8192
    || { status == "answered" && string.trim(answer) == "" }
  {
    True ->
      Error(
        "only a pending question can be answered or cancelled; answer must be nonempty and <=8192 bytes",
      )
    False ->
      store.read(
        storage,
        "UPDATE questions SET status=?,answer=?,revision=revision+1 WHERE session=? AND id=? AND revision=? AND status='pending' RETURNING "
          <> columns,
        [
          sqlight.text(status),
          sqlight.text(answer),
          sqlight.text(current.session),
          sqlight.int(current.id),
          sqlight.int(current.revision),
        ],
        decoder(),
      )
      |> result.try(one)
  }
}

pub fn value(item: Item) -> json.Json {
  json.object([
    #("id", json.string(int.to_string(item.id))),
    #("session_id", json.string(item.session)),
    #("question", json.string(item.question)),
    #("options", json.array(item.options, json.string)),
    #("status", json.string(item.status)),
    #("answer", case item.status {
      "answered" -> json.string(item.answer)
      _ -> json.null()
    }),
    #("revision", json.int(item.revision)),
  ])
}
