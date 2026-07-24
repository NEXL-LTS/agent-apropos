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

module AgentApropos
  # The hook runtime shared by every wired CLI agent. `pre` delivers Layer 2
  # (path-scoped) guidance; `post` delivers Layer 3 (construct-scoped)
  # guidance. Both read the trigger index (the hot path never parses YAML),
  # match against it, dedup per session, render the matched rule bodies under
  # a character cap, and emit the `additionalContext` envelope.
  #
  # `pre`/`post` name Claude Code's PreToolUse/PostToolUse events, but the
  # logic is tool-agnostic: neither method gates on `tool_name`, so the same
  # code runs unchanged for OpenCode's plugin bridge and for Gemini CLI, whose
  # `write_file`/`replace` tools happen to use the exact `file_path`/`content`/
  # `old_string`/`new_string` argument names Claude's do. Gemini wires both
  # `pre` and `post` onto its single `AfterTool` event (see `init.cr`) since
  # its `BeforeTool` output schema cannot inject context.
  #
  # `pre` is also wired onto each agent's *read* tool (Claude's Read matcher;
  # Gemini's AfterTool `read_file` matcher; OpenCode's "read" in the
  # tool.execute.before allowlist) — Layer 2 depends only on the target
  # *path*, which a read carries exactly like an edit, so the same rule can
  # land as early as the model's first read of a file instead of waiting for
  # it to write there. This matters most for Gemini: its Layer 2 delivery is
  # already a post-write AfterTool fallback (see `merge_gemini_settings` in
  # `init.cr`), so without also firing on read, the model can miss the rule
  # on its first edit and need a second one to correct it. Layer 3 stays
  # write-only — it matches the *written* content, which doesn't exist yet
  # on a mere read.
  #
  # Everything here fails **open**: any internal error exits 0 and
  # emits nothing, so a conventions tool can never block or break an edit. All
  # I/O is injected (filesystem, stdin/stdout IO, clock) so every path is
  # unit-testable.
  module Hook
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]
    LOG_RELATIVE   = Path[".cache", "agent-apropos", "log"]

    # Delivered once per session, on whichever of `pre`/`post` fires
    # first — regardless of whether that particular edit matches any rule —
    # so the agent stops proactively exploring docs/conventions/ on its own
    # (which would make the with/without-agent-apropos contrast meaningless: a
    # model that reads the docs directly gets the same content whether or
    # not agent-apropos's hooks are actually wired). See docs/conventions/README.md
    # for the layer model this refers to.
    SESSION_NOTICE = "No need to search for coding conventions, rules, or " \
                     "guidelines — agent-apropos automatically injects the " \
                     "relevant ones into your context via hooks as you " \
                     "read and edit files."

    # PreToolUse handler: match the target *path* against Layer 2 rules and
    # inject them before the write happens.
    def pre(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
            override_root : String? = nil, verbose : Bool = false) : Int32
      deliver(:pre, io_in, stdout, fs, now, override_root, verbose)
    end

    # PostToolUse handler: match the *written content* against Layer 3 rules
    # (honoring `paths:` AND-scoping) and inject them after the write.
    def post(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
             override_root : String? = nil, verbose : Bool = false) : Int32
      deliver(:post, io_in, stdout, fs, now, override_root, verbose)
    end

    private def deliver(event : Symbol, io_in : IO, stdout : IO, fs : Filesystem,
                        now : Time, override_root : String?, verbose : Bool) : Int32
      payload = Payload.parse(io_in.gets_to_end)
      root = resolve_root(override_root, payload)
      execute(event, payload, root, stdout, fs, now) if payload && root
      0
    rescue ex
      log_failure(fs, override_root, verbose, ex)
      0
    end

    private def execute(event : Symbol, payload : Payload, root : Path,
                        stdout : IO, fs : Filesystem, now : Time) : Nil
      file_path = payload.file_path
      return unless file_path
      relative = relativize(root, file_path)

      index = load_or_build_index(root, fs)
      matches = matches_for(event, index, payload, root, fs, relative)

      SessionState.prune(root, fs, now)
      state = SessionState.load(root, fs, payload.session_id)
      fresh = matches.reject { |match| state.injected?(match.entry.path) }

      notice = session_notice(state, payload.session_id)
      combined = combine(notice, build_context(root, fs, fresh.map(&.entry)))
      return if combined.empty?

      layer = event == :pre ? 2 : 3
      name = event_name(event)
      fresh.each do |match|
        cause = SessionState::Cause.new(layer, name, relative, match.patterns)
        state.add(match.entry.path, cause)
      end
      state.notify! if notice
      state.save(root, fs, payload.session_id, now)
      emit(stdout, name, combined, payload.copilot?)
    end

    # A matched rule together with the specific glob/regex pattern(s) from its
    # frontmatter that fired, kept alongside the entry so the cause can be
    # recorded without re-matching.
    private record Match, entry : Index::Entry, patterns : Array(String)

    # The one-time notice, or nil once already delivered this session. A nil
    # `session_id` means there is no key to remember "already notified"
    # against, so the notice is skipped entirely rather than repeated on
    # every call.
    private def session_notice(state : SessionState, session_id : String?) : String?
      return nil if session_id.nil? || state.notified?
      SESSION_NOTICE
    end

    private def combine(notice : String?, context : String) : String
      return context if notice.nil?
      return notice if context.empty?
      "#{notice}\n\n#{context}"
    end

    private def matches_for(event : Symbol, index : Index, payload : Payload,
                            root : Path, fs : Filesystem, relative : String) : Array(Match)
      case event
      when :pre
        match_pre(index, relative)
      else
        match_post(index, payload, root, fs, relative)
      end
    end

    # Layer 2: any path-scoped rule whose glob matches the edited path.
    private def match_pre(index : Index, relative : String) : Array(Match)
      index.docs.compact_map do |entry|
        next unless entry.layer2?
        patterns = Matcher.matching_paths(entry.paths, relative)
        next if patterns.empty?
        Match.new(entry, patterns)
      end
    end

    # Layer 3: any content-scoped rule whose regex matches the written content;
    # when the rule also declares `paths`, the path must match too (AND). The
    # recorded cause combines whichever pattern(s) fired on each side.
    private def match_post(index : Index, payload : Payload, root : Path,
                           fs : Filesystem, relative : String) : Array(Match)
      content = post_content(payload, root, fs, relative)
      return [] of Match unless content

      index.docs.compact_map do |entry|
        next unless entry.layer3?
        content_patterns = Matcher.matching_contents(entry.contents, content)
        next if content_patterns.empty?

        path_patterns = entry.paths.empty? ? [] of String : Matcher.matching_paths(entry.paths, relative)
        next if !entry.paths.empty? && path_patterns.empty?

        Match.new(entry, content_patterns + path_patterns)
      end
    end

    # The content to match Layer 3 against: the payload's written pieces joined,
    # or — when the payload carries no content field — the file read from disk
    # (the drift-tolerant fallback).
    private def post_content(payload : Payload, root : Path, fs : Filesystem,
                             relative : String) : String?
      pieces = payload.written_contents
      return pieces.join('\n') unless pieces.empty?
      fs.read?(root.join(relative).to_s)
    end

    # Read the index; rebuild it in-memory (and best-effort persist) when it is
    # absent, corrupt, or a stale schema version. Freshness against changed docs
    # is *not* checked here — that would re-walk every doc and blow the warm
    # latency budget; `generate` owns keeping the index current.
    private def load_or_build_index(root : Path, fs : Filesystem) : Index
      json = fs.read?(root.join(INDEX_RELATIVE).to_s)
      if json && (index = Index.load(json))
        return index
      end
      index = Index.build(Conventions.walk(root, fs))
      persist_index(root, fs, index)
      index
    end

    private def persist_index(root : Path, fs : Filesystem, index : Index) : Nil
      fs.write(root.join(INDEX_RELATIVE).to_s, index.to_document)
    rescue
      # Warming the cache is best-effort; delivery continues on the in-memory
      # index even when the cache dir is unwritable.
    end

    # Read each matched rule's body (frontmatter stripped) and render them under
    # `Convention (path):` headers, applying the shared cap strategy.
    private def build_context(root : Path, fs : Filesystem, entries : Array(Index::Entry)) : String
      docs = entries.compact_map do |entry|
        text = fs.read?(root.join(entry.path).to_s)
        next unless text
        _, body = Frontmatter.split(text)
        {entry.path, body.strip}
      end
      Rendering.context(docs)
    end

    # GitHub Copilot CLI's `postToolUse` output schema has no envelope — just
    # a flat `additionalContext` key — unlike every other wired agent (Claude
    # Code's own convention, which Gemini's `AfterTool` and OpenCode's plugin
    # bridge both also expect), which want it nested under
    # `hookSpecificOutput.hookEventName`/`additionalContext`. `copilot`
    # (`Payload#copilot?`, detected from the *input's* own wire shape) picks
    # the reply shape — never the reverse, so an already-wired agent's output
    # never changes.
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
      path.absolute? ? path.relative_to(root).to_posix.to_s : path.to_posix.to_s
    end

    # Best-effort `--verbose` diagnostics. Silent unless verbose, and
    # never raises — it is on the fail-open path.
    private def log_failure(fs : Filesystem, override_root : String?, verbose : Bool, ex : Exception) : Nil
      return unless verbose
      dir = override_root ? Path[override_root] : Path[Dir.current]
      fs.append(dir.join(LOG_RELATIVE).to_s, "agent-apropos hook: #{ex.message}\n")
    rescue
      # Logging must never break the fail-open guarantee.
    end
  end
end
