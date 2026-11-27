import albedo_sqlite
import albedo_sqlite/marmot_script
import albedo_sqlite/template
import gleam/dynamic/decode
import gleam/option.{type Option}
import sqlight

/// Shared return type for queries in this directory:
///   src/albedo/accounts/quota/sql/history.sql
///   src/albedo/accounts/quota/sql/latest.sql
pub type SampleRow {
  SampleRow(
    id: Int,
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
    source: String,
  )
}

fn sample_row_decoder() -> decode.Decoder(SampleRow) {
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
  decode.success(SampleRow(
    id:,
    account:,
    provider:,
    plan:,
    limit_id:,
    label:,
    used_percent:,
    window_label:,
    window_seconds:,
    resets_at:,
    scope:,
    status:,
    error:,
    observed_at:,
    source:,
  ))
}

/// Generated from src/albedo/accounts/quota/sql/before_filter.sql
pub const before_filter = "AND id < ?"

/// Generated from src/albedo/accounts/quota/sql/create_quota_samples.sql
pub fn create_quota_samples(db db: sqlight.Connection) -> Result(Nil, String) {
  albedo_sqlite.exec(
    marmot_script.source(
      "src/albedo/accounts/quota/sql/create_quota_samples.sql",
      "CREATE TABLE IF NOT EXISTS quota_sample (\n id INTEGER PRIMARY KEY AUTOINCREMENT,\n account TEXT NOT NULL,\n provider TEXT NOT NULL,\n plan TEXT,\n limit_id TEXT NOT NULL DEFAULT '',\n label TEXT NOT NULL DEFAULT '',\n used_percent REAL,\n window_label TEXT,\n window_seconds INTEGER,\n resets_at INTEGER,\n scope TEXT,\n status TEXT NOT NULL DEFAULT '',\n error TEXT,\n observed_at INTEGER NOT NULL,\n source TEXT NOT NULL DEFAULT 'poll'\n);\nCREATE INDEX IF NOT EXISTS quota_sample_latest\n ON quota_sample(account, provider, limit_id, id);\nCREATE INDEX IF NOT EXISTS quota_sample_report\n ON quota_sample(account, provider, id);",
    ),
    on: db,
  )
}

/// Generated from src/albedo/accounts/quota/sql/history.sql
pub fn history(
  db db: sqlight.Connection,
  predicates predicates: List(template.Predicate),
  page_size page_size: Int,
) -> Result(List(SampleRow), String) {
  albedo_sqlite.rows(
    template.predicates(
      "SELECT id, account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source FROM quota_sample WHERE 1",
      " ORDER BY id DESC LIMIT @page_size",
      predicates,
    ),
    on: db,
    with: template.bindings(predicates, then: [sqlight.int(page_size)]),
    expecting: sample_row_decoder(),
  )
}

/// Generated from src/albedo/accounts/quota/sql/insert.sql
pub fn insert(
  db db: sqlight.Connection,
  account account: String,
  provider provider: String,
  plan plan: Option(String),
  limit_id limit_id: String,
  label label: String,
  used_percent used_percent: Option(Float),
  window_label window_label: Option(String),
  window_seconds window_seconds: Option(Int),
  resets_at resets_at: Option(Int),
  scope scope: Option(String),
  status status: String,
  error error: Option(String),
  observed_at observed_at: Int,
) -> Result(Nil, String) {
  albedo_sqlite.run(
    "INSERT INTO quota_sample( account, provider, plan, limit_id, label, used_percent, window_label, window_seconds, resets_at, scope, status, error, observed_at, source ) VALUES ( @account, @provider, @plan, @limit_id, @label, @used_percent, @window_label, @window_seconds, @resets_at, @scope, @status, @error, @observed_at, 'poll' )",
    on: db,
    with: [
      sqlight.text(account),
      sqlight.text(provider),
      sqlight.nullable(sqlight.text, plan),
      sqlight.text(limit_id),
      sqlight.text(label),
      sqlight.nullable(sqlight.float, used_percent),
      sqlight.nullable(sqlight.text, window_label),
      sqlight.nullable(sqlight.int, window_seconds),
      sqlight.nullable(sqlight.int, resets_at),
      sqlight.nullable(sqlight.text, scope),
      sqlight.text(status),
      sqlight.nullable(sqlight.text, error),
      sqlight.int(observed_at),
    ],
  )
}

/// Generated from src/albedo/accounts/quota/sql/latest.sql
pub fn latest(db db: sqlight.Connection) -> Result(List(SampleRow), String) {
  albedo_sqlite.rows(
    "SELECT s.id, s.account, s.provider, s.plan, s.limit_id, s.label, s.used_percent, s.window_label, s.window_seconds, s.resets_at, s.scope, s.status, s.error, s.observed_at, s.source FROM quota_sample s WHERE s.observed_at = (SELECT t.observed_at FROM quota_sample t WHERE t.account = s.account AND t.provider = s.provider ORDER BY t.id DESC LIMIT 1) AND s.id = (SELECT MAX(r.id) FROM quota_sample r WHERE r.account = s.account AND r.provider = s.provider AND r.limit_id = s.limit_id) ORDER BY s.account, s.provider, s.limit_id",
    on: db,
    with: [],
    expecting: sample_row_decoder(),
  )
}

/// Generated from src/albedo/accounts/quota/sql/since_filter.sql
pub const since_filter = "AND observed_at >= ?"

/// Generated from src/albedo/accounts/quota/sql/trail_filter.sql
pub const trail_filter = "AND account = ? AND provider = ? AND limit_id = ?"
