require "../../spec_helper"

private ROOT       = Path["/repo"]
private HOOKS_PATH = "/repo/.codex/hooks.json"

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
  AgentApropos::Agents::Codex.new.scaffold(ROOT, fs, options, stdout)
  stdout.to_s
end

private def run_checks(fs : AgentApropos::Filesystem, env : AgentApropos::Environment = FakeEnv.new) : Array(AgentApropos::Check)
  AgentApropos::Agents::Codex.new.checks(ROOT, fs, env)
end

private def check_named(checks : Array(AgentApropos::Check), name : String) : AgentApropos::Check
  checks.find! { |check| check.name == name }
end

private def payload(tool_name : String) : AgentApropos::Hook::Payload
  json = %({"tool_name":"#{tool_name}"})
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents::Codex do
  describe "#read?" do
    it "is always false — Codex has no dedicated read tool" do
      AgentApropos::Agents::Codex.new.read?(payload("Bash")).should be_false
      AgentApropos::Agents::Codex.new.read?(payload("apply_patch")).should be_false
    end
  end

  describe "#scaffold" do
    it "writes PreToolUse/PostToolUse hooks matched on apply_patch, calling agent-apropos directly" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs)

      hooks = fs.files[HOOKS_PATH]
      hooks.should contain(%("PreToolUse"))
      hooks.should contain(%("PostToolUse"))
      hooks.should contain(%("matcher": "apply_patch"))
      hooks.should contain(%("command": "agent-apropos hook pre --tool codex"))
      hooks.should contain(%("command": "agent-apropos hook post --tool codex"))
      hooks.should_not contain("bridge")
      stdout.should contain(".codex/hooks.json")
    end

    it "is idempotent — re-running reports current and does not rewrite the file" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      before = fs.files[HOOKS_PATH]

      stdout = run_scaffold(fs)
      stdout.should contain("current  .codex/hooks.json")
      fs.files[HOOKS_PATH].should eq(before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs, AgentApropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create .codex/hooks.json")
      fs.files.has_key?(HOOKS_PATH).should be_false
    end
  end

  describe "#checks" do
    it "is ok (skipped) when codex is not on PATH" do
      check_named(run_checks(InMemoryFS.new), "codex").detail.should contain("not on PATH; skipped hook check")
    end

    it "warns when codex is on PATH but hooks.json is absent" do
      env = FakeEnv.new(Set{"codex"})
      check_named(run_checks(InMemoryFS.new, env), "codex").detail.should contain(".codex/hooks.json absent; run `agent-apropos init --tool codex`")
    end

    it "warns when hooks.json is not valid JSON" do
      env = FakeEnv.new(Set{"codex"})
      fs = InMemoryFS.new({HOOKS_PATH => "{not json"})
      check_named(run_checks(fs, env), "codex").detail.should contain(".codex/hooks.json is not valid JSON")
    end

    it "warns when the hooks are absent from an otherwise-valid file" do
      env = FakeEnv.new(Set{"codex"})
      fs = InMemoryFS.new({HOOKS_PATH => %({"hooks":{}})})
      check_named(run_checks(fs, env), "codex").detail.should contain("hooks absent")
    end

    it "warns when only one of pre/post is wired" do
      env = FakeEnv.new(Set{"codex"})
      only_pre = %({"hooks":{"PreToolUse":[) +
                 %({"matcher":"apply_patch","hooks":[{"command":"agent-apropos hook pre --tool codex"}]}) +
                 %(]}})
      fs = InMemoryFS.new({HOOKS_PATH => only_pre})
      check_named(run_checks(fs, env), "codex").detail.should contain("hooks absent")
    end

    it "warns when both commands are present but wired onto the wrong matcher (miswired, not actually firing)" do
      env = FakeEnv.new(Set{"codex"})
      wrong_matcher = %({"hooks":{) +
                      %("PreToolUse":[{"matcher":"Bash","hooks":[{"command":"agent-apropos hook pre --tool codex"}]}],) +
                      %("PostToolUse":[{"matcher":"Bash","hooks":[{"command":"agent-apropos hook post --tool codex"}]}]) +
                      %(}})
      fs = InMemoryFS.new({HOOKS_PATH => wrong_matcher})
      check_named(run_checks(fs, env), "codex").detail.should contain("hooks absent")
    end

    it "is ok when codex is on PATH and both hooks are wired" do
      env = FakeEnv.new(Set{"codex"})
      fs = InMemoryFS.new
      run_scaffold(fs)
      check_named(run_checks(fs, env), "codex").detail.should contain("PreToolUse and PostToolUse call agent-apropos")
    end
  end

  describe "#configured?" do
    it "is false when hooks.json is absent" do
      AgentApropos::Agents::Codex.new.configured?(ROOT, InMemoryFS.new).should be_false
    end

    it "is true when hooks.json exists, even if malformed" do
      fs = InMemoryFS.new({HOOKS_PATH => "{not json"})
      AgentApropos::Agents::Codex.new.configured?(ROOT, fs).should be_true
    end
  end

  describe "#skill_root" do
    it "is .codex/skills — its own directory" do
      AgentApropos::Agents::Codex.new.skill_root.should eq(Path[".codex", "skills"])
    end
  end
end
