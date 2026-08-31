require "../spec_helper"
require "file_utils"

# Exercises `Git::Real` in-process (not through the built binary) against a real
# throwaway repo, so kcov records the adapter's lines. The pure review logic that
# consumes these primitives is covered separately with a fake git (review_spec).
private def git(dir : String, args : Array(String)) : Nil
  status = Process.run("git", args, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "git #{args.join(' ')} failed" unless status.success?
end

private def commit(dir : String, message : String) : Nil
  git(dir, ["add", "-A"])
  git(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", message])
end

private def with_repo(&)
  dir = File.tempname("agent-apropos-git")
  begin
    Dir.mkdir_p(dir)
    git(dir, ["init", "-b", "main"])
    File.write(File.join(dir, "app.cr"), "line one\n")
    commit(dir, "init")
    git(dir, ["checkout", "-b", "feature"])
    File.write(File.join(dir, "app.cr"), "line one\nadded transaction\n")
    commit(dir, "change")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A repo with a single tracked file committed, for removal-detection specs.
private def with_tracked_repo(name : String, content : String, &)
  dir = File.tempname("agent-apropos-git-removed")
  begin
    Dir.mkdir_p(dir)
    git(dir, ["init", "-b", "main"])
    File.write(File.join(dir, name), content)
    git(dir, ["add", name])
    commit(dir, "add #{name}")
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe AgentApropos::Git::Real do
  it "produces a unified diff for a range" do
    with_repo do |dir|
      diff = AgentApropos::Git::Real.new.diff(Path[dir], "main...feature")
      diff.should contain("+++ b/app.cr")
      diff.should contain("+added transaction")
    end
  end

  it "strips color from the diff even when the repo configures color.diff=always" do
    with_repo do |dir|
      git(dir, ["config", "color.diff", "always"])
      diff = AgentApropos::Git::Real.new.diff(Path[dir], "main...feature")
      diff.should_not contain("\e[")
    end
  end

  it "reports whether a ref exists" do
    with_repo do |dir|
      real = AgentApropos::Git::Real.new
      real.ref_exists?(Path[dir], "main").should be_true
      real.ref_exists?(Path[dir], "nope").should be_false
    end
  end

  it "returns nil for an absent symbolic ref (no remote configured)" do
    with_repo do |dir|
      AgentApropos::Git::Real.new.symbolic_ref(Path[dir], "refs/remotes/origin/HEAD").should be_nil
    end
  end

  it "resolves a configured symbolic ref to its short form" do
    with_repo do |dir|
      git(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
      AgentApropos::Git::Real.new.symbolic_ref(Path[dir], "refs/remotes/origin/HEAD").should eq("origin/main")
    end
  end

  it "lists tracked files relative to the repo root" do
    with_repo do |dir|
      AgentApropos::Git::Real.new.ls_files(Path[dir]).should eq(["app.cr"])
    end
  end

  it "returns nil for ls_files outside a git checkout rather than an empty list" do
    dir = File.tempname("agent-apropos-nongit")
    begin
      Dir.mkdir_p(dir)
      AgentApropos::Git::Real.new.ls_files(Path[dir]).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns nil for ls_files when the directory does not exist and git cannot even start" do
    AgentApropos::Git::Real.new.ls_files(Path[File.tempname("agent-apropos-missing")]).should be_nil
  end

  it "raises rather than reporting no tracked files when git fails inside a checkout" do
    dir = File.tempname("agent-apropos-broken")
    begin
      Dir.mkdir_p(File.join(dir, ".git"))
      expect_raises(AgentApropos::Git::Error, "git ls-files failed") do
        AgentApropos::Git::Real.new.ls_files(Path[dir])
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "raises a Git::Error when the git command fails" do
    with_repo do |dir|
      expect_raises(AgentApropos::Git::Error, "git diff") do
        AgentApropos::Git::Real.new.diff(Path[dir], "no-such-ref...HEAD")
      end
    end
  end

  describe "#removed_paths and #blob" do
    it "covers AE1: reports a worktree deletion of a committed file, blob from the index" do
      with_tracked_repo("gone.txt", "committed\n") do |dir|
        File.delete(File.join(dir, "gone.txt"))
        real = AgentApropos::Git::Real.new
        real.removed_paths(Path[dir]).should eq(["gone.txt"])
        real.blob(Path[dir], "", "gone.txt").should eq("committed\n")
      end
    end

    it "covers AE2: reports a git-rm deletion, index blob absent, HEAD blob present" do
      with_tracked_repo("gone.txt", "committed\n") do |dir|
        git(dir, ["rm", "-q", "gone.txt"])
        real = AgentApropos::Git::Real.new
        real.removed_paths(Path[dir]).should eq(["gone.txt"])
        real.blob(Path[dir], "", "gone.txt").should be_nil
        real.blob(Path[dir], "HEAD", "gone.txt").should eq("committed\n")
      end
    end

    it "covers AE3: a staged-but-never-committed file removed from disk, blob from the index only" do
      with_tracked_repo("app.cr", "line one\n") do |dir|
        File.write(File.join(dir, "staged.txt"), "staged only\n")
        git(dir, ["add", "staged.txt"])
        File.delete(File.join(dir, "staged.txt"))
        real = AgentApropos::Git::Real.new
        real.removed_paths(Path[dir]).should eq(["staged.txt"])
        real.blob(Path[dir], "", "staged.txt").should eq("staged only\n")
        real.blob(Path[dir], "HEAD", "staged.txt").should be_nil
      end
    end

    it "covers AE4: an untracked file removed from disk is not reported" do
      with_tracked_repo("app.cr", "line one\n") do |dir|
        File.write(File.join(dir, "scratch.txt"), "never added\n")
        File.delete(File.join(dir, "scratch.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should be_empty
      end
    end

    it "covers AE5: an unstaged rename reports the old path once and not the new path" do
      with_tracked_repo("old.txt", "content\n") do |dir|
        File.rename(File.join(dir, "old.txt"), File.join(dir, "new.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should eq(["old.txt"])
      end
    end

    it "reports a staged rename's old path only, consuming both NUL-separated fields" do
      with_tracked_repo("old.txt", "content\n") do |dir|
        git(dir, ["mv", "old.txt", "new.txt"])
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should eq(["old.txt"])
      end
    end

    it "reports a path containing a space and a path containing non-ASCII characters unquoted" do
      with_tracked_repo("plain.txt", "x\n") do |dir|
        File.write(File.join(dir, "has space.txt"), "x\n")
        File.write(File.join(dir, "héllo.txt"), "x\n")
        git(dir, ["add", "has space.txt", "héllo.txt"])
        commit(dir, "add unusual paths")
        File.delete(File.join(dir, "has space.txt"))
        File.delete(File.join(dir, "héllo.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).to_set.should eq(Set{"has space.txt", "héllo.txt"})
      end
    end

    it "does not report a modified-but-present file (unstaged)" do
      with_tracked_repo("app.cr", "line one\n") do |dir|
        File.write(File.join(dir, "app.cr"), "line one\nline two\n")
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should be_empty
      end
    end

    it "does not stop early, skip, or loop at an unmatched status between two removals" do
      with_tracked_repo("a_deleted1.txt", "gone\n") do |dir|
        File.write(File.join(dir, "m_modified.cr"), "line1\n")
        File.write(File.join(dir, "z_deleted2.txt"), "gone too\n")
        git(dir, ["add", "m_modified.cr", "z_deleted2.txt"])
        commit(dir, "add the rest")
        File.delete(File.join(dir, "a_deleted1.txt"))
        File.delete(File.join(dir, "z_deleted2.txt"))
        File.write(File.join(dir, "m_modified.cr"), "line1\nline2\n")
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).to_set.should eq(
          Set{"a_deleted1.txt", "z_deleted2.txt"}
        )
      end
    end

    it "does not report a staged modification with no further worktree change" do
      with_tracked_repo("app.cr", "line one\n") do |dir|
        File.write(File.join(dir, "app.cr"), "line one\nline two\n")
        git(dir, ["add", "app.cr"])
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should be_empty
      end
    end

    it "does not stop early: a plain removal after a rename is still reported" do
      with_tracked_repo("a_deleted.txt", "gone\n") do |dir|
        File.write(File.join(dir, "m_old.txt"), "renamed\n")
        File.write(File.join(dir, "z_deleted2.txt"), "gone too\n")
        git(dir, ["add", "m_old.txt", "z_deleted2.txt"])
        commit(dir, "add the rest")
        git(dir, ["mv", "m_old.txt", "n_new.txt"])
        File.delete(File.join(dir, "a_deleted.txt"))
        File.delete(File.join(dir, "z_deleted2.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).to_set.should eq(
          Set{"a_deleted.txt", "m_old.txt", "z_deleted2.txt"}
        )
      end
    end

    it "consumes exactly the rename's two record fields, not more or fewer" do
      with_tracked_repo("a_plain.txt", "gone\n") do |dir|
        # The rename's old name starts with "D ", coincidentally a
        # `tracked_removal_status?` code, and it is not the first record (a
        # plain delete precedes it), so mis-consuming this record pair would
        # reprocess it as a bogus second removal rather than landing on the
        # same index by coincidence.
        File.write(File.join(dir, "D odd.txt"), "renamed\n")
        git(dir, ["add", "D odd.txt"])
        commit(dir, "add D odd.txt")
        git(dir, ["mv", "D odd.txt", "new.txt"])
        File.delete(File.join(dir, "a_plain.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should eq(["a_plain.txt", "D odd.txt"])
      end
    end

    it "reports a rename's destination as removed too when it is also deleted from the worktree" do
      with_tracked_repo("old.txt", "content\n") do |dir|
        git(dir, ["mv", "old.txt", "new.txt"])
        File.delete(File.join(dir, "new.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).to_set.should eq(Set{"old.txt", "new.txt"})
      end
    end

    it "consumes exactly the copy's two record fields, not more or fewer" do
      with_tracked_repo("D odd.txt", "line one\nline two\n") do |dir|
        # The copy's source name starts with "D ", coincidentally a
        # `tracked_removal_status?` code (see the analogous rename test
        # above) — mis-consuming the copy's field pair would land on this
        # bare source field and misreport a truncated path as removed.
        git(dir, ["config", "diff.renames", "copies"])
        File.write(File.join(dir, "D odd.txt"), "line one\nline two\nline three\n")
        File.write(File.join(dir, "copy.txt"), "line one\nline two\n")
        git(dir, ["add", "-A"])
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).should be_empty
      end
    end

    it "does not stop early: a plain removal after a copy is still reported" do
      with_tracked_repo("a_deleted.txt", "gone\n") do |dir|
        File.write(File.join(dir, "original.txt"), "line one\nline two\n")
        File.write(File.join(dir, "z_deleted2.txt"), "gone too\n")
        git(dir, ["add", "original.txt", "z_deleted2.txt"])
        commit(dir, "add the rest")
        git(dir, ["config", "diff.renames", "copies"])
        File.write(File.join(dir, "original.txt"), "line one\nline two\nline three\n")
        File.write(File.join(dir, "copy.txt"), "line one\nline two\n")
        git(dir, ["add", "-A"])
        File.delete(File.join(dir, "a_deleted.txt"))
        File.delete(File.join(dir, "z_deleted2.txt"))
        AgentApropos::Git::Real.new.removed_paths(Path[dir]).to_set.should eq(
          Set{"a_deleted.txt", "z_deleted2.txt"}
        )
      end
    end

    it "yields no removed paths, rather than raising, when git cannot run" do
      AgentApropos::Git::Real.new.removed_paths(Path[File.tempname("agent-apropos-missing")]).should be_empty
    end

    it "returns nil from #blob for a path git does not know" do
      with_tracked_repo("app.cr", "line one\n") do |dir|
        AgentApropos::Git::Real.new.blob(Path[dir], "", "no-such-file.cr").should be_nil
      end
    end
  end
end
