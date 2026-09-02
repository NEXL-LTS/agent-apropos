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

# Counts writes so a test can prove a fresh index is not rewritten redundantly.
private class SpyFS < InMemoryFS
  getter write_count = 0

  def write(path : String, content : String) : Nil
    @write_count += 1
    super
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
# `transaction`) and deleting a file.
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

# A rename with a content change, matching real git's default rename-detected
# format: a single file block whose `---`/`+++` paths differ.
private RENAME_DIFF = <<-DIFF
diff --git a/old_name.cr b/new_name.cr
similarity index 55%
rename from old_name.cr
rename to new_name.cr
index 40bc07c..2dfca03 100644
--- a/old_name.cr
+++ b/new_name.cr
@@ -1,2 +1,3 @@
 class User
-  old
+  changed
 end

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

    it "defaults allow_outside to false, refusing to walk an escaping conventions_dir" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../outside\n"})
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      code = AgentApropos::Review.match(ROOT, fs, ["src/x.cr"], "paths", nil, stdout, stderr)
      code.should eq(1)
      stderr.to_s.should contain("resolves outside the repo root")
    end

    it "rebuilds a stale index when a doc's content changed" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      run_match(fs, ["src/x.cr"])
      before = fs.files[INDEX_PATH]

      fs.files[A_PATH] = A_DOC.sub("Body of A.", "Changed body.")
      run_match(fs, ["src/x.cr"])
      fs.files[INDEX_PATH].should_not eq(before)
    end

    it "does not rewrite an index that already covers the docs" do
      fs = SpyFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      run_match(fs, ["src/x.cr"])
      after_first = fs.write_count

      run_match(fs, ["src/x.cr"])
      fs.write_count.should eq(after_first)
    end

    it "ends json output with exactly one trailing newline" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      _, stdout, _ = run_match(fs, ["src/x.cr"], "json")
      stdout.should end_with("}\n")
      stdout.should_not end_with("}\n\n")
    end

    it "includes the verify field, even null, for every rule in json output" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "/repo/src/x.cr" => "x"})
      _, stdout, _ = run_match(fs, ["src/x.cr"], "json")
      parsed = JSON.parse(stdout)
      parsed["files"][0]["rules"][0].as_h.has_key?("verify").should be_true
    end

    it "includes every matched doc's body for a single file in --format full, not just the first" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC, "/repo/src/x.cr" => "db.transaction do"})
      code, stdout, _ = run_match(fs, ["src/x.cr"], "full")
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "collects doc bodies from every matched file in --format full, not just the first" do
      fs = InMemoryFS.new({
        A_PATH           => A_DOC,
        DB_PATH          => DB_DOC,
        "/repo/src/x.cr" => "x",
        "/repo/src/y.rb" => "run in a transaction",
      })
      code, stdout, _ = run_match(fs, ["src/x.cr", "src/y.rb"], "full")
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "orders --format full conventions by path, not by body content" do
      early_path_late_body = "---\npaths: [\"src/**\"]\n---\n# Z\n\nZ-body sorts last.\n"
      late_path_early_body = "---\ncontents: ['marker']\n---\n# A\n\nA-body sorts first.\n"
      fs = InMemoryFS.new({
        "/repo/docs/conventions/e.md" => early_path_late_body,
        "/repo/docs/conventions/l.md" => late_path_early_body,
        "/repo/src/x.cr"              => "marker",
      })
      _, stdout, _ = run_match(fs, ["src/x.cr"], "full")
      e_index = stdout.index("Convention (docs/conventions/e.md):").as(Int32)
      l_index = stdout.index("Convention (docs/conventions/l.md):").as(Int32)
      e_index.should be < l_index
    end
  end

  describe ".run" do
    it "matches each changed file's path and added lines" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, MODELS_PATH => MODELS_DOC})
      code, stdout, stderr = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      code.should eq(0)
      stderr.should be_empty
      stdout.should contain("# Review manifest (main...HEAD)")
      stdout.should contain("## app/models/user.cr")
      stdout.should contain("- docs/conventions/db.md (`\\btransaction\\b`)")
      stdout.should contain("- docs/conventions/models.md (`app/**`, `\\bupdate_all\\b`)")
    end

    it "covers AE6: emits a row for a deleted file, and a write-only doc does not match it" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      deleted = parsed["files"].as_a.find! { |file| file["path"] == "old.cr" }
      deleted["rules"].as_a.should be_empty
    end

    it "does not match a write-triggered doc against a deleted file even when its glob would match" do
      write_doc = "---\npaths: [\"old.cr\"]\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      deleted = parsed["files"].as_a.find! { |file| file["path"] == "old.cr" }
      deleted["rules"].as_a.should be_empty
    end

    it "matches a removal-triggered doc against the deleted file's removed lines" do
      removal_doc = "---\non: [removed]\ncontents: ['gone']\n---\n# R\n\nRemoved doc body.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("## old.cr")
      stdout.should contain("- docs/conventions/r.md (`gone`)")
    end

    it "produces both an edit row and a deletion row, each matching only its own event" do
      write_doc = "---\npaths: [\"app/**\"]\n---\n# W\n\nWrite doc.\n"
      removal_doc = "---\non: [removed]\npaths: [\"old.cr\"]\n---\n# R\n\nRemoval doc.\n"
      fs = InMemoryFS.new({
        "/repo/docs/conventions/w.md" => write_doc,
        "/repo/docs/conventions/r.md" => removal_doc,
      })
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("## app/models/user.cr")
      stdout.should contain("- docs/conventions/w.md")
      stdout.should contain("## old.cr")
      stdout.should contain("- docs/conventions/r.md")
    end

    it "does not check a removal-triggered doc against an ordinary edit that neither deletes nor renames" do
      removal_doc = "---\non: [removed]\npaths: [\"app/models/user.cr\"]\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      edited = parsed["files"].as_a.find! { |file| file["path"] == "app/models/user.cr" }
      edited["rules"].as_a.should be_empty
    end

    it "matches a rename diff's removal doc on the old path" do
      removal_doc = "---\non: [removed]\npaths: [\"old_name.cr\"]\n---\n# R\n\nRemoval doc.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: RENAME_DIFF), "main...HEAD")
      stdout.should contain("## new_name.cr")
      stdout.should contain("- docs/conventions/r.md")
    end

    it "still matches a write-triggered doc on a rename's new path" do
      write_doc = "---\npaths: [\"new_name.cr\"]\n---\n# W\n\nWrite doc.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: RENAME_DIFF), "main...HEAD")
      stdout.should contain("## new_name.cr")
      stdout.should contain("- docs/conventions/w.md")
    end

    it "detects a rename even when the old path sorts before the new path lexically" do
      lexical_rename = <<-DIFF
      diff --git a/aaa_old.cr b/zzz_new.cr
      similarity index 55%
      rename from aaa_old.cr
      rename to zzz_new.cr
      index 40bc07c..2dfca03 100644
      --- a/aaa_old.cr
      +++ b/zzz_new.cr
      @@ -1,2 +1,3 @@
       class User
      -  old
      +  changed
       end

      DIFF
      removal_doc = "---\non: [removed]\npaths: [\"aaa_old.cr\"]\n---\n# R\n\nRemoval doc.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: lexical_rename), "main...HEAD")
      stdout.should contain("## zzz_new.cr")
      stdout.should contain("- docs/conventions/r.md")
    end

    # A 100%-similarity rename carries no "---"/"+++"/"@@" at all — there is
    # no content diff to show. Confirmed against a real repo (`git mv` with
    # no further edit).
    it "matches a pure rename's removal doc on the old path, with no content diff at all" do
      pure_rename = <<-DIFF
      diff --git a/old.txt b/new.txt
      similarity index 100%
      rename from old.txt
      rename to new.txt

      DIFF
      removal_doc = "---\non: [removed]\npaths: [\"old.txt\"]\n---\n# R\n\nRemoval doc.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: pure_rename), "main...HEAD")
      stdout.should contain("## new.txt")
      stdout.should contain("- docs/conventions/r.md")
    end

    it "still matches a write-triggered doc on a pure rename's new path" do
      pure_rename = <<-DIFF
      diff --git a/old.txt b/new.txt
      similarity index 100%
      rename from old.txt
      rename to new.txt

      DIFF
      write_doc = "---\npaths: [\"new.txt\"]\n---\n# W\n\nWrite doc.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: pure_rename), "main...HEAD")
      stdout.should contain("## new.txt")
      stdout.should contain("- docs/conventions/w.md")
    end

    # A pure rename's metadata lines are handled by their own elsif branches,
    # not the hunk-counting loop — nothing must stop the parser from reaching
    # whatever comes after them in a multi-file diff.
    it "still parses a second file's diff after a pure rename with no content change" do
      rename_then_second_file = <<-DIFF
      diff --git a/old.txt b/new.txt
      similarity index 100%
      rename from old.txt
      rename to new.txt
      diff --git a/second.txt b/second.txt
      index 1111111..2222222 100644
      --- a/second.txt
      +++ b/second.txt
      @@ -1 +1 @@
      -old second line
      +new second line

      DIFF
      write_doc = "---\ncontents: ['new second line']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: rename_then_second_file), "main...HEAD")
      stdout.should contain("## second.txt")
      stdout.should contain("- docs/conventions/w.md")
    end

    # Once the new side's remaining count reaches 0, only the old side's own
    # count still decides whether a trailing removed-only line belongs to
    # this hunk.
    it "collects every trailing removed-only line after the new side's count is exhausted" do
      deleted = <<-DIFF
      diff --git a/f.txt b/f.txt
      deleted file mode 100644
      index 1111111..0000000
      --- a/f.txt
      +++ /dev/null
      @@ -1,3 +0,0 @@
       context
      -removed1
      -removed2

      DIFF
      removal_doc = "---\non: [removed]\ncontents: ['removed2']\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: deleted), "main...HEAD")
      stdout.should contain("## f.txt")
      stdout.should contain("- docs/conventions/r.md")
    end

    # A removed line whose own text starts with "-- " renders as "--- " in
    # the diff — indistinguishable by text alone from a real file header.
    # Confirmed against a real repo (deleting a file containing such a
    # line). Header detection must track the hunk's own declared line
    # counts, not just what a line's text looks like, or this line gets
    # mistaken for the start of a new file and dropped from `removed`.
    it "collects a removed line that looks like a file header, deep inside a real hunk" do
      tricky_delete = <<-DIFF
      diff --git a/markdown.md b/markdown.md
      deleted file mode 100644
      index 1111111..0000000
      --- a/markdown.md
      +++ /dev/null
      @@ -1,3 +0,0 @@
      -line one
      --- a horizontal rule looking line
      -line three

      DIFF
      removal_doc = "---\non: [removed]\ncontents: ['horizontal rule looking line']\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: tricky_delete), "main...HEAD")
      stdout.should contain("## markdown.md")
      stdout.should contain("- docs/conventions/r.md")
    end

    # A pure-addition hunk (old side has zero lines, "@@ -0,0 +1,2 @@") drives
    # the hunk-tracking loop by its new-side count alone, with the old-side
    # count staying at 0 throughout — the mirror image of tricky_delete's
    # pure-removal case above, and the only shape that actually exercises the
    # new-side count independently of the old-side one.
    it "collects every line of a multi-line pure-addition hunk, not just the first" do
      pure_add = <<-DIFF
      diff --git a/new_file.md b/new_file.md
      new file mode 100644
      index 0000000..1111111
      --- /dev/null
      +++ b/new_file.md
      @@ -0,0 +1,2 @@
      +first added line
      +second added line

      DIFF
      write_doc = "---\ncontents: ['second added line']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: pure_add), "main...HEAD")
      stdout.should contain("## new_file.md")
      stdout.should contain("- docs/conventions/w.md")
    end

    # "@@ -0,0 +1 @@" — a single-line pure addition — omits the new-side
    # count entirely (unified diff format elides a count of 1), unlike the
    # explicit "+1,2" above. A content-scoped rule is required here, not a
    # path-only one: a missing-content bug still leaves the path known, so
    # only matching against the actual captured text proves the one added
    # line was collected. Confirmed against a real repo (adding one line to
    # a previously-empty file produces exactly this header shape).
    it "collects the single added line of a hunk whose new-side count is omitted (implicit 1)" do
      single_add = <<-DIFF
      diff --git a/empty.txt b/empty.txt
      index e69de29..2f38458 100644
      --- a/empty.txt
      +++ b/empty.txt
      @@ -0,0 +1 @@
      +just one line

      DIFF
      write_doc = "---\ncontents: ['just one line']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: single_add), "main...HEAD")
      stdout.should contain("## empty.txt")
      stdout.should contain("- docs/conventions/w.md")
    end

    # "\ No newline at end of file" can land mid-hunk, not just at its very
    # end: here it describes a removed line that exhausts the old side
    # while the new side still has two more added lines to come. Confirmed
    # against a real repo (fixing a file that previously lacked a trailing
    # newline). If this metadata line were miscounted as real content, the
    # new side's count would be thrown off by one and the hunk would exit
    # before the second added line — so this only proves correct if BOTH
    # added lines land, not just the first.
    it "does not miscount a mid-hunk \"No newline at end of file\" marker as content" do
      mid_hunk_marker = <<-DIFF
      diff --git a/noeof.txt b/noeof.txt
      index cf0683d..75b8f1c 100644
      --- a/noeof.txt
      +++ b/noeof.txt
      @@ -1,2 +1,3 @@
       line one
      -no newline at end
      \\ No newline at end of file
      +no newline at end
      +new line with newline

      DIFF
      write_doc = "---\ncontents: ['new line with newline']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: mid_hunk_marker), "main...HEAD")
      stdout.should contain("## noeof.txt")
      stdout.should contain("- docs/conventions/w.md")
    end

    # A synthetic swap of consume_hunk_line's returned tuple order survives
    # the single-file marker test above (with nothing following, the
    # corrupted counts have nothing left to overrun) — this is what actually
    # catches it: enough trailing added lines in the first file inflate the
    # corrupted count past the second file's own metadata lines, so its
    # real "---"/"+++" headers get silently swallowed as fake hunk content
    # instead of registering the file at all.
    it "does not let a mid-hunk backslash marker's count corruption bleed into the next file" do
      overrun = <<-DIFF
      diff --git a/noeof.txt b/noeof.txt
      index cf0683d..75b8f1c 100644
      --- a/noeof.txt
      +++ b/noeof.txt
      @@ -1,2 +1,6 @@
       line one
      -no newline at end
      \\ No newline at end of file
      +no newline at end
      +added two
      +added three
      +added four
      +added five
      diff --git a/second.txt b/second.txt
      index 1111111..2222222 100644
      --- a/second.txt
      +++ b/second.txt
      @@ -1 +1 @@
      -old second line
      +new second line

      DIFF
      write_doc = "---\ncontents: ['new second line']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: overrun), "main...HEAD")
      stdout.should contain("## second.txt")
      stdout.should contain("- docs/conventions/w.md")
    end

    it "does not reset already-collected content if the same path's header repeats" do
      odd_diff = <<-DIFF
      --- a/file.cr
      +++ b/file.cr
      @@ -1 +1 @@
      +first
      --- a/file.cr
      +++ b/file.cr
      @@ -1 +1 @@
      +second

      DIFF
      write_doc = "---\ncontents: ['first']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: odd_diff), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      parsed["files"].as_a.size.should eq(1)
      parsed["files"][0]["rules"][0]["path"].should eq("docs/conventions/w.md")
    end

    it "does not collect a stray '+'-prefixed line before any hunk header as content" do
      malformed = <<-DIFF
      --- a/file1
      +++ b/file1
      @@ -1 +1 @@
      +file1 content
      --- a/file2
      +++ b/file2
      +file2 stray without at-at

      DIFF
      write_doc = "---\ncontents: ['stray']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: malformed), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      file2 = parsed["files"].as_a.find! { |file| file["path"] == "file2" }
      file2["rules"].as_a.should be_empty
    end

    it "strips only the diff marker from an added line, not real content" do
      write_doc = "---\ncontents: ['^  User\\.update_all']\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      edited = parsed["files"].as_a.find! { |file| file["path"] == "app/models/user.cr" }
      edited["rules"].as_a.should_not be_empty
    end

    it "strips only the diff marker from a removed line, not real content" do
      removal_doc = "---\non: [removed]\ncontents: ['^gone$']\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      deleted = parsed["files"].as_a.find! { |file| file["path"] == "old.cr" }
      deleted["rules"].as_a.should_not be_empty
    end

    it "leaves a path with no a/ or b/ prefix unmodified" do
      no_prefix_diff = "--- old.cr\n+++ new.cr\n@@ -1 +1 @@\n+x\n"
      write_doc = "---\npaths: [\"new.cr\"]\n---\n# W\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/w.md" => write_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: no_prefix_diff), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      parsed["files"][0]["path"].should eq("new.cr")
    end

    it "harvests `## Verify` criteria as checklist items in the md manifest" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("  - [ ] Models stay thin")
      stdout.should contain("  - [ ] No business logic")
    end

    it "harvests a `## Verify` criterion from a removal doc as a checklist item too" do
      removal_doc = "---\non: [removed]\ncontents: ['gone']\n---\n# R\n\nBody.\n\n## Verify\n\n- Nothing references it anymore\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("  - [ ] Nothing references it anymore")
    end

    it "separates each file's section with a blank line" do
      write_doc = "---\npaths: [\"app/**\"]\n---\n# W\n\nBody.\n"
      removal_doc = "---\non: [removed]\npaths: [\"old.cr\"]\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({
        "/repo/docs/conventions/w.md" => write_doc,
        "/repo/docs/conventions/r.md" => removal_doc,
      })
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("- docs/conventions/w.md (`app/**`)\n\n## old.cr")
    end

    it "still collects a verify item after a blank line between checklist items" do
      removal_doc = "---\non: [removed]\ncontents: ['gone']\n---\n# R\n\nBody.\n\n" \
                    "## Verify\n\n- First item\n\n- Second item\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("- [ ] First item")
      stdout.should contain("- [ ] Second item")
      stdout.scan("  - [ ] ").size.should eq(2)
    end

    it "strips +, *, and numbered-list bullet markers from verify items, leaving unmarked text alone" do
      removal_doc = "---\non: [removed]\ncontents: ['gone']\n---\n# R\n\nBody.\n\n" \
                    "## Verify\n\n" \
                    "+ Plus item\n" \
                    "* Star item\n" \
                    "1. First step\n" \
                    "2) Second step\n" \
                    "-tight\n" \
                    "1.NoSpace\n" \
                    ". Not a number\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD")
      stdout.should contain("- [ ] Plus item")
      stdout.should contain("- [ ] Star item")
      stdout.should contain("- [ ] First step")
      stdout.should contain("- [ ] Second step")
      stdout.should contain("- [ ] -tight")
      stdout.should contain("- [ ] 1.NoSpace")
      stdout.should contain("- [ ] . Not a number")
    end

    it "emits a json manifest with the resolved range" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, MODELS_PATH => MODELS_DOC})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      parsed["range"].should eq("main...HEAD")
      parsed["files"][0]["path"].should eq("app/models/user.cr")
    end

    it "includes the deletion row's rules in a json manifest" do
      removal_doc = "---\non: [removed]\ncontents: ['gone']\n---\n# R\n\nBody.\n"
      fs = InMemoryFS.new({"/repo/docs/conventions/r.md" => removal_doc})
      _, stdout, _ = run_review(fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "json")
      parsed = JSON.parse(stdout)
      deleted = parsed["files"].as_a.find! { |file| file["path"] == "old.cr" }
      deleted["rules"][0]["path"].should eq("docs/conventions/r.md")
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

    it "queries the origin HEAD symbolic ref by its exact name" do
      fs = InMemoryFS.new({} of String => String)
      git = FakeGit.new(symbolic: "origin/main")
      run_review(fs, git)
      git.symbolic_ref_name.should eq("refs/remotes/origin/HEAD")
    end

    it "tries the default base candidates in the documented order" do
      AgentApropos::Review::DEFAULT_BASE_CANDIDATES.should eq(["origin/main", "origin/master", "main", "master"])
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

    it "defaults allow_outside to false, refusing to walk an escaping conventions_dir" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../outside\n"})
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      code = AgentApropos::Review.run(ROOT, fs, FakeGit.new(diff_text: DIFF), "main...HEAD", "md", stdout, stderr)
      code.should eq(1)
      stderr.to_s.should contain("resolves outside the repo root")
    end
  end
end
