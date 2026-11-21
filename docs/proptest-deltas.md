# Suite deltas over upstream in the session/loop path

Upstream: /nix/store/2qcikl7ck4d8izgify54rbj1cay6yqxp-source

1. apps/albedo/src/albedo/model_loop/loop.gleam
   - import albedo/history/tool_count
   - run_tool publishes view.ToolWithImages (was view.Tool), carrying the tool
     output's images and tool_count.total(...) for the live event.

2. apps/albedo/src/albedo/session/session_state.gleam
   - State gains composing_context: Bool (context read composition under way)
   - Session gains kernel_blocked: Bool (failed startup waits for retry/move)
   - current_status treats kernel_blocked as blocking.

3. apps/albedo/src/albedo/observation/events.gleam
   - new Event variant ToolWithImages(call, output, trace, progress_id,
     position, images, failed, tool_calls); Tool now encodes through the same
     tool() with no images and no counter.
   - tool() gains images + tool_calls; publishes entry_id, session_tool_calls,
     images[] (mime_type, width, height, original_bytes, reference{url, field,
     bytes}).
   - new Event variant CostedUsage(metadata, spent, cost); Usage encoding split
     into usage_fields so costed_usage adds session_cost_usd first.
   - project() handles ToolWithImages like Tool.

4. apps/albedo/src/albedo/composition/composition.gleam
   - instructions() folds contributions through prompt_docs.instructions
   - python_modules() appends "api_docs" when prompt_docs.available
   - routes() appends prompt_docs.route when prompt_docs.available

5. apps/albedo/src/albedo/composition/extensions.gleam
   - registers formatter, lsp and zed extensions; zed joins the API-extension
     allowlist.

6. apps/albedo/src/albedo/http/http_resources.gleam
   - usage endpoint: days upper bound 90 -> 371 and a "profile" field from
     usage_profile.read.

7. apps/albedo/src/albedo/http/http_session_resource.gleam
   - session list/detail usage field uses events.costed_usage with cost_usd
   - detail summary adds session_cost_usd and session_tool_calls.

8. apps/albedo/src/albedo/settings/settings.gleam
   - provider profile patches accept "enabled" (saved as "enabled"), require it
     to decode as a Bool, and refuse enabling/toggling an unknown profile that
     names no model (400 invalid_request).

9. extensions/agents/src/albedo_ext_agents/extension.gleam
   - adds a GlancePlugin(sidebar.sidebar, sidebar.resource_url).

10. extensions/run/src/albedo_ext_run/extension.gleam
    - instruction text only ("job.command is the requested command, job.argv
      its argument list").

11. extensions/files/src/albedo_ext_files/extension.gleam
    - drops the ["run"] dependency; "files" route becomes `route`, dispatching
      files.fff to an FFF search with an optional SSH target from
      location.parse(context.workspace), everything else to image().
    - search()/native_search/remote_host via @external erlang albedo_fff.

Suite-owned modules reached from these deltas: composition/prompt_docs.gleam,
history/tool_count.gleam, usage/usage_profile.gleam, usage/session_cost.gleam,
extensions/agents/.../sidebar.gleam.

## Property coverage added (discovery change)

- test/proptest/prompt_docs_delta_prop.gleam -> hunks 4 (composition instructions,
  python_modules, routes) through albedo/composition/prompt_docs.gleam.
- test/proptest/events_delta_prop.gleam -> hunk 3 (ToolWithImages, tool
  images/counter, CostedUsage vs usage_fields).
- test/proptest/agents_sidebar_prop.gleam -> hunk 9 (GlancePlugin rows).

## Untested hunks and why

- 1 loop.gleam: publishing ToolWithImages needs a loop state, a host and a
  kernel; the encoder properties cover the event contract, not the call site.
- 2 session_state.gleam: composing_context/kernel_blocked are plumbing flags
  (current_status reads them); no pure contract beyond the status mapping,
  which session_activity owns upstream.
- 6 http_resources.gleam days bound 90 -> 371 and the usage profile field: the
  handler needs a ledger and an HTTP request; the bound is a literal.
- 7 http_session_resource.gleam summary/usage fields: session_cost_usd and
  session_tool_calls are computed inside the response builder from a captured
  session; testing them needs the capture machinery. The recomputation oracles
  would be session_cost.total and tool_count.total over the same ledger.
- 8 settings.gleam enabled toggle: patch_group needs a home directory, ETag,
  oauth logins and key environment; the rule is testable but expensive glue.
  By inspection the toggle survives normalize_profile because profile_change
  merges the raw profile first; the refusal path is a literal 400.
- 10 run extension: instruction text only.
- 11 files extension: files.fff dispatches through @external erlang modules
  (albedo_fff.search) that spawn work; the pure part is the optional
  _fff_target default, which needs a host context carrying a remote workspace.
