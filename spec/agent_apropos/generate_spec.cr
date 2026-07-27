require "../spec_helper"

private ROOT       = Path["/repo"]
private INDEX_PATH = "/repo/.cache/agent-apropos/index.json"

private def skill_doc(name : String, description : String = "Use when #{name}") : {String, String}
  {"/repo/docs/conventions/workflows/#{name}.md",
   "---\nskill: true\ndescription: \"#{description}\"\n---\nbody\n"}
end

private def run_generate(files : Hash(String, String)) : {Int32, String, String, InMemoryFS}
  fs = InMemoryFS.new(files)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Generate.run(ROOT, fs, stdout, stderr)
  {code, stdout.to_s, stderr.to_s, fs}
end

private def check_generate(files : Hash(String, String)) : {Int32, String, String}
  fs = InMemoryFS.new(files)
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Generate.check(ROOT, fs, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

describe AgentApropos::Generate do
  describe ".run" do
    it "writes the index and the skill wrapper, reporting each" do
      path, doc = skill_doc("foo")
      code, stdout, stderr, fs = run_generate({
        "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n",
        path                          => doc,
      })

      code.should eq(0)
      stderr.should be_empty
      stdout.should contain("index: rebuilt (2 docs)")
      stdout.should contain("skill: wrote .claude/skills/foo/SKILL.md")
      stdout.should contain("skill: wrote .gemini/skills/foo/SKILL.md")
      stdout.should contain("skill: wrote .codex/skills/foo/SKILL.md")

      fs.files[INDEX_PATH].should contain("\"schema_version\": 1")
      expected = AgentApropos::Skills.wrappers([AgentApropos::Convention.parse("docs/conventions/workflows/foo.md", doc)])["foo"]
      fs.files["/repo/.claude/skills/foo/SKILL.md"].should eq(expected)
      fs.files["/repo/.gemini/skills/foo/SKILL.md"].should eq(expected)
      fs.files["/repo/.codex/skills/foo/SKILL.md"].should eq(expected)
    end

    it "leaves a fresh index untouched but still ensures wrappers" do
      path, doc = skill_doc("foo")
      files = {path => doc}
      first = run_generate(files)[3]

      # Re-run against the state the first run produced: index is fresh, wrapper
      # already matches, so nothing is rewritten and nothing is reported.
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      code = AgentApropos::Generate.run(ROOT, first, stdout, stderr)

      code.should eq(0)
      stdout.to_s.should be_empty
      stderr.to_s.should be_empty
    end

    it "rebuilds a stale index when a doc changed" do
      path, doc = skill_doc("foo")
      fs = run_generate({path => doc})[3]

      # Edit the doc; the recorded hash no longer matches.
      fs.files[path] = doc.sub("body", "changed body")
      stdout = IO::Memory.new
      AgentApropos::Generate.run(ROOT, fs, stdout, IO::Memory.new)
      stdout.to_s.should contain("index: rebuilt")
    end

    it "prunes an orphaned wrapper whose source doc is gone, in every skill root" do
      path, doc = skill_doc("keep")
      code, stdout, _, fs = run_generate({
        path                                 => doc,
        "/repo/.claude/skills/gone/SKILL.md" => "stale wrapper\n",
        "/repo/.gemini/skills/gone/SKILL.md" => "stale wrapper\n",
        "/repo/.codex/skills/gone/SKILL.md"  => "stale wrapper\n",
      })

      code.should eq(0)
      stdout.should contain("skill: removed orphan .claude/skills/gone/SKILL.md")
      stdout.should contain("skill: removed orphan .gemini/skills/gone/SKILL.md")
      stdout.should contain("skill: removed orphan .codex/skills/gone/SKILL.md")
      fs.removed.should contain("/repo/.claude/skills/gone")
      fs.removed.should contain("/repo/.gemini/skills/gone")
      fs.removed.should contain("/repo/.codex/skills/gone")
      fs.files.has_key?("/repo/.claude/skills/gone/SKILL.md").should be_false
      fs.files.has_key?("/repo/.gemini/skills/gone/SKILL.md").should be_false
      fs.files.has_key?("/repo/.codex/skills/gone/SKILL.md").should be_false
    end

    it "fails closed on a slug collision" do
      a_path, a = skill_doc("dup", "Use when A")
      code, _, stderr, _ = run_generate({
        a_path                                => a,
        "/repo/docs/conventions/other/dup.md" => "---\nskill: true\ndescription: \"Use when B\"\n---\nb\n",
      })

      code.should eq(1)
      stderr.should contain("slug collision on 'dup'")
    end
  end

  describe ".check" do
    it "exits 0 when wrappers are up to date" do
      path, doc = skill_doc("foo")
      fs = run_generate({path => doc})[3]

      code, stdout, stderr = check_generate(fs.files)
      code.should eq(0)
      stdout.should contain("up to date (1 skill wrappers)")
      stderr.should be_empty
    end

    it "reports a missing wrapper and exits 1" do
      path, doc = skill_doc("foo")
      code, stdout, _ = check_generate({path => doc})
      code.should eq(1)
      stdout.should contain("drift detected")
      stdout.should contain("missing: .claude/skills/foo/SKILL.md")
      stdout.should contain("missing: .gemini/skills/foo/SKILL.md")
      stdout.should contain("missing: .codex/skills/foo/SKILL.md")
    end

    it "reports a hand-edited (stale) wrapper and exits 1" do
      path, doc = skill_doc("foo")
      files = run_generate({path => doc})[3].files
      files["/repo/.claude/skills/foo/SKILL.md"] = "hand edited\n"

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("stale:")
    end

    it "reports an orphaned wrapper and exits 1" do
      path, doc = skill_doc("keep")
      files = run_generate({path => doc})[3].files
      files["/repo/.claude/skills/gone/SKILL.md"] = "orphan\n"

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("orphan:  .claude/skills/gone/SKILL.md")
    end

    it "fails closed on a malformed convention doc" do
      code, _, stderr = check_generate({
        "/repo/docs/conventions/bad.md" => "---\npaths: [unclosed\n---\nbody\n",
      })
      code.should eq(1)
      stderr.should contain("agent-apropos generate:")
    end
  end
end
