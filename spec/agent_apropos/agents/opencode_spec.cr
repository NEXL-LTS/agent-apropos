require "../../spec_helper"

private ROOT        = Path["/repo"]
private PLUGIN_PATH = "/repo/.opencode/plugins/agent-apropos.js"

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
  AgentApropos::Agents::OpenCode.new.scaffold(ROOT, fs, options, stdout)
  stdout.to_s
end

private def run_checks(fs : AgentApropos::Filesystem, env : AgentApropos::Environment = FakeEnv.new) : Array(AgentApropos::Check)
  AgentApropos::Agents::OpenCode.new.checks(ROOT, fs, env)
end

private def check_named(checks : Array(AgentApropos::Check), name : String) : AgentApropos::Check
  checks.find! { |check| check.name == name }
end

private def payload(tool_name : String) : AgentApropos::Hook::Payload
  json = %({"tool_name":"#{tool_name}"})
  AgentApropos::Hook::Payload.parse(json) || raise "expected #{json.inspect} to parse"
end

describe AgentApropos::Agents::OpenCode do
  describe "#read?" do
    it "is true for OpenCode's read tool" do
      AgentApropos::Agents::OpenCode.new.read?(payload("read")).should be_true
    end

    it "is false for OpenCode's edit/write/apply_patch tools" do
      AgentApropos::Agents::OpenCode.new.read?(payload("edit")).should be_false
      AgentApropos::Agents::OpenCode.new.read?(payload("write")).should be_false
      AgentApropos::Agents::OpenCode.new.read?(payload("apply_patch")).should be_false
    end
  end

  describe "#scaffold" do
    it "writes the Bun plugin bridging tool.execute.before/after into agent-apropos hook pre/post" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs)
      plugin = fs.files[PLUGIN_PATH]
      plugin.should contain("tool.execute.before")
      plugin.should contain("tool.execute.after")
      plugin.should contain("noReply: true")
      plugin.should contain(%(["agent-apropos", "hook", sub, "--tool", "opencode"]))
      # OpenCode delivers tool args in the second callback parameter; the plugin
      # must read from there (falling back to input) or no rule ever fires.
      plugin.should contain("async (input, output)")
      plugin.should contain("output?.args ?? input.args")
      # The "read" tool calls the hook — not to inject, but so a convention doc
      # the model read is recorded as already in context. It is wired on the
      # after event only, which fires once the read has actually succeeded.
      plugin.should contain(%(if (!["edit", "write", "apply_patch"].includes(input.tool)) return))
      plugin.should contain(%(if (!["edit", "write", "apply_patch", "read"].includes(input.tool)) return))
      # Both events send the written content, so content regexes can match the
      # fragment about to land rather than only the file after the write, plus
      # the read range so a partial read cannot suppress a whole rule.
      plugin.scan(%(makePayload(input, args))).size.should eq(3) # definition + both calls
      plugin.should contain("offset:     args?.offset")
      plugin.should contain("limit:      args?.limit")
      stdout.should contain(".opencode/plugins/agent-apropos.js")
    end

    # The plugin is fully regenerated on every run (see docs/design/agent-dialects.md's
    # OpenCode section), so its body — including every comment — is the generated
    # artifact; this pins it byte-for-byte against a real captured `init` output rather
    # than leaving prose text uncovered by any assertion.
    it "matches the captured golden output byte-for-byte, unwired" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      fs.files[PLUGIN_PATH].should eq(File.read("spec/fixtures/generated/opencode_plugin.js"))
    end

    it "is idempotent — re-running reports current" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      before = fs.files[PLUGIN_PATH]
      stdout = run_scaffold(fs)
      stdout.should contain("current  .opencode/plugins/agent-apropos.js")
      fs.files[PLUGIN_PATH].should eq(before)
    end

    it "reports would-create under --dry-run without writing" do
      fs = InMemoryFS.new
      stdout = run_scaffold(fs, AgentApropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create .opencode/plugins/agent-apropos.js")
      fs.files.has_key?(PLUGIN_PATH).should be_false
    end
  end

  describe "#checks" do
    it "is ok (skipped) when opencode is not on PATH" do
      check_named(run_checks(InMemoryFS.new), "opencode").detail.should contain("not on PATH; skipped plugin check")
    end

    it "warns when opencode is on PATH but the plugin is absent" do
      env = FakeEnv.new(Set{"opencode"})
      check_named(run_checks(InMemoryFS.new, env), "opencode").detail.should contain("plugin absent; run `agent-apropos init --tool opencode`")
    end

    it "is ok when opencode is on PATH and the plugin is present" do
      env = FakeEnv.new(Set{"opencode"})
      fs = InMemoryFS.new({PLUGIN_PATH => "// plugin"})
      check_named(run_checks(fs, env), "opencode").detail.should contain("plugin wired")
    end
  end

  describe "#configured?" do
    it "is false when the plugin file is absent" do
      AgentApropos::Agents::OpenCode.new.configured?(ROOT, InMemoryFS.new).should be_false
    end

    it "is true when the plugin file exists" do
      fs = InMemoryFS.new({PLUGIN_PATH => "// plugin"})
      AgentApropos::Agents::OpenCode.new.configured?(ROOT, fs).should be_true
    end
  end

  describe "#skill_root" do
    it "is .claude/skills — OpenCode reads Claude Code's directory natively" do
      AgentApropos::Agents::OpenCode.new.skill_root.should eq(Path[".claude", "skills"])
    end
  end

  describe "#sync_shell_hook" do
    it "wires bash onto both events when a removal convention exists" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      existing = fs.files[PLUGIN_PATH]

      wired = AgentApropos::Agents::OpenCode.new.sync_shell_hook(existing, "plugin", true).as(String)
      wired.should contain(%(if (!["edit", "write", "apply_patch", "bash"].includes(input.tool)) return))
      wired.should contain(%(if (!["edit", "write", "apply_patch", "read", "bash"].includes(input.tool)) return))
    end

    it "returns existing unchanged when nothing needs to change" do
      fs = InMemoryFS.new
      run_scaffold(fs)
      existing = fs.files[PLUGIN_PATH]
      AgentApropos::Agents::OpenCode.new.sync_shell_hook(existing, "plugin", false).should eq(existing)
    end

    it "returns exactly to the untouched plugin once the only reason it was wired is gone" do
      opencode = AgentApropos::Agents::OpenCode.new
      fs = InMemoryFS.new
      run_scaffold(fs)
      unwired = fs.files[PLUGIN_PATH]

      wired = opencode.sync_shell_hook(unwired, "plugin", true).as(String)
      opencode.sync_shell_hook(wired, "plugin", false).should eq(unwired)
    end

    it "is a no-op returning existing unchanged when wiring twice" do
      opencode = AgentApropos::Agents::OpenCode.new
      fs = InMemoryFS.new
      run_scaffold(fs)
      unwired = fs.files[PLUGIN_PATH]
      wired = opencode.sync_shell_hook(unwired, "plugin", true).as(String)
      opencode.sync_shell_hook(wired, "plugin", true).should eq(wired)
    end

    it "detects capability from a nil existing file (the doctor/generate probe)" do
      AgentApropos::Agents::OpenCode.new.sync_shell_hook(nil, "probe", true).should_not be_nil
    end

    it "keeps --allow-outside-repo through both directions when the existing plugin carries it" do
      fs = InMemoryFS.new
      run_scaffold(fs, AgentApropos::Init::Options.new(allow_outside_repo: true))
      existing = fs.files[PLUGIN_PATH]
      existing.should contain(%("--allow-outside-repo"))

      opencode = AgentApropos::Agents::OpenCode.new
      wired = opencode.sync_shell_hook(existing, "plugin", true).as(String)
      wired.should contain(%(["agent-apropos", "hook", sub, "--tool", "opencode", "--allow-outside-repo"]))

      unwired = opencode.sync_shell_hook(wired, "plugin", false).as(String)
      unwired.should eq(existing)
    end

    it "includes a command field for bash's args, alongside the existing file-edit fields" do
      wired = AgentApropos::Agents::OpenCode.new.sync_shell_hook(nil, "plugin", true).as(String)
      wired.should contain("command:    args?.command")
    end
  end
end
