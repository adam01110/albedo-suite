//// The session listing's money fields (http_session_collection.read) against
//// an independent model of the ledger: each row's session_cost_usd, the first
//// page's total_cost and partial flag, and both under every filter and page.

import albedo/history/conversation
import albedo/history/tool_count
import albedo/http/http_session_collection
import albedo/runtime
import albedo/session/family
import albedo/session/registry
import albedo/session/session_configuration
import albedo/session/session_workspace
import albedo/storage/core_store
import albedo/usage/session_cost
import albedo_model as types
import albedo_sdk/oauth_flows
import albedo_sdk/session_info
import albedo_sdk/store
import albedo_sqlite
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mist
import proptest
import qcheck
import session_cost_prop.{type Cost, type Row}
import sqlight

/// The registry host, built as the tuple the handlers read the ledger from.
@external(erlang, "session_totals_ffi", "runtime")
fn fake_runtime(ledger: store.Store) -> runtime.Runtime

/// A request body the non-watch path never opens.
@external(erlang, "session_totals_ffi", "connection")
fn fake_connection() -> mist.Connection

const ids = ["a", "b", "c", "d"]

pub type Case {
  Case(
    catalog: List(#(#(String, String), Cost)),
    rows: List(Row),
    archived: List(String),
    opens: List(#(String, Int)),
    limit: Int,
    search: Option(String),
  )
}

pub type Item {
  Item(id: String, cost: Option(Float))
}

pub type Listing {
  Listing(
    items: List(Item),
    next: Option(String),
    /// The first page's `total_cost`: the total and whether any session was
    /// left out of it.
    total: Option(#(Float, Bool)),
  )
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn case_generator() -> qcheck.Generator(Case) {
  use catalog, rows, archived, opens, limit, search <- qcheck.map6(
    session_cost_prop.catalog(),
    qcheck.generic_list(session_cost_prop.row(), qcheck.bounded_int(0, 8)),
    qcheck.generic_list(pick(ids), qcheck.bounded_int(0, 2))
      |> qcheck.map(list.unique),
    qcheck.fixed_length_list_from(qcheck.bounded_int(0, 2), 4),
    qcheck.bounded_int(1, 3),
    qcheck.from_weighted_generators(#(6, qcheck.return(None)), [
      #(2, qcheck.return(Some("zz"))),
      #(2, qcheck.return(Some("a"))),
    ]),
  )
  Case(catalog, rows, archived, list.zip(ids, opens), limit, search)
}

// Ledger and catalog setup.

const schema = ""

fn insert(ledger: store.Store, row: Row) -> Nil {
  let count = fn(value) { sqlight.nullable(sqlight.int, value) }
  list.repeat(Nil, row.count)
  |> list.each(fn(_) {
    let assert Ok(_) =
      store.writing(ledger, fn(db) {
        albedo_sqlite.run(
          "INSERT INTO provider_requests(session,kind,profile,provider,model,started_ms,finished_ms,outcome,head_hash,inputs,input_tokens,cached_input_tokens,cache_creation_tokens,cache_write_5m_tokens,cache_write_1h_tokens,output_tokens) VALUES(?,'turn',?,?,?,0,0,?,'',0,?,?,?,?,?,?)",
          on: db,
          with: [
            sqlight.text(row.session),
            sqlight.text(row.profile),
            sqlight.text("chat_completions:https://p.example/v1"),
            sqlight.text(row.model),
            sqlight.text(case row.ok {
              True -> "ok"
              False -> "error"
            }),
            count(row.input),
            count(row.cached),
            count(row.created),
            count(row.w5),
            count(row.w1),
            count(row.output),
          ],
        )
      })
    Nil
  })
}

fn rate_json(rate: session_cost_prop.Rate) -> json.Json {
  case rate {
    session_cost_prop.Num(value) -> json.float(value)
    session_cost_prop.Whole(value) -> json.int(value)
    session_cost_prop.Bad -> json.string("free")
  }
}

fn rates_json(
  rates: List(#(String, session_cost_prop.Rate)),
  extra: List(#(String, json.Json)),
) -> json.Json {
  list.map(rates, fn(entry) { #(entry.0, rate_json(entry.1)) })
  |> list.append(extra)
  |> json.object
}

fn cost_json(cost: Cost) -> json.Json {
  let tiers =
    list.map(cost.tiers, fn(tier) {
      rates_json(tier.1, [
        #(
          "tier",
          json.object([
            #("type", json.string("context")),
            #("size", json.int(tier.0)),
          ]),
        ),
      ])
    })
  let extra = case tiers {
    [] -> []
    _ -> [#("tiers", json.preprocessed_array(tiers))]
  }
  let extra = case cost.over_200k {
    None -> extra
    Some(rates) -> [#("context_over_200k", rates_json(rates, [])), ..extra]
  }
  rates_json(cost.rates, extra)
}

fn catalog_json(catalog: List(#(#(String, String), Cost))) -> String {
  ["p1", "p2"]
  |> list.map(fn(provider) {
    let models =
      list.filter_map(catalog, fn(entry) {
        let #(#(owner, model), cost) = entry
        case owner == provider {
          True ->
            Ok(#(
              model,
              json.object([
                #("id", json.string(model)),
                #("cost", cost_json(cost)),
              ]),
            ))
          False -> Error(Nil)
        }
      })
    #(
      provider,
      json.object([
        #("api", json.string("https://p.example/v1")),
        #("npm", json.string("@ai-sdk/openai-compatible")),
        #("models", json.object(models)),
      ]),
    )
  })
  |> json.object
  |> json.to_string
}

/// The tables a session's configuration, workspace and selection reads need;
/// the daemon's own startup makes them through its extension install.
fn prepare(ledger: store.Store) -> Nil {
  let assert Ok(_) =
    store.query(ledger, fn(db) { session_configuration.initialise_in(db) })
  let assert Ok(_) =
    store.query(ledger, fn(db) { session_workspace.initialise_in(db) })
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      albedo_sqlite.exec(
        "CREATE TABLE IF NOT EXISTS session_extensions(session TEXT NOT NULL,name TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),PRIMARY KEY(session,name));",
        on: db,
      )
    })
  Nil
}

fn create(ledger: store.Store, id: String) -> Nil {
  let assert Ok(_) =
    conversation.create(
      ledger,
      session_info.Info(
        id,
        id,
        "/work",
        "p1",
        "m1",
        types.Responses,
        session_info.Idle,
        None,
        None,
        False,
        None,
      ),
    )
  Nil
}

/// A registry that holds no live session and answers with the given host.
fn fake_registry(host: runtime.Runtime) -> Subject(registry.Message) {
  let assert Ok(started) =
    actor.new(host)
    |> actor.on_message(fn(host, message) {
      case message {
        registry.Host(reply) -> {
          let _ = process.send(reply, Ok(host))
          actor.continue(host)
        }
        registry.Existing(_, reply) -> {
          let _ = process.send(reply, Ok(None))
          actor.continue(host)
        }
        _ -> actor.continue(host)
      }
    })
    |> actor.start
  started.data
}

fn config(home: String) -> registry.Config {
  let assert Ok(oauth) = oauth_flows.start()
  registry.Config(
    home: home,
    token: "proptest-token",
    idle_ms: 60_000,
    unload_ms: 60_000,
    budget_kb: 1024,
    state_expiry_seconds: 3600,
    image_retention_seconds: 3600,
    tick_ms: 60_000,
    oauth: oauth,
  )
}

fn item_decoder() -> decode.Decoder(Item) {
  use id <- decode.field("id", decode.string)
  use cost <- decode.optional_field(
    "session_cost_usd",
    None,
    decode.optional(decode.float),
  )
  decode.success(Item(id, cost))
}

fn total_decoder() -> decode.Decoder(#(Float, Bool)) {
  use usd <- decode.field("usd", decode.float)
  use partial <- decode.field("partial", decode.bool)
  decode.success(#(usd, partial))
}

fn listing_decoder() -> decode.Decoder(Listing) {
  use items <- decode.field("items", decode.list(item_decoder()))
  use next <- decode.optional_field(
    "next",
    None,
    decode.optional(decode.string),
  )
  use total <- decode.optional_field(
    "total_cost",
    None,
    decode.optional(total_decoder()),
  )
  decode.success(Listing(items, next, total))
}

fn body_text(response: mist.ResponseData) -> String {
  case response {
    mist.Bytes(tree) ->
      bytes_tree.to_bit_array(tree)
      |> bit_array.to_string
      |> result.unwrap("")
    _ -> ""
  }
}

fn listing(
  cfg: registry.Config,
  reg: Subject(registry.Message),
  parameters: List(#(String, String)),
) -> Listing {
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/sessions")
    |> request.set_query(parameters)
    |> request.set_body(<<>>)
  let live = request.new() |> request.set_body(fake_connection())
  let response = http_session_collection.read(cfg, reg, req, live)
  let text = body_text(response.body)
  case json.parse(text, listing_decoder()) {
    Ok(listing) -> listing
    Error(_) -> panic as { "unreadable listing: " <> text }
  }
}

// The model: pricing rules are priced by session_cost_prop, which is written
// from the documented rules rather than from the pricer.

fn session_rows(c: Case, id: String) -> List(Row) {
  list.filter(c.rows, fn(row) { row.session == id })
}

fn expected(c: Case, id: String) -> Option(Float) {
  session_cost_prop.model_total(c.catalog, session_rows(c, id))
}

fn show(value: Option(Float)) -> String {
  case value {
    None -> "unknown"
    Some(x) -> float.to_string(x)
  }
}

fn expect(what: String, found: Option(Float), wanted: Option(Float)) -> Nil {
  case session_cost_prop.close(found, wanted) {
    True -> Nil
    False ->
      panic as {
        what <> ": listing " <> show(found) <> ", model " <> show(wanted)
      }
  }
}

/// The stored total: every session that has requests, priced as its rows are.
fn expected_total(c: Case) -> #(Float, Bool) {
  list.fold(ids, #(0.0, False), fn(acc, id) {
    case list.length(session_rows(c, id)) {
      0 -> acc
      _ ->
        case expected(c, id) {
          Some(cost) -> #(acc.0 +. cost, acc.1)
          None -> #(acc.0, True)
        }
    }
  })
}

fn expect_total(
  what: String,
  found: Option(#(Float, Bool)),
  wanted: #(Float, Bool),
) -> Nil {
  case found {
    None -> panic as { what <> ": no total on the first page" }
    Some(#(usd, partial)) -> {
      expect(what <> " total", Some(usd), Some(wanted.0))
      case partial == wanted.1 {
        True -> Nil
        False ->
          panic as {
            what
            <> ": partial "
            <> bool_text(partial)
            <> ", model "
            <> bool_text(wanted.1)
          }
      }
    }
  }
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn filters(c: Case) -> List(#(String, String)) {
  let search = case c.search {
    None -> []
    Some(value) -> [#("search", value)]
  }
  list.append([#("scope", "all")], search)
}

fn matches_search(c: Case, id: String) -> Bool {
  case c.search {
    None -> True
    Some(value) -> string.starts_with(id, value)
  }
}

/// The cost of one row of a listing page.
fn row_cost(item: Item) -> Option(Float) {
  item.cost
}

fn walk(
  cfg: registry.Config,
  reg: Subject(registry.Message),
  base_parameters: List(#(String, String)),
  limit: Int,
  pages: Int,
  seen: List(Item),
  first_total: Option(#(Float, Bool)),
  next: Option(String),
) -> #(List(Item), Option(#(Float, Bool))) {
  let parameters = case next {
    None -> list.append(base_parameters, [#("limit", int.to_string(limit))])
    Some(token) ->
      list.append(base_parameters, [
        #("limit", int.to_string(limit)),
        #("next", token),
      ])
  }
  let page = listing(cfg, reg, parameters)
  let total = case next, first_total, page.total {
    None, _, found -> found
    Some(_), _, Some(_) -> panic as "a continuation page carried total_cost"
    Some(_), found, None -> found
  }
  let seen = list.append(seen, page.items)
  case page.next {
    None -> #(seen, total)
    Some(_) if pages <= 0 -> panic as "listing does not end"
    Some(token) ->
      walk(
        cfg,
        reg,
        base_parameters,
        limit,
        pages - 1,
        seen,
        total,
        Some(token),
      )
  }
}

pub fn main() -> Nil {
  proptest.check(
    "listing money fields match the ledger model",
    100,
    case_generator(),
    fn(c) {
      let home =
        "/tmp/albedo-proptest-listing-" <> int.to_string(proptest.unique())
      proptest.remove_tree(home)
      proptest.putenv("ALBEDO_HOME", home)
      proptest.write_file(
        home <> "/models.json",
        <<catalog_json(c.catalog):utf8>>,
        1_700_000_000,
      )
      let assert Ok(ledger) =
        store.start(
          home <> "/ledger.db",
          albedo_sqlite.exec(schema, on: _),
          core_store.tables(),
        )
      let assert Ok(_) = conversation.initialise(ledger)
      let assert Ok(_) = family.initialise(ledger)
      prepare(ledger)
      list.each(ids, create(ledger, _))
      // One activity stamp, so the listing's order is its id order.
      let assert Ok(_) =
        store.query(ledger, fn(db) {
          albedo_sqlite.exec("UPDATE sessions SET activity_at=0", on: db)
        })
      list.each(c.rows, insert(ledger, _))
      list.each(c.opens, fn(entry) {
        let assert Ok(_) =
          store.writing(ledger, fn(db) {
            albedo_sqlite.run(
              "UPDATE sessions SET opens=? WHERE id=?",
              on: db,
              with: [
                sqlight.int(entry.1),
                sqlight.text(entry.0),
              ],
            )
          })
        Nil
      })
      list.each(c.archived, fn(id) {
        let assert Ok(_) =
          store.writing(ledger, fn(db) {
            albedo_sqlite.run(
              "UPDATE sessions SET archived=1 WHERE id=?",
              on: db,
              with: [
                sqlight.text(id),
              ],
            )
          })
        proptest.bump("archived")
      })
      let reg = fake_registry(fake_runtime(ledger))
      let cfg = config(home)

      // One page holding every session: each row is priced on its own.
      let all = listing(cfg, reg, list.append(filters(c), [#("limit", "50")]))
      let expected_ids = list.filter(ids, matches_search(c, _))
      assert list.map(all.items, fn(item) { item.id }) == expected_ids
      list.each(all.items, fn(item) {
        let wanted = expected(c, item.id)
        proptest.bump(case wanted {
          None -> "unknown_row"
          Some(_) -> "priced_row"
        })
        expect("row " <> item.id, row_cost(item), wanted)
      })
      let wanted = expected_total(c)
      expect_total("all", all.total, wanted)
      proptest.bump(case wanted.1 {
        True -> "partial_total"
        False -> "known_total"
      })

      // Archived sessions leave the rows but not the ledger total.
      let unarchived =
        listing(
          cfg,
          reg,
          list.append(filters(c), [#("archived", "false"), #("limit", "50")]),
        )
      assert list.map(unarchived.items, fn(item) { item.id })
        == list.filter(expected_ids, fn(id) { !list.contains(c.archived, id) })
      expect_total("archived=false", unarchived.total, wanted)

      // A filter that matches nothing still totals the whole ledger.
      let none =
        listing(cfg, reg, [
          #("scope", "all"),
          #("search", "no-such-session"),
          #("limit", "50"),
        ])
      assert none.items == []
      expect_total("empty filter", none.total, wanted)

      // Paging reads the same rows, and only the first page carries the total.
      let #(walked, total) =
        walk(cfg, reg, filters(c), c.limit, 40, [], None, None)
      assert list.map(walked, fn(item) { item.id }) == expected_ids
      list.each(walked, fn(item) {
        expect("paged row " <> item.id, row_cost(item), expected(c, item.id))
      })
      expect_total("paged", total, wanted)

      // The frequent sort pages the same rows: one page each, no repeats.
      let #(frequent, frequent_total) = {
        let sorted = list.append(filters(c), [#("sort", "frequent")])
        walk(cfg, reg, sorted, c.limit, 40, [], None, None)
      }
      let walked_ids = list.map(frequent, fn(item) { item.id })
      assert list.unique(walked_ids) == walked_ids
      assert list.sort(walked_ids, string.compare)
        == list.sort(expected_ids, string.compare)
      list.each(frequent, fn(item) {
        expect("frequent row " <> item.id, row_cost(item), expected(c, item.id))
      })
      expect_total("frequent", frequent_total, wanted)
      proptest.bump("frequent_sort")

      // archived=true lists the archived sessions alone, with the same total.
      let archived_only =
        listing(
          cfg,
          reg,
          list.append(filters(c), [#("archived", "true"), #("limit", "50")]),
        )
      assert list.map(archived_only.items, fn(item) { item.id })
        == list.filter(expected_ids, fn(id) { list.contains(c.archived, id) })
      expect_total("archived=true", archived_only.total, wanted)

      store.close(ledger)
      proptest.remove_tree(home)
    },
  )

  catalog_revision_observation()
  tool_counts()
}

// The session's tool count: the value `session_tool_calls` serves.

pub type Turn {
  Turn(
    /// One of the session's committed batches.
    inputs: List(types.Input),
    /// How many entries in the batch are tool results.
    results: Int,
  )
}

pub type Counts {
  Counts(turns: List(Turn))
}

fn mentions() -> qcheck.Generator(String) {
  qcheck.from_generators(
    pick([
      "",
      "tool_output",
      "why does tool_output appear here?",
      "tool_output is the tag",
    ]),
    [
      qcheck.bounded_int(0, 3)
      |> qcheck.map(fn(n) {
        string.repeat("padding ", n)
        <> "tool_output"
        <> string.repeat(" tail", n)
      }),
    ],
  )
}

fn output() -> qcheck.Generator(String) {
  qcheck.from_weighted_generators(#(8, mentions()), [
    #(
      2,
      qcheck.bounded_int(0, 40)
        |> qcheck.map(fn(n) { string.repeat("x", times: n) }),
    ),
  ])
}

fn entry() -> qcheck.Generator(#(types.Input, Int)) {
  qcheck.from_weighted_generators(
    #(2, mentions() |> qcheck.map(fn(text) { #(types.User(text), 0) })),
    [
      #(2, mentions() |> qcheck.map(fn(text) { #(types.Assistant(text), 0) })),
      #(
        7,
        qcheck.map2(qcheck.bounded_int(0, 99), output(), fn(n, text) {
          #(types.ToolOutput("call-" <> int.to_string(n), text, []), 1)
        }),
      ),
    ],
  )
}

fn turn() -> qcheck.Generator(Turn) {
  use entries <- qcheck.map(qcheck.generic_list(
    entry(),
    qcheck.bounded_int(0, 4),
  ))
  Turn(
    list.map(entries, fn(entry) { entry.0 }),
    list.fold(entries, 0, fn(total, entry) { total + entry.1 }),
  )
}

fn counts_generator() -> qcheck.Generator(Counts) {
  use turns <- qcheck.map(qcheck.generic_list(turn(), qcheck.bounded_int(0, 4)))
  Counts(turns)
}

fn tool_counts_ledger() -> store.Store {
  let assert Ok(ledger) =
    store.start(":memory:", fn(_) { Ok(Nil) }, core_store.tables())
  let assert Ok(_) = conversation.initialise(ledger)
  list.each(ids, create(ledger, _))
  ledger
}

fn show_int(value: Option(Int)) -> String {
  case value {
    Some(count) -> int.to_string(count)
    None -> "unreadable"
  }
}

/// Each session commits its own slice of the generated turns, and the count
/// is the tool results in that session alone.
pub fn tool_counts() -> Nil {
  proptest.check(
    "session tool counts match the committed results",
    100,
    counts_generator(),
    fn(c) {
      let ledger = tool_counts_ledger()
      let turns = list.filter(c.turns, fn(turn) { turn.inputs != [] })
      let every_other =
        list.index_map(turns, fn(turn, index) { #(turn, index) })
        |> list.filter(fn(entry) { int.is_even(entry.1) })
        |> list.map(fn(entry) { entry.0 })
      let slices = [
        #("a", turns),
        #("b", list.take(turns, 1)),
        #("c", []),
        #("d", every_other),
      ]
      list.each(slices, fn(slice) {
        let #(id, mine) = slice
        list.each(mine, fn(turn) {
          let assert Ok(_) =
            conversation.commit(ledger, id, turn.inputs, session_info.Tool)
          Nil
        })
        let expected =
          list.fold(mine, 0, fn(total, turn) { total + turn.results })
        proptest.bump(case expected {
          0 -> "no_results"
          _ -> "has_results"
        })
        case tool_count.total(ledger, id) {
          Some(count) if count == expected -> Nil
          found ->
            panic as {
              "session "
              <> id
              <> ": count "
              <> show_int(found)
              <> ", model "
              <> int.to_string(expected)
            }
        }
      })
      store.close(ledger)
    },
  )
}

// A discovery observation, not an assertion: a catalog rewrite that keeps the
// file's size and second leaves the cached estimate at the old prices.

const probe_catalog_a =
  "{\"p\":{\"api\":\"https://p.example/v1\",\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"m\":{\"id\":\"m\",\"cost\":{\"input\":1,\"output\":2}}}}}"

/// The same catalog with one price digit changed: a different file of the
/// same length.
const probe_catalog_b =
  "{\"p\":{\"api\":\"https://p.example/v1\",\"npm\":\"@ai-sdk/openai-compatible\",\"models\":{\"m\":{\"id\":\"m\",\"cost\":{\"input\":3,\"output\":2}}}}}"

fn probe_row(ledger: store.Store, session: String) -> Nil {
  let assert Ok(_) =
    store.writing(ledger, fn(db) {
      albedo_sqlite.run(
        "INSERT INTO provider_requests(session,kind,profile,provider,model,started_ms,finished_ms,outcome,head_hash,inputs,input_tokens,output_tokens) VALUES(?,'turn','p','chat_completions:https://p.example/v1','m',0,0,'ok','',0,1000000,0)",
        on: db,
        with: [sqlight.text(session)],
      )
    })
  Nil
}

/// Prints what a catalog rewrite that keeps the file's size and second does to
/// a cached estimate, beside the same rows priced against the new catalog.
/// One million input tokens at the old rate of 1 and the new rate of 3.
pub fn catalog_revision_observation() -> Nil {
  let home =
    "/tmp/albedo-proptest-revision-" <> int.to_string(proptest.unique())
  proptest.remove_tree(home)
  proptest.putenv("ALBEDO_HOME", home)
  let path = home <> "/models.json"
  let same_size =
    string.byte_size(probe_catalog_a) == string.byte_size(probe_catalog_b)
  proptest.write_file(path, <<probe_catalog_a:utf8>>, 1_700_000_000)
  let assert Ok(ledger) =
    store.start(home <> "/ledger.db", fn(_) { Ok(Nil) }, core_store.tables())
  let assert Ok(_) = conversation.initialise(ledger)
  probe_row(ledger, "a")
  let before = session_cost.total(ledger, "a")
  let _ = store.query(ledger, fn(_) { Nil })
  // Same length, same second: the cache's revision string does not move.
  proptest.write_file(path, <<probe_catalog_b:utf8>>, 1_700_000_000)
  probe_row(ledger, "b")
  let cached = session_cost.total(ledger, "a")
  let uncached = session_cost.total(ledger, "b")
  // A second later the revision moves and the cached session reprices too.
  proptest.write_file(path, <<probe_catalog_b:utf8>>, 1_700_000_001)
  let moved = session_cost.total(ledger, "a")
  io.println(
    "catalog rewrite observation: same_size="
    <> bool_text(same_size)
    <> " before="
    <> show(before)
    <> " cached_after_rewrite="
    <> show(cached)
    <> " uncached_after_rewrite="
    <> show(uncached)
    <> " cached_after_a_second="
    <> show(moved),
  )
  store.close(ledger)
  proptest.remove_tree(home)
}
