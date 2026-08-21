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

describe AgentApropos::Git::Real do
  it "produces a unified diff for a range" do
    with_repo do |dir|
      diff = AgentApropos::Git::Real.new.diff(Path[dir], "main...feature")
      diff.should contain("+++ b/app.cr")
      diff.should contain("+added transaction")
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
end
