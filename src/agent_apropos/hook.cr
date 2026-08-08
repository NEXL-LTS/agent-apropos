require "json"
require "./frontmatter"
require "./conventions"
require "./index"
require "./matcher"
require "./session_state"
require "./filesystem"
require "./repo_root"
require "./rendering"
require "./hooks/payload"
require "./agents"

module AgentApropos
  module Hook
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]
    LOG_RELATIVE   = Path[".cache", "agent-apropos", "log"]

    SESSION_NOTICE = "agent-apropos is connected and running. It compiles " \
                     "this repo's coding conventions into a trigger index " \
                     "and automatically injects the ones relevant to " \
                     "whatever file or construct you're touching into your " \
                     "context, as you read and edit files."

    def pre(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
            override_root : String? = nil, verbose : Bool = false, tool : String? = nil,
            allow_outside : Bool = false) : Int32
      deliver(:pre, io_in, stdout, fs, now, override_root, verbose, tool, allow_outside)
    end

    def post(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
             override_root : String? = nil, verbose : Bool = false, tool : String? = nil,
             allow_outside : Bool = false) : Int32
      deliver(:post, io_in, stdout, fs, now, override_root, verbose, tool, allow_outside)
    end

    private def deliver(event : Symbol, io_in : IO, stdout : IO, fs : Filesystem,
                        now : Time, override_root : String?, verbose : Bool, tool : String?,
                        allow_outside : Bool) : Int32
      payload = Payload.parse(io_in.gets_to_end)
      root = resolve_root(override_root, payload)
      execute(event, payload, root, stdout, fs, now, tool, allow_outside) if payload && root
      0
    rescue ex
      log_failure(fs, override_root, verbose, ex)
      0
    end

    private def execute(event : Symbol, payload : Payload, root : Path,
                        stdout : IO, fs : Filesystem, now : Time, tool : String?, allow_outside : Bool) : Nil
      in_root = payload.file_edits.compact_map { |edit| relative_edit(root, edit) }
      return if in_root.empty?

      index = load_or_build_index(root, fs, allow_outside)
      session_id = SessionState.key?(payload.session_id)
      SessionState.prune(root, fs, now)
      state = SessionState.load(root, fs, session_id)
      name = event_name(event)

      agent = Agents.find(tool) || Agents.detect(payload)
      return suppress(index, state, root, fs, session_id, now, name, in_root) if agent.read?(payload)

      pending = index.docs.reject { |entry| state.injected?(entry.path) }
      matches = dedup_by_entry(in_root.flat_map { |relative, edit| matches_for(pending, root, fs, relative, edit) })

      notice = session_notice(state, session_id)
      combined = combine(notice, build_context(root, fs, matches.map(&.entry)))
      return if combined.empty?

      matches.each do |match|
        state.add(match.entry.path, SessionState::Cause.new(name, match.relative, match.patterns))
      end
      state.notify! if notice
      state.save(root, fs, session_id, now)
      emit(stdout, name, combined, payload.copilot?)
    end

    private def suppress(index : Index, state : SessionState, root : Path, fs : Filesystem,
                         session_id : String?, now : Time, name : String,
                         in_root : Array({String, Payload::FileEdit})) : Nil
      read = in_root.map { |relative, _| relative }.to_set
      recorded = index.docs.select { |entry| read.includes?(entry.path) }
      return if recorded.empty?

      recorded.each do |entry|
        state.add(entry.path, SessionState::Cause.new(name, entry.path, [] of String))
      end
      state.save(root, fs, session_id, now)
    end

    private def relative_edit(root : Path, edit : Payload::FileEdit) : {String, Payload::FileEdit}?
      relative = relativize(root, edit.path)
      return nil if outside_root?(relative)
      {relative, edit}
    end

    private record Match, entry : Index::Entry, patterns : Array(String), relative : String

    private def dedup_by_entry(matches : Array(Match)) : Array(Match)
      seen = Set(String).new
      matches.select do |match|
        next false if seen.includes?(match.entry.path)
        seen << match.entry.path
        true
      end
    end

    private def session_notice(state : SessionState, session_id : String?) : String?
      return nil if session_id.nil? || state.notified?
      SESSION_NOTICE
    end

    private def combine(notice : String?, context : String) : String
      return context if notice.nil?
      return notice if context.empty?
      "#{notice}\n\n#{context}"
    end

    private def matches_for(entries : Array(Index::Entry), root : Path, fs : Filesystem,
                            relative : String, edit : Payload::FileEdit) : Array(Match)
      content = content_for(edit, root, fs, relative)
      entries.compact_map do |entry|
        patterns = entry.triggers(relative, content)
        next unless patterns
        Match.new(entry, patterns, relative)
      end
    end

    private def content_for(edit : Payload::FileEdit, root : Path, fs : Filesystem,
                            relative : String) : String?
      pieces = edit.written_contents
      return pieces.join('\n') unless pieces.empty?
      fs.read?(root.join(relative).to_s)
    end

    private def load_or_build_index(root : Path, fs : Filesystem, allow_outside : Bool) : Index
      json = fs.read?(root.join(INDEX_RELATIVE).to_s)
      if json && (index = Index.load(json))
        return index
      end
      index = Index.build(Conventions.walk(root, fs, allow_outside, tolerant: true))
      persist_index(root, fs, index)
      index
    end

    private def persist_index(root : Path, fs : Filesystem, index : Index) : Nil
      fs.write(root.join(INDEX_RELATIVE).to_s, index.to_document)
    rescue
    end

    private def build_context(root : Path, fs : Filesystem, entries : Array(Index::Entry)) : String
      docs = entries.compact_map do |entry|
        text = fs.read?(root.join(entry.path).to_s)
        next unless text
        _, body = Frontmatter.split(text)
        {entry.path, body.strip + scope_note(entry)}
      end
      Rendering.context(docs)
    end

    private def scope_note(entry : Index::Entry) : String
      parts = [] of String
      parts << "whose path matches #{quoted(entry.paths)}" unless entry.paths.empty?
      parts << "where new code matches #{quoted(entry.contents)}" unless entry.contents.empty?
      return "" if parts.empty?
      "\n\n_Scope: this convention applies to every file #{parts.join(" and ")} " \
      "— not only the file that triggered it just now. Apply it to any other " \
      "matching file you touch this session; it will not be shown again._"
    end

    private def quoted(patterns : Array(String)) : String
      patterns.map { |pattern| "`#{pattern}`" }.join(" or ")
    end

    private def emit(stdout : IO, event_name : String, context : String, copilot : Bool) : Nil
      JSON.build(stdout) do |json|
        json.object do
          if copilot
            json.field "additionalContext", context
          else
            json.field "hookSpecificOutput" do
              json.object do
                json.field "hookEventName", event_name
                json.field "additionalContext", context
              end
            end
          end
        end
      end
      stdout.puts
    end

    private def event_name(event : Symbol) : String
      event == :pre ? "PreToolUse" : "PostToolUse"
    end

    private def resolve_root(override_root : String?, payload : Payload?) : Path?
      return Path[override_root] if override_root
      start = payload.try(&.cwd) || Dir.current
      AgentApropos.find_repo_root(Path[start])
    end

    private def relativize(root : Path, file_path : String) : String
      path = Path[file_path]
      absolute = path.absolute? ? path : root.join(path)
      absolute.expand.relative_to(root).to_posix.to_s
    end

    private def outside_root?(relative : String) : Bool
      relative == ".." || relative.starts_with?("../")
    end

    private def log_failure(fs : Filesystem, override_root : String?, verbose : Bool, ex : Exception) : Nil
      return unless verbose
      dir = override_root ? Path[override_root] : Path[Dir.current]
      fs.append(dir.join(LOG_RELATIVE).to_s, "agent-apropos hook: #{ex.message}\n")
    rescue
    end
  end
end
