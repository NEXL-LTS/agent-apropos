require "json"
require "../check"
require "../environment"
require "../filesystem"
require "../hooks/payload"

module AgentApropos
  module Agents
    abstract class Agent
      AGENT_APROPOS_HOOK_PREFIX = "agent-apropos hook"

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
        options.allow_outside_repo ? "#{base} --allow-outside-repo" : base
      end

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
