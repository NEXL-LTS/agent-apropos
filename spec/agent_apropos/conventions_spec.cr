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
    @files[path]
  end

  def read?(path : String) : String?
    @files[path]?
  end

  def write(path : String, content : String) : Nil
    @files[path] = content
  end

  def append(path : String, content : String) : Nil
    @files[path] = "#{@files[path]?}#{content}"
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
  end

  describe "layer classification" do
    it "classifies a paths-only doc as Layer 2" do
      conv = convention(%(paths: ["src/**"]))
      conv.layer2?.should be_true
      conv.layer3?.should be_false
      conv.reference_only?.should be_false
    end

    it "classifies a contents-only doc as repo-wide Layer 3" do
      conv = convention(%(contents: ['\\bTODO\\b']))
      conv.layer2?.should be_false
      conv.layer3?.should be_true
    end

    it "classifies a paths+contents doc as Layer 3, not Layer 2" do
      conv = convention(%(paths: ["app/**"]\ncontents: ['\\bx\\b']))
      conv.layer2?.should be_false
      conv.layer3?.should be_true
    end

    it "treats skill as independent of triggers" do
      conv = convention(%(skill: true\ndescription: "Use when X"))
      conv.skill?.should be_true
      conv.reference_only?.should be_false
      conv.layer2?.should be_false
      conv.layer3?.should be_false
    end
  end

  describe "#triggers_for_path?" do
    it "fires when a Layer 2 glob matches" do
      convention(%(paths: ["app/jobs/**"])).triggers_for_path?("app/jobs/m.cr").should be_true
    end

    it "does not fire when the glob misses" do
      convention(%(paths: ["app/jobs/**"])).triggers_for_path?("src/x.cr").should be_false
    end

    it "never fires for a path-scoped Layer 3 doc (content is unknown pre-write)" do
      convention(%(paths: ["app/**"]\ncontents: ['\\bx\\b']))
        .triggers_for_path?("app/x.cr").should be_false
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

  describe "#triggers_for_content?" do
    it "does not fire for a Layer 2 doc" do
      convention(%(paths: ["src/**"])).triggers_for_content?("src/x.cr", "code").should be_false
    end

    it "fires repo-wide when contents match and no paths are declared" do
      conv = convention(%(contents: ['\\btransaction\\b']))
      conv.triggers_for_content?("anywhere.cr", "db.transaction").should be_true
      conv.triggers_for_content?("anywhere.cr", "no match").should be_false
    end

    it "requires both content and path to match (AND) when paths are declared" do
      conv = convention(%(paths: ["app/**"]\ncontents: ['\\bupdate_all\\b']))
      conv.triggers_for_content?("app/models/u.cr", "User.update_all").should be_true
      conv.triggers_for_content?("scripts/one_off.cr", "User.update_all").should be_false
      conv.triggers_for_content?("app/models/u.cr", "User.save").should be_false
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
      conventions.first.layer2?.should be_true
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
        conventions[0].layer2?.should be_true
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
