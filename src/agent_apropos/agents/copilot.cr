require "json"
require "./agent"

module AgentApropos
  module Agents
    # GitHub Copilot CLI: writes `.github/hooks/agent-apropos.json`. Unlike
    # Claude/Gemini's single shared settings file, Copilot CLI loads every
    # `.github/hooks/*.json` in the repo independently, so this file is
    # entirely agent-apropos-owned — a plain `Init.sync`, no
    # foreign-key-preserving merge needed.
    #
    # Copilot's `preToolUse` output schema is `permissionDecision`/
    # `modifiedArgs` only (no context field), so — as with Gemini's
    # `AfterTool` — both Layer 2 and Layer 3 are wired onto `postToolUse`
    # instead, matched the same way Gemini's are: a `view`-only group
    # carrying just `agent-apropos hook pre`, and a `create|edit` group
    # carrying both. The commands below call `agent-apropos hook pre`/`post`
    # directly — no bridge script — because `Hook::Payload` and `Hook.emit`
    # understand Copilot's dialect natively: `toolArgs` as a JSON-encoded
    # *string* keyed by `path`/`file_text`/`old_str`/`new_str` (confirmed
    # against a real captured Copilot CLI hook payload, not upstream docs —
    # its own reference types `toolArgs` as `unknown`), and a flat
    # `additionalContext` reply instead of the `hookSpecificOutput` envelope
    # every other wired agent expects.
    class Copilot < Agent
      HOOKS_RELATIVE = Path[".github", "hooks", "agent-apropos.json"]

      # Copilot CLI's own hook `timeout` field (`timeoutSec`) is seconds,
      # like Claude Code's.
      HOOK_TIMEOUT = 10

      # `--tool copilot` tells the binary which dialect wired the invocation,
      # so `Hook` can label a Cause's layer as read-triggered without parsing
      # `tool_name` itself. The `view` matcher and the `create|edit` matcher
      # share the identical hook-pre command — the read/write distinction
      # comes from `Copilot#read?` inspecting the payload at run time, not
      # from which matcher fired. `_BASE` because `Agent#hook_command` may
      # append `--allow-outside-repo` to each (see `hooks_json`).
      HOOK_PRE_BASE  = "agent-apropos hook pre --tool copilot"
      HOOK_POST_BASE = "agent-apropos hook post --tool copilot"

      def name : String
        "copilot"
      end

      def read?(payload : Hook::Payload) : Bool
        payload.tool_name == "view"
      end

      def scaffold(repo_root : Path, fs : Filesystem, options : Init::Options, stdout : IO) : Nil
        path = repo_root.join(HOOKS_RELATIVE).to_s
        existing = fs.read?(path)
        Init.sync(fs, options, stdout, path, hooks_json(options), existing, ".github/hooks/agent-apropos.json")
      end

      # Check for the Copilot CLI binary and that the `create|edit`-matched
      # `postToolUse` group calls both `agent-apropos hook pre` and
      # `... post` directly. No bridge script to check for. Advisory only:
      # never fails, so a Copilot-less repo is not penalised.
      def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)
        [hook_check(repo_root, fs, env)]
      end

      private def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
        unless env.which("copilot")
          return Check.new(:ok, "copilot", "not on PATH; skipped hook check")
        end

        content = fs.read?(repo_root.join(HOOKS_RELATIVE).to_s)
        return Check.new(:warn, "copilot", ".github/hooks/agent-apropos.json absent; run `agent-apropos init --tool copilot`") unless content

        wired = wired?(content)
        return Check.new(:warn, "copilot", ".github/hooks/agent-apropos.json is not valid JSON") if wired.nil?

        if wired
          Check.new(:ok, "copilot", "postToolUse hook wired")
        else
          Check.new(:warn, "copilot", "postToolUse hook absent; run `agent-apropos init --tool copilot`")
        end
      end

      # Whether the `create|edit`-matched `postToolUse` entries include both
      # `agent-apropos hook pre` and `... post`. Checked scoped to that one
      # matcher, not flattened across every `postToolUse` entry: the
      # `view`-matched entry carries only `pre` (Layer 3 needs written
      # content a mere read never has), so a flattened check could see both
      # commands present overall while the write-side entries themselves
      # are missing one. Returns nil when the hooks file is not parseable
      # JSON.
      private def wired?(content : String) : Bool?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        entries = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.["postToolUse"]?).try(&.as_a?)
        return false unless entries

        commands = entries.compact_map(&.as_h?)
          .select { |entry| entry["matcher"]?.try(&.as_s?) == "create|edit" }
          .compact_map { |entry| entry["command"]?.try(&.as_s?) }

        commands.any?(&.starts_with?(HOOK_PRE_BASE)) && commands.any?(&.starts_with?(HOOK_POST_BASE))
      end

      private def hooks_json(options : Init::Options) : String
        hook_pre = hook_command(HOOK_PRE_BASE, options)
        hook_post = hook_command(HOOK_POST_BASE, options)
        <<-JSON
          {
            "version": 1,
            "hooks": {
              "postToolUse": [
                {
                  "type": "command",
                  "matcher": "view",
                  "command": "#{hook_pre}",
                  "timeoutSec": #{HOOK_TIMEOUT}
                },
                {
                  "type": "command",
                  "matcher": "create|edit",
                  "command": "#{hook_pre}",
                  "timeoutSec": #{HOOK_TIMEOUT}
                },
                {
                  "type": "command",
                  "matcher": "create|edit",
                  "command": "#{hook_post}",
                  "timeoutSec": #{HOOK_TIMEOUT}
                }
              ]
            }
          }
          JSON
      end
    end
  end
end
