import albedo/composition/extension_cache
import albedo/workspace/worktree
import albedo_ext_agents
import albedo_ext_anthropic_api
import albedo_ext_antigravity
import albedo_ext_artifacts
import albedo_ext_bedrock
import albedo_ext_browser
import albedo_ext_checklist
import albedo_ext_claude
import albedo_ext_codex
import albedo_ext_colab
import albedo_ext_commands
import albedo_ext_cua
import albedo_ext_discord
import albedo_ext_exa
import albedo_ext_files
import albedo_ext_formatter/extension as formatter
import albedo_ext_git
import albedo_ext_github_copilot
import albedo_ext_google_ai_studio
import albedo_ext_hooks
import albedo_ext_imagegen
import albedo_ext_instructions
import albedo_ext_jj
import albedo_ext_lcm
import albedo_ext_links
import albedo_ext_linter/extension as linter
import albedo_ext_lsp/extension as lsp
import albedo_ext_mail
import albedo_ext_mcp
import albedo_ext_memory
import albedo_ext_mistral
import albedo_ext_models
import albedo_ext_notes
import albedo_ext_openai
import albedo_ext_opencode_go
import albedo_ext_opencode_zen
import albedo_ext_paperclips
import albedo_ext_perplexity
import albedo_ext_persistent_agent
import albedo_ext_photon
import albedo_ext_proxy
import albedo_ext_remote
import albedo_ext_rolling
import albedo_ext_run
import albedo_ext_schedule
import albedo_ext_skills
import albedo_ext_snapcompact
import albedo_ext_vertex
import albedo_ext_view
import albedo_ext_warm
import albedo_ext_web_search
import albedo_ext_webhooks
import albedo_ext_work
import albedo_ext_worktrees
import albedo_ext_zed/extension as zed
import albedo_sdk/extension
import albedo_sdk/store
import gleam/json

pub type Config {
  Config(extensions: List(extension.Extension), default_enabled: List(String))
}

/// The installed extensions: a sealed build's cached declarations, or the
/// constructors' result.
pub fn defaults() -> Config {
  case extension_cache.load() {
    Ok(config) -> config
    Error(Nil) -> declared()
  }
}

/// Calls every extension's constructor. Declarations must not capture the
/// environment: a sealed build caches this value.
pub fn declared() -> Config {
  Config(
    [
      albedo_ext_run.extension(),
      albedo_ext_work.extension(),
      albedo_ext_mail.extension(),
      albedo_ext_jj.extension(),
      albedo_ext_git.extension(),
      albedo_ext_worktrees.extension(),
      albedo_ext_agents.extension(),
      albedo_ext_schedule.extension(),
      albedo_ext_paperclips.extension(),
      albedo_ext_checklist.extension(),
      albedo_ext_artifacts.extension(),
      albedo_ext_files.extension(),
      // Diagnostics inspect published formatter output, not unfinished edits.
      formatter.extension(),
      lsp.extension(),
      linter.extension(),
      albedo_ext_memory.extension(),
      albedo_ext_links.extension(worktree.origins()),
      albedo_ext_instructions.extension(),
      albedo_ext_commands.extension(),
      albedo_ext_skills.extension(),
      // Ahead of models.dev: it answers only for its own endpoint, where a
      // shared id such as claude-sonnet-4-6 has Antigravity's limits.
      albedo_ext_antigravity.extension(),
      albedo_ext_opencode_go.extension(),
      albedo_ext_opencode_zen.extension(),
      albedo_ext_github_copilot.extension(),
      albedo_ext_bedrock.extension(),
      albedo_ext_anthropic_api.extension(),
      albedo_ext_claude.extension(),
      albedo_ext_vertex.extension(),
      albedo_ext_google_ai_studio.extension(),
      // Ahead of models.dev: its `perplexity-agent` namespace lists a staler
      // catalog than the Agent API's own /models, and a catalog that answers
      // first is the one the picker shows.
      albedo_ext_perplexity.extension(),
      // Ahead of models.dev: models.dev names no endpoint for Mistral, so this
      // catalog is what answers at api.mistral.ai.
      albedo_ext_mistral.extension(),
      // Before models.dev so Codex's picker keeps its own series filter, and a
      // generic openai endpoint lists its own /models; api.openai.com still
      // gets models.dev's full catalog.
      albedo_ext_codex.extension(),
      albedo_ext_openai.extension(),
      zed.extension(),
      albedo_ext_models.extension(),
      albedo_ext_snapcompact.extension(),
      albedo_ext_rolling.extension(),
      albedo_ext_lcm.memory_extension(),
      // After lcm-memory: the archive covers history past LCM's folds.
      albedo_ext_snapcompact.memory(),
      albedo_ext_lcm.extension(),
      albedo_ext_persistent_agent.extension(),
      albedo_ext_notes.extension(),
      albedo_ext_mcp.configured_extension(),
      albedo_ext_mcp.editor_extension(),
      albedo_ext_remote.extension(),
      albedo_ext_colab.extension(),
      albedo_ext_browser.extension(),
      albedo_ext_cua.extension(),
      albedo_ext_view.extension(),
      albedo_ext_proxy.extension(),
      albedo_ext_webhooks.extension(),
      albedo_ext_discord.extension(),
      albedo_ext_photon.extension(),
      albedo_ext_hooks.extension(),
      albedo_ext_warm.extension(),
      albedo_ext_exa.extension(),
      albedo_ext_web_search.extension(),
      albedo_ext_imagegen.extension(),
    ],
    [
      "run", "work", "mail", "jj", "git", "worktrees", "agents", "schedule",
      "files", "memory", "links", "instructions", "commands", "skills",
      "paperclips", "artifacts", "models", "openai", "codex", "antigravity",
      "opencode-go", "opencode-zen", "bedrock", "claude", "vertex",
      "google-ai-studio", "rolling", "snapcompact-memory", "lcm-memory", "notes",
      "remote", "browser", "warm", "exa", "perplexity", "mistral",
      "github-copilot", "web-search", "editor-mcp", "anthropic-api", "zed",
    ],
  )
}

/// The ACP plan reads retained checklist rows even if the session later
/// disables the extension. A host without the extension has no checklist.
pub fn acp_plan(
  installed: List(extension.Extension),
  ledger: store.Store,
  session: String,
) -> Result(List(json.Json), String) {
  case extension.named(installed, "checklist") {
    Ok(owner) ->
      albedo_ext_checklist.plan(
        extension.session_storage_of(owner, ledger, session),
        session,
      )
    Error(_) -> Ok([])
  }
}
