//// Start supervised programs from Python, without a shell.

import albedo_ext_run/service
import albedo_sdk/capability
import albedo_sdk/client_api
import albedo_sdk/command.{Data}
import albedo_sdk/extension as harness_extension
import albedo_sdk/host
import albedo_sdk/input
import albedo_sdk/kernel
import albedo_sdk/notice
import albedo_sdk/rpc
import albedo_sdk/service as http_service
import albedo_sdk/storage
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None}
import gleam/result

const instructions =
  "run(program, *args, cwd=None, env=None, stdin=None, timeout=300) starts one program without a shell and returns its job handle right away; run is not async, and awaiting the handle waits for the program: job = run(\"go\", \"test\", \"./...\", cwd=\"cli\"), then await job, then job.exit_code and job.tail(lines=20). When you want a command's output, out = await run(\"git\", \"status\").text() is the default: job.text(check=True) awaits the job and returns its whole output as plain text (colour codes dropped, a progress line at its last draw), and raises JobFailed with the last lines when the program exits nonzero or times out (check=False returns the output anyway). For a server or watcher, await job.wait_for(\"ready\", timeout=60) waits until a line of its output contains that text (or matches a compiled re pattern) and returns the line, counting output already written; it raises TimeoutError, or JobFailed when the job ends first, and never stops the job. os.chdir(path) moves the kernel itself: run(), files and relative paths follow it, and kernel restarts keep it, so a session spent in another checkout or worktree sets it once instead of passing cwd= to every call. Bind the handle before awaiting it: job = await run(...) blocks before the assignment, so a cell interrupted mid-wait leaves the running job only in jobs. There is no shell, so shell syntax has Python spellings: cd dir && ... is cwd=, NAME=value is env= (added to the kernel's environment), | tail -n 20 is job.tail(lines=20), | head -n 20 is job.head(lines=20), a | b is .pipe(): run() and job.pipe(program, *args) return handles at once, so chain first and await once, as in job = run(\"git\", \"log\", \"--oneline\").pipe(\"rg\", \"fix\").pipe(\"sort\", \"-u\"); await job; the stages stream like a shell pipe, the await waits for the last one, each stage keeps the timeout of the job it reads unless given its own, and job.pipeline is the whole line. To wait for every stage and see its exit status and timeout, use await job.stage_outcomes(); it returns the stages in pipeline order without raising for nonzero exits. Stage history is unavailable after kernel release. 2>&1 is implied (stderr joins stdout), stdin= takes text, bytes, a path, or another job, and &&, loops, and globs are Python over job.exit_code and the output. `sh -c` and subprocess/os.system in a cell raise an error naming the equivalent run() call. Programs start at once at low priority and are never paused for admission. nix never copies a jj workspace into the store (a flake there is read from its commit), and nix develop -c program ... reuses a cached dev shell. cargo runs through mbx (a shared build cache) when mbx is installed, so every checkout reuses compiled work; env={\"ALBEDO_NO_MBX\": \"1\"} runs plain cargo. The timeout (seconds, at most a day) counts wall time after the program starts. Await the handle for completion, or keep it in a variable. jobs is a dict of job id to handle for this session. A job's output lives on its handle (job.tail(n=4000) for the last n characters, lines= for lines; job.command is the requested command, job.argv its argument list). head/tail previews are limited to 64 KiB and raise rather than silently shortening an unsatisfiable character/line request. job.read() returns complete text after completion when at most 1 MiB; larger output raises with the pagination call. job.read(offset=0, limit=4000) pages output with a byte offset and at most 65536 bytes per call, including while running. Pass page.next_offset as offset for the next read. Jobs automatically spill past 1 MiB to disk, retaining up to 16 MiB per job for 14 days; pages transparently read the spill file. job.save(path) atomically streams complete output bytes to the destination and returns its absolute path, without loading the artifact into memory. If disk spilling fails or output exceeds 16 MiB, whole reads and saves raise an error rather than returning partial output, leaving the destination untouched. The error names the retained byte count and pagination call; a page crossing lost output raises rather than looking like EOF. For artifacts beyond the disk cap, attach job.pipe(\"tee\", path) before awaiting, then read the file. output.read(job.id, offset=0, limit=4000) also pages retained output; await job.stop() ends it. job.exit_code, job.duration, and job.timed_out report the exit status, the seconds it ran, and deadline state once the program ends (job.poll() and job.returncode are subprocess-style spellings of job.exit_code). A job that finishes with its result unread wakes the session by itself, so polling a handle is optional: leave it in a variable, end the cell, and a notice naming the job arrives once the session is idle. A job that finishes while you are still working is reported after your turn ends, unless you read it first. Awaiting the job, reading its result, or stopping it first means no wake."

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "run",
    "Start supervised programs from Python, without a shell.",
    [],
    [
      harness_extension.ClientPlugin([
        client_api.Command("/jobs", client_api.Read, [], service.operation()),
      ]),
      harness_extension.ServicePlugin(http_service.json(1024, service.dispatch)),
      harness_extension.ToolPlugin(instructions, [], ["run"], [
        #("jobs", fn(context: host.Context, method, args) {
          route(context.storage, context.inbox, context.session, method, args)
        }),
      ]),
      harness_extension.CommandPlugin([command()]),
    ],
    harness_extension.no_initialise,
    tables: [],
    uses:,
  )
}

/// `/jobs`: inspect and manage background jobs running in the session.
fn command() -> command.Command(command.Invocation) {
  command.Command(
    "/jobs",
    "Show background jobs running in this session.",
    [],
    False,
    False,
    True,
    None,
    fn(ctx: command.Invocation, _caller, _args) {
      ctx.state(
        command.KernelJobs(fn(jobs, live_job_count) {
          json.object(kernel.jobs_fields(jobs, live_job_count))
        }),
      )
      |> result.map_error(command.state_error_text)
      |> result.map(Data)
    },
  )
}

/// The kernel's notice route (`sdk/notice`): a finished background job whose
/// result nobody read posts a notice under the kernel's own key; the notice
/// waits for a running turn to end, so the model never polls for completion.
/// The kernel withdraws it by that key once the result is read.
fn route(
  scope: storage.Storage,
  inbox: input.Inbox,
  session: String,
  method: String,
  args: decode.Dynamic,
) -> Result(json.Json, #(String, String)) {
  case method {
    "jobs.completed" ->
      case rpc.args(args, notice.posted_decoder(session, "job"), Nil) {
        Ok(posted) ->
          notice.post(inbox, scope, posted)
          |> result.map_error(fn(reason) { #("unavailable", reason) })
        Error(_) -> Error(#("invalid", "invalid jobs notice"))
      }
    "jobs.withdraw" ->
      case rpc.args(args, notice.keys_decoder(), Nil) {
        Ok(keys) ->
          notice.withdraw(inbox, scope, session, keys)
          |> result.replace(json.null())
          |> result.map_error(fn(reason) { #("unavailable", reason) })
        Error(_) -> Error(#("invalid", "invalid notice keys"))
      }
    "jobs.waiting" ->
      case rpc.args(args, notice.keys_decoder(), Nil) {
        Ok(keys) ->
          notice.waiting(inbox, scope, session, keys)
          |> result.map_error(fn(reason) { #("unavailable", reason) })
        Error(_) -> Error(#("invalid", "invalid notice keys"))
      }
    _ -> Error(#("invalid", "unknown jobs operation"))
  }
}

/// The host capabilities this extension uses: it posts job notices and reads
/// job state through the session. Its service, bound to no session, lists
/// and reads the jobs and output of the session a request names, which is
/// that session's history, through the host's job book.
pub const uses = [
  capability.History,
  capability.Inbox,
  capability.KernelJobs,
  capability.SessionState,
]
