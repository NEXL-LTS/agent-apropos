require "json"
require "./agent"

module AgentApropos
  module Agents
    class Copilot < Agent
      HOOKS_RELATIVE = Path[".github", "hooks", "agent-apropos.json"]

      HOOK_TIMEOUT = 10

      HOOK_PRE_BASE  = "agent-apropos hook pre --tool copilot"
      HOOK_POST_BASE = "agent-apropos hook post --tool copilot"

      def name : String
        "copilot"
      end

      def read?(payload : Hook::Payload) : Bool
        payload.tool_name == "view"
      end

      def config_relative : Path
        HOOKS_RELATIVE
      end

      def skill_root : Path
        Path[".claude", "skills"]
      end

      protected def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
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

      protected def config_content(existing : String?, options : Init::Options) : String
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
