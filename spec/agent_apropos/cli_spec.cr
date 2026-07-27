require "../spec_helper"
require "file_utils"

private def run(args : Array(String), stdin : String = "")
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::CLI.run(args, stdout, stderr, IO::Memory.new(stdin))
  {code, stdout.to_s, stderr.to_s}
end

# A throwaway repo with one Layer 2 doc and one skill doc; yields its path.
private def with_fixture_repo(git : Bool = false, &)
  dir = File.tempname("agent-apropos-cli")
  begin
    Dir.mkdir_p(File.join(dir, "docs/conventions/workflows"))
    Dir.mkdir_p(File.join(dir, ".git")) if git
    File.write(File.join(dir, "docs/conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
    File.write(File.join(dir, "docs/conventions/workflows/foo.md"),
      "---\nskill: true\ndescription: \"Use when foo\"\n---\nbody\n")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A repo whose `agent-apropos.yml` points `conventions_dir` at a sibling
# directory outside the repo itself (mirroring agent-apropos's own e2e
# fixture) — yields the repo dir.
private def with_outside_fixture_repo(&)
  parent = File.tempname("agent-apropos-cli-outside")
  dir = File.join(parent, "repo")
  begin
    Dir.mkdir_p(dir)
    Dir.mkdir_p(File.join(parent, "conventions"))
    File.write(File.join(dir, "agent-apropos.yml"), "conventions_dir: ../conventions\n")
    File.write(File.join(parent, "conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
    yield dir
  ensure
    FileUtils.rm_rf(parent)
  end
end

# Same as `with_git_repo`, but the doc lives outside the repo, pointed at via
# `agent-apropos.yml`'s `conventions_dir` (see `with_outside_fixture_repo`).
private def with_outside_git_repo(&)
  parent = File.tempname("agent-apropos-cli-outside-review")
  dir = File.join(parent, "repo")
  begin
    Dir.mkdir_p(dir)
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(parent, "conventions"))
    File.write(File.join(dir, "agent-apropos.yml"), "conventions_dir: ../conventions\n")
    File.write(File.join(parent, "conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
    File.write(File.join(dir, "src/x.cr"), "one\n")
    git_cmd(dir, ["init", "-b", "main"])
    git_cmd(dir, ["add", "-A"])
    git_cmd(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"])
    git_cmd(dir, ["checkout", "-b", "feature"])
    File.write(File.join(dir, "src/x.cr"), "one\ntwo\n")
    git_cmd(dir, ["add", "-A"])
    git_cmd(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "change"])
    yield dir
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def in_dir(dir : String, &)
  original = Dir.current
  Dir.cd(dir)
  begin
    yield
  ensure
    Dir.cd(original)
  end
end

private def git_cmd(dir : String, args : Array(String)) : Nil
  status = Process.run("git", args, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "git #{args.join(' ')} failed" unless status.success?
end

# A real git repo with one Layer 2 doc, an initial commit on `main`, and a
# feature commit that edits a `src/**` file — so `review` has a range to resolve.
private def with_git_repo(&)
  dir = File.tempname("agent-apropos-cli-review")
  begin
    Dir.mkdir_p(File.join(dir, "docs/conventions"))
    Dir.mkdir_p(File.join(dir, "src"))
    File.write(File.join(dir, "docs/conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
    File.write(File.join(dir, "src/x.cr"), "one\n")
    git_cmd(dir, ["init", "-b", "main"])
    git_cmd(dir, ["add", "-A"])
    git_cmd(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"])
    git_cmd(dir, ["checkout", "-b", "feature"])
    File.write(File.join(dir, "src/x.cr"), "one\ntwo\n")
    git_cmd(dir, ["add", "-A"])
    git_cmd(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "change"])
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe AgentApropos::CLI do
  describe "help" do
    it "prints usage and exits 0 with no args" do
      code, out, err = run([] of String)
      code.should eq(0)
      out.should contain("Usage: agent-apropos")
      err.should be_empty
    end

    it "prints usage for --help and -h" do
      %w[--help -h].each do |flag|
        code, out, _ = run([flag])
        code.should eq(0)
        out.should contain("Usage: agent-apropos")
      end
    end
  end

  describe "help" do
    it "prints the mental-model explainer, distinct from --help usage" do
      code, out, _ = run(["help"])
      code.should eq(0)
      out.should contain("What agent-apropos is")
      out.should_not contain("Usage: agent-apropos")
    end

    it "renders the JSON explainer" do
      code, stdout, _ = run(["help", "--format", "json"])
      code.should eq(0)
      JSON.parse(stdout)["commands"].as_a.should_not be_empty
    end

    it "explains a single command" do
      code, out, _ = run(["help", "review"])
      code.should eq(0)
      out.should contain("agent-apropos review —")
    end
  end

  describe "version" do
    it "prints the version for --version and version" do
      %w[--version version].each do |flag|
        code, out, _ = run([flag])
        code.should eq(0)
        out.should contain("agent-apropos #{AgentApropos::VERSION}")
      end
    end
  end

  describe "unknown command" do
    it "reports the error on stderr and exits 1" do
      code, out, err = run(["frobnicate"])
      code.should eq(1)
      out.should be_empty
      err.should contain("unknown command 'frobnicate'")
    end
  end

  describe "generate" do
    it "builds the index and wrappers against an explicit --repo-root" do
      with_fixture_repo do |dir|
        code, out, err = run(["generate", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        out.should contain("index: rebuilt")
        File.exists?(File.join(dir, ".cache/agent-apropos/index.json")).should be_true
        File.exists?(File.join(dir, ".claude/skills/foo/SKILL.md")).should be_true
      end
    end

    it "runs --check green right after a generate" do
      with_fixture_repo do |dir|
        run(["generate", "--repo-root", dir])
        code, out, _ = run(["generate", "--check", "--repo-root", dir])
        code.should eq(0)
        out.should contain("up to date")
      end
    end

    it "resolves the repo root from the working directory by default" do
      with_fixture_repo(git: true) do |dir|
        code, out, _ = in_dir(dir) { run(["generate"]) }
        code.should eq(0)
        out.should contain("index: rebuilt")
      end
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["generate"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["generate", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects an unknown option" do
      code, _, err = run(["generate", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "fails closed when conventions_dir escapes repo_root without --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, _, err = run(["generate", "--repo-root", dir])
        code.should eq(1)
        err.should contain("resolves outside the repo root")
      end
    end

    it "walks an escaping conventions_dir given --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, out, err = run(["generate", "--repo-root", dir, "--allow-outside-repo"])
        code.should eq(0)
        err.should be_empty
        out.should contain("index: rebuilt (1 docs)")
      end
    end
  end

  describe "hook" do
    it "injects a Layer 2 rule on pre with an explicit repo root" do
      with_fixture_repo do |dir|
        payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr")}}.to_json
        code, out, err = run(["hook", "pre", "--repo-root", dir], payload)
        code.should eq(0)
        err.should be_empty
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "runs post through the real filesystem and exits 0" do
      with_fixture_repo do |dir|
        payload = {tool_name: "Write", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr"), content: "code"}}.to_json
        code, out, _ = run(["hook", "post", "--repo-root", dir], payload)
        code.should eq(0)
        out.should be_empty
      end
    end

    it "resolves the repo root from the payload cwd by default" do
      with_fixture_repo(git: true) do |dir|
        payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                   tool_input: {file_path: "src/x.cr"}}.to_json
        code, out, _ = run(["hook", "pre"], payload)
        code.should eq(0)
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "injects a Layer 2 rule on pre from a Read-tool-shaped payload" do
      with_fixture_repo do |dir|
        payload = {session_id: "s", tool_name: "Read", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr")}}.to_json
        code, out, err = run(["hook", "pre", "--repo-root", dir], payload)
        code.should eq(0)
        err.should be_empty
        out.should contain("agent-apropos is connected and running")
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "ignores --repo-root when its value is omitted and the next token is itself a flag" do
      with_fixture_repo(git: true) do |dir|
        payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                   tool_input: {file_path: "src/x.cr"}}.to_json
        # --repo-root's value is missing; the next token is another flag, not
        # a directory. Treating it as the value would make root resolution
        # fail (no such directory), losing injection entirely.
        code, out, _ = run(["hook", "pre", "--repo-root", "--tool", "claude"], payload)
        code.should eq(0)
        out.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "parses --tool and threads it through to label the recorded cause" do
      with_fixture_repo do |dir|
        payload = {session_id: "s", tool_name: "Read", cwd: dir,
                   tool_input: {file_path: File.join(dir, "src/x.cr")}}.to_json
        code, _, err = run(["hook", "pre", "--repo-root", dir, "--tool", "claude"], payload)
        code.should eq(0)
        err.should be_empty
        session_file = File.join(dir, ".cache/agent-apropos/sessions/s.json")
        File.read(session_file).should contain(%("layer": "agent"))
      end
    end

    it "exits 0 on an unknown hook subcommand (fail open)" do
      code, out, err = run(["hook", "frobnicate"])
      code.should eq(0)
      out.should be_empty
      err.should be_empty
    end
  end

  describe "match" do
    it "prints matching rule files for a path (default format)" do
      with_fixture_repo do |dir|
        code, out, err = run(["match", "--repo-root", dir, "src/x.cr"])
        code.should eq(0)
        err.should be_empty
        out.should eq("docs/conventions/a.md\n")
      end
    end

    it "supports json and full formats" do
      with_fixture_repo do |dir|
        _, json, _ = run(["match", "--format", "json", "--repo-root", dir, "src/x.cr"])
        json.should contain(%("path": "docs/conventions/a.md"))
        _, full, _ = run(["match", "--format", "full", "--repo-root", dir, "src/x.cr"])
        full.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "reads content from stdin with --stdin-content" do
      with_fixture_repo do |dir|
        code, out, _ = run(["match", "--stdin-content", "--repo-root", dir, "src/x.cr"], stdin: "code")
        code.should eq(0)
        out.should contain("docs/conventions/a.md")
      end
    end

    it "requires at least one path" do
      code, _, err = run(["match", "--repo-root", "/tmp"])
      code.should eq(1)
      err.should contain("expected at least one path")
    end

    it "rejects --stdin-content with more than one path" do
      code, _, err = run(["match", "--stdin-content", "--repo-root", "/tmp", "a.cr", "b.cr"])
      code.should eq(1)
      err.should contain("--stdin-content takes exactly one path")
    end

    it "rejects an unknown format" do
      code, _, err = run(["match", "--format", "xml", "--repo-root", "/tmp", "a.cr"])
      code.should eq(1)
      err.should contain("unknown --format 'xml'")
    end

    it "rejects --format without a value" do
      code, _, err = run(["match", "--format"])
      code.should eq(1)
      err.should contain("--format requires a value")
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["match", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects an unknown option" do
      code, _, err = run(["match", "--bogus", "a.cr"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["match", "src/x.cr"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end

    it "fails closed when conventions_dir escapes repo_root without --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, _, err = run(["match", "--repo-root", dir, "src/x.cr"])
        code.should eq(1)
        err.should contain("resolves outside the repo root")
      end
    end

    it "matches against an escaping conventions_dir given --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, out, err = run(["match", "--repo-root", dir, "--allow-outside-repo", "src/x.cr"])
        code.should eq(0)
        err.should be_empty
        out.should eq("../conventions/a.md\n")
      end
    end
  end

  describe "review" do
    it "emits a manifest for a git range" do
      with_git_repo do |dir|
        code, out, err = run(["review", "--repo-root", dir, "main...HEAD"])
        code.should eq(0)
        err.should be_empty
        out.should contain("# Review manifest (main...HEAD)")
        out.should contain("docs/conventions/a.md")
      end
    end

    it "resolves the default range and repo root from the working directory" do
      with_git_repo do |dir|
        code, out, _ = in_dir(dir) { run(["review", "--format", "json"]) }
        code.should eq(0)
        out.should contain(%("range": "main...HEAD"))
      end
    end

    it "rejects an unknown format" do
      code, _, err = run(["review", "--format", "html", "--repo-root", "/tmp"])
      code.should eq(1)
      err.should contain("unknown --format 'html'")
    end

    it "rejects --format without a value" do
      code, _, err = run(["review", "--format"])
      code.should eq(1)
      err.should contain("--format requires a value")
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["review", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects a second git range" do
      code, _, err = run(["review", "a...b", "c...d"])
      code.should eq(1)
      err.should contain("only one git range may be given")
    end

    it "rejects an unknown option" do
      code, _, err = run(["review", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "fails closed when conventions_dir escapes repo_root without --allow-outside-repo" do
      with_outside_git_repo do |dir|
        code, _, err = run(["review", "--repo-root", dir, "main...HEAD"])
        code.should eq(1)
        err.should contain("resolves outside the repo root")
      end
    end

    it "reviews a range against an escaping conventions_dir given --allow-outside-repo" do
      with_outside_git_repo do |dir|
        code, out, err = run(["review", "--repo-root", dir, "--allow-outside-repo", "main...HEAD"])
        code.should eq(0)
        err.should be_empty
        out.should contain("../conventions/a.md")
      end
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["review"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end
  end

  describe "init" do
    it "scaffolds a repo against an explicit --repo-root, wiring the explicitly named tool" do
      dir = File.tempname("agent-apropos-cli-init")
      begin
        Dir.mkdir_p(dir)
        code, out, err = run(["init", "--tool", "claude", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        out.should contain("docs/conventions/README.md")
        File.exists?(File.join(dir, ".claude/settings.json")).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "threads every scaffolding flag through to Init" do
      dir = File.tempname("agent-apropos-cli-init-flags")
      begin
        Dir.mkdir_p(dir)
        code, out, _ = run(["init", "--force", "--example", "--claude-symlink", "--dry-run",
                            "--allow-outside-repo", "--repo-root", dir])
        code.should eq(0)
        out.should contain("would create docs/conventions/example-path-rule.md")
        out.should contain("would link CLAUDE.md -> AGENTS.md")
        Dir.glob(File.join(dir, "**/*")).should be_empty # --dry-run wrote nothing
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "fails closed when agent-apropos.yml's conventions_dir escapes repo_root without --allow-outside-repo" do
      parent = File.tempname("agent-apropos-cli-init-outside")
      dir = File.join(parent, "repo")
      begin
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "agent-apropos.yml"), "conventions_dir: ../shared\n")
        code, _, err = run(["init", "--repo-root", dir])
        code.should eq(1)
        err.should contain("resolves outside the repo root")
      ensure
        FileUtils.rm_rf(parent)
      end
    end

    it "scaffolds an escaping conventions_dir and bakes --allow-outside-repo into the wired hook given the flag" do
      parent = File.tempname("agent-apropos-cli-init-outside-allowed")
      dir = File.join(parent, "repo")
      begin
        Dir.mkdir_p(dir)
        File.write(File.join(dir, "agent-apropos.yml"), "conventions_dir: ../shared\n")
        code, _, err = run(["init", "--tool", "claude", "--allow-outside-repo", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        File.exists?(File.join(parent, "shared/README.md")).should be_true
        File.read(File.join(dir, ".claude/settings.json")).should contain("agent-apropos hook pre --tool claude --allow-outside-repo")
      ensure
        FileUtils.rm_rf(parent)
      end
    end

    it "scaffolds every tool named across repeated --tool flags" do
      dir = File.tempname("agent-apropos-cli-init-tool")
      begin
        Dir.mkdir_p(dir)
        code, out, err = run(["init", "--tool", "opencode", "--tool", "claude", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        out.should contain(".opencode/plugins/agent-apropos.js")
        File.exists?(File.join(dir, ".opencode/plugins/agent-apropos.js")).should be_true
        File.exists?(File.join(dir, ".claude/settings.json")).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "wires only the one tool named, not the other" do
      dir = File.tempname("agent-apropos-cli-init-tool-single")
      begin
        Dir.mkdir_p(dir)
        code, _, err = run(["init", "--tool", "opencode", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        File.exists?(File.join(dir, ".opencode/plugins/agent-apropos.js")).should be_true
        File.exists?(File.join(dir, ".claude/settings.json")).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "wires only gemini when named alone" do
      dir = File.tempname("agent-apropos-cli-init-tool-gemini")
      begin
        Dir.mkdir_p(dir)
        code, _, err = run(["init", "--tool", "gemini", "--repo-root", dir])
        code.should eq(0)
        err.should be_empty
        File.exists?(File.join(dir, ".gemini/settings.json")).should be_true
        File.exists?(File.join(dir, ".claude/settings.json")).should be_false
        File.read(File.join(dir, ".gemini/settings.json")).should contain("agent-apropos hook pre")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["init", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects --tool without a value" do
      code, _, err = run(["init", "--tool"])
      code.should eq(1)
      err.should contain("--tool requires a value")
    end

    it "rejects an unknown --tool value" do
      code, _, err = run(["init", "--tool", "cursor"])
      code.should eq(1)
      err.should contain("unknown tool 'cursor'")
    end

    it "rejects an unknown option" do
      code, _, err = run(["init", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["init"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end
  end

  describe "lint" do
    it "lints a generated fixture repo clean" do
      with_fixture_repo do |dir|
        run(["generate", "--repo-root", dir])
        code, out, _ = run(["lint", "--repo-root", dir])
        code.should eq(0)
        out.should contain("lint: clean")
      end
    end

    it "accepts --strict" do
      with_fixture_repo do |dir|
        run(["generate", "--repo-root", dir])
        code, _, _ = run(["lint", "--strict", "--repo-root", dir])
        code.should eq(0)
      end
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["lint", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects an unknown option" do
      code, _, err = run(["lint", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["lint"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end

    it "fails closed when conventions_dir escapes repo_root without --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, _, err = run(["lint", "--repo-root", dir])
        code.should eq(1)
        err.should contain("resolves outside the repo root")
      end
    end

    it "lints an escaping conventions_dir given --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        code, out, err = run(["lint", "--repo-root", dir, "--allow-outside-repo"])
        code.should eq(0)
        err.should be_empty
        out.should contain("lint: clean")
      end
    end
  end

  describe "doctor" do
    it "reports the environment against an explicit --repo-root" do
      with_fixture_repo do |dir|
        code, out, _ = run(["doctor", "--repo-root", dir])
        code.should eq(1) # no settings.json in the fixture → hooks check fails
        out.should contain("doctor:")
        out.should contain("settings.json not found")
      end
    end

    it "rejects --repo-root without a value" do
      code, _, err = run(["doctor", "--repo-root"])
      code.should eq(1)
      err.should contain("--repo-root requires a directory")
    end

    it "rejects an unknown option" do
      code, _, err = run(["doctor", "--bogus"])
      code.should eq(1)
      err.should contain("unknown option '--bogus'")
    end

    it "errors when no repository root can be found" do
      with_fixture_repo do |dir|
        code, _, err = in_dir(dir) { run(["doctor"]) }
        code.should eq(1)
        err.should contain("no repository root found")
      end
    end

    it "warns to pass --allow-outside-repo when conventions_dir escapes repo_root" do
      with_outside_fixture_repo do |dir|
        run(["generate", "--repo-root", dir, "--allow-outside-repo"])
        _, out, _ = run(["doctor", "--repo-root", dir])
        out.should contain("cannot evaluate freshness")
        out.should contain("--allow-outside-repo")
      end
    end

    it "evaluates index freshness against an escaping conventions_dir given --allow-outside-repo" do
      with_outside_fixture_repo do |dir|
        run(["generate", "--repo-root", dir, "--allow-outside-repo"])
        _, out, _ = run(["doctor", "--repo-root", dir, "--allow-outside-repo"])
        out.should contain("index: fresh")
      end
    end
  end
end
