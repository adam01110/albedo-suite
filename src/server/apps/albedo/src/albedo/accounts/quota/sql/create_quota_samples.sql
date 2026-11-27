-- albedo: script
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
