-- returns: SampleRow
SELECT s.id, s.account, s.provider, s.plan, s.limit_id, s.label, s.used_percent,
       s.window_label, s.window_seconds, s.resets_at, s.scope, s.status,
       s.error, s.observed_at, s.source
FROM quota_sample s
WHERE s.observed_at = (SELECT t.observed_at FROM quota_sample t
                      WHERE t.account = s.account AND t.provider = s.provider
                      ORDER BY t.id DESC LIMIT 1)
  AND s.id = (SELECT MAX(r.id) FROM quota_sample r
              WHERE r.account = s.account AND r.provider = s.provider
                AND r.limit_id = s.limit_id)
ORDER BY s.account, s.provider, s.limit_id;
