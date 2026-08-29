require "../../spec_helper"

# Contract test for the captured hook payloads: these fixtures — not
# prose — are the authoritative record of the `tool_input` field names. If an
# upstream rename breaks parsing, the re-captured fixture is where the truth is
# updated and these assertions catch the drift.
private def parse_fixture(name : String) : AgentApropos::Hook::Payload
  json = File.read(File.join(__DIR__, "..", "..", "fixtures", "hook_payloads", name))
  AgentApropos::Hook::Payload.parse(json) || raise "fixture #{name} failed to parse"
end

describe "hook payload fixtures" do
  it "parses a PreToolUse Edit capture" do
    payload = parse_fixture("pre_edit.json")
    payload.tool_name.should eq("Edit")
    payload.cwd.should eq("/repo")
    payload.file_path.should eq("app/jobs/mailer_job.cr")
    payload.written_contents.should eq(["new"])
  end

  it "parses a PostToolUse Write capture" do
    payload = parse_fixture("post_write.json")
    payload.file_path.should eq("db/migrate/001_create.cr")
    payload.written_contents.first.should contain("transaction")
  end

  it "parses a batch-edit capture, collecting each new_string" do
    payload = parse_fixture("post_multiedit.json")
    payload.written_contents.should eq(["b", "User.update_all(active: true)"])
  end

  it "parses a Codex PreToolUse apply_patch capture bundling an Add and an Update" do
    payload = parse_fixture("codex_pre_tool_use_apply_patch.json")
    payload.tool_name.should eq("apply_patch")
    edits = payload.file_edits
    edits.map(&.path).should eq(["/repo/lib/hello.cr", "/repo/app/jobs/mailer_job.cr"])
    edits[0].written_contents.should eq(["def add(a, b)", "  a + b", "end"])
    edits[1].written_contents.should eq(["  # sum two numbers"])
  end

  it "parses a Codex PostToolUse apply_patch capture the same way as its PreToolUse pair" do
    payload = parse_fixture("codex_post_tool_use_apply_patch.json")
    payload.file_edits.map(&.path).should eq(["/repo/lib/hello.cr", "/repo/app/jobs/mailer_job.cr"])
  end

  it "has no file_edits for a Codex Bash capture (no file_path in a shell command)" do
    payload = parse_fixture("codex_pre_tool_use_bash.json")
    payload.tool_name.should eq("Bash")
    payload.file_edits.should be_empty
  end

  it "parses a Codex apply_patch Delete File section as a removal, not a discarded edit" do
    payload = parse_fixture("codex_pre_tool_use_apply_patch_delete.json")
    payload.tool_name.should eq("apply_patch")
    payload.file_edits.should be_empty
    payload.removals.map(&.path).should eq(["/repo/lib/old_helper.cr"])
  end
end
