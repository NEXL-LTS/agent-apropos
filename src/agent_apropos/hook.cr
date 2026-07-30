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
  # The hook runtime shared by every wired CLI agent. `pre` delivers Layer 2
  # (path-scoped) guidance; `post` delivers Layer 3 (construct-scoped)
  # guidance. Both read the trigger index (the hot path never parses YAML),
  # match against it, dedup per session, render the matched rule bodies under
  # a character cap, and emit the `additionalContext` envelope.
  #
  # `pre`/`post` name Claude Code's PreToolUse/PostToolUse events, but
  # matching is tool-agnostic: it never gates on `tool_name`, so the same
  # code runs unchanged for OpenCode's plugin bridge and for Gemini CLI, whose
  # `write_file`/`replace` tools happen to use the exact `file_path`/`content`/
  # `old_string`/`new_string` argument names Claude's do. Gemini wires both
  # `pre` and `post` onto its single `AfterTool` event (see `init.cr`) since
  # its `BeforeTool` output schema cannot inject context. The `tool` argument
  # (from `--tool <name>` — see `Agents::Agent#read?`) is a separate,
  # non-gating concern: it only labels a recorded `SessionState::Cause` for
  # debugging, never whether a rule matches or is delivered.
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
  # Every dialect's edit tool is one file per call — except Codex CLI's
  # `apply_patch`, whose patch envelope can bundle several files' worth of
  # Add/Update sections into a single call (see `Hook::Payload#file_edits`).
  # `execute` matches and dedups across every file such a payload touches, so
  # a rule that any of them satisfies is still injected exactly once.
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
    # first — regardless of whether that particular edit matches any rule.
    # Purely descriptive: it states that agent-apropos is running and what it
    # does, without instructing the agent to act (or not act) any particular
    # way — instructional framing here would make the with/without-agent-apropos
    # contrast meaningless, since a model told what to do behaves the same
    # regardless of whether agent-apropos's hooks are actually wired. See
    # docs/conventions/README.md for the layer model this refers to.
    SESSION_NOTICE = "agent-apropos is connected and running. It compiles " \
                     "this repo's coding conventions into a trigger index " \
                     "and automatically injects the ones relevant to " \
                     "whatever file or construct you're touching into your " \
                     "context, as you read and edit files."

    # PreToolUse handler: match the target *path* against Layer 2 rules and
    # inject them before the write happens. `tool` is the `--tool <name>`
    # value from the wiring that invoked this (`nil` when absent, e.g. an
    # older wiring or a manual invocation), used only to label the
    # `SessionState::Cause` recorded for any match — see `execute`.
    def pre(io_in : IO, stdout : IO, fs : Filesystem, now : Time,
            override_root : String? = nil, verbose : Bool = false, tool : String? = nil,
            allow_outside : Bool = false) : Int32
      deliver(:pre, io_in, stdout, fs, now, override_root, verbose, tool, allow_outside)
    end

    # PostToolUse handler: match the *written content* against Layer 3 rules
    # (honoring `paths:` AND-scoping) and inject them after the write.
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
      # Every dialect but Codex's `apply_patch` yields exactly one edit here,
      # so this is unchanged behavior for them. `relative_edit` drops any
      # edit outside the repo root; when that leaves nothing (the common
      # single-edit case for an outside-root path), bail out entirely with no
      # side effects — same as the old single-`file_path` early return —
      # rather than still emitting a session notice for a call that touched
      # nothing inside the repo.
      in_root = payload.file_edits.compact_map { |edit| relative_edit(root, edit) }
      return if in_root.empty?

      index = load_or_build_index(root, fs, allow_outside)
      matches = dedup_by_entry(in_root.flat_map { |relative, edit| matches_for(event, index, root, fs, relative, edit) })

      # Resolved once and reused for load/notice/save below: an unsafe id (see
      # `SessionState.key?`) must be treated as absent everywhere, not just at
      # the `save` no-op, or `session_notice` — which only checks for `nil` —
      # would see a state that can never persist `notified?` and re-fire the
      # notice on every single call for that id instead of skipping it like a
      # true nil session does.
      session_id = SessionState.key?(payload.session_id)
      SessionState.prune(root, fs, now)
      state = SessionState.load(root, fs, session_id)
      fresh = matches.reject { |match| state.injected?(match.entry.path) }

      notice = session_notice(state, session_id)
      combined = combine(notice, build_context(root, fs, fresh.map(&.entry)))
      return if combined.empty?

      agent = Agents.find(tool) || Agents.detect(payload)
      layer = agent.read?(payload) ? "agent" : (event == :pre ? 2 : 3)
      name = event_name(event)
      fresh.each do |match|
        cause = SessionState::Cause.new(layer, name, match.relative, match.patterns)
        state.add(match.entry.path, cause)
      end
      state.notify! if notice
      state.save(root, fs, session_id, now)
      emit(stdout, name, combined, payload.copilot?)
    end

    # `edit`'s path, relativized to `root` — or nil when it resolves outside
    # the repo (see `outside_root?`), so the caller can filter it out while
    # still processing any other edit from the same payload.
    private def relative_edit(root : Path, edit : Payload::FileEdit) : {String, Payload::FileEdit}?
      relative = relativize(root, edit.path)
      return nil if outside_root?(relative)
      {relative, edit}
    end

    # A matched rule together with the specific glob/regex pattern(s) from its
    # frontmatter that fired and the file that fired it, kept alongside the
    # entry so the cause can be recorded without re-matching.
    private record Match, entry : Index::Entry, patterns : Array(String), relative : String

    # Drop every `Match` after the first seen for a given rule (`entry.path`)
    # — a single `apply_patch` call can touch several files, and more than
    # one of them can match the same rule, but it must still only ever be
    # injected (and recorded) once. Same one-injection-per-rule guarantee
    # `SessionState` already gives *across* hook calls; this is the
    # equivalent guarantee *within* one.
    private def dedup_by_entry(matches : Array(Match)) : Array(Match)
      seen = Set(String).new
      matches.select do |match|
        next false if seen.includes?(match.entry.path)
        seen << match.entry.path
        true
      end
    end

    # The one-time notice, or nil once already delivered this session. `nil`
    # `session_id` — already resolved through `SessionState.key?` by the
    # caller, so this also covers an unsafe id — means there is no key to
    # remember "already notified" against, so the notice is skipped entirely
    # rather than repeated on every call.
    private def session_notice(state : SessionState, session_id : String?) : String?
      return nil if session_id.nil? || state.notified?
      SESSION_NOTICE
    end

    private def combine(notice : String?, context : String) : String
      return context if notice.nil?
      return notice if context.empty?
      "#{notice}\n\n#{context}"
    end

    private def matches_for(event : Symbol, index : Index, root : Path, fs : Filesystem,
                            relative : String, edit : Payload::FileEdit) : Array(Match)
      case event
      when :pre
        match_pre(index, relative)
      else
        match_post(index, root, fs, relative, edit)
      end
    end

    # Layer 2: any path-scoped rule whose glob matches the edited path.
    private def match_pre(index : Index, relative : String) : Array(Match)
      index.docs.compact_map do |entry|
        next unless entry.layer2?
        patterns = Matcher.matching_paths(entry.paths, relative)
        next if patterns.empty?
        Match.new(entry, patterns, relative)
      end
    end

    # Layer 3: any content-scoped rule whose regex matches the written content;
    # when the rule also declares `paths`, the path must match too (AND). Both
    # sides are checked against this one edit's own path/content — never
    # pooled across a multi-file `apply_patch` call's other edits, or the AND
    # could fire from two different files satisfying one side each. The
    # recorded cause combines whichever pattern(s) fired on each side.
    private def match_post(index : Index, root : Path, fs : Filesystem,
                           relative : String, edit : Payload::FileEdit) : Array(Match)
      content = post_content(edit, root, fs, relative)
      return [] of Match unless content

      index.docs.compact_map do |entry|
        next unless entry.layer3?
        content_patterns = Matcher.matching_contents(entry.contents, content)
        next if content_patterns.empty?

        path_patterns = entry.paths.empty? ? [] of String : Matcher.matching_paths(entry.paths, relative)
        next if !entry.paths.empty? && path_patterns.empty?

        Match.new(entry, content_patterns + path_patterns, relative)
      end
    end

    # The content to match Layer 3 against: this edit's own written pieces
    # joined, or — when it carries no content field — the file read from disk
    # (the drift-tolerant fallback).
    private def post_content(edit : Payload::FileEdit, root : Path, fs : Filesystem,
                             relative : String) : String?
      pieces = edit.written_contents
      return pieces.join('\n') unless pieces.empty?
      fs.read?(root.join(relative).to_s)
    end

    # Read the index; rebuild it in-memory (and best-effort persist) when it is
    # absent, corrupt, or a stale schema version. Freshness against changed docs
    # is *not* checked here — that would re-walk every doc and blow the warm
    # latency budget; `generate` owns keeping the index current.
    #
    # `tolerant: true` on this rebuild: a single malformed doc (e.g. right
    # after authoring it, before the index is regenerated) must not blank out
    # delivery of every *other* rule for this call — only its own rule is
    # unavailable until it's fixed and the index is regenerated (see
    # `agent-apropos lint`/`doctor`, which already report it). Once the index is warm again this path isn't hit at all,
    # so the cost of an in-memory rebuild here is a cold-cache-only concern.
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
      # Warming the cache is best-effort; delivery continues on the in-memory
      # index even when the cache dir is unwritable.
    end

    # Read each matched rule's body (frontmatter stripped) and render them under
    # `Convention (path):` headers, applying the shared cap strategy. Each
    # body gets a scope note appended (see `scope_note`) since dedup is now
    # global-per-session (`SessionState`): a rule is only ever injected once,
    # so the agent needs to be told explicitly, up front, that it still
    # applies to every other matching file it touches afterward.
    private def build_context(root : Path, fs : Filesystem, entries : Array(Index::Entry)) : String
      docs = entries.compact_map do |entry|
        text = fs.read?(root.join(entry.path).to_s)
        next unless text
        _, body = Frontmatter.split(text)
        {entry.path, body.strip + scope_note(entry)}
      end
      Rendering.context(docs)
    end

    # A trailing note stating which files this rule covers — every path
    # matching its `paths:` globs and/or every file whose written content
    # matches its `contents:` patterns — so the agent applies it to other
    # matching files later in the session without needing it shown again.
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

    # Absolutizes and normalizes before relativizing, so an embedded `..`
    # segment anywhere in `file_path` (e.g. `docs/../../../etc/passwd`) is
    # collapsed just like a leading one — `Path#expand` resolves `.`/`..`
    # lexically, with no filesystem access (no symlink resolution), so this
    # stays fail-open-safe. Without this, `outside_root?`'s prefix check
    # would see the uncollapsed string, which still starts with `docs/`, and
    # wrongly treat the escape as inside the repo.
    private def relativize(root : Path, file_path : String) : String
      path = Path[file_path]
      absolute = path.absolute? ? path : root.join(path)
      absolute.expand.relative_to(root).to_posix.to_s
    end

    # `relativize` computes a relative path unconditionally, even when
    # `file_path` isn't actually inside `root` — it just comes out prefixed
    # with `..` segments (e.g. a CLI agent writing to its own state dir
    # outside the project, like Copilot's `~/.copilot/session-state/`).
    # Conventions are scoped to the repo; nothing outside it should ever
    # match, so callers must skip entirely rather than match against a path
    # that only superficially looks repo-relative. Safe to check via prefix
    # alone because `relativize` already normalized away any embedded `..`.
    private def outside_root?(relative : String) : Bool
      relative == ".." || relative.starts_with?("../")
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
