require "json"
require "./conventions"

module AgentApropos
  struct Index
    SCHEMA_VERSION = 2

    struct Entry
      include JSON::Serializable

      getter path : String
      getter hash : String
      getter? skill : Bool
      getter paths : Array(String)
      getter contents : Array(String)
      getter description : String?

      def initialize(
        @path : String,
        @hash : String,
        @skill : Bool,
        @paths : Array(String),
        @contents : Array(String),
        @description : String?,
      )
      end

      def self.from(convention : Convention) : Entry
        fm = convention.frontmatter
        new(
          path: convention.path,
          hash: convention.hash,
          skill: convention.skill?,
          paths: fm.paths,
          contents: fm.contents,
          description: fm.description,
        )
      end

      def triggers(relative_path : String, content : String?) : Array(String)?
        Matcher.triggers(paths, contents, relative_path, content)
      end
    end

    include JSON::Serializable

    @[JSON::Field(key: "schema_version")]
    getter schema_version : Int32
    getter docs : Array(Entry)

    def initialize(@docs : Array(Entry), @schema_version : Int32 = SCHEMA_VERSION)
    end

    def self.build(conventions : Array(Convention)) : Index
      new(conventions.map { |convention| Entry.from(convention) })
    end

    def self.load(json : String) : Index?
      index = from_json(json)
      return nil unless index.schema_version == SCHEMA_VERSION
      index
    rescue JSON::ParseException
      nil
    end

    def covers?(conventions : Array(Convention)) : Bool
      docs.map { |entry| {entry.path, entry.hash} } ==
        conventions.map { |convention| {convention.path, convention.hash} }
    end

    def to_document : String
      String.build do |io|
        to_pretty_json(io)
        io << '\n'
      end
    end
  end
end
