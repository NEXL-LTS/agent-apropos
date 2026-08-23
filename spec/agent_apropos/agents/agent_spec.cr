require "../../spec_helper"

# A minimal concrete Agent. The base class is abstract, so its shared
# behaviour — scaffolding, the checks list, the configured? probe, the
# --allow-outside-repo flag, and the hook-group predicate — can only be driven
# through a subclass. The two protected helpers are re-exposed here rather than
# reached through a real agent's config writer, so a failure names the base
# class instead of whichever agent happened to call it.
private class StubAgent < AgentApropos::Agents::Agent
  CONFIG_RELATIVE = Path[".stub", "settings.json"]

  getter config_calls = [] of String?

  def name : String
    "stub"
  end

  def config_relative : Path
    CONFIG_RELATIVE
  end

  def skill_root : Path
    Path[".stub", "skills"]
  end

  def read?(payload : AgentApropos::Hook::Payload) : Bool
    payload.tool_name == "read"
  end

  def expose_hook_command(base : String, options : AgentApropos::Init::Options) : String
    hook_command(base, options)
  end

  def expose_agent_apropos_group?(group : JSON::Any) : Bool
    agent_apropos_group?(group)
  end

  protected def config_content(existing : String?, options : AgentApropos::Init::Options) : String
    @config_calls << existing
    "stub config for #{name}, outside-repo=#{options.allow_outside_repo}\n"
  end

  protected def hook_check(repo_root : Path, fs : AgentApropos::Filesystem,
                           env : AgentApropos::Environment) : AgentApropos::Check
    AgentApropos::Check.new(:ok, "stub hook", repo_root.join(config_relative).to_posix.to_s)
  end
end

# The base class hands the environment straight to the subclass's hook check,
# so the double only has to exist.
private class StubEnv < AgentApropos::Environment
  def which(command : String) : String?
    nil
  end

  def run_capture(command : String, args : Array(String)) : String?
    nil
  end
end

private def group(json : String) : JSON::Any
  JSON.parse(json)
end

private def options(**args) : AgentApropos::Init::Options
  AgentApropos::Init::Options.new(**args)
end

describe AgentApropos::Agents::Agent do
  describe "#hook_command" do
    it "appends the outside-repo flag when the option is set" do
      StubAgent.new.expose_hook_command("agent-apropos hook pre", options(allow_outside_repo: true))
        .should eq("agent-apropos hook pre --allow-outside-repo")
    end

    it "leaves the command untouched when the option is not set" do
      StubAgent.new.expose_hook_command("agent-apropos hook pre", options(allow_outside_repo: false))
        .should eq("agent-apropos hook pre")
    end
  end

  describe "#agent_apropos_group?" do
    it "recognises a group whose hook command carries the agent-apropos prefix" do
      StubAgent.new.expose_agent_apropos_group?(
        group(%({"hooks":[{"command":"agent-apropos hook post --tool stub"}]}))
      ).should be_true
    end

    it "recognises the group when only a later hook carries the prefix" do
      StubAgent.new.expose_agent_apropos_group?(
        group(%({"hooks":[{"command":"make lint"},{"command":"agent-apropos hook pre"}]}))
      ).should be_true
    end

    it "rejects a group whose hooks all belong to something else" do
      StubAgent.new.expose_agent_apropos_group?(
        group(%({"hooks":[{"command":"make lint"}]}))
      ).should be_false
    end

    it "rejects a group with no hooks key" do
      StubAgent.new.expose_agent_apropos_group?(group(%({"matcher":"Edit"}))).should be_false
    end

    it "rejects a group whose hooks value is not an array" do
      StubAgent.new.expose_agent_apropos_group?(group(%({"hooks":"agent-apropos hook pre"}))).should be_false
    end

    it "rejects a group that is not an object at all" do
      StubAgent.new.expose_agent_apropos_group?(group(%(["agent-apropos hook pre"]))).should be_false
    end

    it "rejects a hook entry that is not an object" do
      StubAgent.new.expose_agent_apropos_group?(group(%({"hooks":["agent-apropos hook pre"]}))).should be_false
    end

    it "rejects a hook entry whose command is missing or not a string" do
      StubAgent.new.expose_agent_apropos_group?(group(%({"hooks":[{"timeout":10}]}))).should be_false
      StubAgent.new.expose_agent_apropos_group?(group(%({"hooks":[{"command":10}]}))).should be_false
    end
  end

  describe "#configured?" do
    it "is true when the agent's config file exists under the repo root" do
      root = Path[SpecPaths.absolute("repo")]
      fs = InMemoryFS.new({root.join(StubAgent::CONFIG_RELATIVE).to_s => "{}"})

      StubAgent.new.configured?(root, fs).should be_true
    end

    it "is false when it does not" do
      StubAgent.new.configured?(Path[SpecPaths.absolute("repo")], InMemoryFS.new).should be_false
    end
  end

  describe "#checks" do
    it "returns the subclass's hook check" do
      root = Path[SpecPaths.absolute("repo")]

      checks = StubAgent.new.checks(root, InMemoryFS.new, StubEnv.new)

      checks.map(&.name).should eq(["stub hook"])
    end
  end

  describe "#scaffold" do
    it "writes the config the subclass rendered, at the relative path it declared" do
      root = Path[SpecPaths.absolute("repo")]
      fs = InMemoryFS.new
      stdout = IO::Memory.new

      StubAgent.new.scaffold(root, fs, options, stdout)

      fs.files[SpecPaths.key(root.join(StubAgent::CONFIG_RELATIVE).to_s)]
        .should eq("stub config for stub, outside-repo=false\n")
      stdout.to_s.should eq("created  .stub/settings.json\n")
    end

    it "hands the existing content to the subclass and reports an update" do
      root = Path[SpecPaths.absolute("repo")]
      path = root.join(StubAgent::CONFIG_RELATIVE).to_s
      fs = InMemoryFS.new({path => "previous\n"})
      stdout = IO::Memory.new
      agent = StubAgent.new

      agent.scaffold(root, fs, options, stdout)

      agent.config_calls.should eq(["previous\n"])
      stdout.to_s.should eq("updated  .stub/settings.json\n")
    end

    it "reports the config as current when it already matches" do
      root = Path[SpecPaths.absolute("repo")]
      path = root.join(StubAgent::CONFIG_RELATIVE).to_s
      fs = InMemoryFS.new({path => "stub config for stub, outside-repo=false\n"})
      stdout = IO::Memory.new

      StubAgent.new.scaffold(root, fs, options, stdout)

      stdout.to_s.should eq("current  .stub/settings.json\n")
    end

    it "displays the relative path in POSIX form on every host" do
      root = Path[SpecPaths.absolute("repo")]
      stdout = IO::Memory.new

      StubAgent.new.scaffold(root, InMemoryFS.new, options(dry_run: true), stdout)

      stdout.to_s.should eq("would create .stub/settings.json\n")
    end
  end
end
