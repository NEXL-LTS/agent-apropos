require "../../spec_helper"

private ROOT          = Path["/repo"]
private SETTINGS_PATH = "/repo/.claude/settings.json"

# A configurable Environment double: `present` maps a command to its resolved
# path; `outputs` maps a command to its captured `--version` stdout.
private class FakeEnv < AgentApropos::Environment
  def initialize(@present : Hash(String, String) = {} of String => String,
                 @outputs : Hash(String, String?) = {} of String => String?)
  end

  def which(command : String) : String?
    @present[command]?
  end

  def run_capture(command : String, args : Array(String)) : String?
    @outputs[command]?
  end
end

private def run_scaffold(fs : AgentApropos::Filesystem,
                         options : AgentApropos::Init::Options = AgentApropos::Init::Options.new) : String
  stdout = IO::Memory.new
  AgentApropos::Agents::Claude.new.scaffold(ROOT, fs, options, stdout)
  stdout.to_s
end

private def run_checks(fs : AgentApropos::Filesystem, env : AgentApropos::Environment = FakeEnv.new) : Array(AgentApropos::Check)
  AgentApropos::Agents::Claude.new.checks(ROOT, fs, env)
end

private def check_named(checks : Array(AgentApropos::Check), name : String) : AgentApropos::Check
  checks.find! { |check| check.name == name }
end

private def payload(tool_name : String) : AgentApropos::Hook::Payload
  json = %({"tool_name":"#{tool_name}"})
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents::Claude do
  describe "#read?" do
    it "is true for Claude's Read tool" do
      AgentApropos::Agents::Claude.new.read?(payload("Read")).should be_true
    end

    it "is false for Claude's Edit/Write tools" do
      AgentApropos::Agents::Claude.new.read?(payload("Edit")).should be_false
      AgentApropos::Agents::Claude.new.read?(payload("Write")).should be_false
    end
  end

  describe "#scaffold" do
    it "creates .claude/settings.json wiring PreToolUse and PostToolUse" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs)
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook pre")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post")
      stdout.should contain("created  .claude/settings.json")
    end

    it "preserves foreign keys and other hooks while adding agent-apropos's" do
      seed = <<-JSON
        {
          "model": "opus",
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo hi" } ] }
            ]
          }
        }
        JSON
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("model": "opus"))
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.should contain("agent-apropos hook post")
    end

    it "is idempotent — a second run changes nothing" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      before = fs.files[SETTINGS_PATH]
      stdout = run_scaffold(fs)
      stdout.should contain("current  .claude/settings.json")
      fs.files[SETTINGS_PATH].should eq(before)
    end

    it "does not duplicate a agent-apropos group it already installed" do
      fs = InMemoryFS.new
      run_scaffold(fs) # installs agent-apropos hooks
      stdout = run_scaffold(fs)
      stdout.should contain("current  .claude/settings.json")
      fs.files[SETTINGS_PATH].scan("agent-apropos hook post").size.should eq(1)
    end

    it "does not add an already-installed command into a second group sharing the same matcher" do
      # Legacy layout: an older agent-apropos version (or a hand-edit) put its
      # own command in a *separate* "Edit|Write" group instead of the foreign
      # hook's group. `ensure_commands` must search every group with this
      # matcher for the command, not just the first one it finds — otherwise
      # it heals the foreign hook's group by adding a second copy alongside
      # the one already installed in the other group.
      seed = %({"hooks":{"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"bash myscript.sh","timeout":30}]},) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("bash myscript.sh")
      merged.scan("agent-apropos hook post").size.should eq(1)
    end

    it "replaces a non-array event value and a group with no hooks list" do
      seed = %({"hooks": {"PreToolUse": "weird", "PostToolUse": [{"matcher": "X"}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("agent-apropos hook pre")
      merged.should contain("agent-apropos hook post")
      merged.should contain(%("matcher": "X")) # foreign group preserved
    end

    it "ignores a non-agent-apropos command hook when deciding to add its group" do
      seed = %({"hooks": {"PostToolUse": [{"hooks": [{"type": "command"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post")
    end

    it "fails closed on malformed existing settings JSON" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      expect_raises(AgentApropos::Init::Error, /not valid JSON/) { run_scaffold(fs) }
    end

    it "fails closed when existing settings is not a JSON object" do
      fs = InMemoryFS.new({SETTINGS_PATH => "[]"})
      expect_raises(AgentApropos::Init::Error, /must be a JSON object/) { run_scaffold(fs) }
    end

    it "wires agent-apropos hook pre onto Read too, distinct from the Edit|Write group" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.should contain(%("matcher": "Read"))
      merged.should contain(%("matcher": "Edit|Write"))
    end

    it "adds agent-apropos hook pre into an existing Read group that has a different command" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"echo hi"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain("echo hi")
      merged.should contain("agent-apropos hook pre")
      merged.scan(%("matcher": "Read")).size.should eq(1)
    end

    it "does not mistake an existing Read group for the Edit|Write group to heal" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      # Isolate PreToolUse: PostToolUse gets its own independent "Edit|Write"
      # group (for agent-apropos hook post), which would mask a missing PreToolUse
      # one if counted across the whole file.
      pre_section = fs.files[SETTINGS_PATH].split(%("PostToolUse"))[0]
      pre_section.scan(%("matcher": "Read")).size.should eq(1)
      pre_section.scan(%("matcher": "Edit|Write")).size.should eq(1)
    end

    it "refreshes a stale timeout on the Read group's own pre command too" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook pre","timeout":999}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      pre_section = fs.files[SETTINGS_PATH].split(%("PostToolUse"))[0]
      pre_section.should_not contain(%("timeout": 999))
      pre_section.scan(%("timeout": 10)).size.should eq(2) # Read's own pre, Edit|Write's pre
    end

    it "upgrades a pre-`--tool` command from an older agent-apropos version in place, without duplicating it" do
      seed = %({"hooks":{"PreToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook pre","timeout":10}]},) +
             %({"matcher":"Read","hooks":[{"type":"command","command":"agent-apropos hook pre","timeout":10}]}) +
             %(],"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]

      merged.scan(%("agent-apropos hook pre --tool claude")).size.should eq(2)
      merged.scan(%("agent-apropos hook post --tool claude")).size.should eq(1)
      merged.should_not contain(%("command": "agent-apropos hook pre",))
      merged.should_not contain(%("command": "agent-apropos hook post",))
    end

    it "leaves a stray agent-apropos-prefixed command that is neither pre nor post untouched" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":) +
             %([{"type":"command","command":"agent-apropos hook frobnicate","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]

      merged.should contain(%("command": "agent-apropos hook frobnicate"))
      merged.should contain(%("agent-apropos hook pre --tool claude"))
    end

    it "budgets Claude Code's hook timeout in seconds" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.should contain(%("timeout": 10))
      merged.should_not contain(%("timeout": 10000))
    end

    it "does not duplicate the Read group on a second run" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]
      merged.scan("agent-apropos hook pre").size.should eq(2)
      merged.scan(%("matcher": "Read")).size.should eq(1)
    end
  end

  describe "#checks" do
    describe "hooks check" do
      it "fails when settings.json is absent" do
        check = check_named(run_checks(InMemoryFS.new), "hooks")
        check.status.should eq(:fail)
        check.detail.should contain(".claude/settings.json not found")
      end

      it "warns when settings.json is not valid JSON" do
        fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
        check = check_named(run_checks(fs), "hooks")
        check.status.should eq(:warn)
        check.detail.should contain(".claude/settings.json is not valid JSON")
      end

      it "warns when only one event calls agent-apropos" do
        only_post = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"agent-apropos hook post"}]}]}})
        fs = InMemoryFS.new({SETTINGS_PATH => only_post})
        check_named(run_checks(fs), "hooks").detail.should contain("only PostToolUse calls agent-apropos")
      end

      it "fails when no agent-apropos hooks are wired" do
        foreign = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]},"weird"]}})
        fs = InMemoryFS.new({SETTINGS_PATH => foreign})
        check_named(run_checks(fs), "hooks").detail.should contain("no agent-apropos hooks wired")
      end

      it "fails when settings has no hooks section at all" do
        fs = InMemoryFS.new({SETTINGS_PATH => "{}"})
        check_named(run_checks(fs), "hooks").detail.should contain("no agent-apropos hooks wired")
      end

      it "fails when an event value is not an array" do
        fs = InMemoryFS.new({SETTINGS_PATH => %({"hooks":{"PreToolUse":"weird"}})})
        check_named(run_checks(fs), "hooks").detail.should contain("no agent-apropos hooks wired")
      end

      it "ignores a hook entry with no command field" do
        no_cmd = %({"hooks":{"PostToolUse":[{"hooks":[{"type":"command"}]}]}})
        fs = InMemoryFS.new({SETTINGS_PATH => no_cmd})
        check_named(run_checks(fs), "hooks").detail.should contain("no agent-apropos hooks wired")
      end
    end

    describe "claude check" do
      it "is ok (skipped) when claude is not on PATH" do
        check_named(run_checks(InMemoryFS.new), "claude").detail.should contain("not on PATH; skipped")
      end

      it "warns when claude --version cannot be run" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("could not run `claude --version`")
      end

      it "warns when the version cannot be parsed" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "unknown".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("could not parse a version")
      end

      it "warns when the version is below the minimum" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "0.9.0".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("may lack PreToolUse additionalContext")
      end
    end
  end
end
