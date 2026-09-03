require "yaml"
require "./errors"

module AgentApropos
  struct Frontmatter
    class Error < AgentApropos::Error
    end

    enum Event
      Write
      Removed
    end

    KNOWN_KEYS = ["paths", "contents", "skill", "description", "lint", "on"]

    LINT_IGNORE = "ignore"

    OPEN_FENCE  = /\A---[^\S\r\n]*\r?\n/
    CLOSE_FENCE = /^---[^\S\r\n]*(?:\r?\n|\z)/m

    getter paths : Array(String)
    getter contents : Array(String)
    getter? skill : Bool
    getter description : String?
    getter lint : String?
    getter unknown_keys : Array(String)
    getter events : Set(Event)

    def initialize(
      @paths = [] of String,
      @contents = [] of String,
      @skill = false,
      @description = nil,
      @lint = nil,
      @unknown_keys = [] of String,
      @events = Set{Event::Write},
    )
    end

    def lint_ignore? : Bool
      lint == LINT_IGNORE
    end

    def scoped? : Bool
      !paths.empty? || !contents.empty?
    end

    def reference_only? : Bool
      !scoped? && !skill?
    end

    def self.split(text : String) : {Frontmatter?, String}
      open = text.match(OPEN_FENCE)
      return {nil, text} unless open

      after_open = text[open.end..]
      close = after_open.match(CLOSE_FENCE)
      raise Error.new("unterminated frontmatter block") unless close

      yaml = after_open[0, close.begin]
      body = after_open[close.end..]
      {parse(yaml), body}
    end

    # Quotes only the literal `on:` key so other YAML-boolean-true spellings (`yes:`, `TRUE:`, ...) stay unaliased.
    ON_KEY_LINE = /^(\s*)on:/m

    private def self.preserve_on_key(yaml : String) : String
      yaml.gsub(ON_KEY_LINE) { "#{$~[1]}\"on\":" }
    end

    def self.parse(yaml : String) : Frontmatter
      any =
        begin
          YAML.parse(preserve_on_key(yaml))
        rescue ex : YAML::ParseException
          raise Error.new("invalid YAML frontmatter: #{ex.message}")
        end

      return new if any.raw.nil?

      hash = any.as_h?
      raise Error.new("frontmatter must be a mapping") if hash.nil?

      unknown = hash.keys.compact_map(&.as_s?).reject { |key| KNOWN_KEYS.includes?(key) }.sort!
      new(
        paths: string_list(hash, "paths"),
        contents: string_list(hash, "contents"),
        skill: boolean(hash, "skill"),
        description: string(hash, "description"),
        lint: string(hash, "lint"),
        unknown_keys: unknown,
        events: events(hash),
      )
    end

    private def self.fetch(hash, key)
      value = hash[key]?
      return nil if value.nil? || value.raw.nil?
      value
    end

    private def self.string_list(hash, key) : Array(String)
      value = fetch(hash, key)
      return [] of String if value.nil?
      array = value.as_a?
      raise Error.new("`#{key}` must be a list of strings") if array.nil?
      array.map do |item|
        item.as_s? || raise Error.new("`#{key}` entries must be strings")
      end
    end

    private def self.boolean(hash, key) : Bool
      value = fetch(hash, key)
      return false if value.nil?
      bool = value.as_bool?
      raise Error.new("`#{key}` must be a boolean") if bool.nil?
      bool
    end

    private def self.string(hash, key) : String?
      value = fetch(hash, key)
      return nil if value.nil?
      str = value.as_s?
      raise Error.new("`#{key}` must be a string") if str.nil?
      str
    end

    private def self.events(hash) : Set(Event)
      value = fetch(hash, "on")
      return Set{Event::Write} if value.nil?

      array = value.as_a?
      raise Error.new("`on` must be a list of strings") if array.nil?

      array.reduce(Set(Event).new) do |set, item|
        name = item.as_s? || raise Error.new("`on` entries must be strings")
        set << event(name)
      end
    end

    private def self.event(name : String) : Event
      case name
      when "write"   then Event::Write
      when "removed" then Event::Removed
      else
        raise Error.new("`on` has an unrecognized event: #{name}")
      end
    end
  end
end
