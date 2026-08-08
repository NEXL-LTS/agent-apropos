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

  # Codex CLI's own `apply_patch` tool: `tool_input.command` is a whole patch
  # envelope, not a single file_path/content pair — confirmed against a real
  # captured Codex hook payload, not upstream docs.
  describe "#file_edits" do
    it "returns a single-element edit for a Claude-style Edit payload" do
      json = %({"tool_name":"Edit","tool_input":{"file_path":"a.cr","new_string":"b"}})
      edits = parse(json).file_edits
      edits.size.should eq(1)
      edits[0].path.should eq("a.cr")
      edits[0].written_contents.should eq(["b"])
    end

    it "is empty for a payload with no file_path (e.g. Codex's Bash tool)" do
      json = %({"tool_name":"Bash","tool_input":{"command":"echo hi"}})
      parse(json).file_edits.should be_empty
    end

    it "parses a single Add File section" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Add File: a.py\n+line one\n+line two\n*** End Patch\n"},
      }.to_json
      edits = parse(json).file_edits
      edits.size.should eq(1)
      edits[0].path.should eq("a.py")
      edits[0].written_contents.should eq(["line one", "line two"])
    end

    it "parses a single Update File section, keeping only the added lines" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Update File: a.py\n@@\n def add(a, b):\n+    \"\"\"docstring\"\"\"\n     return a + b\n*** End Patch\n"},
      }.to_json
      edits = parse(json).file_edits
      edits.size.should eq(1)
      edits[0].path.should eq("a.py")
      edits[0].written_contents.should eq(["    \"\"\"docstring\"\"\""])
    end

    it "parses several Add/Update sections bundled into one apply_patch call" do
      command = "*** Begin Patch\n" \
                "*** Add File: lib/hello.py\n" \
                "+def add(a, b):\n" \
                "+    return a + b\n" \
                "*** Update File: app/existing.py\n" \
                "@@\n" \
                " def add(a, b):\n" \
                "+    \"\"\"docstring\"\"\"\n" \
                "     return a + b\n" \
                "*** End Patch\n"
      json = {tool_name: "apply_patch", tool_input: {command: command}}.to_json
      edits = parse(json).file_edits
      edits.map(&.path).should eq(["lib/hello.py", "app/existing.py"])
      edits[0].written_contents.should eq(["def add(a, b):", "    return a + b"])
      edits[1].written_contents.should eq(["    \"\"\"docstring\"\"\""])
    end

    it "skips a Delete File section entirely — no content to match a rule against" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Delete File: gone.py\n*** End Patch\n"},
      }.to_json
      parse(json).file_edits.should be_empty
    end

    it "honors a Move to line as the file's final path" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Update File: old_name.py\n*** Move to: new_name.py\n@@\n context\n+added\n*** End Patch\n"},
      }.to_json
      edits = parse(json).file_edits
      edits.size.should eq(1)
      edits[0].path.should eq("new_name.py")
      edits[0].written_contents.should eq(["added"])
    end

    it "is empty for a nil or blank patch command" do
      parse(%({"tool_name":"apply_patch","tool_input":{}})).file_edits.should be_empty
    end

    it "skips a malformed Add File marker with no path, rather than producing a root-path edit" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Add File: \n+stray content\n*** End Patch\n"},
      }.to_json
      parse(json).file_edits.should be_empty
    end

    it "ignores a malformed Move to line with no path, keeping the section's original path" do
      json = {
        tool_name:  "apply_patch",
        tool_input: {command: "*** Begin Patch\n*** Update File: keep.py\n*** Move to: \n@@\n context\n+added\n*** End Patch\n"},
      }.to_json
      edits = parse(json).file_edits
      edits.size.should eq(1)
      edits[0].path.should eq("keep.py")
      edits[0].written_contents.should eq(["added"])
    end
  end
end
