require "ameba"

module Ameba::Rule::Apropos
  class CommentBlock < Base
    properties do
      description "Disallows multi-line comment blocks; code and specs are the source of truth"
    end

    MSG       = "Multi-line comment block — express this in a name or a spec instead (see docs/conventions/comments.md)"
    DIRECTIVE = /\A#\s*ameba:(disable|enable)\b/

    def test(source)
      run_start = nil
      run_length = 0
      run_end_line = -1
      line_has_code = false

      flush = -> do
        if run_length >= 2 && (start = run_start)
          issue_for start, MSG
        end
        run_start = nil
        run_length = 0
      end

      Tokenizer.new(source).run do |token|
        case token.type
        when .newline?
          line_has_code = false
        when .space?
        when .comment?
          if token.value.to_s =~ DIRECTIVE || line_has_code
            flush.call
            run_end_line = -1
          elsif token.line_number == run_end_line + 1
            run_length += 1
            run_end_line = token.line_number
          else
            flush.call
            run_start = {token.line_number, token.column_number}
            run_length = 1
            run_end_line = token.line_number
          end
          line_has_code = true
        else
          line_has_code = true
        end
      end

      flush.call
    end
  end
end
