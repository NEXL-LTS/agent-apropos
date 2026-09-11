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
    end

    struct FileMatches
      getter path : String
      getter rules : Array(RuleMatch)

      def initialize(@path, @rules)
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
      if base = git.symbolic_ref(repo_root, "refs/remotes/origin/HEAD")
        return base
      end
      DEFAULT_BASE_CANDIDATES.each do |candidate|
        return candidate if git.ref_exists?(repo_root, candidate)
      end
      raise Git::Error.new(
        "could not determine the default branch; pass an explicit range (e.g. origin/main...HEAD)"
      )
    end

    private record ParsedFile, path : String, old_path : String?, added : String, removed : String, deleted : Bool

    private record DiffState,
      order : Array(String) = [] of String,
      added : Hash(String, Array(String)) = {} of String => Array(String),
      removed : Hash(String, Array(String)) = {} of String => Array(String),
      old_paths : Hash(String, String?) = {} of String => String?,
      deleted : Hash(String, Bool) = {} of String => Bool

    private def parse_diff(diff : String) : Array(ParsedFile)
      state = DiffState.new
      current = nil
      pending_old = nil
      pending_rename_from = nil
      old_remaining = 0
      new_remaining = 0

      diff.each_line do |line|
        if old_remaining > 0 || new_remaining > 0
          # Line-count bookkeeping, not the text, decides where a hunk ends.
          old_remaining, new_remaining = consume_hunk_line(state, line, current, old_remaining, new_remaining)
        elsif line.starts_with?("rename from ")
          pending_rename_from = line[12..]
        elsif line.starts_with?("rename to ") && pending_rename_from
          current = register_rename(state, pending_rename_from, line[10..])
        elsif line.starts_with?("--- ")
          pending_old = diff_path(line)
        elsif line.starts_with?("+++ ")
          current = register_file(state, line, pending_old)
        elsif counts = hunk_counts(line)
          old_remaining, new_remaining = counts
        end
      end

      state.order.map do |path|
        ParsedFile.new(path, state.old_paths[path], state.added[path].join('\n'),
          state.removed[path].join('\n'), state.deleted[path])
      end
    end

    HUNK_HEADER = /\A@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/

    # A content line can coincidentally look like a file header.
    private def hunk_counts(line : String) : {Int32, Int32}?
      match = HUNK_HEADER.match(line)
      return nil unless match
      {(match[1]? || "1").to_i, (match[2]? || "1").to_i}
    end

    # "\ No newline at end of file" describes the prior line, not a new one.
    private def consume_hunk_line(state : DiffState, line : String, path : String?,
                                  old_remaining : Int32, new_remaining : Int32) : {Int32, Int32}
      return {old_remaining, new_remaining} if line.starts_with?('\\')
      if line.starts_with?('+')
        state.added[path] << line[1..] if path
        {old_remaining, new_remaining - 1}
      elsif line.starts_with?('-')
        state.removed[path] << line[1..] if path
        {old_remaining - 1, new_remaining}
      else
        {old_remaining - 1, new_remaining - 1}
      end
    end

    # A rename's own "rename from"/"rename to" pair registers it first, so this runs only for add/delete/same-path modify.
    private def register_file(state : DiffState, line : String, pending_old : String?) : String?
      target = diff_path(line)
      path = target || pending_old
      if path && !state.added.has_key?(path)
        state.added[path] = [] of String
        state.removed[path] = [] of String
        state.old_paths[path] = nil
        state.deleted[path] = target.nil?
        state.order << path
      end
      path
    end

    # A pure rename carries no "---"/"+++"/"@@"; a two-tree diff names a destination path at most once.
    private def register_rename(state : DiffState, old_path : String, new_path : String) : String?
      state.added[new_path] = [] of String
      state.removed[new_path] = [] of String
      state.old_paths[new_path] = old_path
      state.deleted[new_path] = false
      state.order << new_path
      new_path
    end

    private def diff_path(line : String) : String?
      target = line[4..].strip
      return nil if target == "/dev/null"
      strip_prefix(target)
    end

    private def strip_prefix(target : String) : String
      {"a/", "b/"}.each do |prefix|
        return target[prefix.size..] if target.starts_with?(prefix)
      end
      target
    end

    private def render_match(files : Array(FileMatches), format : String, stdout : IO) : Nil
      case format
      when "json"
        build_json(stdout) { |json| files_field(json, files) }
      when "full"
        stdout.puts Rendering.context(unique_docs(files))
      else
        rule_paths(files).each { |path| stdout.puts path }
      end
    end

    private def render_review(range : String, files : Array(FileMatches),
                              format : String, stdout : IO) : Nil
      if format == "json"
        build_json(stdout) do |json|
          json.field "range", range
          files_field(json, files)
        end
      else
        render_review_md(range, files, stdout)
      end
    end

    private def render_review_md(range : String, files : Array(FileMatches), io : IO) : Nil
      io << "# Review manifest (#{range})\n\n"
      applicable = files.select { |file| !file.rules.empty? }
      if applicable.empty?
        io << "No conventions apply to the changed files.\n"
        return
      end
      applicable.each do |file|
        io << "## #{file.path}\n\n"
        file.rules.each { |rule| render_rule_md(io, rule) }
        io << '\n'
      end
    end

    private def render_rule_md(io : IO, rule : RuleMatch) : Nil
      io << "- #{rule.path} (#{rule.triggers.map { |trigger| "`#{trigger}`" }.join(", ")})\n"
      verify_items(rule.verify).each { |item| io << "  - [ ] #{item}\n" }
    end

    private def verify_items(verify : String?) : Array(String)
      return [] of String unless verify
      items = [] of String
      verify.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        items << stripped.sub(/\A[-*+]\s+/, "").sub(/\A\d+[.)]\s+/, "")
      end
      items
    end

    private def build_json(io : IO, &) : Nil
      JSON.build(io, indent: "  ") do |json|
        json.object { yield json }
      end
      io.puts
    end

    private def files_field(json : JSON::Builder, files : Array(FileMatches)) : Nil
      json.field "files" do
        json.array { files.each { |file| file_object(json, file) } }
      end
    end

    private def file_object(json : JSON::Builder, file : FileMatches) : Nil
      json.object do
        json.field "path", file.path
        json.field "rules" do
          json.array { file.rules.each { |rule| rule_object(json, rule) } }
        end
      end
    end

    private def rule_object(json : JSON::Builder, rule : RuleMatch) : Nil
      json.object do
        json.field "path", rule.path
        json.field "triggers" do
          json.array { rule.triggers.each { |trigger| json.string trigger } }
        end
        json.field "verify", rule.verify
      end
    end

    private def rule_paths(files : Array(FileMatches)) : Array(String)
      files.flat_map { |file| file.rules.map(&.path) }.uniq!.sort!
    end

    private def unique_docs(files : Array(FileMatches)) : Array({String, String})
      seen = Set(String).new
      docs = [] of {String, String}
      files.each do |file|
        file.rules.each do |rule|
          docs << {rule.path, rule.body} if seen.add?(rule.path)
        end
      end
      docs.sort_by! { |(path, _)| path }
    end
  end
end
