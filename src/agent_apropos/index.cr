require "json"
require "./conventions"

module AgentApropos
  struct Index
    SCHEMA_VERSION = 1

    struct Entry
      include JSON::Serializable

      getter path : String
      getter hash : String
      getter? layer2 : Bool
      getter? layer3 : Bool
      getter? skill : Bool
      getter paths : Array(String)
      getter contents : Array(String)
      getter description : String?

      def initialize(
        @path : String,
        @hash : String,
        @layer2 : Bool,
        @layer3 : Bool,
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
          layer2: convention.layer2?,
          layer3: convention.layer3?,
          skill: convention.skill?,
          paths: fm.paths,
          contents: fm.contents,
          description: fm.description,
        )
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
