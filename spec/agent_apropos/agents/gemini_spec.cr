require "../../spec_helper"

private ROOT          = Path["/repo"]
private SETTINGS_PATH = "/repo/.gemini/settings.json"

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
  AgentApropos::Agents::Gemini.new.scaffold(ROOT, fs, options, stdout)
  stdout.to_s
end

private def run_checks(fs : AgentApropos::Filesystem, env : AgentApropos::Environment = FakeEnv.new) : Array(AgentApropos::Check)
  AgentApropos::Agents::Gemini.new.checks(ROOT, fs, env)
end

private def check_named(checks : Array(AgentApropos::Check), name : String) : AgentApropos::Check
  checks.find! { |check| check.name == name }
end

private def payload(tool_name : String) : AgentApropos::Hook::Payload
  json = %({"tool_name":"#{tool_name}"})
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents::Gemini do
  describe "#read?" do
    it "is true for Gemini's read_file tool" do
      AgentApropos::Agents::Gemini.new.read?(payload("read_file")).should be_true
    end

    it "is false for Gemini's write_file/replace tools" do
      AgentApropos::Agents::Gemini.new.read?(payload("write_file")).should be_false
      AgentApropos::Agents::Gemini.new.read?(payload("replace")).should be_false
    end
  end

  describe "#scaffold" do
    it "writes AfterTool hooks and context.fileName" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      content = fs.files[SETTINGS_PATH]
      content.should contain("AfterTool")
      content.should contain("agent-apropos hook pre")
      content.should contain("agent-apropos hook post")
      content.should contain("write_file|replace")
      content.should contain(%("fileName"))
      content.should contain("AGENTS.md")
    end

    it "does not wire BeforeTool — Gemini's BeforeTool cannot inject context" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[SETTINGS_PATH].should_not contain("BeforeTool")
    end

    it "is idempotent — re-running reports current and does not duplicate the group" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      before = fs.files[SETTINGS_PATH]

      stdout = run_scaffold(fs)
      stdout.should contain("current  .gemini/settings.json")
      fs.files[SETTINGS_PATH].should eq(before)
      # Once in the write_file|replace group, once in the read_file group.
      fs.files[SETTINGS_PATH].scan("agent-apropos hook pre").size.should eq(2)
    end

    it "adds the missing command into the existing group when only pre is present" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      # Once in the healed write_file|replace group, once in the freshly-added
      # read_file group.
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan("agent-apropos hook post").size.should eq(1)
      merged.scan(%("matcher": "write_file|replace")).size.should eq(1) # converged, not a second
    end

    it "adds the missing command into the existing group when only post is present" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook post","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan("agent-apropos hook post").size.should eq(1)
    end

    it "wires agent-apropos hook pre onto a read_file-matched AfterTool group too, distinct from write_file|replace" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      content = fs.files[SETTINGS_PATH]
      content.scan("agent-apropos hook pre").size.should eq(2)
      content.should contain(%("matcher": "read_file"))
    end

    it "budgets the AfterTool hook timeout in milliseconds, not Claude Code's seconds" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[SETTINGS_PATH].should contain(%("timeout": 10000))
    end

    it "refreshes a stale timeout on an already-wired command when healing (e.g. after an agent-apropos upgrade)" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10},) +
             %({"type":"command","command":"agent-apropos hook post","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      # pre and post converged (not just newly-added commands), plus the
      # freshly-added read_file group's own pre command — all three at 10000.
      merged.scan(%("timeout": 10000)).size.should eq(3)
    end

    it "upgrades a pre-`--tool` command from an older agent-apropos version in place, without duplicating it" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"write_file|replace","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10000},) +
             %({"type":"command","command":"agent-apropos hook post","timeout":10000}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]

      merged.scan(%("agent-apropos hook pre --tool gemini")).size.should eq(2) # write group + read_file group
      merged.scan(%("agent-apropos hook post --tool gemini")).size.should eq(1)
      merged.should_not contain(%("command": "agent-apropos hook pre",))
      merged.should_not contain(%("command": "agent-apropos hook post",))
    end

    it "does not duplicate the read_file group on a second run" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan(%("matcher": "read_file")).size.should eq(1)
    end

    it "adds agent-apropos hook pre into an existing read_file group that has a different command" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"echo hi"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.scan(%("matcher": "read_file")).size.should eq(1)
    end

    it "does not mistake an existing read_file group for the write group to heal" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10000}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan(%("matcher": "read_file")).size.should eq(1)
      merged.scan(%("matcher": "write_file|replace")).size.should eq(1)
      read_group = merged.split(%("matcher": "write_file|replace")).first
      read_group.should_not contain("agent-apropos hook post")
    end

    it "refreshes a stale timeout on the read_file group's own pre command too" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"read_file","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should_not contain(%("timeout": 10,))
      merged.scan(%("timeout": 10000)).size.should eq(3) # read's pre, write's pre, write's post
      merged.should_not contain(%("command": "agent-apropos hook pre",))
      merged.scan(%("agent-apropos hook pre --tool gemini")).size.should eq(2)
    end

    it "preserves the group's matcher and a foreign hook alongside it while healing" do
      seed = %({"hooks":{"AfterTool":[{"matcher":"custom_matcher","hooks":) +
             %([{"type":"command","command":"echo hi"},) +
             %({"type":"command","command":"agent-apropos hook pre"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("matcher": "custom_matcher"))
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook post")
    end

    it "preserves foreign keys and an existing fileName list" do
      seed = %({"model": "gemini-pro", "context": {"fileName": ["CONTEXT.md"]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("model": "gemini-pro"))
      merged.should contain("CONTEXT.md")
      merged.should contain("AGENTS.md")
    end

    it "does not duplicate AGENTS.md when it is already listed" do
      seed = %({"context": {"fileName": ["AGENTS.md"]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      fs.files[SETTINGS_PATH].scan("AGENTS.md").size.should eq(1)
    end

    it "upgrades a single fileName string to an array rather than clobbering it" do
      seed = %({"context": {"fileName": "CONTEXT.md"}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("CONTEXT.md")
      merged.should contain("AGENTS.md")
    end

    it "fails closed on malformed existing gemini settings JSON" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      expect_raises(AgentApropos::Init::Error, /not valid JSON/) { run_scaffold(fs) }
    end
  end

  describe "#checks" do
    it "is ok (skipped) when gemini is not on PATH" do
      check_named(run_checks(InMemoryFS.new), "gemini").detail.should contain("not on PATH; skipped hook check")
    end

    it "warns when gemini is on PATH but settings.json is absent" do
      env = FakeEnv.new(Set{"gemini"})
      check_named(run_checks(InMemoryFS.new, env), "gemini").detail.should contain(".gemini/settings.json absent")
    end

    it "warns when settings.json is not valid JSON" do
      env = FakeEnv.new(Set{"gemini"})
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      check_named(run_checks(fs, env), "gemini").detail.should contain(".gemini/settings.json is not valid JSON")
    end

    it "warns when the AfterTool hook is absent" do
      env = FakeEnv.new(Set{"gemini"})
      fs = InMemoryFS.new({SETTINGS_PATH => %({"hooks":{}})})
      check_named(run_checks(fs, env), "gemini").detail.should contain("AfterTool hook absent")
    end

    it "warns when only one of pre/post is wired under AfterTool" do
      env = FakeEnv.new(Set{"gemini"})
      only_pre = %({"hooks":{"AfterTool":[{"hooks":[{"type":"command","command":"agent-apropos hook pre"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => only_pre})
      check_named(run_checks(fs, env), "gemini").detail.should contain("AfterTool hook absent")
    end

    it "is ok when gemini is on PATH and both hooks are wired" do
      env = FakeEnv.new(Set{"gemini"})
      wired = %({"hooks":{"AfterTool":[{"hooks":[) +
              %({"type":"command","command":"agent-apropos hook pre --tool gemini"},) +
              %({"type":"command","command":"agent-apropos hook post --tool gemini"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => wired})
      check_named(run_checks(fs, env), "gemini").detail.should contain("AfterTool hook wired")
    end

    it "warns when pre and post are split across two different groups, not both in one" do
      env = FakeEnv.new(Set{"gemini"})
      split = %({"hooks":{"AfterTool":[) +
              %({"matcher":"read_file","hooks":[{"type":"command","command":"agent-apropos hook pre"}]},) +
              %({"matcher":"write_file|replace","hooks":[{"type":"command","command":"agent-apropos hook post"}]}) +
              %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => split})
      check_named(run_checks(fs, env), "gemini").detail.should contain("AfterTool hook absent")
    end
  end
end
