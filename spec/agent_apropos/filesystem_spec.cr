require "../spec_helper"
require "file_utils"

# Exercises the one adapter that touches disk (Filesystem::Real). glob/read are
# covered via Conventions.walk; here we cover the write-side additions used by
# generate. Each example is self-contained in a temp dir.
describe AgentApropos::Filesystem::Real do
  it "writes a file, creating missing parent directories" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      target = File.join(dir, "nested/deep/out.txt")
      fs.write(target, "hello\n")
      File.read(target).should eq("hello\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reads an existing file and returns nil for an absent one" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      Dir.mkdir_p(dir)
      present = File.join(dir, "there.txt")
      File.write(present, "content\n")
      fs.read?(present).should eq("content\n")
      fs.read?(File.join(dir, "missing.txt")).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "globs through a base whose separators are not POSIX" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/a.md"), "x\n")

      fs.glob(Path.windows(dir), "docs/**/*.md").size.should eq(1)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "removes a directory tree and is a no-op when the target is absent" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      Dir.mkdir_p(File.join(dir, "skills/foo"))
      File.write(File.join(dir, "skills/foo/SKILL.md"), "x\n")
      fs.remove(File.join(dir, "skills/foo"))
      Dir.exists?(File.join(dir, "skills/foo")).should be_false
      fs.remove(File.join(dir, "skills/does-not-exist")) # no raise
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports existence for files, directories, and (even dangling) symlinks" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      Dir.mkdir_p(dir)
      file = File.join(dir, "file.txt")
      File.write(file, "x")
      fs.exists?(file).should be_true
      fs.exists?(dir).should be_true
      fs.exists?(File.join(dir, "nope")).should be_false

      link = File.join(dir, "dangling")
      File.symlink(File.join(dir, "absent-target"), link)
      fs.exists?(link).should be_true # dangling link still "exists"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "creates a symlink, making parent directories as needed" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      link = File.join(dir, "nested/CLAUDE.md")
      fs.symlink("AGENTS.md", link)
      File.symlink?(link).should be_true
      File.readlink(link).should eq("AGENTS.md")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "raises a Filesystem::Error when the OS refuses to create the symlink" do
    dir = File.tempname("agent-apropos-fs")
    fs = AgentApropos::Filesystem::Real.new
    begin
      Dir.mkdir_p(dir)
      blocker = File.join(dir, "blocker")
      File.write(blocker, "not a directory\n")

      expect_raises(AgentApropos::Filesystem::Error, /symlink/) do
        fs.symlink("AGENTS.md", File.join(blocker, "CLAUDE.md"))
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
