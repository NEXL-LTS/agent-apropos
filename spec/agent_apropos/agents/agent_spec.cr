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

# A minimal agent that wires its shell hook through the shared machinery the
# way Claude and Codex do: fixed pre/post bases and a fixed timeout. The
# timeout is deliberately not 10, so a spec cannot pass on another agent's
# constant.
private class ShellAgent < AgentApropos::Agents::Agent
  PRE     = "agent-apropos hook pre --tool shell"
  POST    = "agent-apropos hook post --tool shell"
  TIMEOUT = 7_i64

  def name : String
    "shell"
  end

  def config_relative : Path
    Path[".shell", "settings.json"]
  end

  def skill_root : Path
    Path[".shell", "skills"]
  end

  def read?(payload : AgentApropos::Hook::Payload) : Bool
    false
  end

  def sync_shell_hook(existing : String?, label : String, wire : Bool) : String?
    sync_standard_shell_hook(existing, label, wire, PRE, POST, TIMEOUT)
  end

  protected def config_content(existing : String?, options : AgentApropos::Init::Options) : String
    existing || ""
  end

  # Exposes the protected refresh for specs: the hooks of `existing` after
  # refreshing its own Bash commands for `allow_outside`.
  def refresh(existing : String, allow_outside : Bool) : JSON::Any
    hooks = JSON.parse(existing)["hooks"].as_h.dup
    refresh_shell_hooks(hooks, hook_command(PRE, allow_outside), hook_command(POST, allow_outside), TIMEOUT)
    JSON::Any.new(hooks)
  end

  protected def hook_check(repo_root : Path, fs : AgentApropos::Filesystem,
                           env : AgentApropos::Environment) : AgentApropos::Check
    AgentApropos::Check.new(:ok, "shell hook", "")
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

private def shell_sync(existing : String?, wire : Bool) : String?
  ShellAgent.new.sync_shell_hook(existing, "shell.json", wire)
end

# The exact bytes the machinery writes for `json`: pretty-printed, one
# trailing newline.
private def pretty(json : String) : String
  JSON.parse(json).to_pretty_json + "\n"
end

private def entry(command : String, timeout : Int32 = 7) : String
  %({"type":"command","command":"#{command}","timeout":#{timeout}})
end

private def bash(*hooks : String) : String
  %({"matcher":"Bash","hooks":[#{hooks.join(",")}]})
end

private PRE_ENTRY  = entry(ShellAgent::PRE)
private POST_ENTRY = entry(ShellAgent::POST)
private PRE_FLAG   = "#{ShellAgent::PRE} --allow-outside-repo"
private POST_FLAG  = "#{ShellAgent::POST} --allow-outside-repo"

private def wired(pre : String = bash(PRE_ENTRY), post : String = bash(POST_ENTRY)) : String
  %({"hooks":{"PreToolUse":[#{pre}],"PostToolUse":[#{post}]}})
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

  describe "#refresh_shell_hooks" do
    it "drops a stale --allow-outside-repo from its own Bash hooks, Pre and Post each keeping its own command" do
      stale = wired(bash(entry(PRE_FLAG)), bash(entry(POST_FLAG)))
      ShellAgent.new.refresh(stale, false).should eq(JSON.parse(wired)["hooks"])
    end

    it "adds --allow-outside-repo to its own Bash hooks when it is enabled" do
      ShellAgent.new.refresh(wired, true).should eq(JSON.parse(wired(bash(entry(PRE_FLAG)), bash(entry(POST_FLAG))))["hooks"])
    end

    it "creates no Bash hook where none was wired" do
      seed = %({"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[#{PRE_ENTRY}]}]}})
      ShellAgent.new.refresh(seed, true).should eq(JSON.parse(seed)["hooks"])
      ShellAgent.new.refresh(%({"hooks":{}}), true).should eq(JSON.parse(%({})))
    end

    it "leaves another tool's hook in a Bash group untouched" do
      seed = wired(bash(entry("lint"), entry(PRE_FLAG)), bash(entry(POST_FLAG)))
      ShellAgent.new.refresh(seed, false).should eq(JSON.parse(wired(bash(entry("lint"), PRE_ENTRY), bash(POST_ENTRY)))["hooks"])
    end
  end

  describe "#sync_shell_hook" do
    it "the default (unwired) implementation is a no-op that returns existing unchanged" do
      StubAgent.new.sync_shell_hook("anything", "label", true).should eq("anything")
    end
  end

  describe "#sync_standard_shell_hook" do
    describe "wiring" do
      it "creates the file's content when there is none: a Bash group per event, pre on Pre and post on Post" do
        shell_sync(nil, true).should eq(pretty(wired))
      end

      it "wires an empty object the same way" do
        shell_sync("{}", true).should eq(pretty(wired))
      end

      it "keeps unrelated top-level keys and events where they were, adding its events after them" do
        seed = %({"model":"x","hooks":{"Stop":[{"hooks":[#{entry("notify")}]}]},"z":1})
        shell_sync(seed, true).should eq(pretty(
          %({"model":"x","hooks":{"Stop":[{"hooks":[#{entry("notify")}]}],) +
          %("PreToolUse":[#{bash(PRE_ENTRY)}],"PostToolUse":[#{bash(POST_ENTRY)}]},"z":1})
        ))
      end

      it "adds its own Bash group after another matcher's group, even one holding the very same entry" do
        edit = %({"matcher":"Edit|Write","hooks":[#{PRE_ENTRY}]})
        shell_sync(wired(pre: edit, post: ""), true).should eq(pretty(
          wired(pre: "#{edit},#{bash(PRE_ENTRY)}")
        ))
      end

      it "appends its entry to an existing Bash group after the hooks already there" do
        seed = wired(pre: bash(entry("audit")), post: bash(entry("log", 30)))
        shell_sync(seed, true).should eq(pretty(
          wired(pre: bash(entry("audit"), PRE_ENTRY), post: bash(entry("log", 30), POST_ENTRY))
        ))
      end

      it "appends to the first of several Bash groups when none holds its entry" do
        seed = wired(pre: "#{bash(entry("a"))},#{bash(entry("b"))}")
        shell_sync(seed, true).should eq(pretty(
          wired(pre: "#{bash(entry("a"), PRE_ENTRY)},#{bash(entry("b"))}")
        ))
      end

      it "adds nothing when a later Bash group already holds its entry" do
        seed = wired(pre: "#{bash(entry("a"))},#{bash(PRE_ENTRY)}")
        shell_sync(seed, true).should eq(seed)
      end

      it "wires only the event that is missing" do
        seed = %({"hooks":{"PreToolUse":[#{bash(PRE_ENTRY)}]}})
        shell_sync(seed, true).should eq(pretty(wired))
      end

      it "names the label in the error when the existing content is not JSON" do
        expect_raises(AgentApropos::Init::Error, /shell\.json is not valid JSON/) { shell_sync("{nope", true) }
      end
    end

    describe "idempotence" do
      it "returns already-wired content byte-for-byte, however it was formatted" do
        compact = wired
        shell_sync(compact, true).should eq(compact)
      end

      it "returns its own output unchanged on a second run" do
        once = shell_sync("{}", true)
        shell_sync(once, true).should eq(once)
      end

      it "returns nil when there is nothing to unwire and no file" do
        shell_sync(nil, false).should be_nil
      end
    end

    describe "unwiring" do
      it "returns to the exact seed it wired into" do
        seed = %({"model":"x","hooks":{"Stop":[{"hooks":[#{entry("notify")}]}],) +
               %("PreToolUse":[#{bash(entry("audit"))}]}})
        shell_sync(shell_sync(seed, true).as(String), false).should eq(pretty(seed))
      end

      it "drops the hooks key it created" do
        shell_sync(shell_sync("{}", true), false).should eq("{}\n")
      end

      it "drops only its own hooks from a shared Bash group" do
        seed = wired(pre: bash(entry("audit"), PRE_ENTRY), post: bash(POST_ENTRY, entry("log")))
        shell_sync(seed, false).should eq(pretty(
          wired(pre: bash(entry("audit")), post: bash(entry("log")))
        ))
      end

      it "drops every agent-apropos hook in a Bash group, whichever kind or tool it names" do
        seed = %({"hooks":{"PreToolUse":[#{bash(entry("agent-apropos hook post --tool other"), entry("keep"))}]}})
        shell_sync(seed, false).should eq(pretty(%({"hooks":{"PreToolUse":[#{bash(entry("keep"))}]}})))
      end

      it "leaves agent-apropos hooks under other matchers alone" do
        edit = %({"matcher":"Edit|Write","hooks":[#{PRE_ENTRY}]})
        shell_sync(wired(pre: "#{edit},#{bash(PRE_ENTRY)}"), false).should eq(pretty(
          %({"hooks":{"PreToolUse":[#{edit}]}})
        ))
      end

      it "keeps an empty event and an empty Bash group it did not own" do
        seed = %({"hooks":{"PreToolUse":[],"PostToolUse":[{"matcher":"Bash","hooks":[]}]}})
        shell_sync(seed, false).should eq(seed)
      end

      it "keeps an empty event while removing its own from the other" do
        seed = %({"hooks":{"PreToolUse":[],"PostToolUse":[#{bash(POST_ENTRY)}]}})
        shell_sync(seed, false).should eq(pretty(%({"hooks":{"PreToolUse":[]}})))
      end

      it "returns an empty hooks object unchanged" do
        shell_sync(%({"hooks":{}}), false).should eq(%({"hooks":{}}))
      end
    end

    describe "upgrading" do
      it "rewrites its own entry to the exact current shape, dropping a stale timeout and extra keys" do
        stale = %({"type":"command","command":"#{ShellAgent::PRE}","timeout":3,"extra":true})
        shell_sync(wired(pre: bash(stale)), true).should eq(pretty(wired))
      end

      it "upgrades an older command of the same kind in place, keeping its position" do
        seed = wired(pre: bash(entry("agent-apropos hook pre", 10), entry("audit")))
        shell_sync(seed, true).should eq(pretty(wired(pre: bash(PRE_ENTRY, entry("audit")))))
      end

      it "upgrades same-kind hooks in every Bash group, untouched groups staying byte-identical" do
        seed = wired(pre: "#{bash(entry("a"))},#{bash(entry("agent-apropos hook pre"))},#{bash(entry("agent-apropos hook pre --x"))}")
        shell_sync(seed, true).should eq(pretty(
          wired(pre: "#{bash(entry("a"))},#{bash(PRE_ENTRY)},#{bash(PRE_ENTRY)}")
        ))
      end

      it "does not treat a hook of the other kind as its own: the post hook in a Pre group stays and pre is added" do
        seed = wired(pre: bash(entry("agent-apropos hook post --tool shell")))
        shell_sync(seed, true).should eq(pretty(
          wired(pre: bash(entry("agent-apropos hook post --tool shell"), PRE_ENTRY))
        ))
      end

      it "compares the hook name as a word, not a prefix" do
        seed = wired(pre: bash(entry("agent-apropos hook preview")))
        shell_sync(seed, true).should eq(pretty(
          wired(pre: bash(entry("agent-apropos hook preview"), PRE_ENTRY))
        ))
      end

      it "leaves a foreign command that merely shares the hook's words alone" do
        seed = wired(pre: bash(entry("run agent-apropos hook pre")))
        shell_sync(seed, true).should eq(pretty(
          wired(pre: bash(entry("run agent-apropos hook pre"), PRE_ENTRY))
        ))
      end
    end

    describe "--allow-outside-repo" do
      it "carries the flag over from any agent-apropos hook in any event" do
        seed = %({"hooks":{"Stop":["junk",{"hooks":"junk"},{"hooks":["junk",{"command":1},) +
               %(#{entry("agent-apropos hook stop --allow-outside-repo")}]}],"Other":"junk"}})
        JSON.parse(shell_sync(seed, true).as(String))["hooks"]["PreToolUse"].should eq(
          JSON.parse(%([#{bash(entry(PRE_FLAG))}]))
        )
      end

      it "finds the flag in any argument position and upgrades its own entry to carry it" do
        seed = wired(pre: bash(entry("agent-apropos hook pre --allow-outside-repo --tool shell")))
        shell_sync(seed, true).should eq(pretty(wired(pre: bash(entry(PRE_FLAG)), post: bash(entry(POST_FLAG)))))
      end

      it "ignores the flag on a command that is not agent-apropos's" do
        seed = wired(pre: bash(entry("make --allow-outside-repo"), PRE_ENTRY))
        shell_sync(seed, true).should eq(seed)
      end

      it "ignores a longer argument that only starts with the flag" do
        seed = wired(pre: bash(entry("agent-apropos hook other --allow-outside-repository"), PRE_ENTRY))
        shell_sync(seed, true).should eq(seed)
      end
    end

    describe "malformed shapes" do
      it "replaces a hooks value that is not an object when wiring, and leaves it when unwiring" do
        shell_sync(%({"hooks":[1]}), true).should eq(pretty(wired))
        shell_sync(%({"hooks":[1]}), false).should eq(%({"hooks":[1]}))
      end

      it "replaces an event value that is not an array when wiring, and leaves it when unwiring" do
        seed = %({"hooks":{"PreToolUse":"junk","PostToolUse":[#{bash(POST_ENTRY)}]}})
        shell_sync(seed, true).should eq(pretty(wired))
        shell_sync(%({"hooks":{"PreToolUse":"junk"}}), false).should eq(%({"hooks":{"PreToolUse":"junk"}}))
      end

      it "keeps a group that is not an object and adds its own after it" do
        shell_sync(wired(pre: %("junk")), true).should eq(pretty(wired(pre: %("junk",#{bash(PRE_ENTRY)}))))
        shell_sync(wired(pre: %("junk")), false).should eq(pretty(%({"hooks":{"PreToolUse":["junk"]}})))
      end

      it "ignores a group whose matcher is not a string" do
        odd = %({"matcher":1,"hooks":[#{PRE_ENTRY}]})
        shell_sync(wired(pre: odd), true).should eq(pretty(wired(pre: "#{odd},#{bash(PRE_ENTRY)}")))
      end

      it "gives a Bash group with no hooks key, or a non-array one, a list holding its entry" do
        seed = wired(pre: %({"matcher":"Bash"}), post: %({"matcher":"Bash","hooks":"junk"}))
        shell_sync(seed, true).should eq(pretty(wired))
      end

      it "leaves a Bash group with no hooks list untouched when another Bash group holds its entry" do
        seed = wired(pre: %({"matcher":"Bash"},#{bash(PRE_ENTRY)}), post: %({"matcher":"Bash","hooks":"x"},#{bash(POST_ENTRY)}))
        shell_sync(seed, true).should eq(seed)
      end

      it "leaves a Bash group with no hooks list untouched when unwiring" do
        seed = wired(pre: %({"matcher":"Bash"}), post: %({"matcher":"Bash","hooks":"x"}))
        shell_sync(seed, false).should eq(seed)
      end

      it "keeps hooks without a string command and adds its own after them" do
        odd = %("junk",{"type":"command"},{"command":5})
        shell_sync(wired(pre: bash(odd)), true).should eq(pretty(wired(pre: bash(odd, PRE_ENTRY))))
        shell_sync(wired(pre: bash(odd, PRE_ENTRY)), false).should eq(pretty(%({"hooks":{"PreToolUse":[#{bash(odd)}]}})))
      end
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
