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
end
