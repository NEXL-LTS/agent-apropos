require "../spec_helper"
require "file_utils"

# End-to-end review/match against the built binary over a real git repo — the one
# place the git process boundary and real stdin are exercised together. The pure
# resolution logic is unit-tested with a fake git (review_spec).
private def run_agent_apropos(binary : String, args : Array(String), stdin : String = "") : {Int32, String}
  stdout = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new(stdin), output: stdout)
  {status.exit_code, stdout.to_s}
end

private def git_setup(dir : String, args : Array(String)) : Nil
  status = Process.run("git", args, chdir: dir,
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "git #{args.join(' ')} failed" unless status.success?
end

describe "agent-apropos review/match (binary)" do
  binary = File.join(Dir.tempdir, "agent-apropos-review-#{Process.pid}")

  Spec.before_suite do
    status = Process.run(
      "crystal", ["build", "src/agent_apropos.cr", "-o", binary],
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit
    )
    raise "failed to build agent-apropos binary for integration specs" unless status.success?
  end

  Spec.after_suite do
    File.delete?(binary)
  end

  it "matches a path and reviews a git range end to end" do
    dir = File.tempname("agent-apropos-review-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      Dir.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "docs/conventions/models.md"),
        "---\npaths: [\"app/**\"]\n---\n# Models\n\nKeep models thin.\n\n## Verify\n\n- Stays thin\n")
      File.write(File.join(dir, "app/models/user.cr"), "class User\nend\n")
      git_setup(dir, ["init", "-b", "main"])
      git_setup(dir, ["add", "-A"])
      git_setup(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"])
      git_setup(dir, ["checkout", "-b", "feature"])
      File.write(File.join(dir, "app/models/user.cr"), "class User\n  # changed\nend\n")
      git_setup(dir, ["add", "-A"])
      git_setup(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "change"])

      code, matched = run_agent_apropos(binary, ["match", "--repo-root", dir, "app/models/user.cr"])
      code.should eq(0)
      matched.should eq("docs/conventions/models.md\n")

      code, manifest = run_agent_apropos(binary, ["review", "--repo-root", dir, "main...HEAD"])
      code.should eq(0)
      manifest.should contain("## app/models/user.cr")
      manifest.should contain("- [ ] Stays thin")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "lists a removal-triggered convention for a range that deletes a file" do
    dir = File.tempname("agent-apropos-review-removal-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      Dir.mkdir_p(File.join(dir, "app/models"))
      File.write(File.join(dir, "docs/conventions/models.md"),
        "---\non: [removed]\npaths: [\"app/**\"]\n---\n# Models\n\nRetire the model cleanly.\n")
      File.write(File.join(dir, "app/models/user.cr"), "class User\nend\n")
      git_setup(dir, ["init", "-b", "main"])
      git_setup(dir, ["add", "-A"])
      git_setup(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"])
      git_setup(dir, ["checkout", "-b", "feature"])
      File.delete(File.join(dir, "app/models/user.cr"))
      git_setup(dir, ["add", "-A"])
      git_setup(dir, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "remove"])

      code, manifest = run_agent_apropos(binary, ["review", "--repo-root", dir, "main...HEAD"])
      code.should eq(0)
      manifest.should contain("## app/models/user.cr")
      manifest.should contain("docs/conventions/models.md")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
