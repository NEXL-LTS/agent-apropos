require "json"
require "semantic_version"
require "./agent"

module AgentApropos
  module Agents
    class Claude < Agent
      SETTINGS_RELATIVE = Path[".claude", "settings.json"]

      HOOK_PRE_BASE  = "agent-apropos hook pre --tool claude"
      HOOK_POST_BASE = "agent-apropos hook post --tool claude"

      CLAUDE_HOOK_TIMEOUT = 10_i64

      MIN_CLAUDE_VERSION = "1.0.0"

      def name : String
        "claude"
      end

      def read?(payload : Hook::Payload) : Bool
        payload.tool_name == "Read"
      end

      def config_relative : Path
        SETTINGS_RELATIVE
      end

      def checks(repo_root : Path, fs : Filesystem, env : Environment) : Array(Check)
        super + [capability_check(env)]
      end

      def skill_root : Path
        Path[".claude", "skills"]
      end

      protected def config_content(existing : String?, options : Init::Options) : String
        hook_pre = hook_command(HOOK_PRE_BASE, options)
        hook_post = hook_command(HOOK_POST_BASE, options)

        root = Init.settings_root(existing, ".claude/settings.json")
        hooks = (root["hooks"]?.try(&.as_h?)).try(&.dup) || {} of String => JSON::Any

        pre_groups = (hooks["PreToolUse"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        pre_groups = ensure_commands(pre_groups, "Edit|Write", [hook_pre], CLAUDE_HOOK_TIMEOUT)
        pre_groups = drop_owned_commands(pre_groups, "Read")
        hooks["PreToolUse"] = JSON::Any.new(pre_groups)

        post_groups = (hooks["PostToolUse"]?.try(&.as_a?)).try(&.dup) || [] of JSON::Any
        post_groups = ensure_commands(post_groups, "Edit|Write", [hook_post], CLAUDE_HOOK_TIMEOUT)
        post_groups = ensure_commands(post_groups, "Read", [hook_post], CLAUDE_HOOK_TIMEOUT)
        hooks["PostToolUse"] = JSON::Any.new(post_groups)

        root["hooks"] = JSON::Any.new(hooks)
        JSON::Any.new(root).to_pretty_json + "\n"
      end

      def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
        sync_standard_shell_hook(existing, label, wire, HOOK_PRE_BASE, HOOK_POST_BASE, CLAUDE_HOOK_TIMEOUT)
      end

      protected def hook_check(repo_root : Path, fs : Filesystem, env : Environment) : Check
        content = fs.read?(repo_root.join(SETTINGS_RELATIVE).to_s)
        return Check.new(:fail, "hooks", ".claude/settings.json not found; run `agent-apropos init`") unless content

        events = agent_apropos_events(content)
        return Check.new(:warn, "hooks", ".claude/settings.json is not valid JSON") if events.nil?

        pre = events.includes?("PreToolUse")
        post = events.includes?("PostToolUse")
        if pre && post
          Check.new(:ok, "hooks", "PreToolUse and PostToolUse call agent-apropos")
        elsif pre || post
          Check.new(:warn, "hooks", "only #{pre ? "PreToolUse" : "PostToolUse"} calls agent-apropos; run `agent-apropos init`")
        else
          Check.new(:fail, "hooks", "no agent-apropos hooks wired; run `agent-apropos init`")
        end
      end

      private def agent_apropos_events(content : String) : Set(String)?
        parsed =
          begin
            JSON.parse(content)
          rescue JSON::ParseException
            return nil
          end
        hooks = parsed.as_h?.try(&.["hooks"]?).try(&.as_h?)
        events = Set(String).new
        return events unless hooks
        hooks.each do |event, groups|
          array = groups.as_a?
          next unless array
          events << event if array.any? { |group| agent_apropos_group?(group) }
        end
        events
      end

      private def capability_check(env : Environment) : Check
        return Check.new(:ok, "claude", "not on PATH; skipped PreToolUse capability check") unless env.which("claude")

        output = env.run_capture("claude", ["--version"])
        return Check.new(:warn, "claude", "could not run `claude --version`") unless output

        version = extract_version(output)
        return Check.new(:warn, "claude", "could not parse a version from #{output.strip.inspect}") unless version

        if version >= min_version
          Check.new(:ok, "claude", "#{version} supports PreToolUse additionalContext")
        else
          Check.new(:warn, "claude", "#{version} may lack PreToolUse additionalContext (need >= #{MIN_CLAUDE_VERSION})")
        end
      end

      private def extract_version(output : String) : SemanticVersion?
        match = output.match(/(\d+\.\d+\.\d+)/)
        return nil unless match
        SemanticVersion.parse(match[1])
      end

      private def min_version : SemanticVersion
        SemanticVersion.parse(MIN_CLAUDE_VERSION)
      end
    end
  end
end
