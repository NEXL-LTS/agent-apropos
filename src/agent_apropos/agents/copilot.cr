require "json"
require "./agent"

module AgentApropos
  module Agents
    class Copilot < Agent
      HOOKS_RELATIVE = Path[".github", "hooks", "agent-apropos.json"]

      HOOK_TIMEOUT = 10

      HOOK_PRE_BASE  = "agent-apropos hook pre --tool copilot"
      HOOK_POST_BASE = "agent-apropos hook post --tool copilot"

      BASH_MATCHER = "bash"

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

      def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
        root = Init.settings_root(existing, label)
        hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        entries = (hooks["postToolUse"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        allow_outside = owned_allow_outside?(entries)

        updated = wire ? ensure_bash_entries(entries, allow_outside) : drop_bash_entries(entries)
        return existing if updated == entries

        updated_hooks = hooks.dup
        if updated.empty?
          updated_hooks.delete("postToolUse")
        else
          updated_hooks["postToolUse"] = JSON::Any.new(updated)
        end

        updated_root = root.dup
        if updated_hooks.empty?
          updated_root.delete("hooks")
        else
          updated_root["hooks"] = JSON::Any.new(updated_hooks)
        end
        JSON::Any.new(updated_root).to_pretty_json + "\n"
      end

      private def owned_allow_outside?(entries : Array(JSON::Any)) : Bool
        entries.any? do |entry|
          command = entry.as_h?.try(&.["command"]?).try(&.as_s?)
          !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX) && command.ends_with?(ALLOW_OUTSIDE_FLAG)
        end
      end

      private def ensure_bash_entries(entries : Array(JSON::Any), allow_outside : Bool) : Array(JSON::Any)
        desired = [hook_command(HOOK_PRE_BASE, allow_outside), hook_command(HOOK_POST_BASE, allow_outside)]
        refreshed = entries.map { |entry| refresh_bash_entry(entry, desired) }
        present = bash_commands(refreshed)
        missing = desired.reject { |command| present.includes?(command) }
        refreshed + missing.map { |command| bash_entry(command) }
      end

      private def refresh_bash_entry(entry : JSON::Any, desired : Array(String)) : JSON::Any
        hash = entry.as_h?
        return entry unless hash
        return entry unless hash["matcher"]?.try(&.as_s?) == BASH_MATCHER
        command = hash["command"]?.try(&.as_s?)
        return entry unless command
        target = desired.includes?(command) ? command : upgrade_bash_target(command, desired)
        target ? bash_entry(target) : entry
      end

      private def upgrade_bash_target(command : String, desired : Array(String)) : String?
        if command.starts_with?(HOOK_PRE_BASE)
          desired.find(&.starts_with?(HOOK_PRE_BASE))
        elsif command.starts_with?(HOOK_POST_BASE)
          desired.find(&.starts_with?(HOOK_POST_BASE))
        end
      end

      private def drop_bash_entries(entries : Array(JSON::Any)) : Array(JSON::Any)
        entries.reject do |entry|
          hash = entry.as_h?
          next false unless hash
          command = hash["command"]?.try(&.as_s?)
          hash["matcher"]?.try(&.as_s?) == BASH_MATCHER &&
            !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX)
        end
      end

      private def bash_commands(entries : Array(JSON::Any)) : Array(String)
        entries.compact_map do |entry|
          hash = entry.as_h?
          next nil unless hash
          next nil unless hash["matcher"]?.try(&.as_s?) == BASH_MATCHER
          hash["command"]?.try(&.as_s?)
        end
      end

      private def bash_entry(command : String) : JSON::Any
        JSON::Any.new({
          "type"       => JSON::Any.new("command"),
          "matcher"    => JSON::Any.new(BASH_MATCHER),
          "command"    => JSON::Any.new(command),
          "timeoutSec" => JSON::Any.new(HOOK_TIMEOUT.to_i64),
        })
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
