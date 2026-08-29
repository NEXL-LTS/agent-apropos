require "json"
require "../check"
require "../environment"
require "../filesystem"
require "../hooks/payload"

module AgentApropos
  module Agents
    abstract class Agent
      AGENT_APROPOS_HOOK_PREFIX = "agent-apropos hook"

      SHELL_MATCHER = "Bash"

      ALLOW_OUTSIDE_FLAG = "--allow-outside-repo"

      abstract def name : String

      abstract def config_relative : Path

      protected abstract def config_content(existing : String?, options : Init::Options) : String

      def scaffold(repo_root : Path, fs : Filesystem, options : Init::Options, stdout : IO) : Nil
        path = repo_root.join(config_relative).to_s
        existing = fs.read?(path)
        Init.sync(fs, options, stdout, path, config_content(existing, options), existing, config_relative.to_posix.to_s)
      end

      def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)
        [hook_check(repo_root, fs, env)]
      end

      protected abstract def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check

      def configured?(repo_root : Path, fs : Filesystem) : Bool
        fs.exists?(repo_root.join(config_relative).to_s)
      end

      abstract def skill_root : Path

      abstract def read?(payload : Hook::Payload) : Bool

      protected def hook_command(base : String, options : Init::Options) : String
        hook_command(base, options.allow_outside_repo)
      end

      protected def hook_command(base : String, allow_outside : Bool) : String
        allow_outside ? "#{base} #{ALLOW_OUTSIDE_FLAG}" : base
      end

      protected def agent_apropos_group?(group : JSON::Any) : Bool
        hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?)
        return false unless hooks
        hooks.any? do |hook|
          command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
          !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX)
        end
      end

      def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
        existing
      end

      protected def sync_standard_shell_hook(existing : String?, label : String, wire : Bool,
                                             pre_base : String, post_base : String, timeout : Int64) : String?
        root = Init.settings_root(existing, label)
        hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any
        allow_outside = owned_allow_outside?(hooks)

        updated_hooks = hooks.dup
        sync_event_hook(updated_hooks, "PreToolUse", hook_command(pre_base, allow_outside), wire, timeout)
        sync_event_hook(updated_hooks, "PostToolUse", hook_command(post_base, allow_outside), wire, timeout)
        return existing if updated_hooks == hooks

        updated_root = root.dup
        if updated_hooks.empty?
          updated_root.delete("hooks")
        else
          updated_root["hooks"] = JSON::Any.new(updated_hooks)
        end
        JSON::Any.new(updated_root).to_pretty_json + "\n"
      end

      private def sync_event_hook(hooks : Hash(String, JSON::Any), event : String,
                                  command : String, wire : Bool, timeout : Int64) : Nil
        groups = event_groups(hooks, event)
        updated = sync_shell_group(groups, command, wire, timeout)
        return if updated == groups
        if updated.empty?
          hooks.delete(event)
        else
          hooks[event] = JSON::Any.new(updated)
        end
      end

      private def event_groups(hooks : Hash(String, JSON::Any), event : String) : Array(JSON::Any)
        (hooks[event]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
      end

      private def sync_shell_group(groups : Array(JSON::Any), command : String, wire : Bool, timeout : Int64) : Array(JSON::Any)
        wire ? ensure_commands(groups, SHELL_MATCHER, [command], timeout) : drop_owned_commands(groups, SHELL_MATCHER)
      end

      private def owned_allow_outside?(hooks : Hash(String, JSON::Any)) : Bool
        hooks.each_value.any? do |groups|
          (groups.as_a? || [] of JSON::Any).any? do |group|
            (group.as_h?.try(&.["hooks"]?).try(&.as_a?) || [] of JSON::Any).any? do |hook|
              command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
              !command.nil? && command.starts_with?(AGENT_APROPOS_HOOK_PREFIX) && command.ends_with?(ALLOW_OUTSIDE_FLAG)
            end
          end
        end
      end

      private def ensure_commands(groups : Array(JSON::Any), matcher : String,
                                  commands : Array(String), timeout : Int64) : Array(JSON::Any)
        matching = groups.each_index.select { |i| group_matcher(groups[i]) == matcher }.to_a
        return groups + [hook_entry_group(matcher, commands, timeout)] if matching.empty?

        groups = groups.dup
        matching.each { |i| groups[i] = refresh_owned_hooks(groups[i], commands, timeout) }

        present = matching.flat_map { |i| present_commands(groups[i]) }
        missing = commands.reject { |command| present.includes?(command) }
        return groups if missing.empty?

        target = matching.first
        groups[target] = append_hook_entries(groups[target], missing, timeout)
        groups
      end

      private def drop_owned_commands(groups : Array(JSON::Any), matcher : String) : Array(JSON::Any)
        groups.compact_map do |group|
          next group unless group_matcher(group) == matcher
          kept = (group.as_h?.try(&.["hooks"]?).try(&.as_a?) || [] of JSON::Any).reject do |hook|
            hook.as_h?.try(&.["command"]?).try(&.as_s?).try(&.starts_with?(AGENT_APROPOS_HOOK_PREFIX))
          end
          next nil if kept.empty?
          hash = group.as_h.dup
          hash["hooks"] = JSON::Any.new(kept)
          JSON::Any.new(hash)
        end
      end

      private def group_matcher(group : JSON::Any) : String?
        group.as_h?.try(&.["matcher"]?).try(&.as_s?)
      end

      private def present_commands(group : JSON::Any) : Array(String)
        hooks = group.as_h?.try(&.["hooks"]?).try(&.as_a?) || [] of JSON::Any
        hooks.compact_map { |hook| hook.as_h?.try(&.["command"]?).try(&.as_s?) }
      end

      private def refresh_owned_hooks(group : JSON::Any, commands : Array(String), timeout : Int64) : JSON::Any
        hash = group.as_h.dup
        present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
        refreshed = present.map do |hook|
          command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
          next hook unless command
          target = commands.includes?(command) ? command : upgrade_target(command, commands)
          target ? hook_entry(target, timeout) : hook
        end
        hash["hooks"] = JSON::Any.new(refreshed)
        JSON::Any.new(hash)
      end

      private def upgrade_target(command : String, commands : Array(String)) : String?
        return nil unless command.starts_with?(AGENT_APROPOS_HOOK_PREFIX)
        if command.starts_with?("agent-apropos hook pre")
          commands.find(&.starts_with?("agent-apropos hook pre"))
        elsif command.starts_with?("agent-apropos hook post")
          commands.find(&.starts_with?("agent-apropos hook post"))
        end
      end

      private def append_hook_entries(group : JSON::Any, commands : Array(String), timeout : Int64) : JSON::Any
        hash = group.as_h.dup
        present = hash["hooks"]?.try(&.as_a?) || [] of JSON::Any
        hash["hooks"] = JSON::Any.new(present + commands.map { |command| hook_entry(command, timeout) })
        JSON::Any.new(hash)
      end

      private def hook_entry_group(matcher : String, commands : Array(String), timeout : Int64) : JSON::Any
        JSON::Any.new({
          "matcher" => JSON::Any.new(matcher),
          "hooks"   => JSON::Any.new(commands.map { |command| hook_entry(command, timeout) }),
        })
      end

      private def hook_entry(command : String, timeout : Int64) : JSON::Any
        JSON::Any.new({
          "type"    => JSON::Any.new("command"),
          "command" => JSON::Any.new(command),
          "timeout" => JSON::Any.new(timeout),
        })
      end
    end
  end
end
