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
require "./git"

module AgentApropos
  module Hook
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]
    LOG_RELATIVE   = Path[".cache", "agent-apropos", "logs"]

    LOG_MAX_AGE = 7.days

    LOG_MAX_FILES = 200

    REMOVAL_VERB_PATTERN = /\b(?:rm|mv|unlink|rmdir|trash|shred|truncate|find)\b/

    REMOVAL_CONTENT_RESOLUTION_BOUND = 20

    SESSION_NOTICE = "agent-apropos is connected and running. It compiles " \
                     "this repo's coding conventions into a trigger index " \
                     "and automatically injects the ones relevant to " \
                     "whatever file or construct you're touching into your " \
                     "context, as you read and edit files."

    def pre(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
            override_root : String? = nil, verbose : Bool = false, tool : String? = nil,
            allow_outside : Bool = false, git : Git = Git::Real.new) : Int32
      deliver(:pre, io_in, stdout, fs, now, override_root, verbose, tool, allow_outside, git)
    end

    def post(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
             override_root : String? = nil, verbose : Bool = false, tool : String? = nil,
             allow_outside : Bool = false, git : Git = Git::Real.new) : Int32
      deliver(:post, io_in, stdout, fs, now, override_root, verbose, tool, allow_outside, git)
    end

    private def deliver(event : Symbol, io_in : IO, stdout : IO, fs : Filesystem,
                        now : Time, override_root : String?, verbose : Bool, tool : String?,
                        allow_outside : Bool, git : Git) : Int32
      payload = Payload.parse(io_in.gets_to_end)
      root = resolve_root(override_root, payload)
      execute(event, payload, root, stdout, fs, now, tool, allow_outside, git) if payload && root
      0
    rescue ex
      log_failure(fs, override_root, verbose, now, ex)
      0
    end

    private def execute(event : Symbol, payload : Payload, root : Path, stdout : IO, fs : Filesystem,
                        now : Time, tool : String?, allow_outside : Bool, git : Git) : Nil
      in_root = payload.file_edits.compact_map { |edit| relative_edit(root, edit) }
      removed = removed_relative_paths(payload, root, git)
      return if in_root.empty? && removed.empty?

      index, session_id, state, name, pending = session_context(root, fs, allow_outside, now, payload, event)

      agent = Agents.find(tool) || Agents.detect(payload)
      if !in_root.empty? && agent.read?(payload)
        suppress(index, state, root, fs, session_id, now, name, in_root) unless payload.partial_read?
        return
      end

      write_matches = in_root.flat_map { |relative, edit| matches_for(pending, event, root, fs, relative, edit) }
      removal_matches = removed.each_with_index.flat_map { |relative, i|
        matches_for_removal(pending, root, fs, git, relative, i < REMOVAL_CONTENT_RESOLUTION_BOUND)
      }.to_a
      matches = dedup_by_entry(write_matches + removal_matches)

      deliver_matches(matches, state, root, fs, session_id, now, name, stdout, payload)
    end

    private def session_context(root : Path, fs : Filesystem, allow_outside : Bool, now : Time,
                                payload : Payload, event : Symbol) : {Index, String?, SessionState, String, Array(Index::Entry)}
      index = load_or_build_index(root, fs, allow_outside)
      session_id = SessionState.key?(payload.session_id)
      SessionState.prune(root, fs, now)
      state = SessionState.load(root, fs, session_id)
      name = event_name(event)
      pending = index.docs.reject { |entry| state.injected?(entry.path) }
      {index, session_id, state, name, pending}
    end

    private def removed_relative_paths(payload : Payload, root : Path, git : Git) : Array(String)
      structural = payload.removals.map { |removal| relativize(root, removal.path) }
      candidates = removal_command?(payload) ? structural + git.removed_paths(root) : structural
      candidates.reject { |relative| outside_root?(relative) }
    end

    private def removal_command?(payload : Payload) : Bool
      command = payload.command
      !command.nil? && REMOVAL_VERB_PATTERN.matches?(command)
    end

    private def deliver_matches(matches : Array(Match), state : SessionState, root : Path, fs : Filesystem,
                                session_id : String?, now : Time, name : String, stdout : IO,
                                payload : Payload) : Nil
      notice = session_notice(state, session_id)
      combined = combine(notice, build_context(root, fs, matches))
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

    private record Match, entry : Index::Entry, patterns : Array(String), relative : String, removal : Bool = false

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

    private def matches_for(entries : Array(Index::Entry), event : Symbol, root : Path,
                            fs : Filesystem, relative : String, edit : Payload::FileEdit) : Array(Match)
      content = content_for(event, edit, root, fs, relative)
      entries.compact_map do |entry|
        patterns = entry.triggers(relative, content)
        next unless patterns
        Match.new(entry, patterns, relative)
      end
    end

    private def content_for(event : Symbol, edit : Payload::FileEdit, root : Path,
                            fs : Filesystem, relative : String) : String?
      pieces = edit.written_contents
      return pieces.join('\n') unless pieces.empty?
      return nil if event == :pre
      fs.read?(root.join(relative).to_s)
    end

    private def matches_for_removal(entries : Array(Index::Entry), root : Path, fs : Filesystem,
                                    git : Git, relative : String, resolve_content : Bool) : Array(Match)
      content = nil
      resolved = false
      entries.compact_map do |entry|
        if resolve_content && !entry.contents.empty? && !resolved
          content = resolve_removed_content(root, git, relative)
          resolved = true
        end
        patterns = entry.triggers(relative, content, Frontmatter::Event::Removed)
        next unless patterns
        Match.new(entry, patterns, relative, removal: true)
      end
    end

    private def resolve_removed_content(root : Path, git : Git, relative : String) : String?
      git.blob(root, "", relative) || git.blob(root, "HEAD", relative)
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

    private def build_context(root : Path, fs : Filesystem, matches : Array(Match)) : String
      docs = matches.compact_map do |match|
        entry = match.entry
        text = fs.read?(root.join(entry.path).to_s)
        next unless text
        _, body = Frontmatter.split(text)
        note = match.removal ? removal_scope_note(entry) : scope_note(entry)
        {entry.path, body.strip + note}
      end
      Rendering.context(docs)
    end

    private def scope_note(entry : Index::Entry) : String
      parts = [] of String
      parts << "whose path matches #{quoted(entry.paths)}" unless entry.paths.empty?
      parts << "where new code matches #{quoted(entry.contents)}" unless entry.contents.empty?
      "\n\n_Scope: this convention applies to every file #{parts.join(" and ")} " \
      "— not only the file that triggered it just now. Apply it to any other " \
      "matching file you touch this session; it will not be shown again._"
    end

    private def removal_scope_note(entry : Index::Entry) : String
      parts = [] of String
      parts << "whose path matches #{quoted(entry.paths)}" unless entry.paths.empty?
      parts << "whose last tracked contents matched #{quoted(entry.contents)}" unless entry.contents.empty?
      "\n\n_Scope: this convention fired because a tracked file #{parts.join(" and ")} " \
      "is now missing from the working tree — not necessarily because this command " \
      "removed it. Apply it to any other matching removal this session; it will not " \
      "be shown again._"
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

    private def log_failure(fs : Filesystem, override_root : String?, verbose : Bool,
                            now : Time, ex : Exception) : Nil
      return unless verbose
      log_dir = (override_root ? Path[override_root] : Path[Dir.current]).join(LOG_RELATIVE)
      write_log(fs, log_dir, now, ex)
      prune_logs(fs, log_dir, now)
    rescue
    end

    private def write_log(fs : Filesystem, log_dir : Path, now : Time, ex : Exception) : Nil
      fs.write(log_dir.join(log_name(now)).to_s, "agent-apropos hook: #{ex.message}\n")
    rescue
    end

    private def log_name(now : Time) : String
      "#{now.to_unix}-#{Random::Secure.hex(6)}.log"
    end

    private def prune_logs(fs : Filesystem, log_dir : Path, now : Time) : Nil
      cutoff = (now - LOG_MAX_AGE).to_unix
      dated = fs.glob(log_dir, "*.log").compact_map do |file|
        stamp = Path[file].basename(".log").partition('-').first.to_i64?
        {stamp, file} if stamp
      end
      keep = dated.sort_by! { |stamp, _| -stamp }.first(LOG_MAX_FILES).to_set
      dated.each do |entry|
        stamp, file = entry
        fs.remove(file) if stamp < cutoff || !keep.includes?(entry)
      end
    rescue
    end
  end
end
