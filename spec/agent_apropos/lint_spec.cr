require "../spec_helper"

private ROOT = Path["/repo"]

private def run_lint(fs : AgentApropos::Filesystem, strict : Bool = false) : {Int32, String}
  code, stdout, _ = run_lint_full(fs, strict)
  {code, stdout}
end

private def run_lint_full(fs : AgentApropos::Filesystem, strict : Bool = false) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Lint.run(ROOT, fs, strict, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

private def doc(name : String) : String
  "/repo/docs/conventions/#{name}"
end

# Marks every skill root's consumer agent as initialized (see
# `Skills.active_roots`), so a wrapper-drift test exercises the drift check
# itself rather than the root-gating in front of it.
private WIRED_ALL = {
  "/repo/.claude/settings.json" => "{}",
  "/repo/.gemini/settings.json" => "{}",
  "/repo/.codex/hooks.json"     => "{}",
}

# The correct on-disk wrappers for a skill doc across every generated root
# (`.claude/skills`, `.gemini/skills`, `.codex/skills`), so drift tests can
# install a byte-accurate baseline via the real generator.
private def wrapper_for(name : String, text : String) : {Hash(String, String), String}
  convention = AgentApropos::Convention.parse("docs/conventions/#{name}", text)
  slug, content = AgentApropos::Skills.wrappers([convention]).first
  paths = AgentApropos::Skills::ROOTS.each_with_object({} of String => String) do |root, hash|
    hash[ROOT.join(root, slug, "SKILL.md").to_s] = content
  end
  {paths, content}
end

describe AgentApropos::Lint do
  it "reports a clean structure and exits 0" do
    fs = InMemoryFS.new({doc("ok.md") => "---\npaths: [\"src/**\"]\n---\n# Rule\n\nBody.\n"})
    code, stdout = run_lint(fs)
    code.should eq(0)
    stdout.should contain("lint: clean")
  end

  it "turns a malformed frontmatter doc into an error finding, not a crash" do
    fs = InMemoryFS.new({doc("bad.md") => "---\npaths: [\n---\nbody\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("error  docs/conventions/bad.md:")
  end

  it "fails closed on a malformed agent-apropos.yml rather than defaulting silently" do
    fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "key: [unterminated\n"})
    code, _, stderr = run_lint_full(fs)
    code.should eq(1)
    stderr.should contain("agent-apropos lint:")
    stderr.should contain("not valid YAML")
  end

  it "warns on unknown frontmatter keys" do
    fs = InMemoryFS.new({doc("x.md") => "---\npaths: [\"src/**\"]\nfoo: 1\n---\n# R\n\nb\n"})
    code, stdout = run_lint(fs)
    code.should eq(0)
    stdout.should contain("warn   docs/conventions/x.md: unknown frontmatter keys: foo")
  end

  it "errors when skill: true has no description" do
    fs = InMemoryFS.new({doc("s.md") => "---\nskill: true\n---\n# S\n\nbody\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("`skill: true` requires a `description`")
  end

  it "errors when a description does not start with \"Use when\"" do
    fs = InMemoryFS.new({doc("s.md") => "---\nskill: true\ndescription: \"Do the thing\"\n---\n# S\n\nb\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain(%(`description` must start with "Use when"))
  end

  it "errors on an invalid path glob" do
    fs = InMemoryFS.new({doc("g.md") => "---\npaths: [\"src/[\"]\n---\n# G\n\nb\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("invalid path glob")
  end

  it "errors on an uncompilable content regex" do
    fs = InMemoryFS.new({doc("r.md") => "---\ncontents: ['(']\n---\n# R\n\nb\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("invalid regex")
  end

  it "errors when a triggered doc has an empty body" do
    fs = InMemoryFS.new({doc("e.md") => "---\npaths: [\"src/**\"]\n---\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("declares triggers but has an empty body")
  end

  it "warns on a skill doc over the line budget" do
    body = String.build { |io| (AgentApropos::Lint::SKILL_DOC_MAX + 1).times { io << "line\n" } }
    text = "---\nskill: true\ndescription: \"Use when big\"\n---\n#{body}"
    wrappers, _ = wrapper_for("big.md", text)
    fs = InMemoryFS.new(WIRED_ALL.merge(wrappers).merge({doc("big.md") => text}))
    code, stdout = run_lint(fs)
    code.should eq(0)
    stdout.should contain("skill doc is over")
  end

  it "warns when a root file exceeds its line budget but not when it is short" do
    big = String.build { |io| (AgentApropos::Lint::ROOT_FILE_MAX + 1).times { io << "x\n" } }
    fs = InMemoryFS.new({
      "/repo/AGENTS.md" => big,
      "/repo/CLAUDE.md" => "short\n",
    })
    code, stdout = run_lint(fs)
    code.should eq(0)
    stdout.should contain("warn   AGENTS.md: root file is")
    stdout.should_not contain("CLAUDE.md: root file")
  end

  describe "generated wrappers" do
    it "errors on a missing wrapper" do
      fs = InMemoryFS.new(WIRED_ALL.merge({doc("workflows/w.md") => "---\nskill: true\ndescription: \"Use when w\"\n---\n# W\n\nb\n"}))
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain("missing generated wrapper")
    end

    it "errors on a stale wrapper" do
      text = "---\nskill: true\ndescription: \"Use when w\"\n---\n# W\n\nb\n"
      wrappers, _ = wrapper_for("workflows/w.md", text)
      seed = WIRED_ALL.merge(wrappers).merge({doc("workflows/w.md") => text})
      seed[wrappers.keys.first] = "hand edited\n"
      fs = InMemoryFS.new(seed)
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain("stale generated wrapper")
    end

    it "accepts an up-to-date wrapper" do
      text = "---\nskill: true\ndescription: \"Use when w\"\n---\n# W\n\nb\n"
      wrappers, _ = wrapper_for("workflows/w.md", text)
      fs = InMemoryFS.new(WIRED_ALL.merge(wrappers).merge({doc("workflows/w.md") => text}))
      code, stdout = run_lint(fs)
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "errors on an orphaned wrapper in the gemini skills root too" do
      fs = InMemoryFS.new({"/repo/.gemini/skills/ghost/SKILL.md" => "orphan\n"})
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain(".gemini/skills/ghost/SKILL.md: orphaned generated wrapper")
    end

    it "errors on an orphaned wrapper in the codex skills root too" do
      fs = InMemoryFS.new({"/repo/.codex/skills/ghost/SKILL.md" => "orphan\n"})
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain(".codex/skills/ghost/SKILL.md: orphaned generated wrapper")
    end

    it "errors on an orphaned wrapper with no source doc" do
      fs = InMemoryFS.new({"/repo/.claude/skills/ghost/SKILL.md" => "orphan\n"})
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain(".claude/skills/ghost/SKILL.md: orphaned generated wrapper")
    end

    it "does not require a wrapper in a root whose consumer agent is not wired" do
      fs = InMemoryFS.new(
        {"/repo/.claude/settings.json" => "{}"}.merge(
          {doc("workflows/w.md") => "---\nskill: true\ndescription: \"Use when w\"\n---\n# W\n\nb\n"}
        )
      )
      code, stdout = run_lint(fs)
      code.should eq(1) # still missing .claude/skills/w/SKILL.md — only gemini/codex are exempt
      stdout.should contain("missing generated wrapper (run `agent-apropos generate`)")
      stdout.should_not contain(".gemini/skills")
      stdout.should_not contain(".codex/skills")
    end

    it "reports a slug collision as a single error and skips drift" do
      body = "skill: true\ndescription: \"Use when dup\"\n---\n# D\n\nb\n"
      fs = InMemoryFS.new({
        doc("a/dup.md") => "---\n#{body}",
        doc("b/dup.md") => "---\n#{body}",
      })
      code, stdout = run_lint(fs)
      code.should eq(1)
      stdout.should contain("slug collision")
    end
  end

  describe "--strict" do
    it "promotes warnings to a failing exit code" do
      fs = InMemoryFS.new({doc("x.md") => "---\npaths: [\"src/**\"]\nfoo: 1\n---\n# R\n\nb\n"})
      lenient, _ = run_lint(fs, strict: false)
      lenient.should eq(0)
      strict, stdout = run_lint(fs, strict: true)
      strict.should eq(1)
      stdout.should contain("lint: 0 error(s), 1 warning(s)")
    end
  end
end
