require "../spec_helper"

private def parse(json : String) : AgentApropos::Hook::Payload
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents do
  describe ".names" do
    it "lists every registered agent's name" do
      AgentApropos::Agents.names.should eq(Set{"claude", "opencode", "gemini", "copilot", "codex"})
    end
  end

  describe ".find" do
    it "finds a registered agent by its exact name" do
      AgentApropos::Agents.find("gemini").should be_a(AgentApropos::Agents::Gemini)
    end

    it "returns nil for an unrecognized name" do
      AgentApropos::Agents.find("nonexistent").should be_nil
    end

    it "returns nil for a nil name" do
      AgentApropos::Agents.find(nil).should be_nil
    end
  end

  describe ".detect" do
    it "detects Copilot from its toolArgs-shaped payload" do
      payload = parse(%({"toolName":"view","toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"}))
      AgentApropos::Agents.detect(payload).should be_a(AgentApropos::Agents::Copilot)
    end

    it "detects Gemini from its hook_event_name marker" do
      payload = parse(%({"hook_event_name":"AfterTool","tool_name":"write_file"}))
      AgentApropos::Agents.detect(payload).should be_a(AgentApropos::Agents::Gemini)
    end

    it "defaults to Claude for a Claude-shaped payload" do
      payload = parse(%({"tool_name":"Edit","tool_input":{"file_path":"a.cr"}}))
      AgentApropos::Agents.detect(payload).should be_a(AgentApropos::Agents::Claude)
    end

    it "defaults to Claude for an OpenCode-shaped payload (shape-identical, cosmetic-only impact)" do
      payload = parse(%({"tool_name":"read","tool_input":{"file_path":"a.cr"}}))
      AgentApropos::Agents.detect(payload).should be_a(AgentApropos::Agents::Claude)
    end

    it "defaults to Claude for a Codex-shaped payload (shape-identical, cosmetic-only impact)" do
      payload = parse(%({"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\\n*** End Patch\\n"}}))
      AgentApropos::Agents.detect(payload).should be_a(AgentApropos::Agents::Claude)
    end

    it "returns the registered singleton instances rather than allocating fresh ones" do
      copilot = parse(%({"toolName":"view","toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"}))
      gemini = parse(%({"hook_event_name":"AfterTool","tool_name":"write_file"}))
      claude = parse(%({"tool_name":"Edit","tool_input":{"file_path":"a.cr"}}))

      AgentApropos::Agents.detect(copilot).should be(AgentApropos::Agents.find("copilot"))
      AgentApropos::Agents.detect(gemini).should be(AgentApropos::Agents.find("gemini"))
      AgentApropos::Agents.detect(claude).should be(AgentApropos::Agents.find("claude"))
    end
  end
end
