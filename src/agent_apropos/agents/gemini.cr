require "json"
require "./agent"

module AgentApropos
  module Agents
    class Gemini < Agent
      SETTINGS_RELATIVE = Path[".gemini", "settings.json"]

      CONTEXT_FILENAME = "AGENTS.md"

      HOOK_PRE_BASE  = "agent-apropos hook pre --tool gemini"
      HOOK_POST_BASE = "agent-apropos hook post --tool gemini"

      HOOK_TIMEOUT = 10_000_i64

      def name : String
        "gemini"
      end

      def read?(payload : Hook::Payload) : Bool
        payload.tool_name == "read_file"
      end

      def config_relative : Path
        SETTINGS_RELATIVE
      end

      def skill_root : Path
        Path[".gemini", "skills"]
      end

      protected def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
        unless env.which("gemini")
          return Check.new(:ok, "gemini", "not on PATH; skipped hook check")
        end
        content = fs.read?(repo_root.join(SETTINGS_RELATIVE).to_s)
        return Check.new(:warn, "gemini", ".gemini/settings.json absent; run `agent-apropos init --tool gemini`") unless content

        wired = wired?(content)
        return Check.new(:warn, "gemini", ".gemini/settings.json is not valid JSON") if wired.nil?

        if wired
          Check.new(:ok, "gemini", "AfterTool hook wired")
        else
          Check.new(:warn, "gemini", "AfterTool hook absent; run `agent-apropos init --tool gemini`")
        end
      end

      private def wired?(content : String) : Bool?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        groups = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?).try(&.["AfterTool"]?).try(&.as_a?)
        return false unless groups
        groups.compact_map(&.as_h?).any? do |group|
          commands = (group["hooks"]?.try(&.as_a?) || [] of JSON::Any)
            .compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
          commands.any?(&.starts_with?(HOOK_PRE_BASE)) && commands.any?(&.starts_with?(HOOK_POST_BASE))
        end
      end

      protected def config_content(existing : String?, options : Init::Options) : String
        commands = [hook_command(HOOK_PRE_BASE, options), hook_command(HOOK_POST_BASE, options)]
        root = Init.settings_root(existing, ".gemini/settings.json")
        hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        groups = (hooks["AfterTool"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        groups = ensure_group(groups, commands)
        groups = ensure_read_group(groups, commands)
        hooks["AfterTool"] = JSON::Any.new(groups)
        root["hooks"] = JSON::Any.new(hooks)
        root["context"] = merged_context(root["context"]?)
        JSON::Any.new(root).to_pretty_json + "\n"
      end

      private def ensure_group(groups : Array(JSON::Any), commands : Array(String)) : Array(JSON::Any)
        index = groups.index { |group| agent_apropos_group?(group) && !read_group?(group) }
        return groups + [agent_apropos_group(commands)] if index.nil?

        groups = groups.dup
        groups[index] = with_missing_hooks(groups[index], commands)
        groups
      end

      private def read_group?(group : JSON::Any) : Bool
        group.as_h?.try(&.["matcher"]?).try(&.as_s?) == "read_file"
      end

      private def with_missing_hooks(group : JSON::Any, commands : Array(String)) : JSON::Any
        hash = group.as_h.dup
        refreshed = map_hooks(group) do |entry, command|
          next entry unless command
          target = commands.includes?(command) ? command : upgrade_target(command, commands)
          target ? hook(target) : entry
        end
        present_commands = refreshed.compact_map { |entry| entry.as_h?.try(&.["command"]?).try(&.as_s?) }
        missing = commands.reject { |command| present_commands.includes?(command) }
        hash["hooks"] = JSON::Any.new(refreshed + missing.map { |command| hook(command) })
        JSON::Any.new(hash)
      end

      private def upgrade_target(command : String, desired : Array(String)) : String?
        return nil unless command.starts_with?("agent-apropos hook")
        if command.starts_with?("agent-apropos hook pre")
          desired.find(&.starts_with?("agent-apropos hook pre"))
        elsif command.starts_with?("agent-apropos hook post")
          desired.find(&.starts_with?("agent-apropos hook post"))
        end
      end

      private def ensure_read_group(groups : Array(JSON::Any), commands : Array(String)) : Array(JSON::Any)
        index = groups.index { |group| read_group?(group) }
        return groups + [read_group(commands[0])] if index.nil?

        groups = groups.dup
        groups[index] = with_missing_read_hook(groups[index], commands[0])
        groups
      end

      private def with_missing_read_hook(group : JSON::Any, target : String) : JSON::Any
        hash = group.as_h.dup
        refreshed = map_hooks(group) do |entry, command|
          command && command.starts_with?("agent-apropos hook pre") ? hook(target) : entry
        end
        has_target = refreshed.any? { |entry| entry.as_h?.try(&.["command"]?).try(&.as_s?) == target }
        hash["hooks"] = JSON::Any.new(has_target ? refreshed : refreshed + [hook(target)])
        JSON::Any.new(hash)
      end

      private def read_group(command : String) : JSON::Any
        JSON::Any.new({
          "matcher" => JSON::Any.new("read_file"),
          "hooks"   => JSON::Any.new([hook(command)]),
        })
      end

      private def map_hooks(group : JSON::Any, & : JSON::Any, String? -> JSON::Any) : Array(JSON::Any)
        present = group.as_h["hooks"]?.try(&.as_a?) || [] of JSON::Any
        present.map do |entry|
          yield entry, entry.as_h?.try(&.["command"]?).try(&.as_s?)
        end
      end

      private def merged_context(existing : JSON::Any?) : JSON::Any
        context = (existing.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        names = context["fileName"]?
        list = names.try(&.as_a?) || names.try { |name| [name] } || [] of JSON::Any
        unless list.any? { |name| name.as_s? == CONTEXT_FILENAME }
          list = list + [JSON::Any.new(CONTEXT_FILENAME)]
        end
        context["fileName"] = JSON::Any.new(list)
        JSON::Any.new(context)
      end

      private def agent_apropos_group(commands : Array(String)) : JSON::Any
        JSON::Any.new({
          "matcher" => JSON::Any.new("write_file|replace"),
          "hooks"   => JSON::Any.new(commands.map { |command| hook(command) }),
        })
      end

      private def hook(command : String) : JSON::Any
        JSON::Any.new({
          "type"    => JSON::Any.new("command"),
          "command" => JSON::Any.new(command),
          "timeout" => JSON::Any.new(HOOK_TIMEOUT),
        })
      end
    end
  end
end
