require "../spec_helper"

private NOW = Time.utc(2026, 7, 16, 12, 0, 0)

private A_PATH      = "/repo/docs/conventions/a.md"
private DB_PATH     = "/repo/docs/conventions/db.md"
private MODELS_PATH = "/repo/docs/conventions/models.md"

private A_DOC      = "---\npaths: [\"src/**\"]\n---\n# A\n\nBody of A.\n"
private DB_DOC     = "---\ncontents: ['\\btransaction\\b']\n---\n# DB\n\nUse transactions carefully.\n"
private MODELS_DOC = "---\npaths: [\"app/**\"]\ncontents: ['\\bupdate_all\\b']\n---\n# Models\n\nAvoid update_all.\n"

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
  getter appended = [] of {String, String}

  def initialize(@append_raises : Bool = false, @raise_reads : Bool = true)
  end

  def glob(base : Path, pattern : String) : Array(String)
    [] of String
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
  end

  def append(path : String, content : String) : Nil
    raise "log boom" if @append_raises
    @appended << {path, content}
  end

  def remove(path : String) : Nil
  end

  def exists?(path : String) : Bool
    false
  end

  def symlink(target : String, link_path : String) : Nil
  end
end

private def pre_json(file_path : String, session_id : String? = "s", cwd : String? = "/repo") : String
  {session_id: session_id, tool_name: "Edit", cwd: cwd, tool_input: {file_path: file_path}}.to_json
end

private def write_json(file_path : String, content : String, session_id : String? = "s") : String
  {session_id: session_id, tool_name: "Write", cwd: "/repo",
   tool_input: {file_path: file_path, content: content}}.to_json
end

private def read_json(file_path : String, session_id : String? = "s", cwd : String? = "/repo") : String
  {session_id: session_id, tool_name: "Read", cwd: cwd, tool_input: {file_path: file_path}}.to_json
end

private def invoke(event : Symbol, input : String, fs : AgentApropos::Filesystem,
                   override : String? = "/repo", now : Time = NOW, verbose : Bool = false,
                   tool : String? = nil) : {Int32, String}
  stdout = IO::Memory.new
  reader = IO::Memory.new(input)
  code =
    if event == :pre
      AgentApropos::Hook.pre(reader, stdout, fs, now, override, verbose, tool)
    else
      AgentApropos::Hook.post(reader, stdout, fs, now, override, verbose, tool)
    end
  {code, stdout.to_s}
end

describe AgentApropos::Hook do
  describe ".pre" do
    it "injects a matching path-scoped rule before the edit" do
      fs = InMemoryFS.new({A_PATH => A_DOC, DB_PATH => DB_DOC})
      code, stdout = invoke(:pre, pre_json("/repo/src/app.cr"), fs)

      code.should eq(0)
      stdout.should contain(%("hookEventName":"PreToolUse"))
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should contain("Body of A.")
      fs.files.has_key?("/repo/.cache/agent-apropos/index.json").should be_true
      fs.files.has_key?("/repo/.cache/agent-apropos/sessions/s.json").should be_true
    end

    it "still injects a valid rule when a sibling doc is malformed and the index cache is cold" do
      fs = InMemoryFS.new({
        A_PATH                          => A_DOC,
        "/repo/docs/conventions/bad.md" => "---\npaths: not-a-list\n---\nBad\n",
      })
      code, stdout = invoke(:pre, pre_json("/repo/src/app.cr"), fs)

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
      fs = InMemoryFS.new({"/repo/.cache/agent-apropos/index.json" => index.to_document})
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
      written = fs.files["/repo/.cache/agent-apropos/sessions/s.json"]
      written.should contain(%("event": "PreToolUse"))
      written.should contain(%("file": "src/app.cr"))
      written.should contain(%("src/**"))
    end

    it "still injects when the cache is unwritable and dedup is unavailable" do
      fs = ReadOnlyFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("src/app.cr", session_id: nil), fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      fs.files.has_key?("/repo/.cache/agent-apropos/index.json").should be_false
    end

    it "fails open and stays silent on an internal error" do
      fs = ExplodingFS.new
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.appended.should be_empty
    end

    it "logs the failure under the override root when verbose" do
      fs = ExplodingFS.new
      code, _ = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      fs.appended.map(&.first).should eq(["/repo/.cache/agent-apropos/log"])
    end

    it "logs to the process directory when verbose with no override" do
      fs = ExplodingFS.new
      invoke(:pre, pre_json("src/app.cr", cwd: Dir.current), fs, override: nil, verbose: true)
      fs.appended.first.first.should eq(File.join(Dir.current, ".cache", "agent-apropos", "log"))
    end

    it "swallows a logging failure (best-effort log)" do
      fs = ExplodingFS.new(append_raises: true)
      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs, verbose: true)
      code.should eq(0)
      stdout.should be_empty
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
      fs = InMemoryFS.new({DB_PATH => DB_DOC, "/repo/lib/x.cr" => "wrap in a transaction here"})
      input = %({"session_id":"s","tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"lib/x.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
    end

    it "emits nothing when there is neither content nor a file to read" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"tool_name":"Write","cwd":"/repo","tool_input":{"file_path":"lib/gone.cr"}})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches against every new_string of a batch edit" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","tool_name":"MultiEdit","cwd":"/repo","tool_input":) +
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
      fs.files["/repo/.cache/agent-apropos/sessions/s.json"]
        .should contain(%("path": "docs/conventions/a.md"))

      code, stdout = invoke(:pre, pre_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should contain("agent-apropos is connected and running")
      stdout.should_not contain("Convention (docs/conventions/a.md):")
    end

    it "does not suppress a rule when the read target is the generated skill wrapper, not the source doc" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json(".claude/skills/a/SKILL.md"), fs)
      fs.files.has_key?("/repo/.cache/agent-apropos/sessions/s.json").should be_false

      invoke(:pre, pre_json("src/app.cr"), fs)[1]
        .should contain("Convention (docs/conventions/a.md):")
    end

    it "writes no session state for a read that matches no convention doc" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, read_json("src/app.cr"), fs)
      code.should eq(0)
      stdout.should be_empty
      fs.files.has_key?("/repo/.cache/agent-apropos/sessions/s.json").should be_false
    end

    it "does not suppress a doc read from outside the repo root, which relativizes away" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("/elsewhere/docs/conventions/a.md"), fs)
      fs.files.has_key?("/repo/.cache/agent-apropos/sessions/s.json").should be_false
    end

    it "auto-detects the dialect, so a read is recognized without --tool" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      invoke(:pre, read_json("docs/conventions/a.md"), fs)
      fs.files["/repo/.cache/agent-apropos/sessions/s.json"]
        .should contain(%("path": "docs/conventions/a.md"))
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
      fs.files.keys.each(&.should(start_with("/repo/")))
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
              %("cwd":"/repo","tool_input":{"file_path":"src/app.cr","content":"puts 1"}})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
    end

    it "matches a content-scoped rule from a replace AfterTool payload" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"session_id":"s","hook_event_name":"AfterTool","tool_name":"replace",) +
              %("cwd":"/repo","tool_input":{"file_path":"lib/x.cr","old_string":"noop",) +
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
      input = %({"sessionId":"s","toolName":"edit","cwd":"/repo",) +
              %("toolArgs":"{\\"path\\":\\"/repo/src/app.cr\\"}"})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/a.md):")
      stdout.should_not contain("hookSpecificOutput")
      JSON.parse(stdout)["additionalContext"].as_s.should contain("Convention (docs/conventions/a.md):")
    end

    it "emits nothing for Copilot's view tool, which its dialect marks a read" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      input = %({"sessionId":"s","toolName":"view","cwd":"/repo",) +
              %("toolArgs":"{\\"path\\":\\"/repo/src/app.cr\\"}"})
      code, stdout = invoke(:pre, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "matches a content-scoped rule from a create toolArgs payload's file_text" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = %({"sessionId":"s","toolName":"create","cwd":"/repo",) +
              %("toolArgs":"{\\"path\\":\\"/repo/lib/x.cr\\",\\"file_text\\":\\"db.transaction do\\"}"})
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should contain("Convention (docs/conventions/db.md):")
      stdout.should_not contain("hookSpecificOutput")
    end

    it "still emits the hookSpecificOutput envelope for a non-Copilot payload (no regression)" do
      fs = InMemoryFS.new({A_PATH => A_DOC})
      code, stdout = invoke(:pre, pre_json("/repo/src/app.cr"), fs)
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
  describe "files outside the repo root" do
    it "emits nothing for a pathless content rule matching a write outside the repo root" do
      fs = InMemoryFS.new({DB_PATH => DB_DOC})
      input = write_json("/home/user/.copilot/session-state/x/plan.md", "start a transaction")
      code, stdout = invoke(:post, input, fs)
      code.should eq(0)
      stdout.should be_empty
    end

    it "emits nothing for a rule matching an edit outside the repo root" do
      code, stdout = invoke(:pre, pre_json("/etc/passwd"), InMemoryFS.new)
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
