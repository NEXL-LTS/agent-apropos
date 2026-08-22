require "../spec_helper"

private ROOT                 = Path["/repo"]
private README_PATH          = "/repo/docs/conventions/README.md"
private AGENTS_PATH          = "/repo/AGENTS.md"
private SETTINGS_PATH        = "/repo/.claude/settings.json"
private GITIGNORE            = "/repo/.gitignore"
private PLUGIN_PATH          = "/repo/.opencode/plugins/agent-apropos.js"
private GEMINI_SETTINGS_PATH = "/repo/.gemini/settings.json"
private COPILOT_HOOKS_PATH   = "/repo/.github/hooks/agent-apropos.json"

# A configurable Environment double: `present` is the set of CLI agent
# binaries that resolve on PATH, used to exercise auto-detection.
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

# Refuses to create a symlink, the way an OS without symlink permission does.
private class NoSymlinkFS < InMemoryFS
  def symlink(target : String, link_path : String) : Nil
    raise AgentApropos::Filesystem::Error.new("symlink refused: operation not permitted")
  end
end

# Defaults to both supported agents present on PATH, so examples that are not
# about tool selection itself keep exercising the full scaffold.
private def run_init(fs : AgentApropos::Filesystem,
                     options : AgentApropos::Init::Options = AgentApropos::Init::Options.new,
                     env : AgentApropos::Environment = FakeEnv.new(Set{"claude", "opencode"})) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Init.run(ROOT, fs, env, options, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

describe AgentApropos::Init do
  describe "scaffolding" do
    it "creates the full structure in a fresh repo" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs)
      code.should eq(0)
      stderr.should be_empty

      fs.files[README_PATH].should contain("The three layers")
      fs.files.has_key?("/repo/docs/conventions/workflows/.gitkeep").should be_true
      fs.files["/repo/.claude/skills/.gitkeep"].should contain("Do not edit")
      fs.files[AGENTS_PATH].should contain("Where scoped guidance lives")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook pre")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post")
      fs.files[GITIGNORE].should contain(".cache/agent-apropos/")
      stdout.should contain("created  docs/conventions/README.md")
    end

    it "points at the bootstrapping prompt with a full URL, not a relative path" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs)
      stdout.should contain("https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase")
    end

    it "is idempotent — a second run changes nothing" do
      fs = InMemoryFS.new
      run_init(fs)
      settings_before = fs.files[SETTINGS_PATH]

      _, stdout, _ = run_init(fs)
      stdout.should contain("exists   docs/conventions/README.md")
      stdout.should contain("current  .claude/settings.json")
      stdout.should contain("current  .gitignore")
      fs.files[SETTINGS_PATH].should eq(settings_before)
    end

    it "overwrites managed scaffolds with --force but never the root file" do
      fs = InMemoryFS.new({README_PATH => "old readme", AGENTS_PATH => "custom root"})
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(force: true))
      stdout.should contain("updated  docs/conventions/README.md")
      stdout.should contain("exists   AGENTS.md")
      fs.files[README_PATH].should contain("The three layers")
      fs.files[AGENTS_PATH].should eq("custom root")
    end

    it "writes nothing under --dry-run" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(dry_run: true))
      stdout.should contain("would create docs/conventions/README.md")
      stdout.should contain("would create .claude/settings.json")
      stdout.should_not contain("https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase")
      fs.files.should be_empty
    end

    it "scaffolds into agent-apropos.yml's configured conventions_dir instead of the default, given --allow-outside-repo" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(allow_outside_repo: true))
      fs.files.has_key?("/repo/../shared-conventions/README.md").should be_true
      fs.files.has_key?("/repo/docs/conventions/README.md").should be_false
      stdout.should contain("created  ../shared-conventions/README.md")
    end

    it "fails closed when agent-apropos.yml's conventions_dir escapes repo_root without --allow-outside-repo" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      code, _, stderr = run_init(fs)
      code.should eq(1)
      stderr.should contain("resolves outside the repo root")
      fs.files.has_key?("/repo/../shared-conventions/README.md").should be_false
    end

    it "fails closed for an absolute conventions_dir outside repo_root without --allow-outside-repo" do
      outside = SpecPaths.absolute("var", "conventions")
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: '#{outside}'\n"})
      code, _, stderr = run_init(fs)
      code.should eq(1)
      stderr.should contain("resolves outside the repo root")
    end

    it "bakes --allow-outside-repo into the generated hook commands when the conventions_dir escapes repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      run_init(fs, AgentApropos::Init::Options.new(allow_outside_repo: true))
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook pre --tool claude --allow-outside-repo")
      fs.files[SETTINGS_PATH].should contain("agent-apropos hook post --tool claude --allow-outside-repo")
    end

    it "does not bake --allow-outside-repo into hook commands when conventions_dir stays under repo_root" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(allow_outside_repo: true))
      fs.files[SETTINGS_PATH].should_not contain("--allow-outside-repo")
    end
  end

  describe "--example" do
    it "drops one L2, one L3, and one skill doc" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(example: true))
      fs.files["/repo/docs/conventions/example-path-rule.md"].should contain("paths:")
      fs.files["/repo/docs/conventions/example-content-rule.md"].should contain("contents:")
      fs.files["/repo/docs/conventions/workflows/example-skill.md"].should contain("skill: true")
    end
  end

  describe "--claude-symlink" do
    it "aliases CLAUDE.md to AGENTS.md" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      fs.symlinks["/repo/CLAUDE.md"].should eq("AGENTS.md")
      stdout.should contain("linked   CLAUDE.md -> AGENTS.md")
    end

    it "leaves an existing CLAUDE.md untouched" do
      fs = InMemoryFS.new({"/repo/CLAUDE.md" => "real file"})
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      fs.symlinks.has_key?("/repo/CLAUDE.md").should be_false
      stdout.should contain("exists   CLAUDE.md")
    end

    it "reports the flag as unavailable and still exits zero when the OS refuses" do
      fs = NoSymlinkFS.new
      code, stdout, stderr = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      code.should eq(0)
      stderr.should be_empty
      stdout.should contain("skipped  CLAUDE.md -> AGENTS.md")
      stdout.should contain("operation not permitted")
    end

    it "leaves no partial or substitute link behind when the OS refuses" do
      fs = NoSymlinkFS.new
      run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      fs.symlinks.should be_empty
      fs.files.has_key?("/repo/CLAUDE.md").should be_false
    end

    it "still completes every other init step when the OS refuses" do
      fs = NoSymlinkFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true))
      stdout.should contain("docs/conventions/README.md")
      stdout.should contain(".gitignore")
      stdout.should contain(AgentApropos::Init::NEXT_STEPS_HINT)
    end

    it "reports the link under --dry-run without creating it" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(claude_symlink: true, dry_run: true))
      fs.symlinks.should be_empty
      stdout.should contain("would link CLAUDE.md -> AGENTS.md")
    end
  end

  # Per-agent scaffold/merge behavior (Claude, OpenCode, Gemini, Copilot) lives
  # in spec/agent_apropos/agents/*_spec.cr, exercising each Agents::Agent
  # subclass's own #scaffold directly. What's left here is Init's own
  # dispatch: which agents get scaffolded for a given --tool/auto-detect
  # resolution, independent of any one agent's file format.
  describe "error handling" do
    it "fails closed (exit 1) when an agent's scaffold raises, e.g. malformed existing settings JSON" do
      fs = InMemoryFS.new({SETTINGS_PATH => "{not json"})
      code, _, stderr = run_init(fs)
      code.should eq(1)
      stderr.should contain("not valid JSON")
    end
  end

  describe "--tool (explicit selection)" do
    it "wires only the explicitly named tool, ignoring what else is on PATH" do
      fs = InMemoryFS.new
      code, stdout, stderr = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"opencode"}))
      code.should eq(0)
      stderr.should be_empty
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain(".opencode/plugins/agent-apropos.js")
    end

    it "wires every named tool when --tool is repeated, regardless of PATH" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"claude", "opencode"}), FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
    end

    it "does not narrate detection — an explicit selection is the user's own words" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new(tools: Set{"claude"}))
      stdout.should_not contain("detected")
    end

    it "is not wired when the tool is not selected" do
      fs = InMemoryFS.new
      run_init(fs, AgentApropos::Init::Options.new(tools: Set{"claude"}))
      fs.files.has_key?(COPILOT_HOOKS_PATH).should be_false
    end
  end

  describe "auto-detection (no --tool given)" do
    it "wires only Claude when only claude is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"claude"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("detected claude")
    end

    it "wires only OpenCode when only opencode is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected opencode")
    end

    it "wires both when both are on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"claude", "opencode"}))
      fs.files.has_key?(SETTINGS_PATH).should be_true
      fs.files.has_key?(PLUGIN_PATH).should be_true
      stdout.should contain("detected claude, opencode")
    end

    it "wires neither and says so when no supported agent is on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new)
      fs.files.has_key?(SETTINGS_PATH).should be_false
      fs.files.has_key?(PLUGIN_PATH).should be_false
      stdout.should contain("no supported CLI agent found on PATH")
    end

    it "auto-detects gemini on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"gemini"}))
      fs.files.has_key?(GEMINI_SETTINGS_PATH).should be_true
      stdout.should contain("detected gemini")
    end

    it "auto-detects copilot on PATH" do
      fs = InMemoryFS.new
      _, stdout, _ = run_init(fs, AgentApropos::Init::Options.new, FakeEnv.new(Set{"copilot"}))
      fs.files.has_key?(COPILOT_HOOKS_PATH).should be_true
      stdout.should contain("detected copilot")
    end
  end

  describe ".gitignore merge" do
    it "appends the cache entry when missing, adding a separating newline" do
      fs = InMemoryFS.new({GITIGNORE => "/bin\n/lib"})
      run_init(fs)
      fs.files[GITIGNORE].should eq("/bin\n/lib\n.cache/agent-apropos/\n")
    end

    it "leaves the file unchanged when the entry is already present" do
      existing = "/bin\n.cache/agent-apropos/\n"
      fs = InMemoryFS.new({GITIGNORE => existing})
      _, stdout, _ = run_init(fs)
      stdout.should contain("current  .gitignore")
      fs.files[GITIGNORE].should eq(existing)
    end
  end
end
