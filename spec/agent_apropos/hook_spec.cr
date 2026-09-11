require "../spec_helper"

private NOW = Time.utc(2026, 7, 16, 12, 0, 0)

private REPO      = SpecPaths.absolute("repo")
private ELSEWHERE = SpecPaths.absolute("elsewhere")
private OUTSIDE   = SpecPaths.absolute("outside")

private A_PATH      = "#{REPO}/docs/conventions/a.md"
private DB_PATH     = "#{REPO}/docs/conventions/db.md"
private MODELS_PATH = "#{REPO}/docs/conventions/models.md"

private A_DOC         = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"
private DB_DOC        = "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nUse transactions carefully.\n"
private MODELS_DOC    = "---\npaths: [\"app/**\"]\ncontents: ['\\bupdate_all\\b']\n---\n# Models\n\nAvoid update_all.\n"
private A_REMOVED_DOC = "---\non: [removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"

# A filesystem that rejects writes, so the persist-index and dedup-save paths
# must degrade gracefully.
private class ReadOnlyFS < InMemoryFS
  def write(path : String, content : String) : Nil
    raise "read-only filesystem"
  end
end

# A filesystem that raises on every read, forcing an internal error so the
# fail-open + verbose-logging paths are exercised. The raises are guarded by an
# always-true flag so the compiler still infers String/String? (an unconditional
# raise would be NoReturn and poison type inference in the modules under test).
private class ExplodingFS < AgentApropos::Filesystem
  getter written = [] of {String, String}
  getter removed = [] of String

  def initialize(@write_raises : Bool = false, @raise_reads : Bool = true,
                 @entries = [] of String, @remove_raises : Bool = false)
  end

  def glob(base : Path, pattern : String) : Array(String)
    full = base.join(pattern).to_posix.to_s
    @entries.select { |entry| File.match?(full, entry) }
  end

  def read(path : String) : String
    raise "boom" if @raise_reads
    ""
  end

  def read?(path : String) : String?
    raise "boom" if @raise_reads
    ""
  end

  def write(path : String, content : String) : Nil
    raise "log boom" if @write_raises
    @written << {path, content}
  end

  def remove(path : String) : Nil
    raise "prune boom" if @remove_raises
    @removed << path
  end

  def exists?(path : String) : Bool
    false
  end

  def symlink(target : String, link_path : String) : Nil
  end
end

private def pre_json(file_path : String, session_id : String? = "s", cwd : String? = REPO) : String
  {session_id: session_id, tool_name: "Edit", cwd: cwd, tool_input: {file_path: file_path}}.to_json
end

private def write_json(file_path : String, content : String, session_id : String? = "s") : String
  {session_id: session_id, tool_name: "Write", cwd: REPO,
   tool_input: {file_path: file_path, content: content}}.to_json
end

private def read_json(file_path : String, session_id : String? = "s", cwd : String? = REPO) : String
  {session_id: session_id, tool_name: "Read", cwd: cwd, tool_input: {file_path: file_path}}.to_json
end

private def partial_read_json(file_path : String, offset : Int32? = nil, limit : Int32? = nil) : String
  {session_id: "s", tool_name: "Read", cwd: REPO,
   tool_input: {file_path: file_path, offset: offset, limit: limit}}.to_json
end

private def invoke(event : Symbol, input : String, fs : AgentApropos::Filesystem,
                   override : String? = REPO, now : Time = NOW, verbose : Bool = false,
                   tool : String? = nil, git : AgentApropos::Git = FakeGit.new,
                   allow_outside : Bool = false) : {Int32, String}
  stdout = IO::Memory.new
  reader = IO::Memory.new(input)
  code =
    if event == :pre
      AgentApropos::Hook.pre(reader, stdout, fs, now, override, verbose, tool, allow_outside, git)
    else
      AgentApropos::Hook.post(reader, stdout, fs, now, override, verbose, tool, allow_outside, git)
    end
  {code, stdout.to_s}
end

private def shell_json(command : String, session_id : String? = "s", cwd : String? = REPO) : String
  {session_id: session_id, tool_name: "Bash", cwd: cwd, tool_input: {command: command}}.to_json
end

private def copilot_shell_json(command : String, session_id : String? = "s", cwd : String? = REPO) : String
  tool_args = {command: command, description: "run a shell command"}.to_json
  {sessionId: session_id, toolName: "bash", cwd: cwd, toolArgs: tool_args}.to_json
end

private def apply_patch_delete_json(path : String, session_id : String? = "s", cwd : String? = REPO) : String
  command = "*** Begin Patch\n*** Delete File: #{path}\n*** End Patch"
  {session_id: session_id, tool_name: "apply_patch", cwd: cwd, tool_input: {command: command}}.to_json
end

private def apply_patch_add_and_delete_json(added_path : String, added_content : String, deleted_path : String,
                                            session_id : String? = "s", cwd : String? = REPO) : String
  command = "*** Begin Patch\n*** Add File: #{added_path}\n+#{added_content}\n" \
            "*** Delete File: #{deleted_path}\n*** End Patch"
  {session_id: session_id, tool_name: "apply_patch", cwd: cwd, tool_input: {command: command}}.to_json
end

describe AgentApropos::Hook do
  describe ".pre" do
    it "injects a matching path-scoped rule before the edit" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout = invoke(:pre, pre_json("#{REPO}/src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain(%("hookEventName":"PreToolUse"))
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Body of A.")
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/index.json").should be_true
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_true
    end

    it "still injects a valid rule when a sibling doc is malformed and the index cache is cold" do
      fs = InMemoryFS.new({
        A_PATH                            => A_DOC,
        "#{REPO}/docs/conventions/bad.md" => "---\npaths: not-a-list\n---\nBad\n",
      })
      code, stdout = invoke(:pre, pre_json("#{REPO}/src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "injects a rule at most once per session" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")

      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "does not repeat a rule for a different file that also matches it (dedup is global per session, not per file)" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")

      code, stdout = invoke(:pre, pre_json("src/other.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "appends a scope note stating a path-scoped rule applies to every matching file" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      _, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      stdout.should contain(
        "Scope: this convention applies to every file whose path matches `src/**` " \
        "— not only the file that triggered it just now."
      )
    end

    it "injects a content-scoped rule from the fragment about to be written" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      code, stdout = invoke(:pre, write_json("lib/x.cr", "db.transaction do"), fs)
      code.should eq(0)
      stdout.should contain(%("hookEventName":"PreToolUse"))
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "does not match a content rule against the pre-write file on disk" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, "#{REPO}/lib/x.cr" => "db.transaction do"})
      input = %({"session_id":"s","tool_name":"Edit","cwd":"#{REPO}","tool_input":{"file_path":"lib/x.cr"}})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should_not contain("Convention (docs/conventions/db.md):")
    end

    it "still matches a path rule when the payload carries no written content" do
      fs = InMemoryFS.new({A_PATH => A_DOC, "#{REPO}/src/app.cr" => "existing"})
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "emits nothing when no rule matches the path" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("docs/readme.md", session_id: nil), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing on malformed stdin (fail open)" do
      code, stdout = invoke(:pre, "{ not json", InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when the payload carries no file_path" do
      code, stdout = invoke(:pre, %({"session_id":"s","tool_input":{}}), InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "resolves the repo root from the payload cwd when no override is given" do
      code, stdout = invoke(:pre, pre_json("src/app.cr", cwd: Dir.current, session_id: nil), InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "falls back to the process directory when the payload has no cwd" do
      code, stdout = invoke(:pre, pre_json("src/app.cr", cwd: nil, session_id: nil), InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing when no repo root can be resolved" do
      input = pre_json("src/app.cr", cwd: File.tempname("agent-apropos-norepo"))
      code, stdout = invoke(:pre, input, InMemoryFS.new, override: nil)
      code.should eq(0)
      stdout.should be_empty
    end

    it "uses an existing index and emits nothing when the source doc is unreadable" do
      index = AgentApropos::Index.build([AgentApropos::Convention.parse("docs/conventions/a.md", A_DOC)])
      fs = InMemoryFS.new({"#{REPO}/.cache/agent-apropos/index.json" => index.to_document})
      code, stdout = invoke(:pre, pre_json("src/app.cr", session_id: nil), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "summarizes matched rules that exceed the character cap" do
      big = "First paragraph.\n\n" + ("x" * 11_000)
      fs = InMemoryFS.new({A_PATH => "---\npaths: [\"src/**\"]\n---\n#{big}\n"})
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain("summarized to fit")
      stdout.should contain("First paragraph.")
      stdout.should contain("Read the full rule in docs/conventions/a.md")
    end

    it "records the triggering file and matched patterns as the cause" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, pre_json("src/app.cr"), fs, tool: "claude")
      written = fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
      written.should contain(%("event": "PreToolUse"))
      written.should contain(%("file": "src/app.cr"))
      written.should contain(%("src/**"))
    end

    it "still injects when the cache is unwritable and dedup is unavailable" do
      fs = ReadOnlyFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("src/app.cr", session_id: nil), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/index.json").should be_false
    end

    it "fails open and stays silent on an internal error" do
      fs = ExplodingFS.new
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.written.should be_empty
    end

    it "logs the failure to a per-invocation file under the override root when verbose" do
      fs = ExplodingFS.new
      code, _ = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      path, content = fs.written.first
      Path[path].parent.to_posix.to_s.should eq("#{REPO}/.cache/agent-apropos/logs")
      Path[path].extension.should eq(".log")
      content.should contain("agent-apropos hook:")
    end

    it "gives each invocation its own log file rather than overwriting the last" do
      fs = ExplodingFS.new
      2.times { invoke(:pre, pre_json("src/app.cr"), fs, verbose: true) }
      fs.written.size.should eq(2)
      fs.written.map(&.first).uniq!.size.should eq(2)
    end

    it "logs to the process directory when verbose with no override" do
      fs = ExplodingFS.new
      invoke(:pre, pre_json("src/app.cr", cwd: Dir.current), fs, override: nil, verbose: true)
      Path[fs.written.first.first].parent.should eq(
        Path[Dir.current].join(".cache", "agent-apropos", "logs"))
    end

    it "prunes a log file older than the retention window and keeps a newer one" do
      stale = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 8.days).to_unix}-aaaaaa.log"
      fresh = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 1.day).to_unix}-bbbbbb.log"
      fs = ExplodingFS.new(entries: [stale, fresh])
      invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      fs.removed.should eq([stale])
    end

    it "keeps a log file exactly 7 days old, pinning the retention window's literal length" do
      boundary = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 7.days).to_unix}-aaaaaa.log"
      just_over = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 7.days - 1.second).to_unix}-bbbbbb.log"
      fs = ExplodingFS.new(entries: [boundary, just_over])
      invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      fs.removed.should eq([just_over])
    end

    it "keeps the log directory bounded by count, dropping the oldest entries" do
      entries = (1..(AgentApropos::Hook::LOG_MAX_FILES + 5)).map do |index|
        "#{REPO}/.cache/agent-apropos/logs/#{(NOW - index.minutes).to_unix}-#{index}.log"
      end
      fs = ExplodingFS.new(entries: entries)
      invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)

      fs.removed.size.should eq(5)
      fs.removed.should_not contain(entries.first)
      fs.removed.should contain(entries.last)
    end

    it "keeps exactly 200 log files and drops the 201st, pinning the count's literal value" do
      entries = (1..201).map do |index|
        "#{REPO}/.cache/agent-apropos/logs/#{(NOW - index.minutes).to_unix}-#{index}.log"
      end
      fs = ExplodingFS.new(entries: entries)
      invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      fs.removed.should eq([entries.last])
    end

    it "leaves a log-directory entry alone when its name carries no timestamp" do
      fs = ExplodingFS.new(entries: ["#{REPO}/.cache/agent-apropos/logs/notes.log"])
      invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      fs.removed.should be_empty
    end

    it "prunes nothing when not verbose, because nothing writes to the log directory" do
      stale = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 8.days).to_unix}-aaaaaa.log"
      fs = ExplodingFS.new(entries: [stale])
      invoke(:pre, pre_json("src/app.cr"), fs)
      fs.removed.should be_empty
    end

    it "still writes the diagnostic when pruning the log directory fails" do
      stale = "#{REPO}/.cache/agent-apropos/logs/#{(NOW - 8.days).to_unix}-aaaaaa.log"
      fs = ExplodingFS.new(entries: [stale], remove_raises: true)
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)

      code.should eq(0)
      stdout.should be_empty
      fs.written.size.should eq(1)
      fs.written.first.last.should contain("agent-apropos hook:")
    end

    it "swallows a logging failure (best-effort log)" do
      fs = ExplodingFS.new(write_raises: true)
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      stdout.should be_empty
    end
  end

  # R4 / AE2: an agent reports the file it is editing using the host's own path
  # syntax, which on Windows means a drive letter and backslashes. These drive
  # the hook itself with a natively-shaped absolute path — `Path#join` inserts
  # the host separator — so on Windows they are the backslash case and on POSIX
  # they are its equivalent, with no platform branch either way.
  describe "natively-shaped absolute edit paths" do
    it "matches a POSIX-globbed rule against a natively separated absolute path" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      native = Path[REPO].join("src", "app.cr").to_s
      code, stdout = invoke(:pre, pre_json(native), fs)

      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "rejects a natively separated absolute path outside the repo root" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      native = Path[OUTSIDE].join("src", "app.cr").to_s
      code, stdout = invoke(:pre, pre_json(native), fs)

      code.should eq(0)
      stdout.should be_empty
    end

    # The hook accepts either separator on the host that has two of them, so a
    # payload mixing them resolves the same as the fully native form. There is
    # no POSIX equivalent to drive end-to-end, so this one pins the conversion
    # `Hook#relativize` performs rather than the injection it feeds.
    it "resolves a mixed-separator path the same as the fully-backslashed form" do
      root = Path.windows("C:\\projects\\foo")
      %w[C:\\projects\\foo\\src\\bar.cr C:/projects/foo/src\\bar.cr].each do |raw|
        Path.windows(raw).expand(base: root).relative_to(root).to_posix.to_s
          .should eq("src/bar.cr")
      end
    end
  end

  describe ".post" do
    it "injects a repo-wide content-scoped rule when written content matches" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout = invoke(:post, write_json("lib/x.cr", "db.transaction do"), fs)

      code.should eq(0)
      stdout.should contain(%("hookEventName":"PostToolUse"))
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "appends a scope note naming the content pattern for a construct-scoped rule" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      _, stdout = invoke(:post, write_json("lib/x.cr", "db.transaction do"), fs)
      stdout.should contain(
        "Scope: this convention applies to every file where new code matches `\\\\btransaction\\\\b`"
      )
    end

    it "injects a path-and-content rule only when both match" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      invoke(:post, write_json("app/models/u.cr", "User.update_all(x: 1)"), fs)[1]
        .should contain("Convention (docs/conventions/models.md):")

      other = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      code, stdout = invoke(:post, write_json("scripts/one_off.cr", "User.update_all(x: 1)", nil), other)
      code.should eq(0)
      stdout.should be_empty
    end

    it "appends a scope note combining path and content for a path+content rule" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      _, stdout = invoke(:post, write_json("app/models/u.cr", "User.update_all(x: 1)"), fs)
      stdout.should contain(
        "Scope: this convention applies to every file whose path matches `app/**` " \
        "and where new code matches `\\\\bupdate_all\\\\b`"
      )
    end

    it "emits nothing when no content pattern matches" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      code, stdout = invoke(:post, write_json("lib/x.cr", "just some code", nil), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "reads the file from disk when the payload has no content field" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC, "#{REPO}/lib/x.cr" => "wrap in a transaction here"})
      input = %({"session_id":"s","tool_name":"Write","cwd":"#{REPO}","tool_input":{"file_path":"lib/x.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "emits nothing when there is neither content nor a file to read" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"tool_name":"Write","cwd":"#{REPO}","tool_input":{"file_path":"lib/gone.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches against every new_string of a batch edit" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","tool_name":"MultiEdit","cwd":"#{REPO}","tool_input":) +
              %({"file_path":"lib/x.cr","edits":[{"new_string":"noop"},{"new_string":"begin transaction"}]}})
      _, stdout = invoke(:post, input, fs)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end
  end

  describe ".pre (fired from a read tool)" do
    it "emits nothing for a read of a file a rule matches — reads never inject" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, read_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "does not deliver the session notice on a read" do
      code, stdout = invoke(:pre, read_json("docs/readme.md"), InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "records a convention doc the agent read as already injected, so no write re-injects it" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("docs/conventions/a.md"), fs)
      fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
        .should contain(%("path": "docs/conventions/a.md"))

      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain("agent-apropos is connected and running")
      stdout.should_not contain("Convention (docs/conventions/a.md):")
    end

    it "does not suppress a rule when the read target is the generated skill wrapper, not the source doc" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json(".claude/skills/a/SKILL.md"), fs)
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_false

      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")
    end

    it "writes no session state for a read that matches no convention doc" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, read_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_false
    end

    it "does not suppress a doc read from outside the repo root, which relativizes away" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("#{ELSEWHERE}/docs/conventions/a.md"), fs)
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_false
    end

    it "auto-detects the dialect, so a read is recognized without --tool" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("docs/conventions/a.md"), fs)
      fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
        .should contain(%("path": "docs/conventions/a.md"))
    end

    it "does not suppress a rule when only part of the doc was read (offset)" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, partial_read_json("docs/conventions/a.md", offset: 40), fs)
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_false

      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")
    end

    it "does not suppress a rule when only part of the doc was read (limit)" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, partial_read_json("docs/conventions/a.md", limit: 5), fs)
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/sessions/s.json").should be_false
    end

    it "suppresses from the post event too, which is where the read tools are wired" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:post, read_json("docs/conventions/a.md"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
        .should contain(%("event": "PostToolUse"))
    end

    it "falls back to auto-detection for an unrecognized --tool value" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, read_json("src/app.cr"), fs, tool: "nonexistent")
      code.should eq(0)
      stdout.should be_empty
    end
  end

  # The one-time, purely descriptive "agent-apropos is running" notice —
  # delivered on whichever of pre/post fires first for a session, regardless
  # of whether that particular edit matches any rule.
  describe "session-start notice" do
    it "fires on the first call even when no rule matches" do
      code, stdout = invoke(:pre, pre_json("docs/readme.md"), InMemoryFS.new)
      code.should eq(0)
      stdout.should contain("agent-apropos is connected and running")
    end

    it "is combined with a real match on the very first call" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      _, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      stdout.should contain("agent-apropos is connected and running")
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "does not repeat on a second call in the same session" do
      fs = InMemoryFS.new
      invoke(:pre, pre_json("docs/readme.md"), fs)
      code, stdout = invoke(:pre, pre_json("docs/other.md"), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "is claimed by whichever of pre/post fires first" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      pre_stdout = invoke(:pre, pre_json("docs/readme.md"), fs)[1]
      pre_stdout.should contain("agent-apropos is connected and running")

      code, post_stdout = invoke(:post, write_json("lib/x.cr", "just some code"), fs)
      code.should eq(0)
      post_stdout.should be_empty
    end

    it "waits for the first write — a read that precedes it claims nothing" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("src/app.cr"), fs)[1].should be_empty

      code, edit_stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      edit_stdout.should contain("agent-apropos is connected and running")
      edit_stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "is skipped when there is no session id to key it on" do
      code, stdout = invoke(:pre, pre_json("docs/readme.md", session_id: nil), InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    it "is skipped for a path-traversal session id, same as a nil one, and writes nothing outside the sessions dir" do
      fs = InMemoryFS.new
      code, stdout = invoke(:pre, pre_json("docs/readme.md", session_id: "../../../../tmp/PWNED"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.files.keys.each(&.should(start_with("#{REPO}/")))
    end

    it "stays skipped on a second call with the same traversal session id (never gets stuck re-firing)" do
      fs = InMemoryFS.new
      invoke(:pre, pre_json("docs/readme.md", session_id: "../../../../tmp/PWNED"), fs)

      code, stdout = invoke(:pre, pre_json("docs/other.md", session_id: "../../../../tmp/PWNED"), fs)
      code.should eq(0)
      stdout.should be_empty
    end
  end

  # Gemini CLI wires both `hook pre` and `hook post` onto its single
  # `AfterTool` event (its `BeforeTool` output schema cannot inject context —
  # see init.cr). Its `write_file`/`replace` tools use the exact same
  # `file_path`/`content`/`old_string`/`new_string` argument names Claude's
  # `Write`/`Edit` do, so this runtime needs no Gemini-specific code — these
  # cases lock that finding in against a regression.
  describe "Gemini CLI payload shapes (no tool_name gating)" do
    it "matches a path-scoped rule from a write_file AfterTool payload" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      input = %({"session_id":"s","hook_event_name":"AfterTool","tool_name":"write_file",) +
              %("cwd":"#{REPO}","tool_input":{"file_path":"src/app.cr","content":"puts 1"}})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "matches a content-scoped rule from a replace AfterTool payload" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","hook_event_name":"AfterTool","tool_name":"replace",) +
              %("cwd":"#{REPO}","tool_input":{"file_path":"lib/x.cr","old_string":"noop",) +
              %("new_string":"db.transaction do"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end
  end

  # GitHub Copilot CLI calls `agent-apropos hook pre`/`post` directly (see
  # init.cr's scaffold_copilot) — no bridge script — because Payload
  # understands its dialect (camelCase, toolArgs as a JSON-encoded string)
  # natively. Its postToolUse hook output schema has no envelope, though —
  # just a flat additionalContext key — unlike every other wired agent, so
  # these cases lock in that the reply shape differs only for a
  # Copilot-shaped payload, never for Claude/Gemini/OpenCode's.
  describe "Copilot CLI payload shape (flat additionalContext, no envelope)" do
    it "matches a path-scoped rule from an edit toolArgs payload and emits flat additionalContext" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      input = %({"sessionId":"s","toolName":"edit","cwd":"#{REPO}",) +
              %("toolArgs":"{\\"path\\":\\"#{REPO}/src/app.cr\\"}"})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should_not contain("hookSpecificOutput")
      JSON.parse(stdout)["additionalContext"].as_s.should contain("Convention (docs/conventions/a.md):")
    end

    it "emits nothing for Copilot's view tool, which its dialect marks a read" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      input = %({"sessionId":"s","toolName":"view","cwd":"#{REPO}",) +
              %("toolArgs":"{\\"path\\":\\"#{REPO}/src/app.cr\\"}"})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches a content-scoped rule from a create toolArgs payload's file_text" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"sessionId":"s","toolName":"create","cwd":"#{REPO}",) +
              %("toolArgs":"{\\"path\\":\\"#{REPO}/lib/x.cr\\",\\"file_text\\":\\"db.transaction do\\"}"})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
      stdout.should_not contain("hookSpecificOutput")
    end

    it "still emits the hookSpecificOutput envelope for a non-Copilot payload (no regression)" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("#{REPO}/src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain(%("hookSpecificOutput"))
      JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
        .should contain("Convention (docs/conventions/a.md):")
    end
  end

  # A CLI agent's own bookkeeping (e.g. Copilot's ~/.copilot/session-state/)
  # can live entirely outside the project — conventions are scoped to the
  # repo, so a match there would be meaningless noise at best and a leak of
  # repo-specific guidance into an unrelated file at worst.
  describe "removal detection" do
    it "covers AE8: reads no index and makes no git call for a command with no removal verb" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      git = FakeGit.new
      code, stdout = invoke(:pre, shell_json("echo hi"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
      git.removed_paths_called?.should be_false
      fs.files.has_key?("#{REPO}/.cache/agent-apropos/index.json").should be_false
    end

    it "injects nothing when a removal verb ran but git reports nothing missing" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      git = FakeGit.new(removed: [] of String)
      code, stdout = invoke(:pre, shell_json("rm scratch.txt"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
      git.removed_paths_called?.should be_true
    end

    it "injects the convention for a removed path and records a cause naming it" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      git = FakeGit.new(removed: ["src/app.cr"])
      code, stdout = invoke(:pre, shell_json("rm src/app.cr"), fs, git: git, tool: "claude")
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      written = fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
      written.should contain(%("file": "src/app.cr"))
      written.should contain(%("event": "PreToolUse"))
    end

    it "records PostToolUse, not PreToolUse, when the removal is detected from a post-event call" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      git = FakeGit.new(removed: ["src/app.cr"])
      invoke(:post, shell_json("rm src/app.cr"), fs, git: git)
      written = fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
      written.should contain(%("event": "PostToolUse"))
    end

    it "detects a removal verb from a Copilot-shaped bash payload too" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      git = FakeGit.new(removed: ["src/app.cr"])
      code, stdout = invoke(:post, copilot_shell_json("rm src/app.cr"), fs, git: git)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "detects a structural removal from a Codex apply_patch Delete File section" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      code, stdout = invoke(:post, apply_patch_delete_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    # A real captured Codex apply_patch Delete File section names the file by
    # its ABSOLUTE path (confirmed live — see spec/fixtures/hook_payloads/
    # codex_pre_tool_use_apply_patch_delete.json), unlike every other removal
    # source (a shell `rm` argument, or git status output), which is already
    # repo-relative. Missing this relativization silently dropped every
    # structural removal path this glob check ever saw, since an absolute
    # path never matches a repo-relative `paths:` pattern.
    it "still matches when the Delete File section names the file by its absolute path" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      code, stdout = invoke(:post, apply_patch_delete_json("#{REPO}/src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "delivers both a write match and a removal match from one apply_patch bundling an Add and a Delete" do
      fs = InMemoryFS.new({A_PATH => A_DOC, MODELS_PATH => "---\non: [removed]\npaths: [\"lib/**\"]\n---\n# M\n\nBody.\n"})
      code, stdout = invoke(:post, apply_patch_add_and_delete_json("src/new.cr", "content", "lib/old.cr"), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Convention (docs/conventions/models.md):")
    end

    it "says the convention fired because the path is missing, not that this command removed it" do
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
      git = FakeGit.new(removed: ["src/app.cr"])
      _, stdout = invoke(:pre, shell_json("rm src/app.cr"), fs, git: git)
      stdout.should contain("is now missing from the working tree")
      stdout.should_not contain("this convention applies to every file")
    end

    it "covers AE7: does not re-inject a doc already injected for a write earlier in the session" do
      fs = InMemoryFS.new({A_PATH => "---\non: [write, removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"})
      invoke(:pre, pre_json("src/app.cr"), fs)[1].should contain("Convention (docs/conventions/a.md):")

      git = FakeGit.new(removed: ["src/other.cr"])
      code, stdout = invoke(:pre, shell_json("rm src/other.cr"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches a removal-triggered contents rule against the resolved blob" do
      fs = InMemoryFS.new({DB_PATH => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nBody.\n"})
      git = FakeGit.new(removed: ["lib/x.cr"], blobs: {":lib/x.cr" => "db.transaction do"})
      code, stdout = invoke(:pre, shell_json("rm lib/x.cr"), fs, git: git)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "stays silent for a contents rule whose blob cannot be resolved, while a paths-only doc still fires" do
      fs = InMemoryFS.new({
        A_PATH  => "---\non: [removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n",
        DB_PATH => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nBody.\n",
      })
      git = FakeGit.new(removed: ["src/app.cr"])
      code, stdout = invoke(:pre, shell_json("rm src/app.cr"), fs, git: git)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should_not contain("Convention (docs/conventions/db.md):")
    end

    it "injects each matching doc exactly once for several paths removed in one call" do
      fs = InMemoryFS.new({A_PATH => "---\non: [removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"})
      git = FakeGit.new(removed: ["src/one.cr", "src/two.cr"])
      _, stdout = invoke(:pre, shell_json("rm src/one.cr src/two.cr"), fs, git: git)
      stdout.scan("Convention (docs/conventions/a.md):").size.should eq(1)
    end

    it "ignores a removed path outside the repo root" do
      fs = InMemoryFS.new({A_PATH => "---\non: [removed]\npaths: [\"**\"]\n---\n# A\n\nBody of A.\n"})
      git = FakeGit.new(removed: ["../outside.txt"])
      code, stdout = invoke(:pre, shell_json("rm ../outside.txt"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
    end

    it "resolves content for paths up to the bound and still injects beyond it" do
      fs = InMemoryFS.new({DB_PATH => "---\non: [removed]\ncontents: ['\\bx\\b']\n---\n# DB\n\nBody.\n"})
      bound = AgentApropos::Hook::REMOVAL_CONTENT_RESOLUTION_BOUND
      removed = (1..(bound + 1)).map { |i| "src/f#{i}.cr" }
      blobs = removed.each_with_index.to_h { |path, i| {":#{path}", i < bound ? "has x here" : "no match here"} }
      git = FakeGit.new(removed: removed, blobs: blobs)
      code, _ = invoke(:pre, shell_json("rm src/*.cr"), fs, git: git)
      code.should eq(0)
      git.blob_requests.size.should eq(bound)
    end

    it "still treats a read tool as a read, not a removal" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      git = FakeGit.new(removed: ["src/app.cr"])
      code, stdout = invoke(:pre, read_json("src/app.cr"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
      git.removed_paths_called?.should be_false
    end

    it "fails open and stays silent when git raises during removal detection" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      git = FakeGit.new(removed_paths_raises: true)
      code, stdout = invoke(:pre, shell_json("rm src/app.cr"), fs, git: git)
      code.should eq(0)
      stdout.should be_empty
    end

    it "falls back to the HEAD blob when the index has nothing for the removed path" do
      fs = InMemoryFS.new({DB_PATH => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nBody.\n"})
      git = FakeGit.new(removed: ["lib/x.cr"], blobs: {"HEAD:lib/x.cr" => "db.transaction do"})
      code, stdout = invoke(:pre, shell_json("rm lib/x.cr"), fs, git: git)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "resolves removed content at most once per path even when several docs need it" do
      fs = InMemoryFS.new({
        DB_PATH     => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nBody.\n",
        MODELS_PATH => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# Models\n\nBody.\n",
      })
      git = FakeGit.new(removed: ["lib/x.cr"], blobs: {":lib/x.cr" => "db.transaction do"})
      invoke(:pre, shell_json("rm lib/x.cr"), fs, git: git)
      git.blob_requests.size.should eq(1)
    end

    it "records every matching doc, not just the first, when several match one removal" do
      fs = InMemoryFS.new({
        A_PATH  => A_REMOVED_DOC,
        DB_PATH => "---\non: [removed]\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nBody.\n",
      })
      git = FakeGit.new(removed: ["src/app.cr"], blobs: {":src/app.cr" => "db.transaction do"})
      code, stdout = invoke(:pre, shell_json("rm src/app.cr"), fs, git: git)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Convention (docs/conventions/db.md):")
      written = fs.files["#{REPO}/.cache/agent-apropos/sessions/s.json"]
      written.should contain(%("docs/conventions/a.md"))
      written.should contain(%("docs/conventions/db.md"))
    end

    it "threads allow_outside through to convention loading for a removal" do
      repo = SpecPaths.absolute("repo-outside-removal")
      outside_dir = SpecPaths.absolute("shared-conventions-removal")
      doc = "---\non: [removed]\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"
      fs = InMemoryFS.new({
        "#{repo}/agent-apropos.yml"                  => "conventions_dir: '#{outside_dir}'\n",
        "#{outside_dir}/a.md"                        => doc,
        "#{repo}/../shared-conventions-removal/a.md" => doc,
      })
      git = FakeGit.new(removed: ["src/app.cr"])
      code, stdout = invoke(:pre, shell_json("rm src/app.cr", cwd: repo), fs,
        override: repo, git: git, allow_outside: true)
      code.should eq(0)
      stdout.should contain("Convention (")
    end

    it "recognizes every configured removal verb" do
      %w[rm mv unlink rmdir trash shred truncate find].each do |verb|
        fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC})
        git = FakeGit.new(removed: ["src/app.cr"])
        _, stdout = invoke(:pre, shell_json("#{verb} src/app.cr"), fs, git: git)
        stdout.should contain("Convention (docs/conventions/a.md):")
      end
    end

    it "resolves content for exactly the paths before the bound, not merely the one at it" do
      fs = InMemoryFS.new({DB_PATH => "---\non: [removed]\ncontents: ['\\bx\\b']\n---\n# DB\n\nBody.\n"})
      bound = AgentApropos::Hook::REMOVAL_CONTENT_RESOLUTION_BOUND
      removed = (1..(bound + 2)).map { |i| "src/f#{i}.cr" }
      blobs = removed.to_h { |path| {":#{path}", "no match"} }
      git = FakeGit.new(removed: removed, blobs: blobs)
      invoke(:pre, shell_json("rm src/*.cr"), fs, git: git)
      git.blob_requests.map(&.last).should eq(removed.first(bound))
    end

    it "resolves content for exactly 20 removed paths, pinning the bound's literal value" do
      fs = InMemoryFS.new({DB_PATH => "---\non: [removed]\ncontents: ['\\bx\\b']\n---\n# DB\n\nBody.\n"})
      removed = (1..22).map { |i| "src/f#{i}.cr" }
      blobs = removed.to_h { |path| {":#{path}", "no match"} }
      git = FakeGit.new(removed: removed, blobs: blobs)
      invoke(:pre, shell_json("rm src/*.cr"), fs, git: git)
      git.blob_requests.map(&.last).should eq(removed.first(20))
    end
  end

  describe "text and boundary pinning" do
    it "emits the session notice's exact text, with nothing appended when there is no match" do
      code, stdout = invoke(:pre, pre_json("docs/readme.md"), InMemoryFS.new)
      code.should eq(0)
      JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s.should eq(
        "agent-apropos is connected and running. It compiles this repo's coding " \
        "conventions into a trigger index and automatically injects the ones " \
        "relevant to whatever file or construct you're touching into your " \
        "context, as you read and edit files."
      )
    end

    it "renders the exact write-scope note for a doc declaring both paths and contents" do
      fs = InMemoryFS.new({MODELS_PATH => MODELS_DOC})
      _, stdout = invoke(:pre, write_json("app/models/u.cr", "User.update_all(x: 1)"), fs)
      context = JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
      context.should contain(
        "\n\n_Scope: this convention applies to every file whose path matches `app/**` " \
        "and where new code matches `\\bupdate_all\\b` " \
        "— not only the file that triggered it just now. Apply it to any other " \
        "matching file you touch this session; it will not be shown again._"
      )
    end

    it "renders the exact removal-scope note for a doc declaring both paths and contents" do
      fs = InMemoryFS.new({
        MODELS_PATH => "---\non: [removed]\npaths: [\"app/**\"]\ncontents: ['\\bx\\b']\n---\n# Models\n\nBody.\n",
      })
      git = FakeGit.new(removed: ["app/models/u.cr"], blobs: {":app/models/u.cr" => "x"})
      _, stdout = invoke(:pre, shell_json("rm app/models/u.cr"), fs, git: git)
      context = JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
      context.should contain(
        "\n\n_Scope: this convention fired because a tracked file whose path matches `app/**` " \
        "and whose last tracked contents matched `\\bx\\b` is now missing from the " \
        "working tree — not necessarily because this command removed it. Apply it to any " \
        "other matching removal this session; it will not be shown again._"
      )
    end

    it "joins several matched patterns with \" or \", not concatenating them bare" do
      fs = InMemoryFS.new({A_PATH => "---\npaths: [\"src/**\", \"lib/**\"]\n---\n# A\n\nBody of A.\n"})
      _, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      stdout.should contain("matches `src/**` or `lib/**`")
    end

    it "does not append an empty context to a lone session notice" do
      code, stdout = invoke(:pre, pre_json("docs/readme.md"), InMemoryFS.new)
      code.should eq(0)
      JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s.should_not end_with("\n\n")
    end

    it "does not treat the repo root itself (relativizing to \".\") as outside the root" do
      fs = InMemoryFS.new({A_PATH => "---\npaths: [\"**\"]\n---\n# A\n\nBody of A.\n"})
      code, stdout = invoke(:pre, pre_json(REPO), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "rejects a path that relativizes to exactly \"..\", not merely one starting with it" do
      fs = InMemoryFS.new({A_PATH => "---\npaths: [\"**\"]\n---\n# A\n\nBody of A.\n"})
      code, stdout = invoke(:pre, pre_json(Path[REPO].parent.to_s), fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "terminates the emitted JSON with a trailing newline" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      _, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      stdout.should end_with("}}\n")
    end

    it "reuses a valid cached index instead of rebuilding it from disk" do
      cached = AgentApropos::Index.build([AgentApropos::Convention.parse("docs/conventions/a.md", A_DOC)])
      fs = InMemoryFS.new({
        "#{REPO}/.cache/agent-apropos/index.json" => cached.to_document,
        A_PATH                                    => A_DOC,
        "#{REPO}/docs/conventions/b.md"           => "---\npaths: [\"src/**\"]\n---\n# B\n\nBody of B.\n",
      })
      _, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should_not contain("Convention (docs/conventions/b.md):")
    end

    it "prunes a stale session file as part of handling a call" do
      stale = %({"updated_at": #{(NOW - 8.days).to_unix}, "injected": [], "notified": false})
      fs = InMemoryFS.new({A_PATH => A_DOC, "#{REPO}/.cache/agent-apropos/sessions/old.json" => stale})
      invoke(:pre, pre_json("src/app.cr", session_id: nil), fs)
      fs.removed.should contain("#{REPO}/.cache/agent-apropos/sessions/old.json")
    end

    it "prunes a stale session file as part of handling a removal" do
      stale = %({"updated_at": #{(NOW - 8.days).to_unix}, "injected": [], "notified": false})
      fs = InMemoryFS.new({A_PATH => A_REMOVED_DOC, "#{REPO}/.cache/agent-apropos/sessions/old.json" => stale})
      git = FakeGit.new(removed: ["src/app.cr"])
      invoke(:pre, shell_json("rm src/app.cr", session_id: nil), fs, git: git)
      fs.removed.should contain("#{REPO}/.cache/agent-apropos/sessions/old.json")
    end
  end

  describe "files outside the repo root" do
    it "emits nothing for a pathless content rule matching a write outside the repo root" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = write_json("#{OUTSIDE}/.copilot/session-state/x/plan.md", "start a transaction")
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing for a rule matching an edit outside the repo root" do
      code, stdout = invoke(:pre, pre_json("#{OUTSIDE}/passwd"), InMemoryFS.new)
      code.should eq(0)
      stdout.should be_empty
    end

    # `src/**` matches this string literally (`File.match?` doesn't collapse
    # `..` either), so a naive "does the relativized path start with `../`"
    # check would miss the embedded traversal and let a path rule fire for
    # a path that actually resolves to /etc/passwd, well outside the repo.
    it "emits nothing for a rule matching a path with an embedded traversal" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("src/../../../../etc/passwd"), fs)
      code.should eq(0)
      stdout.should be_empty
    end
  end
end
