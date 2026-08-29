require "../../spec_helper"

private ROOT          = Path["/repo"]
private SETTINGS_PATH = "/repo/.claude/settings.json"

# A configurable Environment double: `present` maps a command to its resolved
# path; `outputs` maps a command to its captured `--version` stdout.
private class FakeEnv < AgentApropos::Environment
  getter run_capture_calls = [] of {String, Array(String)}

  def initialize(@present : Hash(String, String) = {} of String => String,
                 @outputs : Hash(String, String?) = {} of String => String?)
  end

  def which(command : String) : String?
    @present[command]?
  end

  def run_capture(command : String, args : Array(String)) : String?
    @run_capture_calls << {command, args}
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

# Read the generated wiring back as JSON rather than string-slicing it: the
# key order of `hooks` follows whatever the seed used, so a `split` on an
# event name silently pulls in the other event's groups.
private def hook_entries(fs : InMemoryFS, event : String, matcher : String) : Array(JSON::Any)
  groups(fs, event).select { |group| group["matcher"]?.try(&.as_s?) == matcher }
    .flat_map { |group| group["hooks"]?.try(&.as_a) || [] of JSON::Any }
end

private def commands_for(fs : InMemoryFS, event : String, matcher : String) : Array(String)
  hook_entries(fs, event, matcher).compact_map { |entry| entry["command"]?.try(&.as_s?) }
end

private def matchers_for(fs : InMemoryFS, event : String) : Array(String)
  groups(fs, event).compact_map { |group| group["matcher"]?.try(&.as_s?) }
end

private def groups(fs : InMemoryFS, event : String) : Array(JSON::Any)
  JSON.parse(fs.files[SETTINGS_PATH])["hooks"][event].as_a
end

private def sync(existing : String?, wire : Bool) : String?
  AgentApropos::Agents::Claude.new.sync_shell_hook(existing, "settings", wire)
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
      commands_for(fs, "PostToolUse", "Edit|Write")
        .should eq(["agent-apropos hook post --tool claude"])
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
      fs.files[SETTINGS_PATH].should contain("bash myscript.sh")
      commands_for(fs, "PostToolUse", "Edit|Write")
        .count("agent-apropos hook post --tool claude").should eq(1)
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

    it "fails closed on malformed existing settings JSON, naming the file in the error" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      expect_raises(AgentApropos::Init::Error, /\.claude\/settings\.json is not valid JSON/) { run_scaffold(fs) }
    end

    it "ends the written settings file with exactly one trailing newline" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[SETTINGS_PATH].should end_with("}\n")
      fs.files[SETTINGS_PATH].should_not end_with("\n\n")
    end

    it "fails closed when existing settings is not a JSON object" do
      fs = InMemoryFS.new({SETTINGS_PATH => "[]"})
      expect_raises(AgentApropos::Init::Error, /must be a JSON object/) { run_scaffold(fs) }
    end

    it "wires the Read group onto PostToolUse, so a denied read cannot suppress a rule" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      matchers_for(fs, "PreToolUse").should eq(["Edit|Write"])
      matchers_for(fs, "PostToolUse").should eq(["Edit|Write", "Read"])
      commands_for(fs, "PostToolUse", "Read")
        .should eq(["agent-apropos hook post --tool claude"])
    end

    it "unwires a Read group left on PreToolUse by an older agent-apropos version" do
      seed = %({"hooks":{"PreToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook pre --tool claude","timeout":10}]},) +
             %({"matcher":"Read","hooks":[{"type":"command","command":"agent-apropos hook pre --tool claude","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      matchers_for(fs, "PreToolUse").should eq(["Edit|Write"])
      commands_for(fs, "PreToolUse", "Edit|Write")
        .should eq(["agent-apropos hook pre --tool claude"])
    end

    it "keeps a foreign Read hook when unwiring its agent-apropos sibling from PreToolUse" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[) +
             %({"type":"command","command":"echo hi"},) +
             %({"type":"command","command":"agent-apropos hook pre --tool claude","timeout":10}) +
             %(]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      commands_for(fs, "PreToolUse", "Read").should eq(["echo hi"])
    end

    it "adds agent-apropos hook post into an existing PostToolUse Read group that has a different command" do
      seed = %({"hooks":{"PostToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"echo hi"}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      commands_for(fs, "PostToolUse", "Read")
        .should eq(["echo hi", "agent-apropos hook post --tool claude"])
    end

    it "does not mistake an existing Read group for the Edit|Write group to heal" do
      seed = %({"hooks":{"PostToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook post","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      matchers_for(fs, "PostToolUse").should eq(["Read", "Edit|Write"])
    end

    it "refreshes a stale timeout on the Read group's own post command too" do
      seed = %({"hooks":{"PostToolUse":[{"matcher":"Read","hooks":) +
             %([{"type":"command","command":"agent-apropos hook post","timeout":999}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      entries = hook_entries(fs, "PostToolUse", "Read")
      entries.size.should eq(1)
      entries[0]["timeout"].as_i.should eq(10)
    end

    it "upgrades a pre-`--tool` command from an older agent-apropos version in place, without duplicating it" do
      seed = %({"hooks":{"PreToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook pre","timeout":10}]}) +
             %(],"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post","timeout":10}]},) +
             %({"matcher":"Read","hooks":[{"type":"command","command":"agent-apropos hook post","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      merged = fs.files[SETTINGS_PATH]

      merged.scan(%("agent-apropos hook pre --tool claude")).size.should eq(1)
      merged.scan(%("agent-apropos hook post --tool claude")).size.should eq(2)
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

    it "does not silently absorb a stray agent-apropos-prefixed command that is neither pre nor post into the post slot" do
      seed = %({"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":) +
             %([{"type":"command","command":"agent-apropos hook frobnicate","timeout":10}]}]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      commands_for(fs, "PostToolUse", "Edit|Write")
        .should eq(["agent-apropos hook frobnicate", "agent-apropos hook post --tool claude"])
    end

    it "does not cross-convert a stale pre command sitting in a post-designated group" do
      seed = %({"hooks":{"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook pre --tool claude","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      commands_for(fs, "PostToolUse", "Edit|Write")
        .should eq(["agent-apropos hook pre --tool claude", "agent-apropos hook post --tool claude"])
    end

    it "does not cross-convert a stale post command sitting in a pre-designated group" do
      seed = %({"hooks":{"PreToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post --tool claude","timeout":10}]}) +
             %(]}})
      fs = InMemoryFS.new({SETTINGS_PATH => seed})
      run_scaffold(fs)
      commands_for(fs, "PreToolUse", "Edit|Write")
        .should eq(["agent-apropos hook post --tool claude", "agent-apropos hook pre --tool claude"])
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
      merged.scan("agent-apropos hook post").size.should eq(2)
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

      it "warns rather than passing when only PreToolUse (not PostToolUse) is wired" do
        only_pre = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"agent-apropos hook pre"}]}]}})
        fs = InMemoryFS.new({SETTINGS_PATH => only_pre})
        check_named(run_checks(fs), "hooks").detail.should contain("only PreToolUse calls agent-apropos")
      end

      it "still detects a later event's wiring after an earlier event's value is malformed" do
        mixed = %({"hooks":{"PreToolUse":"weird","PostToolUse":[{"hooks":[) +
                %({"type":"command","command":"agent-apropos hook post"}]}]}})
        fs = InMemoryFS.new({SETTINGS_PATH => mixed})
        check_named(run_checks(fs), "hooks").detail.should contain("only PostToolUse calls agent-apropos")
      end

      it "detects agent-apropos ownership when only one of several groups for an event is owned" do
        mixed_groups = %({"hooks":{"PreToolUse":[) +
                       %({"hooks":[{"type":"command","command":"unrelated"}]},) +
                       %({"hooks":[{"type":"command","command":"agent-apropos hook pre"}]}) +
                       %(],"PostToolUse":[{"hooks":[{"type":"command","command":"agent-apropos hook post"}]}]}})
        fs = InMemoryFS.new({SETTINGS_PATH => mixed_groups})
        check_named(run_checks(fs), "hooks").detail.should contain("PreToolUse and PostToolUse call agent-apropos")
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

      it "is ok, not a warning, when the version is exactly the minimum" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "1.0.0".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("supports PreToolUse additionalContext")
      end

      it "asks claude for its version with the --version flag" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "1.2.3".as(String?)})
        run_checks(InMemoryFS.new, env)
        env.run_capture_calls.should eq([{"claude", ["--version"]}])
      end

      it "does not treat a version-less prefix earlier in the output as the version" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => ".1.2 3.4.5".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("3.4.5")
      end

      it "does not let an empty middle segment produce a bogus early match" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "1..2 3.4.5".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("3.4.5")
      end

      it "does not let an empty trailing segment produce a bogus early match" do
        env = FakeEnv.new(present: {"claude" => "/usr/bin/claude"},
          outputs: {"claude" => "1.2. 3.4.5".as(String?)})
        check_named(run_checks(InMemoryFS.new, env), "claude").detail.should contain("3.4.5")
      end
    end
  end

  describe "#configured?" do
    it "is false when settings.json is absent" do
      AgentApropos::Agents::Claude.new.configured?(ROOT, InMemoryFS.new).should be_false
    end

    it "is true when settings.json exists, even if malformed" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      AgentApropos::Agents::Claude.new.configured?(ROOT, fs).should be_true
    end
  end

  describe "#skill_root" do
    it "is .claude/skills — its own directory" do
      AgentApropos::Agents::Claude.new.skill_root.should eq(Path[".claude", "skills"])
    end
  end

  describe "#sync_shell_hook" do
    it "returns existing verbatim, byte-for-byte, when nothing needs to change" do
      sync("{}", false).should eq("{}")
    end

    it "returns exactly to the untouched seed once the only reason it was wired is gone" do
      wired = sync("{}", true).as(String)
      wired.should contain("Bash")
      sync(wired, false).should eq("{}\n")
    end

    it "ends the wired content with exactly one trailing newline" do
      wired = sync("{}", true).as(String)
      wired.should end_with("}\n")
      wired.should_not end_with("\n\n")
    end

    it "wires PreToolUse with the pre command and PostToolUse with the post command, never swapped" do
      wired = JSON.parse(sync("{}", true).as(String))
      pre = wired["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      post = wired["hooks"]["PostToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      pre["hooks"][0]["command"].as_s.should eq("agent-apropos hook pre --tool claude")
      post["hooks"][0]["command"].as_s.should eq("agent-apropos hook post --tool claude")
    end

    it "writes the exact hook entry shape: a command-type entry with the configured timeout" do
      wired = JSON.parse(sync("{}", true).as(String))
      pre = wired["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      pre["hooks"][0]["type"].as_s.should eq("command")
      pre["hooks"][0]["timeout"].as_i.should eq(10)
    end

    it "leaves an already-empty hook-event array untouched rather than deleting the key" do
      existing = %({"hooks":{"PreToolUse":[]}})
      sync(existing, false).should eq(existing)
    end

    it "detects an existing --allow-outside-repo flag buried in a second group of a second event" do
      seed = %({"hooks":{"PreToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook pre --tool claude"}]}) +
             %(],"PostToolUse":[) +
             %({"matcher":"Edit|Write","hooks":[{"type":"command","command":"agent-apropos hook post --tool claude"}]},) +
             %({"matcher":"Read","hooks":[) +
             %({"type":"command","command":"unrelated"},) +
             %({"type":"command","command":"agent-apropos hook post --tool claude --allow-outside-repo"}) +
             %(]}) +
             %(]}})
      wired = JSON.parse(sync(seed, true).as(String))
      bash_pre = wired["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      bash_pre["hooks"][0]["command"].as_s.should eq("agent-apropos hook pre --tool claude --allow-outside-repo")
    end

    it "upgrades its own outdated Bash-matcher command when the allow-outside state changes between runs" do
      first = sync("{}", true).as(String)
      with_flag_elsewhere = JSON.parse(first).as_h
      with_flag_elsewhere["hooks"].as_h["PreToolUse"] = JSON::Any.new(
        with_flag_elsewhere["hooks"].as_h["PreToolUse"].as_a + [JSON::Any.new({
          "matcher" => JSON::Any.new("Edit|Write"),
          "hooks"   => JSON::Any.new([JSON::Any.new({
            "type"    => JSON::Any.new("command"),
            "command" => JSON::Any.new("agent-apropos hook pre --tool claude --allow-outside-repo"),
          })]),
        })]
      )
      seeded = JSON::Any.new(with_flag_elsewhere).to_json

      second = JSON.parse(sync(seeded, true).as(String))
      bash = second["hooks"]["PreToolUse"].as_a.select { |group| group["matcher"] == "Bash" }
      bash.size.should eq(1)
      bash.first["hooks"].as_a.map(&.[]("command").as_s)
        .should eq(["agent-apropos hook pre --tool claude --allow-outside-repo"])
    end
  end
end
