require "../spec_helper"

private ROOT       = Path["/repo"]
private INDEX_PATH = "/repo/.cache/agent-apropos/index.json"

private CLAUDE_SETTINGS = "/repo/.claude/settings.json"
private GEMINI_SETTINGS = "/repo/.gemini/settings.json"
private CODEX_HOOKS     = "/repo/.codex/hooks.json"

# All three skill roots' consumers are "wired" (the init file each of
# `Skills.active_roots`'s consumer agents probes for exists), matching most
# specs' intent to exercise wrapper writing/checking itself rather than the
# gating in front of it. Content is irrelevant — `configured?` is a bare
# existence probe.
private WIRED_ALL = {
  CLAUDE_SETTINGS => "{}",
  GEMINI_SETTINGS => "{}",
  CODEX_HOOKS     => "{}",
}

private def skill_doc(name : String, description : String = "Use when #{name}") : {String, String}
  {"/repo/docs/conventions/workflows/#{name}.md",
   "---\nskill: true\ndescription: \"#{description}\"\n---\nbody\n"}
end

private def removal_doc : {String, String}
  {"/repo/docs/conventions/a.md", "---\non: [removed]\npaths: [\"src/**\"]\n---\nA\n"}
end

private def run_generate(files : Hash(String, String), wired : Hash(String, String) = WIRED_ALL) : {Int32, String, String, InMemoryFS}
  fs = InMemoryFS.new(wired.merge(files))
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Generate.run(ROOT, fs, stdout, stderr)
  {code, stdout.to_s, stderr.to_s, fs}
end

private def check_generate(files : Hash(String, String), wired : Hash(String, String) = WIRED_ALL) : {Int32, String, String}
  fs = InMemoryFS.new(wired.merge(files))
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

      fs.files[INDEX_PATH].should contain("\"schema_version\": 3")
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

    it "prunes every orphaned wrapper in a root, not just the first" do
      path, doc = skill_doc("keep")
      code, stdout, _, fs = run_generate({
        path                                       => doc,
        "/repo/.claude/skills/aaa_orphan/SKILL.md" => "stale wrapper\n",
        "/repo/.claude/skills/bbb_orphan/SKILL.md" => "stale wrapper\n",
      })

      code.should eq(0)
      stdout.should contain("skill: removed orphan .claude/skills/aaa_orphan/SKILL.md")
      stdout.should contain("skill: removed orphan .claude/skills/bbb_orphan/SKILL.md")
      fs.files.has_key?("/repo/.claude/skills/aaa_orphan/SKILL.md").should be_false
      fs.files.has_key?("/repo/.claude/skills/bbb_orphan/SKILL.md").should be_false
    end

    it "writes every missing slug's wrapper in a root, not just the first" do
      a_path, a_doc = skill_doc("aaa")
      b_path, b_doc = skill_doc("bbb")
      code, stdout, _, fs = run_generate({a_path => a_doc, b_path => b_doc})

      code.should eq(0)
      stdout.should contain("skill: wrote .claude/skills/aaa/SKILL.md")
      stdout.should contain("skill: wrote .claude/skills/bbb/SKILL.md")
      fs.files.has_key?("/repo/.claude/skills/bbb/SKILL.md").should be_true
    end

    it "defaults allow_outside to false, refusing to walk an escaping conventions_dir" do
      code, _, stderr, _ = run_generate({"/repo/agent-apropos.yml" => "conventions_dir: ../outside\n"})
      code.should eq(1)
      stderr.should contain("resolves outside the repo root")
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

    describe "root gating" do
      it "writes only the root whose consumer agent is initialized" do
        path, doc = skill_doc("foo")
        code, stdout, _, fs = run_generate({path => doc}, {CLAUDE_SETTINGS => "{}"})

        code.should eq(0)
        stdout.should contain("skill: wrote .claude/skills/foo/SKILL.md")
        stdout.should_not contain(".gemini/skills")
        stdout.should_not contain(".codex/skills")
        fs.files.has_key?("/repo/.gemini/skills/foo/SKILL.md").should be_false
        fs.files.has_key?("/repo/.codex/skills/foo/SKILL.md").should be_false
      end

      it "activates .claude/skills for OpenCode alone, without Claude Code itself wired" do
        path, doc = skill_doc("foo")
        code, stdout, _, fs = run_generate({path => doc}, {"/repo/.opencode/plugins/agent-apropos.js" => "// js"})

        code.should eq(0)
        stdout.should contain("skill: wrote .claude/skills/foo/SKILL.md")
        fs.files.has_key?("/repo/.claude/skills/foo/SKILL.md").should be_true
      end

      it "activates .claude/skills for Copilot alone" do
        path, doc = skill_doc("foo")
        code, _, _, fs = run_generate({path => doc}, {"/repo/.github/hooks/agent-apropos.json" => "{}"})

        code.should eq(0)
        fs.files.has_key?("/repo/.claude/skills/foo/SKILL.md").should be_true
      end

      it "writes no wrappers at all when no agent is initialized" do
        path, doc = skill_doc("foo")
        code, stdout, _, fs = run_generate({path => doc}, {} of String => String)

        code.should eq(0)
        stdout.should_not contain("skill: wrote")
        fs.files.keys.any?(&.includes?("skills")).should be_false
      end

      it "prunes a wrapper left behind in a root whose consumer was un-wired" do
        path, doc = skill_doc("keep")
        code, stdout, _, fs = run_generate({
          path                                 => doc,
          "/repo/.gemini/skills/keep/SKILL.md" => "stale, from before gemini was un-wired\n",
        }, {CLAUDE_SETTINGS => "{}"})

        code.should eq(0)
        stdout.should contain("skill: removed orphan .gemini/skills/keep/SKILL.md")
        fs.files.has_key?("/repo/.gemini/skills/keep/SKILL.md").should be_false
      end

      it "still writes gemini's wrapper when claude's own root is inactive (no short-circuit across roots)" do
        path, doc = skill_doc("foo")
        code, stdout, _, fs = run_generate({path => doc}, {GEMINI_SETTINGS => "{}"})

        code.should eq(0)
        stdout.should contain("skill: wrote .gemini/skills/foo/SKILL.md")
        fs.files.has_key?("/repo/.gemini/skills/foo/SKILL.md").should be_true
      end
    end

    it "writes a later slug's wrapper even when an earlier slug's is already up to date (no short-circuit across slugs)" do
      a_path, a_doc = skill_doc("aaa")
      b_path, b_doc = skill_doc("bbb")
      expected_a = AgentApropos::Skills.wrappers(
        [AgentApropos::Convention.parse("docs/conventions/workflows/aaa.md", a_doc)]
      )["aaa"]
      code, stdout, _, fs = run_generate({
        a_path                              => a_doc,
        b_path                              => b_doc,
        "/repo/.claude/skills/aaa/SKILL.md" => expected_a,
      })

      code.should eq(0)
      stdout.should contain("skill: wrote .claude/skills/bbb/SKILL.md")
      fs.files.has_key?("/repo/.claude/skills/bbb/SKILL.md").should be_true
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

    it "reports every orphaned wrapper in a root, not just the first" do
      path, doc = skill_doc("keep")
      files = run_generate({path => doc})[3].files
      files["/repo/.claude/skills/aaa_orphan/SKILL.md"] = "orphan\n"
      files["/repo/.claude/skills/bbb_orphan/SKILL.md"] = "orphan\n"

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("orphan:  .claude/skills/aaa_orphan/SKILL.md")
      stdout.should contain("orphan:  .claude/skills/bbb_orphan/SKILL.md")
    end

    it "reports staleness by inequality, not lexical ordering" do
      path, doc = skill_doc("foo")
      files = run_generate({path => doc})[3].files
      files["/repo/.claude/skills/foo/SKILL.md"] = ""

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("stale:   .claude/skills/foo/SKILL.md")
    end

    it "still reports a later slug even after an earlier slug in the same root is found stale" do
      a_path, a_doc = skill_doc("aaa")
      b_path, b_doc = skill_doc("bbb")
      files = run_generate({a_path => a_doc, b_path => b_doc})[3].files
      files["/repo/.claude/skills/aaa/SKILL.md"] = "hand edited\n"
      files.delete("/repo/.claude/skills/bbb/SKILL.md")

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("stale:   .claude/skills/aaa/SKILL.md")
      stdout.should contain("missing: .claude/skills/bbb/SKILL.md")
    end

    it "still reports a later slug's drift after an earlier slug is found missing" do
      a_path, a_doc = skill_doc("aaa")
      b_path, b_doc = skill_doc("bbb")
      files = run_generate({a_path => a_doc, b_path => b_doc})[3].files
      files.delete("/repo/.claude/skills/aaa/SKILL.md")
      files["/repo/.claude/skills/bbb/SKILL.md"] = "hand edited\n"

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("missing: .claude/skills/aaa/SKILL.md")
      stdout.should contain("stale:   .claude/skills/bbb/SKILL.md")
    end

    it "still checks a later slug even when an earlier slug in the same root is already up to date" do
      a_path, a_doc = skill_doc("aaa")
      b_path, b_doc = skill_doc("bbb")
      files = run_generate({a_path => a_doc, b_path => b_doc})[3].files
      files.delete("/repo/.claude/skills/bbb/SKILL.md")

      code, stdout, _ = check_generate(files)
      code.should eq(1)
      stdout.should contain("missing: .claude/skills/bbb/SKILL.md")
    end

    it "defaults allow_outside to false, refusing to walk an escaping conventions_dir" do
      code, _, stderr = check_generate({"/repo/agent-apropos.yml" => "conventions_dir: ../outside\n"})
      code.should eq(1)
      stderr.should contain("resolves outside the repo root")
    end

    it "fails closed on a malformed convention doc" do
      code, _, stderr = check_generate({
        "/repo/docs/conventions/bad.md" => "---\npaths: [unclosed\n---\nbody\n",
      })
      code.should eq(1)
      stderr.should contain("agent-apropos generate:")
    end

    describe "root gating" do
      it "does not expect a wrapper in an uninitialized root" do
        path, doc = skill_doc("foo")
        code, stdout, _ = check_generate({
          path                                => doc,
          "/repo/.claude/skills/foo/SKILL.md" => AgentApropos::Skills.wrappers(
            [AgentApropos::Convention.parse("docs/conventions/workflows/foo.md", doc)]
          )["foo"],
        }, {CLAUDE_SETTINGS => "{}"})

        code.should eq(0)
        stdout.should contain("up to date")
      end

      it "flags a wrapper in a root whose consumer was un-wired as an orphan, not missing" do
        path, doc = skill_doc("foo")
        code, stdout, _ = check_generate({
          path                                => doc,
          "/repo/.gemini/skills/foo/SKILL.md" => "stale, from before gemini was un-wired\n",
        }, {CLAUDE_SETTINGS => "{}"})

        code.should eq(1)
        stdout.should contain("orphan:  .gemini/skills/foo/SKILL.md")
        stdout.should_not contain("missing: .gemini")
      end
    end

    describe "shell-hook drift" do
      it "covers AE8: reports up to date with no removal convention" do
        code, stdout, _ = check_generate({
          "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n",
        })
        code.should eq(0)
        stdout.should_not contain("shell removal detection")
      end

      it "reports missing when a removal convention exists but the shell hook is not wired" do
        code, stdout, _ = check_generate({
          "/repo/docs/conventions/a.md" => "---\non: [removed]\npaths: [\"src/**\"]\n---\nA\n",
        })
        code.should eq(1)
        stdout.should contain("hook:    .claude/settings.json (shell removal detection missing)")
        stdout.should contain("hook:    .codex/hooks.json (shell removal detection missing)")
      end

      it "reports orphaned when the shell hook is wired but no removal convention exists" do
        wired = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":" \
                "[{\"type\":\"command\",\"command\":\"agent-apropos hook pre --tool claude\",\"timeout\":10}]}]}}"
        code, stdout, _ = check_generate({
          "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n",
        }, WIRED_ALL.merge({CLAUDE_SETTINGS => wired}))
        code.should eq(1)
        stdout.should contain("hook:    .claude/settings.json (shell removal detection orphaned)")
      end

      it "does not report drift for an agent that isn't configured at all" do
        path, doc = removal_doc
        code, stdout, _ = check_generate({path => doc}, {CLAUDE_SETTINGS => "{}"})
        code.should eq(1)
        stdout.should contain("hook:    .claude/settings.json (shell removal detection missing)")
        stdout.should_not contain(".codex/hooks.json")
      end
    end
  end

  describe "shell-hook wiring (.run)" do
    it "covers AE8: leaves a configured agent's settings byte-identical with no removal convention" do
      path, doc = skill_doc("foo")
      files = {path => doc, "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n"}
      _, _, _, fs = run_generate(files)
      fs.files[CLAUDE_SETTINGS].should eq("{}")
      fs.files[CODEX_HOOKS].should eq("{}")
    end

    it "adds the shell-hook entry for configured agents only when a removal convention exists" do
      path, doc = removal_doc
      _, _, _, fs = run_generate({path => doc})
      claude = JSON.parse(fs.files[CLAUDE_SETTINGS])
      claude["hooks"]["PreToolUse"].as_a.any? { |group| group["matcher"] == "Bash" }.should be_true
      claude["hooks"]["PostToolUse"].as_a.any? { |group| group["matcher"] == "Bash" }.should be_true
      codex = JSON.parse(fs.files[CODEX_HOOKS])
      codex["hooks"]["PreToolUse"].as_a.any? { |group| group["matcher"] == "Bash" }.should be_true
    end

    it "reports each agent it wires by name" do
      path, doc = removal_doc
      _, stdout, _, _ = run_generate({path => doc})
      stdout.should contain("hook: wired shell removal detection for claude")
      stdout.should contain("hook: wired shell removal detection for codex")
    end

    it "wires the shell hook when only one of several conventions declares removal" do
      path, doc = removal_doc
      _, _, _, fs = run_generate({
        path                          => doc,
        "/repo/docs/conventions/b.md" => "---\npaths: [\"src/**\"]\n---\nB\n",
      })
      claude = JSON.parse(fs.files[CLAUDE_SETTINGS])
      claude["hooks"]["PreToolUse"].as_a.any? { |group| group["matcher"] == "Bash" }.should be_true
    end

    it "does not write an agent that is not configured" do
      path, doc = removal_doc
      _, _, _, fs = run_generate({path => doc}, {} of String => String)
      fs.files.has_key?(CLAUDE_SETTINGS).should be_false
      fs.files.has_key?(CODEX_HOOKS).should be_false
    end

    it "prunes the shell-hook entry again once the last removal convention is removed" do
      path, doc = removal_doc
      wired_with_hook = WIRED_ALL.dup
      _, _, _, first = run_generate({path => doc})
      wired_with_hook[CLAUDE_SETTINGS] = first.files[CLAUDE_SETTINGS]
      wired_with_hook[CODEX_HOOKS] = first.files[CODEX_HOOKS]

      _, _, _, second = run_generate({
        "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n",
      }, wired_with_hook)

      JSON.parse(second.files[CLAUDE_SETTINGS])["hooks"]?.try(&.["PreToolUse"]?)
        .try(&.as_a.any? { |group| group["matcher"] == "Bash" }).should be_falsey
      second.files[CLAUDE_SETTINGS].should eq("{}\n")
    end

    it "preserves a user-added unrelated hook in the same matcher group in both directions" do
      hand_written = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":" \
                     "[{\"type\":\"command\",\"command\":\"my-other-tool\",\"timeout\":5}]}]}}"
      path, doc = removal_doc
      _, _, _, fs = run_generate({path => doc}, WIRED_ALL.merge({CLAUDE_SETTINGS => hand_written}))
      wired = JSON.parse(fs.files[CLAUDE_SETTINGS])
      bash_group = wired["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      commands = bash_group["hooks"].as_a.map(&.[]("command").as_s)
      commands.should contain("my-other-tool")
      commands.should contain("agent-apropos hook pre --tool claude")

      # remove the removal convention: the owned command drops, the hand-written one survives
      _, _, _, second = run_generate({
        "/repo/docs/conventions/a.md" => "---\npaths: [\"src/**\"]\n---\nA\n",
      }, WIRED_ALL.merge({CLAUDE_SETTINGS => fs.files[CLAUDE_SETTINGS]}))
      after = JSON.parse(second.files[CLAUDE_SETTINGS])
      after_group = after["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      after_commands = after_group["hooks"].as_a.map(&.[]("command").as_s)
      after_commands.should eq(["my-other-tool"])
    end

    it "keeps --allow-outside-repo through both directions when the existing config carries it" do
      with_flag = "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Edit|Write\",\"hooks\":" \
                  "[{\"type\":\"command\",\"command\":\"agent-apropos hook pre --tool claude --allow-outside-repo\",\"timeout\":10}]}]}}"
      path, doc = removal_doc
      _, _, _, fs = run_generate({path => doc}, WIRED_ALL.merge({CLAUDE_SETTINGS => with_flag}))
      wired = JSON.parse(fs.files[CLAUDE_SETTINGS])
      bash_group = wired["hooks"]["PreToolUse"].as_a.find! { |group| group["matcher"] == "Bash" }
      bash_group["hooks"].as_a.first["command"].as_s
        .should eq("agent-apropos hook pre --tool claude --allow-outside-repo")
    end

    it "produces identical output when generate runs twice in a row" do
      path, doc = removal_doc
      _, _, _, first = run_generate({path => doc})
      seeded = WIRED_ALL.merge({CLAUDE_SETTINGS => first.files[CLAUDE_SETTINGS], CODEX_HOOKS => first.files[CODEX_HOOKS]})
      _, _, _, second = run_generate({path => doc}, seeded)
      second.files[CLAUDE_SETTINGS].should eq(first.files[CLAUDE_SETTINGS])
      second.files[CODEX_HOOKS].should eq(first.files[CODEX_HOOKS])
    end
  end
end
