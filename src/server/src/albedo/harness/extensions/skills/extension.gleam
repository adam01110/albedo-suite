//// Progressive Agent Skills extension.
////
//// Each opened runtime session gets one immutable metadata snapshot. That same
//// snapshot drives prompt context, Python RPC, session commands, and user slash
//// activation: every cataloged skill contributes its slash command to the
//// unified command catalog, where a user invocation submits the activation as
//// one turn and a model invocation returns it as data.

import albedo/daemon/store
import albedo/harness/capabilities
import albedo/harness/command
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/skills/catalog
import albedo/harness/extensions/skills/loads
import albedo/harness/extensions/skills/rpc
import albedo/harness/extensions/skills/service
import albedo/harness/extensions/skills/transfer
import albedo/harness/settings
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// Reads the user's home when a session composes, so the declaration holds no
/// environment value.
pub fn extension() -> harness_extension.Extension {
  extension_with(catalog.native_home)
}

/// Explicit home keeps integration tests and embedders isolated.
pub fn extension_at(home: String) -> harness_extension.Extension {
  extension_with(fn() { home })
}

fn extension_with(home: fn() -> String) -> harness_extension.Extension {
  harness_extension.Extension(
    "skills",
    "Discover Agent Skills metadata and activate selected instructions or resources on demand.",
    ["python", "commands"],
    [
      harness_extension.TransferPlugin(transfer.adapter()),
      harness_extension.GlancePlugin(service.sidebar, service.resource_url),
      harness_extension.ServicePlugin(harness_extension.Service(
        fn(_, _) {
          harness_extension.Admission(harness_extension.DaemonToken, 65_536)
        },
        service.handle,
      )),
      harness_extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["skill_loads"], session)
      }),
      harness_extension.ManagedPlugin(fn(ledger, session, workspace) {
        use discovered <- result.try(catalog.scan_at(
          workspace,
          home(),
          catalog.native_builtin(),
        ))
        use preferences <- result.try(
          capabilities.load(settings.home(), case discovered.skills {
            [] -> None
            _ -> Some(#(ledger, session))
          }),
        )
        use names <- result.try(
          list.try_fold(discovered.skills, [], fn(acc, skill) {
            use enabled <- result.try(capabilities.enabled(
              preferences,
              "skills",
              skill.name,
            ))
            Ok(case enabled {
              True -> [skill.name, ..acc]
              False -> acc
            })
          }),
        )
        let snapshot = catalog.only(discovered, names)
        let loaded = fn(load) { record(ledger, session, load) }
        Ok(
          harness_extension.Managed(
            ..harness_extension.empty(),
            context: catalog.context(snapshot),
            instructions: instructions,
            python_modules: ["skills"],
            routes: [
              #("skills", fn(_, method, args) {
                rpc.handle(snapshot, loaded, method, args)
              }),
            ],
            commands: list.map(catalog.commands(snapshot), skill_command(
              snapshot,
              loaded,
              _,
            )),
          ),
        )
      }),
    ],
    loads.initialise,
  )
}

/// A load that cannot be noted still loads: the model and the user get the
/// skill either way, and only the session's list of loads misses it.
fn record(ledger: store.Store, session: String, load: catalog.Load) -> Nil {
  case loads.record(ledger, session, load) {
    Ok(Nil) | Error(_) -> Nil
  }
}

const instructions =
  "SkillsError reports skill read/activation failures. Skill API and selection guidance accompany available_skills."

pub fn command_arguments() -> List(command.Argument) {
  [command.Argument("arguments", "arguments for the skill", False, [])]
}

/// One cataloged skill as a session command: both callers resolve the same
/// activation, and only the delivery differs.
fn skill_command(
  snapshot: catalog.Catalog,
  loaded: fn(catalog.Load) -> Nil,
  entry: catalog.Command,
) -> command.Command {
  // Only this skill, captured once per closure: the command is copied into
  // every process that holds the composition, and a copy does not keep what
  // its closures share, so a closure holding another closure pays twice.
  let own = catalog.Catalog(catalog.only(snapshot, [entry.name]).skills, [])
  command.Command(
    entry.command,
    entry.description,
    command_arguments(),
    True,
    True,
    False,
    Some(fn(arguments) { activate(own, loaded, entry, arguments) }),
    fn(_context, caller, args) {
      let arguments = dict.get(args, "arguments") |> result.unwrap("")
      case caller {
        command.UserCall -> {
          use activation <- result.try(activate(own, loaded, entry, arguments))
          Ok(command.Turn(
            catalog.activation_display(activation),
            catalog.activation_prompt(activation),
          ))
        }
        command.ModelCall -> {
          use activation <- result.try(catalog.activate(
            own,
            entry.name,
            arguments,
          ))
          loaded(catalog.activation_loaded(activation))
          Ok(command.Data(rpc.activation_json(activation)))
        }
      }
    },
  )
}

/// A user's activation, from a slash command or a mention in a message.
fn activate(
  own: catalog.Catalog,
  loaded: fn(catalog.Load) -> Nil,
  entry: catalog.Command,
  arguments: String,
) -> Result(catalog.Activation, String) {
  use activation <- result.try(catalog.activate(
    own,
    entry.name,
    string.trim(arguments),
  ))
  loaded(catalog.activation_loaded(activation))
  Ok(activation)
}
