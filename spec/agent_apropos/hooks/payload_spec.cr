require "../../spec_helper"

private def parse(json : String) : AgentApropos::Hook::Payload
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Hook::Payload do
  describe ".parse" do
    it "parses a PreToolUse Edit payload" do
      json = {
        session_id:      "abc123",
        tool_name:       "Edit",
        cwd:             "/repo",
        transcript_path: "/home/u/.claude/x.jsonl",
        tool_input:      {file_path: "app/jobs/m.cr", old_string: "a", new_string: "b"},
      }.to_json

      payload = parse(json)
      payload.session_id.should eq("abc123")
      payload.tool_name.should eq("Edit")
      payload.cwd.should eq("/repo")
      payload.file_path.should eq("app/jobs/m.cr")
    end

    it "returns nil for malformed JSON (fail open)" do
      AgentApropos::Hook::Payload.parse("{not json").should be_nil
    end

    it "tolerates a payload with no tool_input at all" do
      payload = parse(%({"session_id":"s"}))
      payload.file_path.should be_nil
      payload.written_contents.should be_empty
    end

    it "ignores unknown top-level and tool_input keys" do
      json = %({"future_field":1,"tool_input":{"file_path":"a.cr","extra":true}})
      parse(json).file_path.should eq("a.cr")
    end
  end

  describe "#written_contents" do
    it "returns a Write's content" do
      json = %({"tool_input":{"file_path":"a.cr","content":"hello"}})
      parse(json).written_contents.should eq(["hello"])
    end

    it "returns an Edit's new_string" do
      json = %({"tool_input":{"file_path":"a.cr","new_string":"edited"}})
      parse(json).written_contents.should eq(["edited"])
    end

    it "collects every new_string of a batch edit" do
      json = %({"tool_input":{"file_path":"a.cr","edits":[{"new_string":"x"},{"new_string":"y"},{}]}})
      parse(json).written_contents.should eq(["x", "y"])
    end
  end

  # GitHub Copilot CLI's own wire format, confirmed against a real captured
  # hook payload (upstream docs type toolArgs as `unknown`): camelCase
  # top-level fields, and toolArgs arrives as a JSON-encoded STRING (not a
  # nested object), keyed by path/file_text/old_str/new_str rather than
  # file_path/content/new_string. `Payload` understands this dialect
  # natively so Copilot's hook config can call `agent-apropos hook pre`/`post`
  # directly, with no bridge script translating one shape into the other.
  describe "Copilot CLI payload shape" do
    it "reads sessionId (camelCase) as session_id" do
      json = %({"sessionId":"abc123","toolName":"view","cwd":"/repo",) +
             %("toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"})
      parse(json).session_id.should eq("abc123")
    end

    it "reads toolName (camelCase) as tool_name" do
      json = %({"toolName":"view","toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"})
      parse(json).tool_name.should eq("view")
    end

    it "reads path out of toolArgs's JSON-encoded string as file_path" do
      json = %({"toolName":"view","toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"})
      parse(json).file_path.should eq("/repo/a.cr")
    end

    it "reads a create tool's file_text as written content" do
      json = %({"toolName":"create",) +
             %("toolArgs":"{\\"path\\":\\"/repo/a.cr\\",\\"file_text\\":\\"hello\\"}"})
      parse(json).written_contents.should eq(["hello"])
    end

    it "reads an edit tool's new_str as written content" do
      json = %({"toolName":"edit",) +
             %("toolArgs":"{\\"path\\":\\"/repo/a.cr\\",\\"old_str\\":\\"a\\",\\"new_str\\":\\"b\\"}"})
      parse(json).written_contents.should eq(["b"])
    end

    it "reports #copilot? true only when toolArgs is present" do
      copilot = %({"toolName":"view","toolArgs":"{\\"path\\":\\"/repo/a.cr\\"}"})
      parse(copilot).copilot?.should be_true

      claude = %({"tool_input":{"file_path":"a.cr"}})
      parse(claude).copilot?.should be_false
    end

    it "tolerates a malformed toolArgs string (fail open)" do
      json = %({"toolName":"view","toolArgs":"{not json"})
      payload = parse(json)
      payload.file_path.should be_nil
      payload.written_contents.should be_empty
      # toolArgs was present but unparseable — still Copilot-shaped for
      # emit's purposes, not silently misidentified as some other agent.
      payload.copilot?.should be_true
    end

    it "tolerates a payload with no toolArgs at all when checked for Copilot shape" do
      parse(%({"tool_name":"Edit"})).copilot?.should be_false
    end
  end
end
