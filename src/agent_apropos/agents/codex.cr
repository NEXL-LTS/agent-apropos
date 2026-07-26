require "json"
require "./agent"

module AgentApropos
  module Agents
    # OpenAI Codex CLI: writes `.codex/hooks.json`. Confirmed against a real
    # captured Codex hook payload, not upstream docs: its `PreToolUse`/
    # `PostToolUse` envelope and reply schema mirror Claude Code's almost
    # exactly — down to naming its shell tool `Bash`, matching Claude's own
    # tool name — including `PreToolUse`'s own
    # `hookSpecificOutput.additionalContext`, so Layer 2 lands *before* the
    # write here, the same as Claude, unlike Gemini/Copilot's post-only
    # degradation.
    #
    # Codex's own file-editing tool, `apply_patch`, is structurally
    # different from every other wired agent's: a single call's
    # `tool_input.command` is a patch envelope (`*** Begin Patch` / `*** Add
    # File:` / `*** Update File:` / `*** End Patch`) that can bundle several
    # files' Add/Update sections into one call. `Hook::Payload#file_edits`
    # and its `ApplyPatch` parser handle this; every other wired dialect is
    # exactly one file per call.
    #
    # Codex has no separate structured "read" tool the way Claude's `Read`
    # or Gemini's `read_file` are — it reads files by shelling out through
    # its own `Bash` tool (`cat`/`sed`/`rg`), which carries no `file_path` —
    # so Layer 2 cannot land on a bare read the way it does for Claude/Gemini
    # (see `#read?`); only `apply_patch` is matched here.
    #
    # Unlike Claude's shared `.claude/settings.json`, `.codex/hooks.json` is
    # entirely agent-apropos-owned here — same reasoning as Copilot's
    # `.github/hooks/agent-apropos.json` — a plain `Init.sync`, no
    # foreign-key-preserving merge needed.
    class Codex < Agent
      HOOKS_RELATIVE = Path[".codex", "hooks.json"]

      # `--tool codex` tells the binary which dialect wired the invocation,
      # so `Hook` can label a Cause's layer without parsing `tool_name`
      # itself.
      HOOK_PRE  = "agent-apropos hook pre --tool codex"
      HOOK_POST = "agent-apropos hook post --tool codex"

      # Codex CLI's own hook `timeout` field is seconds, like Claude Code's
      # — confirmed against a real captured run, not upstream docs.
      HOOK_TIMEOUT = 10

      def name : String
        "codex"
      end

      # Codex has no dedicated read tool (see the class comment) — nothing
      # in its payload distinguishes a read from an edit today, so this
      # always reports false. Non-gating: at most this costs a debugging
      # label, never match/injection correctness (see `Agent#read?`).
      def read?(payload : Hook::Payload) : Bool
        false
      end

      def scaffold(repo_root : Path, fs : Filesystem, options : Init::Options, stdout : IO) : Nil
        path = repo_root.join(HOOKS_RELATIVE).to_s
        existing = fs.read?(path)
        Init.sync(fs, options, stdout, path, HOOKS_JSON, existing, ".codex/hooks.json")
      end

      # Check for the Codex CLI binary and that `.codex/hooks.json` calls
      # both `agent-apropos hook pre` and `... post` on the `apply_patch`
      # matcher. Advisory only: never fails, so a Codex-less repo is not
      # penalised.
      def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)
        [hook_check(repo_root, fs, env)]
      end

      private def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
        unless env.which("codex")
          return Check.new(:ok, "codex", "not on PATH; skipped hook check")
        end

        content = fs.read?(repo_root.join(HOOKS_RELATIVE).to_s)
        return Check.new(:warn, "codex", ".codex/hooks.json absent; run `agent-apropos init --tool codex`") unless content

        wired = wired?(content)
        return Check.new(:warn, "codex", ".codex/hooks.json is not valid JSON") if wired.nil?

        if wired
          Check.new(:ok, "codex", "PreToolUse and PostToolUse call agent-apropos")
        else
          Check.new(:warn, "codex", "hooks absent; run `agent-apropos init --tool codex`")
        end
      end

      # Whether both `PreToolUse` and `PostToolUse` have a group calling
      # their respective agent-apropos command. Returns nil when the hooks
      # file is not parseable JSON.
      private def wired?(content : String) : Bool?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        command_present?(parsed, "PreToolUse", HOOK_PRE) && command_present?(parsed, "PostToolUse", HOOK_POST)
      end

      private def command_present?(parsed : JSON::Any, event : String, command : String) : Bool
        groups = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.[event]?).try(&.as_a?)
        return false unless groups
        groups.compact_map(&.as_h?).any? do |group|
          (group["hooks"]?.try(&.as_a?) || [] of JSON::Any)
            .compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
            .includes?(command)
        end
      end

      HOOKS_JSON = <<-JSON
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "apply_patch",
                "hooks": [
                  {
                    "type": "command",
                    "command": "#{HOOK_PRE}",
                    "timeout": #{HOOK_TIMEOUT}
                  }
                ]
              }
            ],
            "PostToolUse": [
              {
                "matcher": "apply_patch",
                "hooks": [
                  {
                    "type": "command",
                    "command": "#{HOOK_POST}",
                    "timeout": #{HOOK_TIMEOUT}
                  }
                ]
              }
            ]
          }
        }
        JSON
    end
  end
end
