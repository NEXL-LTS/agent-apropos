require "json"
require "./filesystem"

module AgentApropos
  # Per-session dedup store: the set of rule paths already injected during a
  # session — shared by every wired CLI agent (Claude Code, OpenCode, Gemini
  # CLI, GitHub Copilot CLI), not Claude-specific — so a rule is delivered at
  # most once per session, full stop, regardless of how many different files
  # go on to match it. The injected text itself states that it applies to
  # every matching file (see `Hook#scope_note`), so the agent is expected to
  # keep applying it on its own after the first delivery rather than needing
  # it repeated per file. Persisted as pretty-printed JSON at
  # `.cache/agent-apropos/sessions/<session_id>.json` with an `updated_at` stamp
  # used to prune stale files opportunistically.
  #
  # Each injection also carries a `cause` — the layer, the hook event, the file
  # that triggered it, and the specific glob/regex pattern(s) that matched — so
  # the cache doubles as a debugging trail: reading the file answers "why did
  # this rule show up?" without re-deriving it from the index.
  #
  # All disk access goes through an injected `Filesystem`; the clock is injected
  # too (`now`), so persistence and pruning are unit-testable without real time.
  class SessionState
    DIR = Path[".cache", "agent-apropos", "sessions"]

    # Session files untouched for longer than this are pruned on any hook run.
    MAX_AGE = 7.days

    # Ids longer than this may exceed a filesystem's ~255-byte name limit once
    # the ".json" suffix and the atomic-write temp suffix (".<name>.<pid>.tmp") are added.
    MAX_ID_BYTES = 230

    # Rejected as an id's first character: `.` (what makes `.` and `..`
    # dangerous) and `-` (a filename that reads as a flag when passed around).
    LEADING_REJECT = {'.', '-'}

    # Why a rule was injected: which layer matched, the hook event that fired,
    # the file that triggered the match, and the specific frontmatter
    # glob/regex pattern(s) that made it fire. `layer` is normally `2`/`3`,
    # but becomes the string `"agent"` when the wired agent's own dialect
    # identifies the triggering event as a genuine *read* rather than an
    # edit/write — a debugging label only (see `Agents::Agent#read?`), never
    # something match/dedup logic branches on.
    struct Cause
      include JSON::Serializable

      getter layer : Int32 | String
      getter event : String
      getter file : String
      getter matched_patterns : Array(String)

      def initialize(@layer : Int32 | String, @event : String, @file : String, @matched_patterns : Array(String))
      end
    end

    # One rule-doc path plus the cause that first injected it this session.
    struct Injection
      include JSON::Serializable

      getter path : String
      getter cause : Cause

      def initialize(@path : String, @cause : Cause)
      end
    end

    # Just enough of the on-disk shape to decide staleness, independent of how
    # `injected` is shaped. `.prune` parses this instead of the full
    # `Document` so a schema change to `injected` (e.g. the string-array ->
    # object-array upgrade) still ages the file out on schedule instead of
    # leaving it stuck forever as "unparseable".
    private struct Timestamp
      include JSON::Serializable

      @[JSON::Field(key: "updated_at")]
      getter updated_at : Int64
    end

    # The on-disk shape. Kept minimal beyond `cause` so a lost concurrent
    # update costs at most one duplicate injection. `notified` defaults to
    # false so session files written before that field existed still parse.
    # A schema change here (e.g. the string-array -> object-array upgrade for
    # `injected`) is not migrated: an old-format file simply fails to parse and
    # is treated as empty state, same as any other corrupt file (see `.load`).
    # It still ages out on schedule, since `.prune` doesn't depend on this
    # schema (see `Timestamp`).
    struct Document
      include JSON::Serializable

      @[JSON::Field(key: "updated_at")]
      getter updated_at : Int64
      getter injected : Array(Injection)
      getter? notified : Bool = false

      def initialize(@updated_at : Int64, @injected : Array(Injection), @notified : Bool = false)
      end

      # Deterministic, human-readable on-disk form: pretty JSON, LF endings, a
      # single trailing newline.
      def to_document : String
        String.build do |io|
          to_pretty_json(io)
          io << '\n'
        end
      end
    end

    getter? notified : Bool

    # Keyed by rule path alone — dedup is global across the whole session,
    # not scoped per file.
    def initialize(@injected : Hash(String, Injection) = {} of String => Injection, @notified : Bool = false)
    end

    # The session id, if it is usable as a single filename inside `DIR`; nil
    # otherwise. Session ids arrive from an untrusted hook payload and are the
    # only caller-controlled component of the session-file path built by
    # `file_for`, so an id that is not a plain one-line filename is discarded
    # rather than sanitized — `load`/`save` then behave exactly as they do for
    # an absent session id: no dedup, no persistence, no notice (see
    # `Hook#execute`, which resolves this once and reuses it for all three).
    # Deliberately permissive about *characters* — spaces and non-ASCII pass,
    # as does every id shape a wired agent actually issues — and rejects only
    # shapes that would escape `DIR`, nest below it (`.prune`'s glob is not
    # recursive, so a nested file would never age out), or break the write.
    def self.key?(session_id : String?) : String?
      return nil unless session_id
      return nil if session_id.empty? || session_id.bytesize > MAX_ID_BYTES
      return nil if LEADING_REJECT.includes?(session_id[0])
      return nil if session_id.each_char.any?(&.control?)
      return nil unless single_component?(session_id)
      session_id
    end

    # `Path.windows`, even on POSIX: it is the superset parser — it treats
    # both `/` and `\` as separators and understands drive (`C:`) and UNC
    # (`\\srv\share`) anchors — so this one structural check covers every
    # platform's escapes instead of a hand-maintained character denylist.
    private def self.single_component?(session_id : String) : Bool
      path = Path.windows(session_id)
      path.parts == [session_id] && path.anchor.nil?
    end

    # Load the state for `session_id`. A missing or unparseable file is treated
    # as an empty state (fail open). A nil or unsafe (see `.key?`) `session_id`
    # means dedup is unavailable, so every rule is considered new.
    def self.load(repo_root : Path, fs : Filesystem, session_id : String?) : SessionState
      return new unless session_id = key?(session_id)
      json = fs.read?(file_for(repo_root, session_id).to_s)
      return new unless json
      document = Document.from_json(json)
      injected = document.injected.to_h { |entry| {entry.path, entry} }
      new(injected, document.notified?)
    rescue JSON::ParseException
      new
    end

    # Delete session files whose `updated_at` is older than MAX_AGE. Best-effort
    # and opportunistic: a corrupt or unreadable file is skipped, never fatal.
    def self.prune(repo_root : Path, fs : Filesystem, now : Time) : Nil
      cutoff = (now - MAX_AGE).to_unix
      fs.glob(repo_root.join(DIR), "*.json").each do |file|
        json = fs.read?(file)
        next unless json
        timestamp = parse(json)
        next unless timestamp
        fs.remove(file) if timestamp.updated_at < cutoff
      end
    end

    private def self.parse(json : String) : Timestamp?
      Timestamp.from_json(json)
    rescue JSON::ParseException
      nil
    end

    # Has `rule_path` already been injected this session, for any file?
    def injected?(rule_path : String) : Bool
      @injected.has_key?(rule_path)
    end

    # The injected rule paths, for inspection.
    def injected : Array(String)
      @injected.values.map(&.path)
    end

    # Record `rule_path` as injected this session, with the cause that first
    # triggered it. A rule already recorded keeps its original cause — first
    # injection wins, even if a later, different file would also match it.
    def add(rule_path : String, cause : Cause) : Nil
      @injected[rule_path] ||= Injection.new(rule_path, cause)
    end

    # Mark the one-time session-start notice as delivered.
    def notify! : Nil
      @notified = true
    end

    # Persist the state for `session_id`, stamping `now`. Entries are sorted by
    # path and the document is pretty-printed so the file is byte-stable for a
    # given set and easy to scan by hand for debugging. A nil or unsafe (see
    # `.key?`) `session_id` is a no-op.
    def save(repo_root : Path, fs : Filesystem, session_id : String?, now : Time) : Nil
      return unless session_id = SessionState.key?(session_id)
      entries = @injected.values.sort_by! { |entry| {entry.path, entry.cause.file} }
      document = Document.new(now.to_unix, entries, @notified)
      fs.write(SessionState.file_for(repo_root, session_id).to_s, document.to_document)
    end

    # Callers (`.load`/`#save`) only ever pass a `session_id` already filtered
    # through `.key?`, so this is a plain, safe join — never a caller of raw
    # hook-payload input.
    def self.file_for(repo_root : Path, session_id : String) : Path
      repo_root.join(DIR, "#{session_id}.json")
    end
  end
end
