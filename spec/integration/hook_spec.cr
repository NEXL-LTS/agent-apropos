require "../spec_helper"
require "file_utils"

# End-to-end hook runtime against the built binary, driving payloads through
# real stdin (the one place the process boundary and fail-open exit code are
# exercised honestly — unit specs drive the same logic through injected IO).
private def run_hook(binary : String, args : Array(String), payload : String) : {Int32, String}
  stdout = IO::Memory.new
  status = Process.run(binary, args, input: IO::Memory.new(payload), output: stdout)
  {status.exit_code, stdout.to_s}
end

# The payload fixtures are JSON, so splicing a raw Windows temp path in would
# leave unescaped backslashes and fail to parse. Windows accepts the POSIX form
# and the hook relativizes either — see the Windows-shaped path examples in
# spec/agent_apropos/hook_spec.cr.
private def json_path(*parts : String) : String
  Path[*parts].to_posix.to_s
end

describe "agent-apropos hook (binary)" do
  binary = File.join(Dir.tempdir, "agent-apropos-hook-#{Process.pid}")

  Spec.before_suite do
    status = Process.run(
      "crystal",
      ["build", "src/agent_apropos.cr", "-o", binary],
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
    raise "failed to build agent-apropos binary for integration specs" unless status.success?
  end

  Spec.after_suite do
    File.delete?(binary)
  end

  it "injects a path-scoped rule on PreToolUse and dedupes within a session" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = {session_id: "s", tool_name: "Edit", cwd: dir,
                 tool_input: {file_path: File.join(dir, "app/jobs/m.cr")}}.to_json

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain(%("hookEventName":"PreToolUse"))
      output.should contain("Keep jobs idempotent.")

      # Second identical call in the same session injects nothing.
      _, second = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      second.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "injects a content-scoped rule on PostToolUse from written content" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/db.md"),
        "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes in a transaction.\n")

      payload = {session_id: "s", tool_name: "Write", cwd: dir,
                 tool_input: {file_path: File.join(dir, "db/m.cr"), content: "transaction do\nend\n"}}.to_json

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain(%("hookEventName":"PostToolUse"))
      output.should contain("Wrap writes in a transaction.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "fails open (exit 0, no output) on malformed stdin" do
    code, output = run_hook(binary, ["hook", "pre", "--repo-root", "/nonexistent"], "{ not json")
    code.should eq(0)
    output.should be_empty
  end

  # Gemini CLI wires both `hook pre` and `hook post` onto its AfterTool event
  # (its BeforeTool output schema cannot inject context — see init.cr), and its
  # write_file/replace tools happen to use the exact argument names Claude's
  # Write/Edit do. These fixtures are real captures of that shape (see
  # spec/fixtures/hook_payloads/), proving the binary needs no Gemini-specific
  # code, not just the injected-IO unit specs.
  it "handles a Gemini CLI write_file AfterTool payload with no tool-specific code" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/db.md"),
        "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes in a transaction.\n")

      payload = File.read("spec/fixtures/hook_payloads/gemini_after_tool_write_file.json")
        .gsub("db/migrate/001_create.cr", json_path(dir, "db/migrate/001_create.cr"))

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Wrap writes in a transaction.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "handles a Gemini CLI replace AfterTool payload with no tool-specific code" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = File.read("spec/fixtures/hook_payloads/gemini_after_tool_replace.json")
        .gsub("app/jobs/mailer_job.cr", json_path(dir, "app/jobs/mailer_job.cr"))

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Keep jobs idempotent.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # GitHub Copilot CLI calls `agent-apropos hook pre`/`post` directly — no
  # bridge script — since Payload understands its dialect (camelCase,
  # toolArgs as a JSON-encoded string) natively (see init.cr's
  # scaffold_copilot). These fixtures are real captures of that shape (see
  # spec/fixtures/hook_payloads/), proving the binary needs no bridge, not
  # just the injected-IO unit specs.
  it "handles a Copilot CLI create postToolUse payload with no bridge script" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/db.md"),
        "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nWrap writes in a transaction.\n")

      payload = File.read("spec/fixtures/hook_payloads/copilot_post_tool_use_create.json")
        .gsub("/repo", json_path(dir))

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Wrap writes in a transaction.")
      output.should_not contain("hookSpecificOutput")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "handles a Copilot CLI edit postToolUse payload with no bridge script" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = File.read("spec/fixtures/hook_payloads/copilot_post_tool_use_edit.json")
        .gsub("/repo", json_path(dir))

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Keep jobs idempotent.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "stays silent on a Copilot CLI view postToolUse payload — a read never injects" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = File.read("spec/fixtures/hook_payloads/copilot_post_tool_use_view.json")
        .gsub("/repo", json_path(dir))

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # Codex CLI calls `agent-apropos hook pre`/`post` directly, matched on its
  # apply_patch tool (see agents/codex.cr). Unlike Gemini/Copilot, this one
  # genuinely needs Codex-specific code: a single apply_patch call's
  # tool_input is a patch envelope that can bundle several files' Add/Update
  # sections together (see Payload#file_edits/ApplyPatch) — these fixtures are
  # real captures of that shape (spec/fixtures/hook_payloads/), proving the
  # binary matches and injects for *every* file such a payload touches, not
  # just the first.
  it "handles a Codex CLI apply_patch PreToolUse payload bundling two files (a rule for each)" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/lib.md"),
        "---\npaths: [\"lib/**\"]\n---\n# Lib\n\nKeep lib modules pure.\n")
      File.write(File.join(dir, "docs/conventions/jobs.md"),
        "---\npaths: [\"app/jobs/**\"]\n---\n# Jobs\n\nKeep jobs idempotent.\n")

      payload = File.read("spec/fixtures/hook_payloads/codex_pre_tool_use_apply_patch.json")
        .gsub("/repo", json_path(dir))

      code, output = run_hook(binary, ["hook", "pre", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Keep lib modules pure.")
      output.should contain("Keep jobs idempotent.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "handles a Codex CLI apply_patch PostToolUse payload, matching content on the Update section's added line" do
    dir = File.tempname("agent-apropos-hook-repo")
    begin
      Dir.mkdir_p(File.join(dir, "docs/conventions"))
      File.write(File.join(dir, "docs/conventions/comments.md"),
        "---\ncontents: ['\\bsum\\b']\n---\n# Comments\n\nExplain why, not what.\n")

      payload = File.read("spec/fixtures/hook_payloads/codex_post_tool_use_apply_patch.json")
        .gsub("/repo", json_path(dir))

      code, output = run_hook(binary, ["hook", "post", "--repo-root", dir], payload)
      code.should eq(0)
      output.should contain("Explain why, not what.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
