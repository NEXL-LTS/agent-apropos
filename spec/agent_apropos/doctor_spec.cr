require "../spec_helper"

private ROOT             = Path["/repo"]
private SETTINGS_PATH    = "/repo/.claude/settings.json"
private INDEX_PATH       = "/repo/.cache/agent-apropos/index.json"
private DOC_PATH         = "/repo/docs/conventions/a.md"
private DOC_TEXT         = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody.\n"
private REMOVAL_DOC_TEXT = "---\non: [removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody.\n"

private FULL_SETTINGS = %({"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"agent-apropos hook pre"}]}],) +
                        %("PostToolUse":[{"hooks":[{"type":"command","command":"agent-apropos hook post"}]}]}})

# A configurable Environment: `present` maps a command to its resolved path;
# `outputs` maps a command to its captured `--version` stdout.
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

# Rejects writes so the cache-writability check can fail.
private class ReadOnlyFS < InMemoryFS
  def write(path : String, content : String) : Nil
    raise "read-only filesystem"
  end
end

private def index_for(text : String) : String
  AgentApropos::Index.build([AgentApropos::Convention.parse("docs/conventions/a.md", text)]).to_document
end

private def run_doctor(fs : AgentApropos::Filesystem, env : AgentApropos::Environment,
                       allow_outside : Bool = false) : {Int32, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Doctor.run(ROOT, fs, env, stdout, stderr, allow_outside)
  {code, stdout.to_s}
end

# Per-agent checks (Claude, OpenCode, Gemini, Copilot) are unit-tested against
# each Agents::Agent subclass's own #checks in spec/agent_apropos/agents/*_spec.cr.
# This file covers Doctor's own checks (agent-apropos on PATH, index, cache)
# and that it aggregates every agent's checks into one report.
describe AgentApropos::Doctor do
  it "passes cleanly when everything is wired" do
    fs = InMemoryFS.new({
      SETTINGS_PATH => FULL_SETTINGS,
      DOC_PATH      => DOC_TEXT,
      INDEX_PATH    => index_for(DOC_TEXT),
    })
    env = FakeEnv.new(
      present: {"agent-apropos" => "/usr/bin/agent-apropos", "claude" => "/usr/bin/claude"},
      outputs: {"claude" => "2.1.0 (Claude Code)".as(String?)})
    code, stdout = run_doctor(fs, env)
    code.should eq(0)
    stdout.should contain("ok    hooks: PreToolUse and PostToolUse call agent-apropos")
    stdout.should contain("ok    agent-apropos: on PATH at /usr/bin/agent-apropos")
    stdout.should contain("supports PreToolUse additionalContext")
    stdout.should contain("ok    index: fresh")
    stdout.should contain("ok    cache: .cache/agent-apropos is writable")
    stdout.should contain("doctor: 0 failure(s), 0 warning(s)")
  end

  describe "agent-apropos check" do
    it "reports the resolved path verbatim, including an executable extension" do
      env = FakeEnv.new({"agent-apropos" => "C:/Users/dev/.local/bin/agent-apropos.exe"})
      _, stdout = run_doctor(InMemoryFS.new, env)
      stdout.should contain("ok    agent-apropos: on PATH at C:/Users/dev/.local/bin/agent-apropos.exe")
    end

    it "warns when agent-apropos is not on PATH" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("warn  agent-apropos: not found on PATH")
    end
  end

  describe "index check" do
    it "warns when the index is missing" do
      _, stdout = run_doctor(InMemoryFS.new, FakeEnv.new)
      stdout.should contain("index: not built")
    end

    it "warns when the index is unreadable" do
      fs = InMemoryFS.new({INDEX_PATH => "garbage"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("index: unreadable")
    end

    it "warns when a malformed doc blocks freshness evaluation" do
      fs = InMemoryFS.new({
        INDEX_PATH => index_for(DOC_TEXT),
        DOC_PATH   => "---\npaths: [\n---\nx\n", # malformed → walk raises
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("cannot evaluate freshness")
    end

    it "warns when the index is stale" do
      fs = InMemoryFS.new({
        INDEX_PATH => index_for(DOC_TEXT),
        DOC_PATH   => DOC_TEXT + "\nmore\n", # content changed → hash differs
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("index: stale")
    end

    it "warns to pass --allow-outside-repo when conventions_dir escapes repo_root" do
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n",
        INDEX_PATH                => index_for(DOC_TEXT),
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("cannot evaluate freshness")
      stdout.should contain("--allow-outside-repo")
    end

    it "evaluates freshness against an escaping conventions_dir given allow_outside" do
      outside_index = AgentApropos::Index.build(
        [AgentApropos::Convention.parse("../shared-conventions/a.md", DOC_TEXT)]
      ).to_document
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml"          => "conventions_dir: ../shared-conventions\n",
        "/repo/../shared-conventions/a.md" => DOC_TEXT,
        INDEX_PATH                         => outside_index,
      })
      _, stdout = run_doctor(fs, FakeEnv.new, allow_outside: true)
      stdout.should contain("index: fresh")
    end
  end

  describe "cache check" do
    it "fails when the cache is not writable" do
      fs = ReadOnlyFS.new({SETTINGS_PATH => FULL_SETTINGS})
      code, stdout = run_doctor(fs, FakeEnv.new)
      code.should eq(1)
      stdout.should contain("fail  cache: .cache/agent-apropos is not writable")
    end
  end

  describe "removal hook check" do
    it "reports ok when no removal convention exists" do
      fs = InMemoryFS.new({DOC_PATH => DOC_TEXT, SETTINGS_PATH => "{}"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("ok    removal hook: no removal-triggered convention declared")
    end

    it "warns when a removal convention exists and a configured agent's shell hook is absent" do
      fs = InMemoryFS.new({DOC_PATH => REMOVAL_DOC_TEXT, SETTINGS_PATH => FULL_SETTINGS})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("warn  removal hook: claude missing the shell-tool removal hook; run `agent-apropos generate`")
    end

    it "reports ok when the shell hook is already wired" do
      wired = AgentApropos::Agents::Claude.new.sync_shell_hook(FULL_SETTINGS, "settings", true).as(String)
      fs = InMemoryFS.new({DOC_PATH => REMOVAL_DOC_TEXT, SETTINGS_PATH => wired})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("ok    removal hook: shell-tool removal detection is wired for every capable, configured agent")
    end

    it "stays silent about a configured agent that cannot deliver the event at all" do
      fs = InMemoryFS.new({DOC_PATH => REMOVAL_DOC_TEXT, "/repo/.gemini/settings.json" => "{}"})
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("ok    removal hook: shell-tool removal detection is wired for every capable, configured agent")
    end

    it "names every unwired capable agent" do
      fs = InMemoryFS.new({
        DOC_PATH                  => REMOVAL_DOC_TEXT,
        SETTINGS_PATH             => FULL_SETTINGS,
        "/repo/.codex/hooks.json" => "{}",
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("warn  removal hook: claude, codex missing the shell-tool removal hook")
    end

    it "detects a removal convention when only one of several docs declares it" do
      fs = InMemoryFS.new({
        DOC_PATH                      => DOC_TEXT,
        "/repo/docs/conventions/b.md" => REMOVAL_DOC_TEXT,
        SETTINGS_PATH                 => FULL_SETTINGS,
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("warn  removal hook: claude missing the shell-tool removal hook")
    end

    it "reports ok rather than warning when conventions cannot be evaluated" do
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n",
        SETTINGS_PATH             => "{}",
      })
      _, stdout = run_doctor(fs, FakeEnv.new)
      stdout.should contain("ok    removal hook: no removal-triggered convention declared")
    end

    it "probes and removes the exact .cache/agent-apropos/.doctor-probe path" do
      fs = InMemoryFS.new
      run_doctor(fs, FakeEnv.new)
      fs.removed.should contain("/repo/.cache/agent-apropos/.doctor-probe")
    end

    it "defaults allow_outside to false, refusing to see a removal convention outside the repo root" do
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml"          => "conventions_dir: ../shared-conventions\n",
        "/repo/../shared-conventions/a.md" => REMOVAL_DOC_TEXT,
        SETTINGS_PATH                      => "{}",
      })
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      AgentApropos::Doctor.run(ROOT, fs, FakeEnv.new, stdout, stderr)
      stdout.to_s.should contain("ok    removal hook: no removal-triggered convention declared")
    end
  end

  it "counts a lone warning correctly, not zero or two" do
    fs = InMemoryFS.new({SETTINGS_PATH => FULL_SETTINGS, DOC_PATH => DOC_TEXT, INDEX_PATH => index_for(DOC_TEXT)})
    code, stdout = run_doctor(fs, FakeEnv.new)
    code.should eq(0)
    stdout.should contain("doctor: 0 failure(s), 1 warning(s)")
  end
end
