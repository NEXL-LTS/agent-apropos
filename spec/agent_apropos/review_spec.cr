require "../spec_helper"

private ROOT       = Path["/repo"]
private INDEX_PATH = "/repo/.cache/agent-apropos/index.json"

private A_PATH      = "/repo/docs/conventions/a.md"
private DB_PATH     = "/repo/docs/conventions/db.md"
private MODELS_PATH = "/repo/docs/conventions/models.md"

private A_DOC      = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"
private DB_DOC     = "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes.\n"
private MODELS_DOC = "---\npaths: [\"app/**\"]\ncontents: ['\\bupdate_all\\b']\n---\n" \
                     "# Models\n\nKeep models thin.\n\n## Verify\n\n- Models stay thin\n- No business logic\n"

# Rejects writes so the refresh-index best-effort path is exercised.
private class ReadOnlyFS < InMemoryFS
  def write(path : String, content : String) : Nil
    raise "read-only filesystem"
  end
end

private def run_match(fs : AgentApropos::Filesystem, paths : Array(String),
                      format : String = "paths", stdin_content : String? = nil) : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Review.match(ROOT, fs, paths, format, stdin_content, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

private def run_review(fs : AgentApropos::Filesystem, git : AgentApropos::Git,
                       range : String? = nil, format : String = "md") : {Int32, String, String}
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  code = AgentApropos::Review.run(ROOT, fs, git, range, format, stdout, stderr)
  {code, stdout.to_s, stderr.to_s}
end

# A minimal unified diff touching an app model (adds an `update_all` and a
# `transaction`) and deleting a file (which must be skipped).
private DIFF = <<-DIFF
diff --git a/app/models/user.cr b/app/models/user.cr
index 1111111..2222222 100644
--- a/app/models/user.cr
+++ b/app/models/user.cr
@@ -1,2 +1,4 @@
 class User
+  User.update_all(active: true)
+  transaction do
 end
diff --git a/old.cr b/old.cr
deleted file mode 100644
index 3333333..0000000
--- a/old.cr
+++ /dev/null
@@ -1 +0,0 @@
-gone

DIFF

describe AgentApropos::Review do
  describe ".match" do
    it "prints matched rule files, one per line, sorted and unique (default format)" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC, "/repo/src/x.cr" => "db.transaction do"})
      code, stdout, stderr = run_match(fs, ["src/x.cr"])
      code.should eq(0)
      stderr.should be_empty
      stdout.should eq("docs/conventions/a.md\ndocs/conventions/db.md\n")
    end

    it "resolves path globs and on-disk content regexes into one triggers list in json form" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC, "/repo/src/x.cr" => "run in a transaction"})
      code, stdout, _ = run_match(fs, ["src/x.cr"], "json")
      code.should eq(0)
      parsed = JSON.parse(stdout)
      rules = parsed["files"][0]["rules"].as_a
      rules.map(&.["path"].as_s).should eq(["docs/conventions/a.md", "docs/conventions/db.md"])
      rules[0]["triggers"].should eq(["src/**"])
      rules[1]["triggers"].should eq(["\\btransaction\\b"])
      rules[0].as_h.has_key?("layer").should be_false
    end

    it "concatenates bodies for --format full, deduping a rule matched by two paths" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x", "/repo/src/y.cr" => "y"})
      code, stdout, _ = run_match(fs, ["src/x.cr", "src/y.cr"], "full")
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.scan("Convention (docs/conventions/a.md):").size.should eq(1)
    end

    it "matches against stdin content instead of disk" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      code, stdout, _ = run_match(fs, ["lib/x.cr"], "paths", stdin_content: "wrap in a transaction")
      code.should eq(0)
      stdout.should eq("docs/conventions/db.md\n")
    end

    it "skips a content rule when the file is absent from disk (a path rule still resolves)" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout, _ = run_match(fs, ["src/gone.cr"])
      code.should eq(0)
      stdout.should eq("docs/conventions/a.md\n")
    end

    it "prints nothing when no rule applies" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout, _ = run_match(fs, ["README.md"])
      code.should eq(0)
      stdout.should be_empty
    end

    it "rebuilds the index when missing and reuses it when it already covers the docs" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      run_match(fs, ["src/x.cr"])
      fs.files.has_key?(INDEX_PATH).should be_true
      before = fs.files[INDEX_PATH]

      run_match(fs, ["src/x.cr"])
      fs.files[INDEX_PATH].should eq(before)
    end

    it "still matches when the cache is unwritable (index refresh is best-effort)" do
      fs = ReadOnlyFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      code, stdout, _ = run_match(fs, ["src/x.cr"])
      code.should eq(0)
      stdout.should eq("docs/conventions/a.md\n")
      fs.files.has_key?(INDEX_PATH).should be_false
    end

    it "fails closed on a malformed convention doc" do
      fs = InMemoryFS.new({"/repo/docs/conventions/bad.md" => "---\npaths: [\n"})
      code, _, stderr = run_match(fs, ["src/x.cr"])
      code.should eq(1)
      stderr.should contain("agent-apropos match:")
    end
  end

  describe ".run" do
    it "matches each changed file's path and added lines, skipping deletions" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, MODELS_PATH => MODELS_DOC})
      code, stdout, stderr = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      code.should eq(0)
      stderr.should be_empty
      stdout.should contain("# Review manifest (main...HEAD)")
      stdout.should contain("## app/models/user.cr")
      stdout.should contain("- docs/conventions/db.md (`\\btransaction\\b`)")
      stdout.should contain("- docs/conventions/models.md (`app/**`, `\\bupdate_all\\b`)")
      stdout.should_not contain("old.cr")
    end

    it "harvests `## Verify` criteria as checklist items in the md manifest" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("  - [ ] Models stay thin")
      stdout.should contain("  - [ ] No business logic")
    end

    it "emits a json manifest with the resolved range" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, MODELS_PATH => MODELS_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      parsed["range"].should eq("main...HEAD")
      parsed["files"][0]["path"].should eq("app/models/user.cr")
    end

    it "reports when no conventions apply to the changed files" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("No conventions apply to the changed files.")
    end

    it "defaults the range to the origin/HEAD symbolic ref" do
      fs = InMemoryFS.new({} of String => String)
      git = FakeGit.new(symbolic: "origin/main")
      run_review(fs, git)
      git.diffed_range.should eq("origin/main...HEAD")
    end

    it "falls back to probing candidate default branches" do
      fs = InMemoryFS.new({} of String => String)
      git = FakeGit.new(refs: ["main"])
      run_review(fs, git)
      git.diffed_range.should eq("main...HEAD")
    end

    it "fails closed when no default branch can be determined" do
      fs = InMemoryFS.new({} of String => String)
      code, _, stderr = run_review(fs, FakeGit.new)
      code.should eq(1)
      stderr.should contain("could not determine the default branch")
    end

    it "fails closed when git fails" do
      fs = InMemoryFS.new({} of String => String)
      code, _, stderr = run_review(fs, FakeGit.new(diff_raises: true), "main...HEAD")
      code.should eq(1)
      stderr.should contain("agent-apropos review: diff boom")
    end
  end
end
