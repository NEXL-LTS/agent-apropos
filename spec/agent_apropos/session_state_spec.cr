require "../spec_helper"

private ROOT = Path["/repo"]
private NOW  = Time.utc(2026, 7, 16, 12, 0, 0)

private def session_path(id : String) : String
  "/repo/.cache/agent-apropos/sessions/#{id}.json"
end

private def cause(file : String = "src/app.cr", patterns : Array(String) = ["src/**"]) : AgentApropos::SessionState::Cause
  AgentApropos::SessionState::Cause.new(layer: 2, event: "PreToolUse", file: file, matched_patterns: patterns)
end

# A filesystem whose glob returns paths that read? cannot resolve — models a
# session file vanishing between listing and reading (the prune race guard).
private class PhantomFS < AgentApropos::Filesystem
  def initialize(@paths : Array(String))
  end

  def glob(base : Path, pattern : String) : Array(String)
    @paths
  end

  def read(path : String) : String
    ""
  end

  def read?(path : String) : String?
    nil
  end

  def write(path : String, content : String) : Nil
  end

  def append(path : String, content : String) : Nil
  end

  def remove(path : String) : Nil
    raise "prune must not remove a file it could not read"
  end

  def exists?(path : String) : Bool
    false
  end

  def symlink(target : String, link_path : String) : Nil
  end
end

describe AgentApropos::SessionState do
  describe ".load" do
    it "is empty when there is no session id" do
      AgentApropos::SessionState.load(ROOT, InMemoryFS.new, nil).injected.should be_empty
    end

    it "is empty when the session file is absent" do
      AgentApropos::SessionState.load(ROOT, InMemoryFS.new, "s").injected.should be_empty
    end

    it "reads back a persisted injected set" do
      fs = InMemoryFS.new
      state = AgentApropos::SessionState.new
      state.add("docs/conventions/a.md", cause(file: "src/app.cr"))
      state.save(ROOT, fs, "s", NOW)

      loaded = AgentApropos::SessionState.load(ROOT, fs, "s")
      loaded.injected?("docs/conventions/a.md").should be_true
    end

    it "treats a corrupt session file as empty (fail open)" do
      fs = InMemoryFS.new({session_path("s") => "{broken"})
      AgentApropos::SessionState.load(ROOT, fs, "s").injected.should be_empty
    end

    it "treats an old flat-string-array session file as empty (fail open)" do
      old_format = %({"updated_at":#{NOW.to_unix},"injected":["a.md"],"notified":false})
      fs = InMemoryFS.new({session_path("s") => old_format})
      AgentApropos::SessionState.load(ROOT, fs, "s").injected.should be_empty
    end

    it "defaults notified? to false when absent (older session files)" do
      AgentApropos::SessionState.load(ROOT, InMemoryFS.new, "s").notified?.should be_false
    end

    it "round-trips a persisted notified flag" do
      fs = InMemoryFS.new
      state = AgentApropos::SessionState.new
      state.notify!
      state.save(ROOT, fs, "s", NOW)

      AgentApropos::SessionState.load(ROOT, fs, "s").notified?.should be_true
    end
  end

  describe "#notify!" do
    it "marks the state notified" do
      state = AgentApropos::SessionState.new
      state.notified?.should be_false
      state.notify!
      state.notified?.should be_true
    end
  end

  describe "#save" do
    it "writes a pretty-printed, timestamped, sorted document" do
      fs = InMemoryFS.new
      state = AgentApropos::SessionState.new
      state.add("z.md", cause(file: "src/z.cr", patterns: ["src/z.cr"]))
      state.add("a.md", cause(file: "src/a.cr", patterns: ["src/*.cr"]))
      state.save(ROOT, fs, "s", NOW)

      written = fs.files[session_path("s")]
      written.should eq(<<-JSON)
        {
          "updated_at": #{NOW.to_unix},
          "injected": [
            {
              "path": "a.md",
              "cause": {
                "layer": 2,
                "event": "PreToolUse",
                "file": "src/a.cr",
                "matched_patterns": [
                  "src/*.cr"
                ]
              }
            },
            {
              "path": "z.md",
              "cause": {
                "layer": 2,
                "event": "PreToolUse",
                "file": "src/z.cr",
                "matched_patterns": [
                  "src/z.cr"
                ]
              }
            }
          ],
          "notified": false
        }\n
        JSON
    end

    it "keeps the first cause when the same rule is added twice for the same file" do
      fs = InMemoryFS.new
      state = AgentApropos::SessionState.new
      state.add("a.md", cause(file: "src/app.cr", patterns: ["first"]))
      state.add("a.md", cause(file: "src/app.cr", patterns: ["second"]))
      state.save(ROOT, fs, "s", NOW)

      written = fs.files[session_path("s")]
      written.should contain(%("first"))
      written.should_not contain(%("second"))
    end

    it "records the same rule only once per session, regardless of which file triggered it" do
      fs = InMemoryFS.new
      state = AgentApropos::SessionState.new
      state.add("a.md", cause(file: "src/first.cr"))
      state.add("a.md", cause(file: "src/second.cr"))
      state.save(ROOT, fs, "s", NOW)

      loaded = AgentApropos::SessionState.load(ROOT, fs, "s")
      loaded.injected?("a.md").should be_true
      loaded.injected.size.should eq(1)

      written = fs.files[session_path("s")]
      written.should contain(%("file": "src/first.cr"))
      written.should_not contain(%("file": "src/second.cr"))
    end

    it "is a no-op without a session id" do
      fs = InMemoryFS.new
      AgentApropos::SessionState.new.save(ROOT, fs, nil, NOW)
      fs.files.should be_empty
    end
  end

  describe ".prune" do
    it "removes session files older than the max age and keeps fresh ones" do
      injection = AgentApropos::SessionState::Injection.new("a.md", cause)
      old = AgentApropos::SessionState::Document.new((NOW - 8.days).to_unix, [injection])
      fresh = AgentApropos::SessionState::Document.new((NOW - 1.day).to_unix, [injection])
      fs = InMemoryFS.new({
        session_path("old")   => old.to_json,
        session_path("fresh") => fresh.to_json,
      })

      AgentApropos::SessionState.prune(ROOT, fs, NOW)

      fs.removed.should eq([session_path("old")])
      fs.files.has_key?(session_path("fresh")).should be_true
    end

    it "ages out an old-format (flat string array) session file on schedule" do
      legacy = %({"updated_at":#{(NOW - 8.days).to_unix},"injected":["a.md"],"notified":false})
      fs = InMemoryFS.new({session_path("legacy") => legacy})

      AgentApropos::SessionState.prune(ROOT, fs, NOW)

      fs.removed.should eq([session_path("legacy")])
    end

    it "skips a session file that cannot be read (listing race)" do
      AgentApropos::SessionState.prune(ROOT, PhantomFS.new([session_path("gone")]), NOW)
    end

    it "skips a corrupt session file rather than removing it" do
      fs = InMemoryFS.new({session_path("bad") => "{broken"})
      AgentApropos::SessionState.prune(ROOT, fs, NOW)
      fs.removed.should be_empty
    end
  end
end
