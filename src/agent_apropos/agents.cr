require "./agents/agent"
require "./agents/claude"
require "./agents/opencode"
require "./agents/gemini"
require "./agents/copilot"
require "./agents/codex"

module AgentApropos
  module Agents
    # Every CLI agent `agent-apropos` knows how to wire hooks for, in a
    # stable order (auto-detect and `doctor` reporting both iterate this).
    # Extend this array as more agents (Cursor CLI, ...) land — no
    # other file needs a new per-agent branch.
    ALL = [
      Claude.new,
      OpenCode.new,
      Gemini.new,
      Copilot.new,
      Codex.new,
    ] of Agent

    # The `--tool <name>` values `Init`/`Doctor` know how to wire, for
    # validating `--tool` flags and auto-detect probing.
    def self.names : Set(String)
      ALL.map(&.name).to_set
    end

    # The agent named by `--tool <name>` on `hook pre`/`hook post`, or `nil`
    # for an absent or unrecognized name (the caller falls back to `.detect`).
    def self.find(name : String?) : Agent?
      return nil unless name
      ALL.find { |agent| agent.name == name }
    end

    # Best-effort fallback when `hook pre`/`hook post` ran without `--tool`
    # (an older wiring, or a manual invocation) — identify the dialect from
    # the payload's own shape. Copilot and Gemini each carry a distinguishing
    # marker (`toolArgs`, `hook_event_name` of `"AfterTool"`); Claude,
    # OpenCode, and Codex are payload-shape-identical by design (Codex's own
    # `hook_event_name` is `"PreToolUse"`/`"PostToolUse"`, same literal
    # values as the event name itself, so it never matches Gemini's marker
    # either — see `Hook`'s doc comment), so this defaults to Claude for all
    # three — a wrong guess here only costs `read?`'s debugging label, never
    # match/injection correctness.
    def self.detect(payload : Hook::Payload) : Agent
      return find("copilot") || Claude.new if payload.copilot?
      return find("gemini") || Claude.new if payload.hook_event_name == "AfterTool"
      find("claude") || Claude.new
    end
  end
end
