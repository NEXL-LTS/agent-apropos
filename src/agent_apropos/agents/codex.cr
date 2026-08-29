require "json"
require "./agent"

module AgentApropos
  module Agents
    class Codex < Agent
      HOOKS_RELATIVE = Path[".codex", "hooks.json"]

      HOOK_PRE_BASE  = "agent-apropos hook pre --tool codex"
      HOOK_POST_BASE = "agent-apropos hook post --tool codex"

      HOOK_TIMEOUT = 10

      MATCHER = "apply_patch"

      def name : String
        "codex"
      end

      def read?(payload : Hook::Payload) : Bool
        false
      end

      def config_relative : Path
        HOOKS_RELATIVE
      end

      def skill_root : Path
        Path[".codex", "skills"]
      end

      def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
        sync_standard_shell_hook(existing, label, wire, HOOK_PRE_BASE, HOOK_POST_BASE, HOOK_TIMEOUT.to_i64)
      end

      protected def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
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

      private def wired?(content : String) : Bool?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        command_prefix_present?(parsed, "PreToolUse", HOOK_PRE_BASE) &&
          command_prefix_present?(parsed, "PostToolUse", HOOK_POST_BASE)
      end

      private def command_prefix_present?(parsed : JSON::Any, event : String, prefix : String) : Bool
        groups = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.[event]?).try(&.as_a?)
        return false unless groups
        groups.compact_map(&.as_h?)
          .select { |group| group["matcher"]?.try(&.as_s?) == MATCHER }
          .any? do |group|
            (group["hooks"]?.try(&.as_a?) || [] of JSON::Any)
              .compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
              .any?(&.starts_with?(prefix))
          end
      end

      protected def config_content(existing : String?, options : Init::Options) : String
        hook_pre = hook_command(HOOK_PRE_BASE, options)
        hook_post = hook_command(HOOK_POST_BASE, options)
        <<-JSON
          {
            "hooks": {
              "PreToolUse": [
                {
                  "matcher": "#{MATCHER}",
                  "hooks": [
                    {
                      "type": "command",
                      "command": "#{hook_pre}",
                      "timeout": #{HOOK_TIMEOUT}
                    }
                  ]
                }
              ],
              "PostToolUse": [
                {
                  "matcher": "#{MATCHER}",
                  "hooks": [
                    {
                      "type": "command",
                      "command": "#{hook_post}",
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
end
