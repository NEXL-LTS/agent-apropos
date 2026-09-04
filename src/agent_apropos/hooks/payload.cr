require "json"

module AgentApropos
  module Hook
    struct Payload
      include JSON::Serializable

      @[JSON::Field(key: "session_id")]
      getter session_id_snake : String?

      @[JSON::Field(key: "sessionId")]
      getter session_id_camel : String?

      @[JSON::Field(key: "tool_name")]
      getter tool_name_snake : String?

      @[JSON::Field(key: "toolName")]
      getter tool_name_camel : String?

      getter cwd : String?
      getter tool_input : ToolInput?

      getter hook_event_name : String?

      @[JSON::Field(key: "toolArgs")]
      getter copilot_tool_args : String?

      struct Edit
        include JSON::Serializable
        getter new_string : String?
      end

      struct ToolInput
        include JSON::Serializable

        getter file_path : String?
        getter content : String?
        getter new_string : String?
        getter edits : Array(Edit)?

        getter command : String?

        getter offset : JSON::Any?
        getter limit : JSON::Any?
      end

      struct CopilotArgs
        include JSON::Serializable
        getter path : String?
        getter file_text : String?
        getter new_str : String?

        getter view_range : JSON::Any?
      end

      def self.parse(json : String) : Payload?
        from_json(json)
      rescue JSON::ParseException
      end

      def session_id : String?
        session_id_snake || session_id_camel
      end

      def tool_name : String?
        tool_name_snake || tool_name_camel
      end

      def copilot? : Bool
        !copilot_tool_args.nil?
      end

      def file_path : String?
        tool_input.try(&.file_path) || copilot_args.try(&.path)
      end

      def partial_read? : Bool
        ranges = [tool_input.try(&.offset), tool_input.try(&.limit), copilot_args.try(&.view_range)]
        ranges.any? { |range| range && !range.raw.nil? }
      end

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

      private def copilot_args : CopilotArgs?
        raw = copilot_tool_args
        return nil unless raw
        CopilotArgs.from_json(raw)
      rescue JSON::ParseException
      end

      struct FileEdit
        getter path : String
        getter written_contents : Array(String)

        def initialize(@path : String, @written_contents : Array(String))
        end
      end

      def file_edits : Array(FileEdit)
        return ApplyPatch.parse(tool_input.try(&.command))[0] if tool_name == "apply_patch"
        path = file_path
        path ? [FileEdit.new(path, written_contents)] : [] of FileEdit
      end

      struct Removal
        getter path : String

        def initialize(@path)
        end
      end

      def removals : Array(Removal)
        return ApplyPatch.parse(tool_input.try(&.command))[1] if tool_name == "apply_patch"
        [] of Removal
      end

      module ApplyPatch
        extend self

        ADD_MARKER    = "*** Add File: "
        UPDATE_MARKER = "*** Update File: "
        DELETE_MARKER = "*** Delete File: "
        MOVE_MARKER   = "*** Move to: "
        END_MARKER    = "*** End Patch"

        def parse(command : String?) : {Array(FileEdit), Array(Removal)}
          return {[] of FileEdit, [] of Removal} unless command
          lines = command.lines
          edits = [] of FileEdit
          removals = [] of Removal
          i = 0
          while i < lines.size
            line = lines[i]
            if path = (prefix(line, ADD_MARKER) || prefix(line, UPDATE_MARKER))
              i, edit = read_section(lines, i + 1, path)
              edits << edit
            elsif path = prefix(line, DELETE_MARKER)
              i, _ = read_section(lines, i + 1, "")
              removals << Removal.new(path)
            else
              i += 1
            end
          end
          {edits, removals}
        end

        private def prefix(line : String, marker : String) : String?
          return nil unless line.starts_with?(marker)
          value = line[marker.size..].strip
          value.empty? ? nil : value
        end

        private def section_marker?(line : String) : Bool
          line.starts_with?(ADD_MARKER) || line.starts_with?(UPDATE_MARKER) ||
            line.starts_with?(DELETE_MARKER) || line.starts_with?(END_MARKER)
        end

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
