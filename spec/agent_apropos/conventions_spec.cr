require "../spec_helper"
require "digest/sha256"
require "file_utils"

# In-memory filesystem so walk() is exercised without touching disk in the
# unit path; Filesystem::Real is covered by the temp-dir example below.
private class FakeFS < AgentApropos::Filesystem
  def initialize(@files : Hash(String, String))
  end

  def glob(base : Path, pattern : String) : Array(String)
    @files.keys
  end

  def read(path : String) : String
    @files[SpecPaths.key(path)]
  end

  def read?(path : String) : String?
    @files[SpecPaths.key(path)]?
  end

  def write(path : String, content : String) : Nil
    @files[SpecPaths.key(path)] = content
  end

  def remove(path : String) : Nil
    @files.delete(path)
  end

  def exists?(path : String) : Bool
    @files.has_key?(path)
  end

  def symlink(target : String, link_path : String) : Nil
  end
end

private def convention(frontmatter : String) : AgentApropos::Convention
  AgentApropos::Convention.parse("docs/conventions/rule.md", "---\n#{frontmatter}\n---\nbody\n")
end

describe AgentApropos::Convention do
  describe ".parse" do
    it "hashes the whole doc text" do
      text = "---\npaths: [\"src/**\"]\n---\nbody\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", text).hash
        .should eq(Digest::SHA256.hexdigest(text))
    end

    it "keeps a doc with no frontmatter as reference-only with the full body" do
      conv = AgentApropos::Convention.parse("docs/conventions/a.md", "# Just prose\n")
      conv.reference_only?.should be_true
      conv.body.should eq("# Just prose\n")
    end

    it "hashes a CRLF doc the same as its LF-equivalent bytes" do
      lf = "---\npaths: [\"src/**\"]\n---\nbody\n"
      crlf = "---\r\npaths: [\"src/**\"]\r\n---\r\nbody\r\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", crlf).hash
        .should eq(AgentApropos::Convention.parse("docs/conventions/a.md", lf).hash)
    end

    it "parses the same frontmatter fields from a CRLF doc as from its LF equivalent" do
      crlf = "---\r\npaths: [\"src/**\"]\r\ncontents: ['\\bTODO\\b']\r\n" \
             "skill: true\r\ndescription: \"Use when x\"\r\n---\r\nbody\r\n"
      frontmatter = AgentApropos::Convention.parse("docs/conventions/a.md", crlf).frontmatter
      frontmatter.paths.should eq(["src/**"])
      frontmatter.contents.should eq(["\\bTODO\\b"])
      frontmatter.skill?.should be_true
      frontmatter.description.should eq("Use when x")
    end

    it "normalizes a CRLF body to LF" do
      crlf = "---\r\npaths: [\"src/**\"]\r\n---\r\nline one\r\nline two\r\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", crlf).body
        .should eq("line one\nline two\n")
    end

    it "normalizes a lone CR to LF so a classic-Mac checkout still parses" do
      cr = "---\rpaths: [\"src/**\"]\r---\rline one\rline two\r"
      conv = AgentApropos::Convention.parse("docs/conventions/a.md", cr)
      conv.frontmatter.paths.should eq(["src/**"])
      conv.body.should eq("line one\nline two\n")
    end

    it "normalizes a doc mixing CRLF and LF sections to all-LF" do
      mixed = "---\r\npaths: [\"src/**\"]\n---\r\nline one\nline two\r\n"
      lf = "---\npaths: [\"src/**\"]\n---\nline one\nline two\n"
      conv = AgentApropos::Convention.parse("docs/conventions/a.md", mixed)
      conv.body.should eq("line one\nline two\n")
      conv.hash.should eq(AgentApropos::Convention.parse("docs/conventions/a.md", lf).hash)
    end
  end

  describe "trigger classification" do
    it "classifies a paths-only doc as scoped" do
      conv = convention(%(paths: ["src/**"]))
      conv.scoped?.should be_true
      conv.reference_only?.should be_false
    end

    it "classifies a contents-only doc as scoped" do
      convention(%(contents: ['\\bTODO\\b'])).scoped?.should be_true
    end

    it "classifies a paths+contents doc as scoped" do
      convention(%(paths: ["app/**"]\ncontents: ['\\bx\\b'])).scoped?.should be_true
    end

    it "treats skill as independent of triggers" do
      conv = convention(%(skill: true\ndescription: "Use when X"))
      conv.skill?.should be_true
      conv.reference_only?.should be_false
      conv.scoped?.should be_false
    end
  end

  describe "#verify" do
    it "harvests the section under a `## Verify` heading up to the next heading" do
      text = "---\npaths: [\"src/**\"]\n---\n# Rule\n\nBody.\n\n## Verify\n\n- one\n- two\n\n## Notes\n\nignored\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", text).verify.should eq("- one\n- two")
    end

    it "harvests to end of doc when no heading follows" do
      text = "---\npaths: [\"src/**\"]\n---\nBody.\n\n## Verify\n\nCheck it works.\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", text).verify.should eq("Check it works.")
    end

    it "is nil when there is no Verify heading" do
      convention(%(paths: ["src/**"])).verify.should be_nil
    end

    it "is nil when the Verify section is empty" do
      text = "---\npaths: [\"src/**\"]\n---\nBody.\n\n## Verify\n\n## Next\n\nx\n"
      AgentApropos::Convention.parse("docs/conventions/a.md", text).verify.should be_nil
    end
  end

  describe "#triggers?" do
    it "fires on a path match alone, whatever the content is" do
      conv = convention(%(paths: ["app/jobs/**"]))
      conv.triggers?("app/jobs/m.cr", nil).should be_true
      conv.triggers?("app/jobs/m.cr", "anything").should be_true
    end

    it "does not fire when the glob misses" do
      convention(%(paths: ["app/jobs/**"])).triggers?("src/x.cr", "anything").should be_false
    end

    it "fires repo-wide when contents match and no paths are declared" do
      conv = convention(%(contents: ['\\btransaction\\b']))
      conv.triggers?("anywhere.cr", "db.transaction").should be_true
      conv.triggers?("anywhere.cr", "no match").should be_false
    end

    it "does not fire a content rule when the content is unavailable (fail open to silence)" do
      convention(%(contents: ['\\btransaction\\b'])).triggers?("anywhere.cr", nil).should be_false
    end

    it "requires both content and path to match (AND) when both are declared" do
      conv = convention(%(paths: ["app/**"]\ncontents: ['\\bupdate_all\\b']))
      conv.triggers?("app/models/u.cr", "User.update_all").should be_true
      conv.triggers?("scripts/one_off.cr", "User.update_all").should be_false
      conv.triggers?("app/models/u.cr", "User.save").should be_false
      conv.triggers?("app/models/u.cr", nil).should be_false
    end

    it "never fires for a doc that declares no triggers" do
      convention(%(skill: true\ndescription: "Use when X")).triggers?("any.cr", "any").should be_false
    end
  end

  describe "#triggers" do
    it "returns the matched path globs then the matched content regexes" do
      convention(%(paths: ["app/**", "lib/**"]\ncontents: ['\\bx\\b', '\\by\\b']))
        .triggers("app/m.cr", "x here").should eq(["app/**", "\\bx\\b"])
    end

    it "is nil when nothing matches" do
      convention(%(paths: ["app/**"])).triggers("src/x.cr", nil).should be_nil
    end
  end
end

describe AgentApropos::Conventions do
  describe ".walk" do
    it "walks docs sorted, with repo-relative POSIX paths (in-memory)" do
      root = Path["/repo"]
      fs = FakeFS.new({
        "/repo/docs/conventions/workflows/b.md" => "---\nskill: true\ndescription: \"Use when B\"\n---\nB\n",
        "/repo/docs/conventions/a.md"           => "---\npaths: [\"src/**\"]\n---\nA\n",
      })
      conventions = AgentApropos::Conventions.walk(root, fs)
      conventions.map(&.path).should eq([
        "docs/conventions/a.md",
        "docs/conventions/workflows/b.md",
      ])
      conventions.first.scoped?.should be_true
    end

    it "reads real files through the default adapter" do
      dir = File.tempname("agent-apropos-conv")
      begin
        Dir.mkdir_p(File.join(dir, "docs/conventions/workflows"))
        File.write(File.join(dir, "docs/conventions/a.md"), "---\npaths: [\"src/**\"]\n---\nA\n")
        File.write(File.join(dir, "docs/conventions/workflows/b.md"), "no frontmatter\n")
        File.write(File.join(dir, "docs/conventions/note.txt"), "ignored\n")

        conventions = AgentApropos::Conventions.walk(Path[dir])
        conventions.map(&.path).should eq([
          "docs/conventions/a.md",
          "docs/conventions/workflows/b.md",
        ])
        conventions[0].scoped?.should be_true
        conventions[1].reference_only?.should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "raises on a malformed doc by default" do
      root = Path["/repo"]
      fs = FakeFS.new({"/repo/docs/conventions/bad.md" => "---\npaths: not-a-list\n---\nBad\n"})
      expect_raises(AgentApropos::Frontmatter::Error) do
        AgentApropos::Conventions.walk(root, fs)
      end
    end

    it "skips a malformed doc and keeps the rest when tolerant" do
      root = Path["/repo"]
      fs = FakeFS.new({
        "/repo/docs/conventions/a.md"   => "---\npaths: [\"src/**\"]\n---\nA\n",
        "/repo/docs/conventions/bad.md" => "---\npaths: not-a-list\n---\nBad\n",
      })
      conventions = AgentApropos::Conventions.walk(root, fs, tolerant: true)
      conventions.map(&.path).should eq(["docs/conventions/a.md"])
    end
  end
end
