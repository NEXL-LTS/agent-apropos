require "../../spec_helper"

private ROOT       = Path["/repo"]
private HOOKS_PATH = "/repo/.github/hooks/agent-apropos.json"

# A configurable Environment double: `present` is the set of CLI agent
# binaries that resolve on PATH.
private class FakeEnv < AgentApropos::Environment
  def initialize(@present : Set(String) = Set(String).new)
  end

  def which(command : String) : String?
    @present.includes?(command) ? "/usr/bin/#{command}" : nil
  end

  def run_capture(command : String, args : Array(String)) : String?
    nil
  end
end

private def run_scaffold(fs : AgentApropos::Filesystem,
                         options : AgentApropos::Init::Options = AgentApropos::Init::Options.new) : String
  stdout = IO::Memory.new
  AgentApropos::Agents::Copilot.new.scaffold(ROOT, fs, options, stdout)
  stdout.to_s
end

private def run_checks(fs : AgentApropos::Filesystem, env : AgentApropos::Environment = FakeEnv.new) : Array(AgentApropos::Check)
  AgentApropos::Agents::Copilot.new.checks(ROOT, fs, env)
end

private def check_named(checks : Array(AgentApropos::Check), name : String) : AgentApropos::Check
  checks.find! { |check| check.name == name }
end

private def payload(tool_name : String) : AgentApropos::Hook::Payload
  json = %({"toolName":"#{tool_name}"})
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents::Copilot do
  describe "#read?" do
    it "is true for Copilot's view tool" do
      AgentApropos::Agents::Copilot.new.read?(payload("view")).should be_true
    end

    it "is false for Copilot's create/edit tools" do
      AgentApropos::Agents::Copilot.new.read?(payload("create")).should be_false
      AgentApropos::Agents::Copilot.new.read?(payload("edit")).should be_false
    end
  end

  describe "#scaffold" do
    it "writes the postToolUse hook config calling agent-apropos hook pre/post directly (no bridge)" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs)

      hooks = fs.files[HOOKS_PATH]
      hooks.should contain(%("postToolUse"))
      hooks.should contain(%("matcher": "view"))
      hooks.should contain(%("matcher": "create|edit"))
      hooks.should contain(%("command": "agent-apropos hook pre --tool copilot"))
      hooks.should contain(%("command": "agent-apropos hook post --tool copilot"))
      hooks.should_not contain("bridge")
      stdout.should contain(".github/hooks/agent-apropos.json")
    end

    it "matches the captured golden output byte-for-byte" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[HOOKS_PATH].should eq(File.read("spec/fixtures/generated/copilot_hooks.json"))
    end

    it "does not wire preToolUse — Copilot's preToolUse output schema cannot inject context" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[HOOKS_PATH].should_not contain("preToolUse")
    end

    it "is idempotent — re-running reports current and does not rewrite the file" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      before = fs.files[HOOKS_PATH]

      stdout = run_scaffold(fs)
      stdout.should contain("current  .github/hooks/agent-apropos.json")
      fs.files[HOOKS_PATH].should eq(before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs, AgentApropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create .github/hooks/agent-apropos.json")
      fs.files.has_key?(HOOKS_PATH).should be_false
    end
  end

  describe "#checks" do
    it "is ok (skipped) when copilot is not on PATH" do
      check_named(run_checks(InMemoryFS.new), "copilot").detail.should contain("not on PATH; skipped hook check")
    end

    it "warns when copilot is on PATH but agent-apropos.json is absent" do
      env = FakeEnv.new(Set{"copilot"})
      check_named(run_checks(InMemoryFS.new, env), "copilot").detail.should contain(".github/hooks/agent-apropos.json absent; run `agent-apropos init --tool copilot`")
    end

    it "warns when agent-apropos.json is not valid JSON" do
      env = FakeEnv.new(Set{"copilot"})
      fs = InMemoryFS.new({HOOKS_PATH => "{not json"})
      check_named(run_checks(fs, env), "copilot").detail.should contain(".github/hooks/agent-apropos.json is not valid JSON")
    end

    it "warns when the postToolUse hook is absent" do
      env = FakeEnv.new(Set{"copilot"})
      fs = InMemoryFS.new({HOOKS_PATH => %({"version":1,"hooks":{}})})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end

    it "warns when only one of pre/post is wired for the create|edit matcher" do
      env = FakeEnv.new(Set{"copilot"})
      only_pre = %({"hooks":{"postToolUse":[) +
                 %({"matcher":"create|edit","command":"agent-apropos hook pre"}) +
                 %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => only_pre})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end

    it "is ok when copilot is on PATH and both hooks are wired" do
      env = FakeEnv.new(Set{"copilot"})
      wired = %({"hooks":{"postToolUse":[) +
              %({"matcher":"view","command":"agent-apropos hook pre --tool copilot"},) +
              %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot"},) +
              %({"matcher":"create|edit","command":"agent-apropos hook post --tool copilot"}) +
              %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => wired})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook wired")
    end

    it "warns when pre and post are both present but only in the view matcher, not create|edit" do
      env = FakeEnv.new(Set{"copilot"})
      split = %({"hooks":{"postToolUse":[) +
              %({"matcher":"view","command":"agent-apropos hook pre"},) +
              %({"matcher":"view","command":"agent-apropos hook post"}) +
              %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => split})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end
  end

  describe "#configured?" do
    it "is false when agent-apropos.json is absent" do
      AgentApropos::Agents::Copilot.new.configured?(ROOT, InMemoryFS.new).should be_false
    end

    it "is true when agent-apropos.json exists, even if malformed" do
      fs = InMemoryFS.new({HOOKS_PATH => "{not json"})
      AgentApropos::Agents::Copilot.new.configured?(ROOT, fs).should be_true
    end
  end

  describe "#skill_root" do
    it "is .claude/skills — Copilot CLI reads Claude Code's directory natively" do
      AgentApropos::Agents::Copilot.new.skill_root.should eq(Path[".claude", "skills"])
    end
  end

  describe "#sync_shell_hook" do
    it "wires the pre command and the post command onto the bash matcher, never swapped" do
      wired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook("{}", "hooks", true).as(String))
      entries = wired["hooks"]["postToolUse"].as_a.select { |entry| entry["matcher"] == "bash" }
      commands = entries.map(&.[]("command").as_s)
      commands.should contain("agent-apropos hook pre --tool copilot")
      commands.should contain("agent-apropos hook post --tool copilot")
    end

    it "writes the exact hook entry shape: a command-type entry with the configured timeout" do
      wired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook("{}", "hooks", true).as(String))
      entry = wired["hooks"]["postToolUse"].as_a.find! { |e| e["matcher"] == "bash" }
      entry["type"].as_s.should eq("command")
      entry["timeoutSec"].as_i.should eq(10)
    end

    it "returns exactly to the untouched seed once the only reason it was wired is gone" do
      copilot = AgentApropos::Agents::Copilot.new
      wired = copilot.sync_shell_hook("{}", "hooks", true).as(String)
      copilot.sync_shell_hook(wired, "hooks", false).should eq("{}\n")
    end

    it "is idempotent — wiring twice does not duplicate entries" do
      copilot = AgentApropos::Agents::Copilot.new
      wired = copilot.sync_shell_hook("{}", "hooks", true).as(String)
      copilot.sync_shell_hook(wired, "hooks", true).should eq(wired)
    end

    it "does not touch the existing view/create|edit entries when wiring bash" do
      seed = %({"hooks":{"postToolUse":[) +
             %({"matcher":"view","command":"agent-apropos hook pre --tool copilot"},) +
             %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot"}) +
             %(]}})
      wired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook(seed, "hooks", true).as(String))
      matchers = wired["hooks"]["postToolUse"].as_a.map(&.[]("matcher").as_s)
      matchers.should contain("view")
      matchers.should contain("create|edit")
      matchers.count("bash").should eq(2)
    end

    it "preserves a user-added foreign bash entry in both directions" do
      hand_written = %({"hooks":{"postToolUse":[) +
                     %({"matcher":"bash","command":"my-other-tool"}) +
                     %(]}})
      copilot = AgentApropos::Agents::Copilot.new
      wired = JSON.parse(copilot.sync_shell_hook(hand_written, "hooks", true).as(String))
      commands = wired["hooks"]["postToolUse"].as_a.select { |e| e["matcher"] == "bash" }.map(&.[]("command").as_s)
      commands.should contain("my-other-tool")
      commands.should contain("agent-apropos hook pre --tool copilot")

      unwired = JSON.parse(copilot.sync_shell_hook(wired.to_json, "hooks", false).as(String))
      after = unwired["hooks"]["postToolUse"].as_a.select { |e| e["matcher"] == "bash" }.map(&.[]("command").as_s)
      after.should eq(["my-other-tool"])
    end

    it "keeps --allow-outside-repo through both directions when the existing config carries it" do
      with_flag = %({"hooks":{"postToolUse":[) +
                  %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot --allow-outside-repo"}) +
                  %(]}})
      wired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook(with_flag, "hooks", true).as(String))
      entry = wired["hooks"]["postToolUse"].as_a.find! { |e| e["matcher"] == "bash" && e["command"].as_s.starts_with?("agent-apropos hook pre") }
      entry["command"].as_s.should eq("agent-apropos hook pre --tool copilot --allow-outside-repo")
    end

    it "returns existing verbatim, without reformatting, when there is truly nothing to wire or drop" do
      AgentApropos::Agents::Copilot.new.sync_shell_hook("{}", "hooks", false).should eq("{}")
    end

    it "does not refresh an entry whose matcher isn't bash, even if its command is stale" do
      foreign_matcher = %({"hooks":{"postToolUse":[) +
                        %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot"}) +
                        %(]}})
      wired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook(foreign_matcher, "hooks", true).as(String))
      entries = wired["hooks"]["postToolUse"].as_a
      entries.count { |e| e["matcher"] == "create|edit" }.should eq(1)
      entries.count { |e| e["matcher"] == "bash" }.should eq(2)
    end

    it "upgrades its own outdated bash entry when the allow-outside state changes between runs" do
      copilot = AgentApropos::Agents::Copilot.new
      first = copilot.sync_shell_hook("{}", "hooks", true).as(String)
      with_flag_elsewhere = JSON.parse(first).as_h
      with_flag_elsewhere["hooks"].as_h["postToolUse"] = JSON::Any.new(
        with_flag_elsewhere["hooks"].as_h["postToolUse"].as_a + [JSON::Any.new({
          "matcher" => JSON::Any.new("create|edit"),
          "command" => JSON::Any.new("agent-apropos hook pre --tool copilot --allow-outside-repo"),
        })]
      )
      seeded = JSON::Any.new(with_flag_elsewhere).to_json

      second = JSON.parse(copilot.sync_shell_hook(seeded, "hooks", true).as(String))
      bash = second["hooks"]["postToolUse"].as_a.select { |e| e["matcher"] == "bash" }
      bash.map(&.[]("command").as_s).count("agent-apropos hook pre --tool copilot --allow-outside-repo").should eq(1)
      # The stale bash pre/post entries must be refreshed in place, not left stale
      # alongside freshly-appended replacements — otherwise the config accumulates
      # duplicate bash entries every time the allow-outside state flips.
      bash.size.should eq(2)
    end

    it "does not drop a non-bash entry that happens to carry an agent-apropos command, when unwiring bash" do
      seed = %({"hooks":{"postToolUse":[) +
             %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot"},) +
             %({"matcher":"bash","command":"agent-apropos hook pre --tool copilot"}) +
             %(]}})
      unwired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook(seed, "hooks", false).as(String))
      matchers = unwired["hooks"]["postToolUse"].as_a.map(&.[]("matcher").as_s)
      matchers.should eq(["create|edit"])
    end

    it "preserves a non-object entry in postToolUse untouched when unwiring bash" do
      seed = %({"hooks":{"postToolUse":[) +
             %({"matcher":"bash","command":"agent-apropos hook pre --tool copilot"},) +
             %("not-an-object") +
             %(]}})
      unwired = JSON.parse(AgentApropos::Agents::Copilot.new.sync_shell_hook(seed, "hooks", false).as(String))
      unwired["hooks"]["postToolUse"].as_a.should eq([JSON::Any.new("not-an-object")])
    end
  end

  describe "#checks — wired? matcher scoping" do
    it "warns when pre and post are fully wired under view only, never under create|edit" do
      env = FakeEnv.new(Set{"copilot"})
      view_only = %({"hooks":{"postToolUse":[) +
                  %({"matcher":"view","command":"agent-apropos hook pre --tool copilot"},) +
                  %({"matcher":"view","command":"agent-apropos hook post --tool copilot"}) +
                  %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => view_only})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end

    it "warns when only pre (fully qualified) is wired under create|edit" do
      env = FakeEnv.new(Set{"copilot"})
      only_pre = %({"hooks":{"postToolUse":[) +
                 %({"matcher":"create|edit","command":"agent-apropos hook pre --tool copilot"}) +
                 %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => only_pre})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end

    it "warns when only post (fully qualified) is wired under create|edit" do
      env = FakeEnv.new(Set{"copilot"})
      only_post = %({"hooks":{"postToolUse":[) +
                  %({"matcher":"create|edit","command":"agent-apropos hook post --tool copilot"}) +
                  %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => only_post})
      check_named(run_checks(fs, env), "copilot").detail.should contain("postToolUse hook absent")
    end
  end
end
