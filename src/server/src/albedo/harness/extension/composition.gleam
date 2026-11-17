//// One session's composed extensions: the harness base (`kernel/base`), then
//// every selected extension's static contributions and prepared managed
//// plugins, composed once and read as tools, context, instructions, commands,
//// routes, observers, and hooks.

import albedo/daemon/acp_overlay
import albedo/daemon/mail
import albedo/daemon/webhook_intake
import albedo/harness/extension/prompt_docs
import albedo/harness/kernel/base
import albedo/harness/kernel/tool as cell_tool
import albedo/harness/sdk/client_api
import albedo/harness/sdk/command
import albedo/harness/sdk/extension
import albedo/harness/sdk/hook
import albedo/harness/sdk/selection
import albedo/harness/sdk/store
import albedo_model as types
import albedo_protect
import gleam/bool
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string

/// One session's extension state, composed from nothing: the harness base and
/// every selected extension's static contributions in registry order, then
/// every prepared managed plugin. It is never mutated. A refresh or reload
/// composes a replacement and closes whichever composition loses, so each
/// contribution applies exactly once and a plugin that disappears takes its
/// tools with it.
pub opaque type Composition {
  Composition(
    requested: List(extension.Extension),
    /// The base, then the active selected extensions: every owner whose
    /// contributions this composition scopes.
    extensions: List(extension.Extension),
    /// Static contributions only; `contributions` appends the other two, so
    /// a composition copied to another process carries each plugin once.
    static: List(extension.Prepared),
    managed: List(extension.Prepared),
    /// The warning-only contributions of the extensions that broke.
    failures: List(extension.Prepared),
    /// The store `tools` and `routes` scope each extension's handle on.
    ledger: store.Store,
    /// The host's selection capability, which each extension's commands
    /// receive in their `command.Invocation` when it declares `Selection`.
    selection: selection.Selection,
  )
}

/// Compose one session's extensions: static contributions with their loaded
/// context, then every prepared managed plugin. The harness base comes first
/// whatever `selected` holds, so its python tool claims its names before any
/// extension can. An extension that fails, crashes, or collides with another
/// is left out with a warning; the session composes without it. `harness`
/// is the base (`base.contribution()`); the runtime builds it once and passes
/// the shared value, so a session holds no copy of its own.
pub fn compose(
  harness: extension.Extension,
  selected: List(extension.Extension),
  owner: extension.PreparationOwner,
  ledger: store.Store,
  session: String,
  workspace: String,
  selection: selection.Selection,
) -> Composition {
  let empty = Composition(selected, [], [], [], [], ledger, selection)
  let composed =
    list.fold([harness, ..selected], empty, fn(composed, candidate) {
      let #(static, load_failures) = split(loaded(candidate, workspace))
      let #(managed, prepare_failures) = case load_failures {
        [] -> split(prepare([candidate], owner, ledger, session, workspace))
        _ -> #([], [])
      }
      let failures = list.append(load_failures, prepare_failures)
      let claimed =
        list.flatten([composed.static, composed.managed, static, managed])
      let failures = case failures {
        [] ->
          case
            extension.module_clash(claimed),
            extension.duplicate_capabilities(list.map(claimed, value)),
            unbound_client_command(candidate, list.append(static, managed))
          {
            option.Some(reason), _, _ -> [broken(candidate.name, reason)]
            option.None, True, _ -> [
              broken(candidate.name, "it duplicates tools, commands, or routes"),
            ]
            option.None, False, option.Some(name) -> [
              broken(
                candidate.name,
                "client binding " <> name <> " has no command in this extension",
              ),
            ]
            option.None, False, option.None -> []
          }
        _ -> failures
      }
      case failures {
        [] ->
          Composition(
            ..composed,
            extensions: list.append(composed.extensions, [candidate]),
            static: list.append(composed.static, static),
            managed: list.append(composed.managed, managed),
          )
        _ -> {
          close_prepared(managed)
          Composition(
            ..composed,
            failures: list.append(composed.failures, [
              extension.Prepared(
                candidate.name,
                extension.Managed(
                  ..extension.empty(),
                  warnings: list.flat_map(failures, fn(item) {
                    item.value.warnings
                  }),
                ),
              ),
            ]),
          )
        }
      }
    })
  let active = supported(composed.extensions)
  let names = list.map(active, fn(item) { item.name })
  let kept = fn(item: extension.Prepared) {
    list.contains(names, item.extension)
  }
  let #(managed, rejected) = list.partition(composed.managed, kept)
  close_prepared(rejected)
  let failures =
    composed.extensions
    |> list.filter(fn(item) { !list.contains(names, item.name) })
    |> list.map(fn(item) {
      let missing =
        list.filter(item.requires, fn(name) { !list.contains(names, name) })
      broken(
        item.name,
        "it requires active extension " <> string.join(missing, ", "),
      )
    })
  Composition(
    ..composed,
    extensions: active,
    static: list.filter(composed.static, kept),
    managed: managed,
    failures: list.append(composed.failures, failures),
  )
}

/// Only this extension's completed contributions can satisfy its bindings.
fn unbound_client_command(
  candidate: extension.Extension,
  prepared: List(extension.Prepared),
) -> option.Option(String) {
  let names =
    list.flat_map(prepared, fn(item) {
      list.map(item.value.commands, fn(command) { command.name })
    })
  let bindings =
    list.flat_map(candidate.plugins, fn(plugin) {
      case plugin {
        extension.ClientPlugin(bindings) -> bindings
        _ -> []
      }
    })
  bindings
  |> list.find(fn(binding) { !list.contains(names, binding.slash_name) })
  |> result.map(fn(binding) { binding.slash_name })
  |> option.from_result
}

/// Remove dependents until every remaining requirement is active.
fn supported(
  candidates: List(extension.Extension),
) -> List(extension.Extension) {
  let names = list.map(candidates, fn(item) { item.name })
  let kept =
    list.filter(candidates, fn(item) {
      list.all(item.requires, fn(name) { list.contains(names, name) })
    })
  case list.length(kept) == list.length(candidates) {
    True -> kept
    False -> supported(kept)
  }
}

/// Every contribution in order: static, managed, then the broken ones.
pub fn contributions(composition: Composition) -> List(extension.Prepared) {
  list.flatten([composition.static, composition.managed, composition.failures])
}

/// The working contributions and the broken ones, each in order.
fn split(
  values: List(Result(extension.Prepared, extension.Prepared)),
) -> #(List(extension.Prepared), List(extension.Prepared)) {
  list.fold_right(values, #([], []), fn(state, value) {
    case value {
      Ok(working) -> #([working, ..state.0], state.1)
      Error(broken) -> #(state.0, [broken, ..state.1])
    }
  })
}

/// One extension's static contributions, with its context loaded. An
/// extension whose context will not load contributes only its warning: the
/// rest of the session composes without it.
pub fn loaded(
  ext: extension.Extension,
  workspace: String,
) -> List(Result(extension.Prepared, extension.Prepared)) {
  let values =
    list.try_map(ext.plugins, fn(plugin) {
      case plugin {
        extension.ContextPlugin(load) ->
          albedo_protect.guarded(fn() { load(workspace) })
          |> result.map(fn(context) {
            [extension.Managed(..extension.empty(), context: context)]
          })
        _ -> Ok(option.values([extension.declare(plugin)]))
      }
    })
  case values {
    Ok(values) ->
      values
      |> list.flatten
      |> list.map(fn(value) { Ok(extension.Prepared(ext.name, value)) })
    Error(error) -> [
      Error(broken(ext.name, "its context failed: " <> error)),
    ]
  }
}

/// A broken extension's only contribution: no capabilities, one warning,
/// which the session shows as a note.
fn broken(name: String, reason: String) -> extension.Prepared {
  extension.Prepared(
    name,
    extension.Managed(..extension.empty(), warnings: [
      "extension " <> name <> " is inactive in this session: " <> reason,
    ]),
  )
}

/// Every contribution's value with its tools and routes scoped to its own
/// extension's storage handle and capabilities, though the host builds one
/// context for the whole composition. Scoped when read, not when composed:
/// the composition is copied from the preparing worker to the runtime and
/// the session, a copy shares nothing, and so each wrapping closure carried
/// its own copy of the handle. Stored that way it cost about 18 KB per idle
/// session (idle_session_beam, robot-docs/perf.md).
fn scoped(composition: Composition) -> List(extension.Managed) {
  list.map(contributions(composition), scope(composition, _))
}

fn scope(
  composition: Composition,
  item: extension.Prepared,
) -> extension.Managed {
  case
    list.find(composition.extensions, fn(candidate) {
      candidate.name == item.extension
    })
  {
    Ok(candidate) -> extension.scoped(item.value, candidate, composition.ledger)
    // A broken extension contributes only its warnings.
    Error(Nil) -> item.value
  }
}

pub fn value(prepared: extension.Prepared) -> extension.Managed {
  prepared.value
}

/// Release every managed resource, newest first.
pub fn close(composition: Composition) -> Nil {
  close_prepared(composition.managed)
}

/// Hand each managed contribution to the runtime in preparation order.
/// On the first refusal, close the entire composition newest first.
pub fn adopt(composition: Composition) -> Result(Nil, String) {
  let adopted =
    list.try_each(composition.managed, fn(item) {
      albedo_protect.guarded(item.value.adopt)
      |> result.map_error(fn(reason) {
        "extension " <> item.extension <> " refused adoption: " <> reason
      })
    })
  case adopted {
    Ok(Nil) -> Ok(Nil)
    Error(reason) -> {
      close_prepared(composition.managed)
      Error(reason)
    }
  }
}

/// Every contribution's observer, in registry order, each guarded: these run
/// inside the session actor, where a crash would take the session with it.
pub fn observers(
  composition: Composition,
) -> List(fn(extension.Session, extension.SessionEvent) -> Nil) {
  list.map(contributions(composition), fn(item) {
    fn(session, event) {
      case albedo_protect.attempt(fn() { item.value.observe(session, event) }) {
        Ok(_) -> Nil
        Error(crash) -> report(item.extension, "observer", crash)
      }
    }
  })
}

/// Every contributed hook, asked for `session` in `workspace`, in the one
/// order `hook.ask` relies on: extensions in composition order (the harness
/// base, then the selection in registry order), and within one extension its
/// `HookPlugin` hooks in plugin order before its managed contribution's hook.
/// Whether a hook is static or managed never moves it past another
/// extension's: the first block and argument rewrite win, so the order is
/// behaviour. Each is asked with its own extension's handle bound to the
/// session, built when read, as `scoped` builds the tools' and commands', so
/// the stored composition holds no handle per hook.
pub fn hooks(
  composition: Composition,
  session: String,
  workspace: String,
) -> List(hook.Hook) {
  let contributed = contributions(composition)
  list.flat_map(composition.extensions, fn(owner) {
    // `contributions` lists static before managed, each in plugin order.
    list.filter_map(contributed, fn(item) {
      use <- bool.guard(item.extension != owner.name, Error(Nil))
      use ask <- result.map(option.to_result(item.value.hook, Nil))
      let context =
        extension.hook_context(owner, composition.ledger, session, workspace)
      #(item.extension, fn(event) { ask(context, event) })
    })
  })
}

/// Whether any contribution hooks the session.
fn hooked(composition: Composition) -> Bool {
  list.any(contributions(composition), fn(item) {
    option.is_some(item.value.hook)
  })
}

/// The prepared managed plugins, in registry order.
pub fn managed(composition: Composition) -> List(extension.Prepared) {
  composition.managed
}

pub fn requested(composition: Composition) -> List(extension.Extension) {
  composition.requested
}

/// The active selected extensions, in registry order. The harness base is
/// not one of them.
pub fn extensions(composition: Composition) -> List(extension.Extension) {
  list.filter(composition.extensions, fn(item) { item.name != base.name })
}

/// Nonempty context blocks, labelled by the extension that supplied them.
pub fn context(composition: Composition) -> List(#(String, String)) {
  contributions(composition)
  |> list.filter(fn(item) { string.trim(item.value.context) != "" })
  |> list.map(fn(item) { #(item.extension, item.value.context) })
}

/// Each extension that failed to load or prepare, with the warning saying
/// why. Enabling one of these is an error, not a silent no-op.
pub fn inactive(composition: Composition) -> List(#(String, String)) {
  list.map(composition.failures, fn(item) {
    #(item.extension, string.join(item.value.warnings, "; "))
  })
}

pub fn warnings(composition: Composition) -> List(String) {
  list.flat_map(contributions(composition), fn(item) { item.value.warnings })
}

/// Every contribution's instructions, after one sentence naming where the
/// session's capabilities are reached, worded from its actual tools. Two
/// extensions that share a binding give the same text, said once.
pub fn instructions(composition: Composition) -> String {
  let tools = list.map(tools(composition), fn(tool) { tool.definition.name })
  [reach(tools), prompt_docs.instructions(contributions(composition))]
  |> list.filter(fn(value) { string.trim(value) != "" })
  |> list.unique
  |> string.join("\n")
}

/// Every composition has the cell tool; a tool beside it is named, since its
/// schema is the only place it is described.
fn reach(tools: List(String)) -> String {
  case list.filter(tools, fn(name) { name != cell_tool.name }) {
    [] ->
      "python is your only tool: every capability this session has is a Python binding in its kernel, so call these names inside a python cell."
    others ->
      "Every capability this session has is a Python binding in the python tool's kernel, except the tools "
      <> string.join(others, ", ")
      <> ", which their own schemas describe; call everything else inside a python cell."
  }
}

pub fn tools(composition: Composition) -> List(extension.Tool) {
  list.flat_map(scoped(composition), fn(value) { value.tools })
}

/// Every tool's definition, in `tools` order. Reading definitions wraps
/// nothing, so the per-turn tool list costs no scoping.
pub fn definitions(composition: Composition) -> List(types.Tool) {
  list.flat_map(contributions(composition), fn(item) {
    list.map(item.value.tools, fn(tool) { tool.definition })
  })
}

/// The tool named `name`, scoped like `tools` returns it. Only that tool is
/// wrapped, so a call costs one wrapper rather than every tool's.
pub fn tool(
  composition: Composition,
  name: String,
) -> Result(extension.Tool, Nil) {
  list.find_map(contributions(composition), fn(item) {
    use found <- result.try(
      list.find(item.value.tools, fn(tool) { tool.definition.name == name }),
    )
    let single =
      extension.Prepared(
        ..item,
        value: extension.Managed(..item.value, tools: [found], routes: []),
      )
    list.first(scope(composition, single).tools)
  })
}

/// With `hook` last when any extension hooks the session: it reports the
/// calls cells make, which a session without hooks never pays for. A module
/// two extensions share (`mcp`) loads once.
pub fn python_modules(composition: Composition) -> List(String) {
  let modules =
    list.flat_map(contributions(composition), fn(item) {
      item.value.python_modules
    })
    |> list.unique
  let modules = case prompt_docs.available(contributions(composition)) {
    True -> list.append(modules, ["api_docs"])
    False -> modules
  }
  case hooked(composition) {
    False -> modules
    True -> list.append(modules, ["hook"])
  }
}

/// The modules a composition of `extensions` loads from their static
/// declarations, with `hook`: what a spare imports before any session adopts
/// it. A managed plugin prepares per session, so the modules it adds (an
/// editor's `mcp`) and whether it hooks are unknown until then; `hook` is
/// counted because default sessions hook (agents does). An extension whose
/// module should load early declares it in a `ToolPlugin`.
pub fn declared_python_modules(
  extensions: List(extension.Extension),
) -> List(String) {
  extensions
  |> list.flat_map(extension.declared)
  |> list.flat_map(fn(value) { value.python_modules })
  |> list.unique
  |> list.append(["hook"])
}

/// Every session command, in registry order, bound like `tools` are
/// scoped: each runs with its own extension's handle in its
/// `command.Invocation`. One list feeds the CLI menu, the kernel bindings,
/// and the aggregate command routes.
pub fn commands(
  composition: Composition,
) -> List(command.Command(command.Context)) {
  list.flat_map(command_entries(composition), fn(entry) { [entry.1] })
}

pub fn command_entries(
  composition: Composition,
) -> List(#(String, command.Command(command.Context))) {
  list.flat_map(contributions(composition), fn(item) {
    list.map(bound_commands(composition, item), fn(command) {
      #(item.extension, command)
    })
  })
}

/// `item`'s commands bound to its extension. A broken extension
/// contributes none.
fn bound_commands(
  composition: Composition,
  item: extension.Prepared,
) -> List(command.Command(command.Context)) {
  case
    list.find(composition.extensions, fn(candidate) {
      candidate.name == item.extension
    })
  {
    Ok(candidate) ->
      extension.scoped_commands(
        item.value,
        candidate,
        composition.ledger,
        composition.selection,
      )
    Error(Nil) -> []
  }
}

pub fn client_commands(
  composition: Composition,
) -> List(#(String, client_api.Command, command.Command(command.Context))) {
  let commands = command_entries(composition)
  composition.extensions
  |> list.flat_map(fn(item) {
    item.plugins
    |> list.flat_map(fn(plugin) {
      case plugin {
        extension.ClientPlugin(bindings) ->
          bindings
          |> list.map(fn(binding) {
            // Composition validates this owner/name relationship before publication.
            let assert Ok(entry) =
              list.find(commands, fn(entry) {
                entry.0 == item.name && entry.1.name == binding.slash_name
              })
            #(item.name, binding, entry.1)
          })
        _ -> []
      }
    })
  })
}

pub fn routes(composition: Composition) -> List(extension.Route) {
  let routes =
    extension.contribution_routes(
      list.flat_map(scoped(composition), fn(value) { value.routes }),
      commands(composition),
    )
  let items = contributions(composition)
  case prompt_docs.available(items) {
    True -> list.append(routes, [prompt_docs.route(items)])
    False -> routes
  }
}

/// Prepare every session-owned plugin in registry order. A plugin that fails
/// or crashes contributes its warning and nothing else; it must close any
/// resources it started itself.
pub fn prepare(
  installed: List(extension.Extension),
  owner: extension.PreparationOwner,
  ledger: store.Store,
  session: String,
  workspace: String,
) -> List(Result(extension.Prepared, extension.Prepared)) {
  list.flat_map(installed, fn(candidate) {
    let name = candidate.name
    let scope = extension.session_storage_of(candidate, ledger, session)
    list.filter_map(candidate.plugins, fn(plugin) {
      case plugin {
        extension.ManagedPlugin(run) ->
          Ok(
            #(name, fn() {
              run(scope, session, workspace) |> result.map(option.Some)
            }),
          )
        extension.OwnedManagedPlugin(run) ->
          Ok(
            #(name, fn() {
              use owned <- result.map(
                run(extension.gate_preparation(
                  extension.Preparation(
                    owner,
                    mail.letters(),
                    session,
                    workspace,
                    fn() { acp_overlay.resolve(ledger, session) },
                    webhook_intake.port,
                    scope,
                  ),
                  candidate,
                )),
              )
              option.map(owned, extension.owned_value)
            }),
          )
        _ -> Error(Nil)
      }
    })
  })
  |> list.flat_map(fn(item) {
    let #(name, run) = item
    case albedo_protect.guarded(run) {
      Ok(option.Some(value)) -> [Ok(extension.Prepared(name, value))]
      Ok(option.None) -> []
      Error(error) -> [Error(broken(name, "it failed to prepare: " <> error))]
    }
  })
}

/// Release each contribution, newest first. A close that crashes is reported
/// and the rest still run, so one bad teardown leaks nothing else.
fn close_prepared(prepared: List(extension.Prepared)) -> Nil {
  prepared
  |> list.reverse
  |> list.each(fn(item) {
    case albedo_protect.attempt(item.value.close) {
      Ok(_) -> Nil
      Error(crash) -> report(item.extension, "close", crash)
    }
  })
}

/// What an extension's crash leaves in the daemon's log.
fn report(name: String, stage: String, crash: String) -> Nil {
  io.println_error(
    "extension " <> name <> " " <> stage <> " crashed, " <> crash,
  )
}
