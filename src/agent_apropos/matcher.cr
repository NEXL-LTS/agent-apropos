require "./errors"

module AgentApropos
  module Matcher
    extend self

    class Error < AgentApropos::Error
    end

    def path_match?(pattern : String, path : String) : Bool
      File.match?(pattern, path)
    end

    def any_path_match?(patterns : Enumerable(String), path : String) : Bool
      patterns.any? { |pattern| path_match?(pattern, path) }
    end

    def matching_paths(patterns : Enumerable(String), path : String) : Array(String)
      patterns.select { |pattern| path_match?(pattern, path) }
    end

    def content_match?(source : String, content : String) : Bool
      compile(source).matches?(content)
    rescue ex : Regex::Error
      raise Error.new("regex #{source.inspect} failed to match #{content.bytesize} bytes: #{ex.message}")
    end

    def any_content_match?(sources : Enumerable(String), content : String) : Bool
      sources.any? { |source| content_match?(source, content) }
    end

    def matching_contents(sources : Enumerable(String), content : String) : Array(String)
      sources.select { |source| content_match?(source, content) }
    end

    def valid_glob?(pattern : String) : Bool
      sample = pattern.gsub(/[*?\[\]!]/, "a")
      File.match?(pattern, sample)
      true
    rescue File::BadPatternError
      false
    end

    def compile(source : String) : Regex
      Regex.new(source)
    rescue ex : ArgumentError
      raise Error.new("invalid regex #{source.inspect}: #{ex.message}")
    end
  end
end
