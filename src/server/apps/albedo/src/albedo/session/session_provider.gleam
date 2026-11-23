//// Provider selection, reasoning effort, and on-demand upstream binding.

import albedo_sdk/session_info

import albedo/composition/selection
import albedo/history/conversation
import albedo/refusal.{type Refusal}
import albedo/runtime
import albedo/session/session_configuration
import albedo/session/session_history
import albedo/session/session_state
import albedo_model as albedo_types
import albedo_sdk/extension
import albedo_sdk/profiles as configuration
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub fn configured_client(
  state: session_state.State(message),
) -> Result(#(session_state.State(message), extension.Upstream), String) {
  use provider <- result.try(case state.info.provider {
    "" -> {
      use provider <- result.try(
        configuration.legacy(state.home)
        |> result.map_error(configuration.explain),
      )
      use _ <- result.try(conversation.assign_session_provider(
        runtime.ledger(state.host),
        state.info.id,
        provider.name,
      ))
      Ok(provider)
    }
    name ->
      configuration.named(state.home, name)
      |> result.map_error(configuration.explain)
  })
  let state = case state.info.provider {
    "" ->
      session_state.State(
        ..state,
        history: option.map(state.history, session_history.tag_unknown_provider(
          _,
          provider.name,
        )),
        info: session_info.Info(..state.info, provider: provider.name),
      )
    _ -> state
  }
  use client <- result.try(
    runtime.upstream(
      state.host,
      state.info.id,
      state.home,
      provider.name,
      provider.extension,
      state.info.model,
      state.info.protocol,
      state.info.effort,
      state.info.fast,
      state.info.cyber_access,
    )
    |> result.map_error(runtime.upstream_error_text),
  )
  Ok(#(state, client))
}

/// The endpoint a profile is configured with, if any.
pub fn profile_endpoint(
  home: String,
  provider: String,
) -> option.Option(String) {
  configuration.settings(home, provider, base_url())
  |> result.unwrap("")
  |> extension.clean_endpoint
  |> catalog_endpoint(home, provider, _)
}

@external(erlang, "albedo_zed_auth", "catalog_endpoint")
fn catalog_endpoint(
  home: String,
  profile: String,
  ordinary: option.Option(String),
) -> option.Option(String)

/// `profile_endpoint` for every saved profile, by name, from one read.
pub fn profile_endpoints(
  home: String,
) -> dict.Dict(String, option.Option(String)) {
  configuration.every_settings(home, base_url())
  |> result.unwrap(dict.new())
  |> dict.map_values(fn(profile, url) {
    result.unwrap(url, "")
    |> extension.clean_endpoint
    |> catalog_endpoint(home, profile, _)
  })
}

fn base_url() -> decode.Decoder(String) {
  decode.optional_field("baseUrl", "", decode.string, decode.success)
}

/// The reasoning efforts a session on `provider` accepts for `model`.
pub fn model_efforts(
  host: runtime.Runtime,
  home: String,
  provider: String,
  model: String,
) -> List(albedo_types.Effort) {
  runtime.profile_efforts(
    host,
    home,
    provider,
    profile_extension(home, provider),
    model,
  )
}

/// The extension a saved profile uses, with `configuration.default_extension` for
/// profiles saved before the field existed.
fn profile_extension(home: String, provider: String) -> String {
  configuration.settings(
    home,
    provider,
    decode.optional_field(
      "extension",
      configuration.default_extension(),
      decode.string,
      decode.success,
    ),
  )
  |> result.unwrap(configuration.default_extension())
}

/// Read only provider/account/model capability; this never prepares a kernel or sends inference.
pub fn fast_mode(
  state: session_state.State(message),
  provider: String,
  model: String,
  protocol: albedo_types.Protocol,
  effort: option.Option(String),
) -> extension.FastMode {
  case configuration.named(state.home, provider) {
    Error(failure) -> extension.FastUnknown(configuration.explain(failure))
    Ok(profile) ->
      runtime.fast_mode(
        state.host,
        state.info.id,
        state.home,
        provider,
        profile.extension,
        model,
        protocol,
        effort,
      )
  }
}

pub fn read_fast(
  state: session_state.State(message),
) -> Result(json.Json, String) {
  let support =
    fast_mode(
      state,
      state.info.provider,
      state.info.model,
      state.info.protocol,
      state.info.effort,
    )
  let #(fields, detail) = case support {
    extension.FastAvailable(mode, source) -> #(
      [
        #("status", json.string("supported")),
        #("mode", json.string(mode)),
        #("source", json.string(source)),
      ],
      "supported; premium usage or pricing may apply",
    )
    extension.FastUnavailable(reason) -> #(
      [
        #("status", json.string("unsupported")),
        #("detail", json.string(reason)),
      ],
      reason,
    )
    extension.FastUnknown(reason) -> #(
      [
        #("status", json.string("unknown")),
        #("detail", json.string(reason)),
      ],
      "support cannot be verified: " <> reason,
    )
  }
  let enabled = case state.info.fast {
    True -> "on"
    False -> "off"
  }
  Ok(
    json.object([
      #("fast", json.bool(state.info.fast)),
      #("support", json.object(fields)),
      #(
        "message",
        json.string(
          "fast mode is "
          <> enabled
          <> " ("
          <> detail
          <> "). Subagents start with fast mode off.",
        ),
      ),
    ]),
  )
}

pub fn read_effort(
  state: session_state.State(message),
) -> Result(json.Json, String) {
  let efforts =
    model_efforts(state.host, state.home, state.info.provider, state.info.model)
  let current = state.info.effort
  use effective <- result.try(
    runtime.resolve_effort(
      state.host,
      state.home,
      state.info.provider,
      profile_extension(state.home, state.info.provider),
      state.info.model,
      current,
    )
    |> result.map_error(runtime.effort_error_text),
  )
  use default <- result.try(
    runtime.resolve_effort(
      state.host,
      state.home,
      state.info.provider,
      profile_extension(state.home, state.info.provider),
      state.info.model,
      option.Some("default"),
    )
    |> result.map_error(runtime.effort_error_text),
  )
  let configured =
    configuration.named(state.home, state.info.provider)
    |> result.map(fn(p) { p.effort })
    |> result.unwrap(option.None)
  let source = case current, configured {
    option.Some("inherit"), option.Some(level)
      if level != "default" && level != "inherit"
    -> "profile"
    option.Some("inherit"), _ | option.Some("default"), _ -> {
      let endpoint = profile_endpoint(state.home, state.info.provider)
      runtime.global(state.host)
      |> result.unwrap([])
      |> extension.model_info(
        profile_extension(state.home, state.info.provider),
        state.info.model,
        endpoint,
      )
      |> option.map(fn(info) { info.default_effort_source })
      |> option.unwrap("provider")
    }
    option.None, _ -> "legacy"
    _, _ -> "session"
  }
  let names = list.map(efforts, albedo_types.effort_name)
  let available = string.join(names, ", ")
  let choice = case current {
    option.Some("inherit") -> "automatic"
    option.Some("default") -> "model default"
    option.Some(level) -> level
    option.None -> "unset (legacy)"
  }
  let message =
    "reasoning effort is "
    <> choice
    <> ": "
    <> option.map(effective, albedo_types.effort_name)
    |> option.unwrap("provider decides")
    <> " (source: "
    <> source
    <> "; available: "
    <> available
    <> ")"
  Ok(
    json.object([
      #("effort", json.nullable(current, json.string)),
      #("available", json.array(names, json.string)),
      #("default_effort", json.nullable(default, effort_json)),
      #("effective_effort", json.nullable(effective, effort_json)),
      #("source", json.string(source)),
      #("message", json.string(message)),
    ]),
  )
}

pub fn read_compact_at(
  state: session_state.State(message),
) -> Result(json.Json, String) {
  use session_window <- result.try(session_configuration.context_window(
    runtime.ledger(state.host),
    state.info.id,
  ))
  let endpoint = profile_endpoint(state.home, state.info.provider)
  let info =
    runtime.global(state.host)
    |> result.unwrap([])
    |> extension.model_info(
      profile_extension(state.home, state.info.provider),
      state.info.model,
      endpoint,
    )
  let model_window = option.then(info, selection.window)
  let effective = option.or(session_window, model_window)
  let #(source, message) = case session_window, model_window {
    option.Some(tokens), option.Some(default_tokens) -> #(
      "session",
      "This session compacts against a "
        <> int.to_string(tokens)
        <> "-token window (model default: "
        <> int.to_string(default_tokens)
        <> "); /compact-at default restores the model's window.",
    )
    option.Some(tokens), option.None -> #(
      "session",
      "This session compacts against a "
        <> int.to_string(tokens)
        <> "-token window.",
    )
    option.None, option.Some(tokens) -> {
      let origin = case selection.compact_at(state.info.model) {
        option.Some(saved) if saved == tokens ->
          " (saved for this model in /model)"
        _ -> ""
      }
      #(
        "model",
        "This session uses "
          <> state.info.model
          <> "'s "
          <> int.to_string(tokens)
          <> "-token window"
          <> origin
          <> "; /compact-at <tokens> overrides it for this session.",
      )
    }
    option.None, option.None -> #(
      "unknown",
      "No context window is configured or catalogued for "
        <> state.info.model
        <> "; /compact-at <tokens> sets one for this session.",
    )
  }
  Ok(
    json.object([
      #("context_window", json.nullable(session_window, json.int)),
      #("effective_context_tokens", json.nullable(effective, json.int)),
      #("model_context_tokens", json.nullable(model_window, json.int)),
      #("source", json.string(source)),
      #("message", json.string(message)),
    ]),
  )
}

/// Whether `level`, as a session or profile saves it, names one of `efforts`.
pub fn lists_effort(efforts: List(albedo_types.Effort), level: String) -> Bool {
  albedo_types.parse_effort(level)
  |> result.map(list.contains(efforts, _))
  == Ok(True)
}

fn effort_json(effort: albedo_types.Effort) -> json.Json {
  json.string(albedo_types.effort_name(effort))
}

/// Validate intent using the same resolution used at the provider boundary.
pub fn validate_effort(
  host: runtime.Runtime,
  home: String,
  provider: String,
  model: String,
  choice: option.Option(String),
) -> Result(Nil, Refusal) {
  use resolved <- result.try(
    runtime.resolve_effort(
      host,
      home,
      provider,
      profile_extension(home, provider),
      model,
      choice,
    )
    |> result.map_error(fn(error) {
      case error {
        runtime.SavedEffortUnsupported -> refusal.SavedEffortUnsupported
        runtime.EffortUnknown(_) ->
          refusal.Unavailable(runtime.effort_error_text(error))
        runtime.EffortProfile(failure) -> refusal.ProviderUnconfigured(failure)
      }
    }),
  )
  case choice, resolved {
    option.Some("inherit"), _ | option.Some("default"), _ -> Ok(Nil)
    _, option.None -> Ok(Nil)
    _, option.Some(level) ->
      case list.contains(model_efforts(host, home, provider, model), level) {
        True -> Ok(Nil)
        False ->
          Error(refusal.Unavailable(
            "unsupported reasoning effort: " <> albedo_types.effort_name(level),
          ))
      }
  }
}
