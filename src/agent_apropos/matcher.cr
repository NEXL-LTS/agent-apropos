require "./errors"

module AgentApropos
  module Matcher
    extend self

    class Error < AgentApropos::Error
    end

    def path_match?(pattern : String, path : String) : Bool
      File.match?(pattern, path)
    end

    def matching_paths(patterns : Enumerable(String), path : String) : Array(String)
      patterns.select { |pattern| path_match?(pattern, path) }
    end

    def content_match?(source : String, content : String) : Bool
      compile(source).matches?(content)
    rescue ex : Regex::Error
      raise Error.new("regex #{source.inspect} failed to match #{content.bytesize} bytes: #{ex.message}")
    end

    def matching_contents(sources : Enumerable(String), content : String) : Array(String)
      sources.select { |source| content_match?(source, content) }
    end

    def triggers(paths : Array(String), contents : Array(String),
                 path : String, content : String?) : Array(String)?
      return nil if paths.empty? && contents.empty?

      path_hits = matching_paths(paths, path)
      return nil if path_hits.empty? && !paths.empty?

      return nil if content.nil? && !contents.empty?
      content_hits = content ? matching_contents(contents, content) : [] of String
      return nil if content_hits.empty? && !contents.empty?

      path_hits + content_hits
    end

    MAX_BRACE_DEPTH = 10

    def valid_glob?(pattern : String) : Bool
      chars = pattern.chars
      index = 0
      brace_depth = 0

      while index < chars.size
        char = chars[index]
        brace_depth += 1 if char == '{'
        brace_depth -= 1 if char == '}' && brace_depth > 0
        return false if brace_depth > MAX_BRACE_DEPTH

        index = next_index_after(chars, index, char)
        return false if index > chars.size
      end

      true
    end

    private def next_index_after(chars : Array(Char), index : Int32, char : Char) : Int32
      case char
      when '\\' then index + 2
      when '['  then past_character_set(chars, index) || chars.size + 1
      else           index + 1
      end
    end

    private def past_character_set(chars : Array(Char), open : Int32) : Int32?
      index = open + 1
      index += 1 if chars[index]? == '^'

      first = true
      while index < chars.size && (first || chars[index] != ']')
        index = past_member(chars, index)
        index = past_member(chars, index + 1) if range_separator?(chars, index)
        first = false
      end

      index < chars.size ? index + 1 : nil
    end

    private def range_separator?(chars : Array(Char), index : Int32) : Bool
      index + 1 < chars.size && chars[index] == '-' && chars[index + 1] != ']'
    end

    private def past_member(chars : Array(Char), index : Int32) : Int32
      chars[index]? == '\\' ? index + 2 : index + 1
    end

    def compile(source : String) : Regex
      Regex.new(source)
    rescue ex : ArgumentError
      raise Error.new("invalid regex #{source.inspect}: #{ex.message}")
    end
  end
end
