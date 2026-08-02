require "json"
require "../check"
require "../environment"
require "../filesystem"
require "../hooks/payload"

module AgentApropos
  module Agents
    # One CLI agent `agent-apropos init`/`agent-apropos doctor` know how to wire
    # hooks for (Claude Code, OpenCode, Gemini CLI, GitHub Copilot CLI, ...).
    # `#scaffold` writes or merges this agent's own hook config into the
    # repo; `#checks` (run by `Doctor`) reports whether it is correctly wired.
    # Adding a new agent (Codex, Cursor CLI, ...) is writing one new subclass
    # and registering it in `Agents::ALL` — neither `Init` nor `Doctor` needs
    # a new per-agent branch.
    abstract class Agent
      # agent-apropos identifies its own hook entries by this command prefix, so
      # a merge/probe never mistakes a foreign hook for one it installed.
      AGENT_APROPOS_HOOK_PREFIX = "agent-apropos hook"

      # The `--tool <name>` value / auto-detect PATH probe name.
      abstract def name : String

      # The repo-relative config file `#scaffold` writes or merges this
      # agent's hook wiring into (`.claude/settings.json`,
      # `.codex/hooks.json`, ...).
      abstract def config_relative : Path

      # The desired full content of `config_relative`, given its current
      # bytes (`nil` when the file doesn't exist yet). Agents that merge into
      # a shared settings file (Claude, Gemini) fold `existing` in; agents
      # whose config file is entirely agent-apropos-owned (Codex, Copilot,
      # OpenCode) ignore it and always return the same content.
      protected abstract def config_content(existing : String?, options : Init::Options) : String

      # Write or merge this agent's hook wiring into the repo. Idempotent
      # (safe to re-run) via `Init.sync`, which no-ops when `config_content`
      # matches what's already on disk.
      def scaffold(repo_root : Path, fs : Filesystem, options : Init::Options, stdout : IO) : Nil
        path = repo_root.join(config_relative).to_s
        existing = fs.read?(path)
        Init.sync(fs, options, stdout, path, config_content(existing, options), existing, config_relative.to_posix.to_s)
      end

      # The one check (beyond Claude's extra capability check) every agent
      # reports for `agent-apropos doctor`: whether its hook wiring is
      # present and correct. See `#hook_check`.
      def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)
        [hook_check(repo_root, fs, env)]
      end

      # Probe whether this agent's hook wiring is present and correct, for
      # `agent-apropos doctor`. Every implementation but Claude's is
      # advisory-only (`:ok`/`:warn`, never `:fail`) — an agent that is not
      # on PATH must never penalise a repo that doesn't use it.
      protected abstract def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check

      # Whether this agent's own init-generated hook file exists in the repo
      # — a bare existence probe, unlike `#checks`, which also inspects
      # content for correctness. `Skills.active_roots` uses this to decide
      # whether a skill root is worth generating into at all, so `generate`
      # doesn't scatter e.g. `.gemini/skills/` into a repo that never ran
      # `init --tool gemini`.
      def configured?(repo_root : Path, fs : Filesystem) : Bool
        fs.exists?(repo_root.join(config_relative).to_s)
      end

      # The directory this agent discovers generated skill wrappers from.
      # Not necessarily this agent's *own* directory — OpenCode and Copilot
      # both read Claude Code's `.claude/skills/` natively, so their
      # implementations return that same path rather than one of their own.
      # `Skills::ROOTS`/`Skills.active_roots` are both derived from this
      # across `Agents::ALL`, so adding a new agent never needs a matching
      # edit in `Skills`.
      abstract def skill_root : Path

      # Whether this agent's own dialect marks `payload` as having come from
      # a *read* tool rather than an edit/write one. `Hook` calls this only
      # to label a `SessionState::Cause` for debugging (`"agent"` vs the
      # numeric layer) — it never gates whether a rule is matched or
      # delivered, so a wrong answer here costs a debugging label, not
      # correctness.
      abstract def read?(payload : Hook::Payload) : Bool

      # Append `--allow-outside-repo` to a generated hook command when `init`
      # itself was run with that flag — so a wired hook keeps resolving an
      # intentionally out-of-tree conventions_dir (see `Config.conventions_dir`)
      # without needing to re-consent on every invocation; hook runs
      # non-interactively, so there is no later moment to ask again.
      protected def hook_command(base : String, options : Init::Options) : String
        options.allow_outside_repo ? "#{base} --allow-outside-repo" : base
      end

      # Whether one hook group's `hooks` array carries a command
      # agent-apropos itself installed, keyed on `AGENT_APROPOS_HOOK_PREFIX`.
      # Shared by Claude (across `PreToolUse`/`PostToolUse` groups) and
      # Gemini (across `AfterTool` groups).
      protected def agent_apropos_group?(group : JSON::Any) : Bool
        hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
        return false unless hooks
        hooks.any? do |hook|
          command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
          !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX)
        end
      end
    end
  end
end
