require "json"
require "./conventions"
require "./index"
require "./matcher"
require "./filesystem"
require "./rendering"
require "./git"
require "./frontmatter"

module AgentApropos
  module Review
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]

    DEFAULT_BASE_CANDIDATES = %w[origin/main origin/master main master]

    struct RuleMatch
      getter path : String
      getter triggers : Array(String)
      getter verify : String?
      getter body : String

      def initialize(@path, @triggers, @verify, @body)
      end

      def to_json(json : JSON::Builder) : Nil
        {path: path, triggers: triggers, verify: verify}.to_json(json)
      end
    end

    struct FileMatches
      getter path : String
      getter rules : Array(RuleMatch)

      def initialize(@path, @rules)
      end

      def to_json(json : JSON::Builder) : Nil
        {path: path, rules: rules}.to_json(json)
      end
    end

    def match(repo_root : Path, fs : Filesystem, paths : Array(String),
              format : String, stdin_content : String?, stdout : IO, stderr : IO,
              allow_outside : Bool = false) : Int32
      conventions = load_conventions(repo_root, fs, allow_outside)
      files = paths.map do |given|
        resolve_path(repo_root, fs, conventions, given, stdin_content)
      end
      render_match(files, format, stdout)
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos match: #{ex.message}"
      1
    end

    def run(repo_root : Path, fs : Filesystem, git : Git, range : String?,
            format : String, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions = load_conventions(repo_root, fs, allow_outside)
      resolved = range || default_range(git, repo_root)
      files = parse_diff(git.diff(repo_root, resolved)).map do |parsed|
        FileMatches.new(parsed.path, file_rules(conventions, parsed))
      end
      render_review(resolved, files, format, stdout)
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos review: #{ex.message}"
      1
    end

    private def load_conventions(repo_root : Path, fs : Filesystem, allow_outside : Bool) : Array(Convention)
      list = Conventions.walk(repo_root, fs, allow_outside)
      refresh_index(repo_root, fs, list)
      list
    end

    private def refresh_index(repo_root : Path, fs : Filesystem, list : Array(Convention)) : Nil
      path = repo_root.join(INDEX_RELATIVE).to_s
      existing = fs.read?(path).try { |json| Index.load(json) }
      return if existing && existing.covers?(list)
      fs.write(path, Index.build(list).to_document)
    rescue
    end

    private def resolve_path(repo_root : Path, fs : Filesystem, conventions : Array(Convention),
                             given : String, stdin_content : String?) : FileMatches
      relative = relativize(repo_root, given)
      content = stdin_content || fs.read?(absolute(repo_root, given))
      FileMatches.new(relative, rules_for(conventions, relative, content))
    end

    private def rules_for(conventions : Array(Convention), relative : String, content : String?,
                          event : Frontmatter::Event = Frontmatter::Event::Write) : Array(RuleMatch)
      conventions.compact_map { |convention| rule_for(convention, relative, content, event) }
    end

    private def rule_for(convention : Convention, relative : String, content : String?,
                         event : Frontmatter::Event) : RuleMatch?
      hits = convention.triggers(relative, content, event)
      return nil unless hits
      RuleMatch.new(convention.path, hits, convention.verify, convention.body.strip)
    end

    private def file_rules(conventions : Array(Convention), file : ParsedFile) : Array(RuleMatch)
      rules = [] of RuleMatch
      unless file.deleted
        rules.concat(rules_for(conventions, file.path, file.added, Frontmatter::Event::Write))
      end
      removal_path = file.deleted ? file.path : file.old_path
      if removal_path
        rules.concat(rules_for(conventions, removal_path, file.removed, Frontmatter::Event::Removed))
      end
      rules
    end

    private def absolute(repo_root : Path, given : String) : String
      path = Path[given]
      path.absolute? ? path.to_s : repo_root.join(path).to_s
    end

    private def relativize(repo_root : Path, given : String) : String
      path = Path[given]
      path.absolute? ? path.relative_to(repo_root).to_posix.to_s : path.to_posix.to_s
    end

    private def default_range(git : Git, repo_root : Path) : String
      "#{default_base(git, repo_root)}...HEAD"
    end

    private def default_base(git : Git, repo_root : Path) : String
      git.symbolic_ref(repo_root, "refs/remotes/origin/HEAD") ||
        DEFAULT_BASE_CANDIDATES.find { |candidate| git.ref_exists?(repo_root, candidate) } ||
        raise Git::Error.new("could not determine the default branch; pass an explicit range (e.g. origin/main...HEAD)")
    end

    private record ParsedFile, path : String, old_path : String?, added : String, removed : String, deleted : Bool

    private class DiffState
      getter order = [] of String
      getter added = {} of String => Array(String)
      getter removed = {} of String => Array(String)
      getter old_paths = {} of String => String?
      getter deleted = {} of String => Bool
      property current : String? = nil
      property pending_old : String? = nil
      property hunk_path : String? = nil
    end

    private def parse_diff(diff : String) : Array(ParsedFile)
      state = DiffState.new
      diff.each_line { |line| step(state, line) }
      state.order.map do |path|
        ParsedFile.new(path, state.old_paths[path], state.added[path].join('\n'),
          state.removed[path].join('\n'), state.deleted[path])
      end
    end

    private def step(state : DiffState, line : String) : Nil
      if line.starts_with?("--- ")
        state.pending_old = diff_path(line)
      elsif line.starts_with?("+++ ")
        state.current = register_file(state, line)
        state.hunk_path = nil
      elsif line.starts_with?("@@")
        state.hunk_path = state.current
      elsif path = state.hunk_path
        collect_line(state, line, path)
      end
    end

    private def register_file(state : DiffState, line : String) : String?
      pending_old = state.pending_old
      target = diff_path(line)
      path = target || pending_old
      if path && !state.added.has_key?(path)
        state.added[path] = [] of String
        state.removed[path] = [] of String
        state.old_paths[path] = (target && pending_old && pending_old != target) ? pending_old : nil
        state.deleted[path] = target.nil?
        state.order << path
      end
      path
    end

    private def collect_line(state : DiffState, line : String, path : String) : Nil
      if line.starts_with?('+')
        state.added[path] << line[1..]
      elsif line.starts_with?('-')
        state.removed[path] << line[1..]
      end
    end

    private def diff_path(line : String) : String?
      target = line[4..].rstrip
      return nil if target == "/dev/null"
      strip_prefix(target)
    end

    private def strip_prefix(target : String) : String
      target.sub(/\A[ab]\//, "")
    end

    private def render_match(files : Array(FileMatches), format : String, stdout : IO) : Nil
      case format
      when "json"
        stdout.puts({files: files}.to_pretty_json)
      when "full"
        stdout.puts Rendering.context(unique_docs(files))
      else
        rule_paths(files).each { |path| stdout.puts path }
      end
    end

    private def render_review(range : String, files : Array(FileMatches),
                              format : String, stdout : IO) : Nil
      case format
      when "json"
        stdout.puts({range: range, files: files}.to_pretty_json)
      else
        render_review_md(range, files, stdout)
      end
    end

    private def render_review_md(range : String, files : Array(FileMatches), io : IO) : Nil
      io << "# Review manifest (#{range})\n\n"
      applicable = files.reject(&.rules.empty?)
      io << "No conventions apply to the changed files.\n" if applicable.empty?
      applicable.each { |file| render_file_md(io, file) }
    end

    private def render_file_md(io : IO, file : FileMatches) : Nil
      io << "## #{file.path}\n\n"
      file.rules.each { |rule| render_rule_md(io, rule) }
      io << '\n'
    end

    private def render_rule_md(io : IO, rule : RuleMatch) : Nil
      io << "- #{rule.path} (#{rule.triggers.map { |trigger| "`#{trigger}`" }.join(", ")})\n"
      verify_items(rule.verify).each { |item| io << "  - [ ] #{item}\n" }
    end

    private def verify_items(verify : String?) : Array(String)
      return [] of String unless verify
      verify.each_line.map(&.strip).reject(&.empty?).map { |item| item.sub(/\A[-*+]\s+/, "").sub(/\A\d+[.)]\s+/, "") }.to_a
    end

    private def rule_paths(files : Array(FileMatches)) : Array(String)
      unique_docs(files).map(&.first)
    end

    private def unique_docs(files : Array(FileMatches)) : Array({String, String})
      docs = files.flat_map(&.rules).to_h { |rule| {rule.path, rule.body} }.to_a
      docs.sort_by { |(path, _)| path }
    end
  end
end
