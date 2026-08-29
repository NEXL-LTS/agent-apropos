require "../spec_helper"

private ROOT = Path["/repo"]

private def run_lint(fs : AgentApropos::Filesystem, strict : Bool = false,
                     tracked : Array(String)? = nil) : {Int32, String}
  code, stdout, _ = run_lint_full(fs, strict, tracked)
  {code, stdout}
end

private def run_lint_full(fs : AgentApropos::Filesystem, strict : Bool = false,
                          tracked : Array(String)? = nil,
                          git : AgentApropos::Git? = nil) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Lint.run(ROOT, fs, git || FakeGit.new(tracked: tracked), strict, stdout, stderr)
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

  it "errors when a removal-triggered doc has no paths and no contents" do
    fs = InMemoryFS.new({doc("r.md") => "---\non: [removed]\n---\n# R\n\nb\n"})
    code, stdout = run_lint(fs)
    code.should eq(1)
    stdout.should contain("declares `on:` events with no `paths` or `contents` to match")
  end

  it "errors when on: is an empty list" do
    fs = InMemoryFS.new({doc("e.md") => "---\non: []\npaths: [\"src/**\"]\n---\n# E\n\nb\n"})
    code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
    code.should eq(1)
    stdout.should contain("`on:` declares no events, so this doc can never fire")
  end

  it "accepts a removal-triggered doc that has a paths glob" do
    fs = InMemoryFS.new({doc("r.md") => "---\non: [removed]\npaths: [\"src/**\"]\n---\n# R\n\nb\n"})
    code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
    code.should eq(0)
    stdout.should contain("lint: clean")
  end

  it "does not warn about on: as an unknown frontmatter key" do
    fs = InMemoryFS.new({doc("r.md") => "---\non: [removed]\npaths: [\"src/**\"]\n---\n# R\n\nb\n"})
    code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
    code.should eq(0)
    stdout.should_not contain("unknown frontmatter keys")
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

  it "does not warn at exactly the skill doc line budget" do
    body = String.build { |io| 500.times { io << "line\n" } }
    text = "---\nskill: true\ndescription: \"Use when big\"\n---\n#{body}"
    wrappers, _ = wrapper_for("big.md", text)
    fs = InMemoryFS.new(WIRED_ALL.merge(wrappers).merge({doc("big.md") => text}))
    _, stdout = run_lint(fs)
    stdout.should_not contain("skill doc is over")
  end

  it "warns at exactly one line over the skill doc budget, naming the exact budget" do
    body = String.build { |io| 501.times { io << "line\n" } }
    text = "---\nskill: true\ndescription: \"Use when big\"\n---\n#{body}"
    wrappers, _ = wrapper_for("big.md", text)
    fs = InMemoryFS.new(WIRED_ALL.merge(wrappers).merge({doc("big.md") => text}))
    _, stdout = run_lint(fs)
    stdout.should contain("skill doc is over 500 lines")
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

  it "does not warn at exactly the root file line budget" do
    fs = InMemoryFS.new({"/repo/AGENTS.md" => String.build { |io| 150.times { io << "x\n" } }})
    _, stdout = run_lint(fs)
    stdout.should_not contain("root file is")
  end

  it "warns at exactly one line over the root file budget, naming the exact budget" do
    fs = InMemoryFS.new({"/repo/AGENTS.md" => String.build { |io| 151.times { io << "x\n" } }})
    _, stdout = run_lint(fs)
    stdout.should contain("root file is 151 lines (budget 150)")
  end

  it "defaults allow_outside to false, refusing to walk an escaping conventions_dir" do
    fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../outside\n"})
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    code = AgentApropos::Lint.run(ROOT, fs, FakeGit.new, false, stdout, stderr)
    code.should eq(1)
    stderr.to_s.should contain("resolves outside the repo root")
  end

  it "sorts findings across categories by location, not by insertion order" do
    fs = InMemoryFS.new({
      doc("z.md")       => "---\nskill: true\n---\n# Z\n\nbody\n",
      "/repo/AGENTS.md" => String.build { |io| 151.times { io << "x\n" } },
    })
    _, stdout = run_lint(fs)
    agents_index = stdout.index("AGENTS.md: root file").as(Int32)
    z_index = stdout.index("docs/conventions/z.md").as(Int32)
    agents_index.should be < z_index
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

  describe "dead path globs" do
    it "errors when a path glob matches no tracked file" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.rb\"]\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain(%(error  docs/conventions/d.md: path glob matches no tracked file: "src/**/*.rb"))
    end

    it "accepts a glob that matches a tracked file" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.cr\"]\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "matches dotfile paths the hook would fire on, unlike Dir.glob" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"**/*.yml\"]\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: [".github/workflows/ci.yml"])
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "fails loudly instead of reporting clean when git blows up listing tracked files" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.rb\"]\n---\n# D\n\nb\n"})
      code, stdout, stderr = run_lint_full(fs, git: FakeGit.new(ls_files_raises: true))
      code.should eq(1)
      stdout.should_not contain("lint: clean")
      stderr.should contain("agent-apropos lint: ls-files boom")
    end

    it "skips the check entirely when the repo is not a git checkout" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.rb\"]\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: nil)
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "reports an invalid glob once rather than also calling it dead" do
      fs = InMemoryFS.new({doc("g.md") => "---\npaths: [\"src/[\"]\n---\n# G\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain("invalid path glob")
      stdout.should_not contain("matches no tracked file")
      stdout.should contain("lint: 1 error(s), 0 warning(s)")
    end

    it "still flags a dead glob on a removal-scoped doc" do
      fs = InMemoryFS.new({doc("d.md") => "---\non: [removed]\npaths: [\"src/**/*.rb\"]\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain(%(error  docs/conventions/d.md: path glob matches no tracked file: "src/**/*.rb"))
    end
  end

  describe "lint: ignore" do
    it "suppresses a dead path glob" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.rb\"]\nlint: ignore\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "suppresses both the inert on: findings" do
      fs = InMemoryFS.new({
        doc("r.md") => "---\non: [removed]\nlint: ignore\n---\n# R\n\nb\n",
        doc("e.md") => "---\non: []\nlint: ignore\n---\n# E\n\nb\n",
      })
      code, stdout = run_lint(fs)
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "suppresses every finding the doc's frontmatter could raise" do
      fs = InMemoryFS.new({
        doc("s.md") => "---\nskill: true\npaths: [\"src/[\"]\nlint: ignore\n---\n# S\n\nb\n",
      })
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "does not suppress invalid YAML, which stops the key from being read at all" do
      fs = InMemoryFS.new({doc("bad.md") => "---\nlint: ignore\npaths: [\n---\nbody\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain("invalid YAML frontmatter")
    end

    it "does not suppress an unterminated frontmatter fence" do
      fs = InMemoryFS.new({doc("bad.md") => "---\nlint: ignore\npaths: [\"src/**\"]\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain("unterminated frontmatter block")
    end

    it "does not suppress a wrong-typed key" do
      fs = InMemoryFS.new({doc("bad.md") => "---\nlint: ignore\npaths: \"src/**\"\n---\n# B\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain("`paths` must be a list of strings")
    end

    it "does not suppress a wrong-typed lint key itself" do
      fs = InMemoryFS.new({doc("bad.md") => "---\nlint: true\n---\n# B\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain("`lint` must be a string")
    end

    it "does not make an ignored skill doc's existing wrapper look orphaned" do
      text = "---\nskill: true\ndescription: \"Use when w\"\nlint: ignore\n---\n# W\n\nb\n"
      wrappers, _ = wrapper_for("workflows/w.md", text)
      fs = InMemoryFS.new(WIRED_ALL.merge(wrappers).merge({doc("workflows/w.md") => text}))
      code, stdout = run_lint(fs, tracked: ["docs/conventions/workflows/w.md"])
      code.should eq(0)
      stdout.should contain("lint: clean")
    end

    it "errors on an unrecognized value instead of suppressing" do
      fs = InMemoryFS.new({doc("d.md") => "---\npaths: [\"src/**/*.rb\"]\nlint: strict\n---\n# D\n\nb\n"})
      code, stdout = run_lint(fs, tracked: ["src/agent_apropos/lint.cr"])
      code.should eq(1)
      stdout.should contain(%(unrecognized `lint` value: "strict"))
      stdout.should contain("path glob matches no tracked file")
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
