require "json"

module AgentApropos
  module Hook
    # The hook input contract, shared across every wired CLI agent's own wire
    # format (Claude Code's PreToolUse/PostToolUse payload; Gemini CLI's
    # AfterTool payload, whose `write_file`/`replace` tools happen to use the
    # same `file_path`/`content`/`new_string` argument names; Codex CLI's own
    # PreToolUse/PostToolUse payload, whose envelope and `Bash` tool mirror
    # Claude's almost exactly, but whose `apply_patch` tool's `tool_input` is a
    # whole multi-file patch envelope rather than a single `file_path`/
    # `content` — see `#file_edits`/`ApplyPatch`). Parsing is deliberately
    # *tolerant*: every field is optional, unknown keys are ignored,
    # and malformed JSON yields nil rather than raising — the hook path must fail
    # open, and the field names are the part of the contract most
    # exposed to upstream schema drift. The captured fixtures under
    # `spec/fixtures/hook_payloads/` — not this struct — are the authoritative
    # record of the field names; this parser just follows them.
    struct Payload
      include JSON::Serializable

      @[JSON::Field(key: "session_id")]
      getter session_id_snake : String?

      # GitHub Copilot CLI's own key for the same field — see the dialect note
      # on `copilot?` below.
      @[JSON::Field(key: "sessionId")]
      getter session_id_camel : String?

      @[JSON::Field(key: "tool_name")]
      getter tool_name_snake : String?

      # GitHub Copilot CLI's own key for the same field.
      @[JSON::Field(key: "toolName")]
      getter tool_name_camel : String?

      getter cwd : String?
      getter tool_input : ToolInput?

      # Gemini CLI's own marker for its single `AfterTool` event, present on
      # every payload it sends regardless of tool — used only to auto-detect
      # which `Agents::Agent` dialect a payload came from when `--tool` was
      # not passed on the command line.
      getter hook_event_name : String?

      # Copilot CLI's own tool-argument field: a JSON-encoded STRING (not a
      # nested object), parsed lazily by `copilot_args` below.
      @[JSON::Field(key: "toolArgs")]
      getter copilot_tool_args : String?

      # One entry of a batch-edit tool input (a `MultiEdit`-style shape, absent
      # in some Claude Code versions). Only its `new_string` matters
      # for Layer 3 content matching.
      struct Edit
        include JSON::Serializable
        getter new_string : String?
      end

      struct ToolInput
        include JSON::Serializable

        getter file_path : String?
        getter content : String?    # Write
        getter new_string : String? # Edit
        getter edits : Array(Edit)? # batch edit

        # Codex CLI's own field, shared by two of its tools: a shell string
        # for its `Bash` tool, or a whole patch envelope (see `ApplyPatch`)
        # for its `apply_patch` tool. Which one it is depends on the
        # payload's `tool_name` — see `Payload#file_edits`.
        getter command : String?
      end

      # GitHub Copilot CLI's `toolArgs`, once parsed out of its enclosing
      # string: keyed by path/file_text/old_str/new_str rather than
      # file_path/content/new_string — confirmed against a real captured hook
      # payload, not upstream docs (which type `toolArgs` as `unknown`).
      struct CopilotArgs
        include JSON::Serializable
        getter path : String?
        getter file_text : String? # create
        getter old_str : String?   # edit
        getter new_str : String?   # edit
      end

      # Parse hook JSON from stdin, returning nil on anything malformed so the
      # caller emits nothing and exits 0.
      def self.parse(json : String) : Payload?
        from_json(json)
      rescue JSON::ParseException
        nil
      end

      # `session_id` is the field every other accessor and `Hook` itself reads
      # — merging both dialects here means nothing downstream needs to know
      # there are two wire formats.
      def session_id : String?
        session_id_snake || session_id_camel
      end

      # `tool_name` merges both dialects the same way `session_id` does —
      # nothing downstream needs to know Copilot spells it `toolName`.
      def tool_name : String?
        tool_name_snake || tool_name_camel
      end

      # Whether this payload arrived in Copilot CLI's own dialect. Detected by
      # the presence of `toolArgs` — the field structurally unique to it, and
      # one every Copilot payload carries regardless of tool (unlike
      # `session_id`, which a malformed/partial payload could plausibly omit
      # either way). `Hook.emit` uses this to reply in Copilot's flat
      # `additionalContext` shape instead of the `hookSpecificOutput` envelope
      # every other wired agent expects — never the reverse, so an
      # already-wired agent's output never changes.
      def copilot? : Bool
        !copilot_tool_args.nil?
      end

      # The edited file's path, if the payload carries one.
      def file_path : String?
        tool_input.try(&.file_path) || copilot_args.try(&.path)
      end

      # Every piece of written content the payload exposes for Layer 3 matching:
      # a Write's `content`, an Edit's `new_string`, each `new_string` of a
      # batch edit, and Copilot's `file_text`/`new_str`. Empty when none is
      # present (the caller then reads the file from disk).
      def written_contents : Array(String)
        pieces = [] of String
        if input = tool_input
          input.content.try { |value| pieces << value }
          input.new_string.try { |value| pieces << value }
          input.edits.try(&.each { |edit| edit.new_string.try { |value| pieces << value } })
        end
        if args = copilot_args
          args.file_text.try { |value| pieces << value }
          args.new_str.try { |value| pieces << value }
        end
        pieces
      end

      # `copilot_tool_args`, parsed — nil when absent or malformed (fail open;
      # `copilot?` still reports true on malformed JSON, since the field was
      # present and this payload is still Copilot-shaped, just unreadable).
      private def copilot_args : CopilotArgs?
        raw = copilot_tool_args
        return nil unless raw
        CopilotArgs.from_json(raw)
      rescue JSON::ParseException
        nil
      end

      # One file this payload's edit touches, together with the newly
      # written content for that file specifically (empty when none, e.g. a
      # Delete section). Every dialect but Codex's `apply_patch` touches
      # exactly one file per tool call, so this is normally a single-element
      # array built from `#file_path`/`#written_contents`; `apply_patch`'s own
      # patch envelope can bundle several Add/Update File sections into one
      # call, so it can return more. Each file's content must be matched
      # (Layer 3) and AND-scoped against its own path independently — never
      # pooled across files, or a rule could fire because one file's content
      # matched while a different file's path did — so callers must iterate
      # this rather than falling back to the single-file accessors.
      struct FileEdit
        getter path : String
        getter written_contents : Array(String)

        def initialize(@path : String, @written_contents : Array(String))
        end
      end

      def file_edits : Array(FileEdit)
        return ApplyPatch.parse(tool_input.try(&.command)) if tool_name == "apply_patch"
        path = file_path
        path ? [FileEdit.new(path, written_contents)] : [] of FileEdit
      end

      # Parses Codex CLI's `apply_patch` tool's own patch envelope out of
      # `tool_input.command` — confirmed against a real captured Codex hook
      # payload, not upstream docs. Not a standard unified diff: sections
      # start with `*** Add File: <path>`, `*** Update File: <path>`
      # (optionally followed by a `*** Move to: <path>` rename), or `***
      # Delete File: <path>` (this last one per OpenAI's public apply_patch
      # format spec — not itself independently captured live), each running
      # until the next such marker or `*** End Patch`. Only Add/Update
      # sections become a `FileEdit` — a Delete has no newly written content
      # to match Layer 3 against, and no other wired agent's hooks fire on a
      # pure delete either, so this keeps Codex's scope consistent with the
      # rest of the layer model.
      module ApplyPatch
        extend self

        ADD_MARKER    = "*** Add File: "
        UPDATE_MARKER = "*** Update File: "
        DELETE_MARKER = "*** Delete File: "
        MOVE_MARKER   = "*** Move to: "
        END_MARKER    = "*** End Patch"

        def parse(command : String?) : Array(FileEdit)
          return [] of FileEdit unless command
          lines = command.lines
          edits = [] of FileEdit
          i = 0
          while i < lines.size
            line = lines[i]
            if path = (prefix(line, ADD_MARKER) || prefix(line, UPDATE_MARKER))
              i, edit = read_section(lines, i + 1, path)
              edits << edit
            elsif prefix(line, DELETE_MARKER)
              i, _ = read_section(lines, i + 1, "")
            else
              i += 1
            end
          end
          edits
        end

        private def prefix(line : String, marker : String) : String?
          line.starts_with?(marker) ? line[marker.size..].strip : nil
        end

        private def section_marker?(line : String) : Bool
          line.starts_with?(ADD_MARKER) || line.starts_with?(UPDATE_MARKER) ||
            line.starts_with?(DELETE_MARKER) || line.starts_with?(END_MARKER)
        end

        # Collect one section's added (`+`-prefixed) lines up to (not
        # including) the next section marker, honoring a `*** Move to:
        # <path>` line as the file's final path when present.
        private def read_section(lines : Array(String), start : Int32, path : String) : {Int32, FileEdit}
          added = [] of String
          effective_path = path
          i = start
          while i < lines.size && !section_marker?(lines[i])
            line = lines[i]
            if moved = prefix(line, MOVE_MARKER)
              effective_path = moved
            elsif line.starts_with?("+")
              added << line[1..]
            end
            i += 1
          end
          {i, FileEdit.new(effective_path, added)}
        end
      end
    end
  end
end
