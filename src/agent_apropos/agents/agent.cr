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
        group_hooks(group).any? { |hook| owned_command(hook) }
      end

      def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
        existing
      end

      protected def sync_standard_shell_hook(existing : String?, label : String, wire : Bool,
                                             pre_base : String, post_base : String, timeout : Int64) : String?
        root = Init.settings_root(existing, label)
        hooks = root["hooks"]?.try(&.as_h?) || {} of String => JSON::Any
        allow_outside = owned_allow_outside?(hooks)

        updated = hooks.dup
        sync_event_hook(updated, "PreToolUse", hook_command(pre_base, allow_outside), wire, timeout)
        sync_event_hook(updated, "PostToolUse", hook_command(post_base, allow_outside), wire, timeout)
        return existing if updated == hooks

        if updated.empty?
          root.delete("hooks")
        else
          root["hooks"] = JSON::Any.new(updated)
        end
        JSON::Any.new(root).to_pretty_json + "\n"
      end

      private def sync_event_hook(hooks : Hash(String, JSON::Any), event : String,
                                  command : String, wire : Bool, timeout : Int64) : Nil
        groups = event_groups(hooks, event)
        updated = wire ? ensure_command(groups, SHELL_MATCHER, command, timeout) : drop_owned_commands(groups, SHELL_MATCHER)
        return if updated == groups
        if updated.empty?
          hooks.delete(event)
        else
          hooks[event] = JSON::Any.new(updated)
        end
      end

      private def event_groups(hooks : Hash(String, JSON::Any), event : String) : Array(JSON::Any)
        hooks[event]?.try(&.as_a?) || [] of JSON::Any
      end

      private def owned_allow_outside?(hooks : Hash(String, JSON::Any)) : Bool
        hooks.each_value.any? do |groups|
          (groups.as_a? || [] of JSON::Any).any? do |group|
            group_hooks(group).any? { |hook| owned_command(hook).try(&.split.includes?(ALLOW_OUTSIDE_FLAG)) }
          end
        end
      end

      private def ensure_command(groups : Array(JSON::Any), matcher : String,
                                 command : String, timeout : Int64) : Array(JSON::Any)
        entry = hook_entry(command, timeout)
        target = groups.index { |group| group_matcher(group) == matcher }
        return groups + [hook_entry_group(matcher, entry)] unless target

        refreshed = groups.map { |group| group_matcher(group) == matcher ? refresh_owned_hooks(group, command, entry) : group }
        return refreshed if refreshed.any? { |group| group_matcher(group) == matcher && group_hooks(group).includes?(entry) }
        refreshed[target] = with_hooks(refreshed[target], group_hooks(refreshed[target]) + [entry])
        refreshed
      end

      private def drop_owned_commands(groups : Array(JSON::Any), matcher : String) : Array(JSON::Any)
        groups.compact_map do |group|
          next group unless group_matcher(group) == matcher
          hooks = group_hooks(group)
          kept = hooks.reject { |hook| owned_command(hook) }
          next group if kept == hooks
          with_hooks(group, kept) unless kept.empty?
        end
      end

      private def refresh_owned_hooks(group : JSON::Any, command : String, entry : JSON::Any) : JSON::Any
        hooks = group_hooks(group)
        refreshed = hooks.map { |hook| same_kind?(hook, command) ? entry : hook }
        refreshed == hooks ? group : with_hooks(group, refreshed)
      end

      private def same_kind?(hook : JSON::Any, command : String) : Bool
        owned_command(hook).try(&.split.first(3)) == command.split.first(3)
      end

      private def group_matcher(group : JSON::Any) : String?
        group.as_h?.try(&.["matcher"]?).try(&.as_s?)
      end

      private def group_hooks(group : JSON::Any) : Array(JSON::Any)
        group.as_h?.try(&.["hooks"]?).try(&.as_a?) || [] of JSON::Any
      end

      private def owned_command(hook : JSON::Any) : String?
        command = hook.as_h?.try(&.["command"]?).try(&.as_s?)
        command if command.try(&.starts_with?(AGENT_APROPOS_HOOK_PREFIX))
      end

      private def with_hooks(group : JSON::Any, hooks : Array(JSON::Any)) : JSON::Any
        hash = group.as_h.dup
        hash["hooks"] = JSON::Any.new(hooks)
        JSON::Any.new(hash)
      end

      private def hook_entry_group(matcher : String, entry : JSON::Any) : JSON::Any
        JSON::Any.new({"matcher" => JSON::Any.new(matcher), "hooks" => JSON::Any.new([entry])})
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
