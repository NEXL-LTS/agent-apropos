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

      content_hits = content ? matching_contents(contents, content) : [] of String
      return nil if content_hits.empty? && !contents.empty?

      path_hits + content_hits
    end

    WELL_FORMED_GLOB = /\A(?:[^\[\\]|\\[\s\S]|\[\^?(?:\\[\s\S]|[^\\])(?:\\[\s\S]|[^\]\\])*\])*\z/

    def valid_glob?(pattern : String) : Bool
      return false unless WELL_FORMED_GLOB.matches?(pattern)

      File.match?(pattern, pattern)
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
