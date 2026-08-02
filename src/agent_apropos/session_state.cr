require "json"
require "./filesystem"

module AgentApropos
  class SessionState
    DIR = Path[".cache", "agent-apropos", "sessions"]

    MAX_AGE = 7.days

    MAX_ID_BYTES = 230

    LEADING_REJECT = {'.', '-'}

    struct Cause
      include JSON::Serializable

      getter layer : Int32 | String
      getter event : String
      getter file : String
      getter matched_patterns : Array(String)

      def initialize(@layer : Int32 | String, @event : String, @file : String, @matched_patterns : Array(String))
      end
    end

    struct Injection
      include JSON::Serializable

      getter path : String
      getter cause : Cause

      def initialize(@path : String, @cause : Cause)
      end
    end

    private struct Timestamp
      include JSON::Serializable

      @[JSON::Field(key: "updated_at")]
      getter updated_at : Int64
    end

    struct Document
      include JSON::Serializable

      @[JSON::Field(key: "updated_at")]
      getter updated_at : Int64
      getter injected : Array(Injection)
      getter? notified : Bool = false

      def initialize(@updated_at : Int64, @injected : Array(Injection), @notified : Bool = false)
      end

      def to_document : String
        String.build do |io|
          to_pretty_json(io)
          io << '\n'
        end
      end
    end

    getter? notified : Bool

    def initialize(@injected : Hash(String, Injection) = {} of String => Injection, @notified : Bool = false)
    end

    def self.key?(session_id : String?) : String?
      return nil unless session_id
      return nil if session_id.empty? || session_id.bytesize > MAX_ID_BYTES
      return nil if LEADING_REJECT.includes?(session_id[0])
      return nil if session_id.each_char.any?(&.control?)
      return nil unless single_component?(session_id)
      session_id
    end

    private def self.single_component?(session_id : String) : Bool
      path = Path.windows(session_id)
      path.parts == [session_id] && path.anchor.nil?
    end

    def self.load(repo_root : Path, fs : Filesystem, session_id : String?) : SessionState
      return new unless session_id = key?(session_id)
      json = fs.read?(file_for(repo_root, session_id).to_s)
      return new unless json
      document = Document.from_json(json)
      injected = document.injected.to_h { |entry| {entry.path, entry} }
      new(injected, document.notified?)
    rescue JSON::ParseException
      new
    end

    def self.prune(repo_root : Path, fs : Filesystem, now : Time) : Nil
      cutoff = (now - MAX_AGE).to_unix
      fs.glob(repo_root.join(DIR), "*.json").each do |file|
        json = fs.read?(file)
        next unless json
        timestamp = parse(json)
        next unless timestamp
        fs.remove(file) if timestamp.updated_at < cutoff
      end
    end

    private def self.parse(json : String) : Timestamp?
      Timestamp.from_json(json)
    rescue JSON::ParseException
      nil
    end

    def injected?(rule_path : String) : Bool
      @injected.has_key?(rule_path)
    end

    def injected : Array(String)
      @injected.values.map(&.path)
    end

    def add(rule_path : String, cause : Cause) : Nil
      @injected[rule_path] ||= Injection.new(rule_path, cause)
    end

    def notify! : Nil
      @notified = true
    end

    def save(repo_root : Path, fs : Filesystem, session_id : String?, now : Time) : Nil
      return unless session_id = SessionState.key?(session_id)
      entries = @injected.values.sort_by! { |entry| {entry.path, entry.cause.file} }
      document = Document.new(now.to_unix, entries, @notified)
      fs.write(SessionState.file_for(repo_root, session_id).to_s, document.to_document)
    end

    def self.file_for(repo_root : Path, session_id : String) : Path
      repo_root.join(DIR, "#{session_id}.json")
    end
  end
end
