require "./agents/agent"
require "./agents/claude"
require "./agents/opencode"
require "./agents/gemini"
require "./agents/copilot"
require "./agents/codex"

module AgentApropos
  module Agents
    ALL = [
      Claude.new,
      OpenCode.new,
      Gemini.new,
      Copilot.new,
      Codex.new,
    ] of Agent

    def self.names : Set(String)
      ALL.map(&.name).to_set
    end

    def self.find(name : String?) : Agent?
      return nil unless name
      ALL.find { |agent| agent.name == name }
    end

    def self.detect(payload : Hook::Payload) : Agent
      return find("copilot") || Claude.new if payload.copilot?
      return find("gemini") || Claude.new if payload.hook_event_name == "AfterTool"
      find("claude") || Claude.new
    end
  end
end
