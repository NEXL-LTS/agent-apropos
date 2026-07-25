require "json"

module AgentApropos
  module Hook
    # The hook input contract, shared across every wired CLI agent's own wire
    # format (Claude Code's PreToolUse/PostToolUse payload; Gemini CLI's
    # AfterTool payload, whose `write_file`/`replace` tools happen to use the
    # same `file_path`/`content`/`new_string` argument names). Parsing is
    # deliberately *tolerant*: every field is optional, unknown keys are ignored,
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
    end
  end
end
