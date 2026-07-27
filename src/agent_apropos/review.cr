require "json"
require "./conventions"
require "./index"
require "./matcher"
require "./filesystem"
require "./rendering"
require "./git"

module AgentApropos
  # The review-agent interface: `match` resolves the conventions that
  # apply to given paths (Layer 2 by path, Layer 3 by on-disk or stdin content),
  # and `review` resolves them for a git range (Layer 2 by path, Layer 3 by the
  # diff's *added* lines) and emits a checklist manifest harvesting each rule's
  # `## Verify` section. Both rebuild the index if missing or stale.
  #
  # These are review/CI commands (seconds of latency budget), so unlike the hook
  # path they fail **closed**: a malformed doc or git failure exits non-zero.
  module Review
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]

    # Default-branch probes when `review` gets no explicit range, tried after the
    # authoritative `origin/HEAD` symbolic ref.
    DEFAULT_BASE_CANDIDATES = %w[origin/main origin/master main master]

    # One convention that applies to a file, with the specific triggers hit and
    # its harvested `## Verify` text. `body` is carried for `--format full` and
    # excluded from JSON output.
    struct RuleMatch
      getter path : String
      getter layer : Int32
      getter triggers : Array(String)
      getter verify : String?
      getter body : String

      def initialize(@path, @layer, @triggers, @verify, @body)
      end
    end

    # A file and the conventions resolved for it.
    struct FileMatches
      getter path : String
      getter rules : Array(RuleMatch)

      def initialize(@path, @rules)
      end
    end

    # `agent-apropos match <path> [...paths]`. `stdin_content`, when given,
    # replaces the on-disk content for the (single) path so a proposed patch can
    # be tested.
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

    # `agent-apropos review [<git-range>]`. Resolves the range (default:
    # merge-base with the default branch), then matches each changed file's path
    # and added lines.
    def run(repo_root : Path, fs : Filesystem, git : Git, range : String?,
            format : String, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions = load_conventions(repo_root, fs, allow_outside)
      resolved = range || default_range(git, repo_root)
      files = parse_diff(git.diff(repo_root, resolved)).map do |(path, added)|
        FileMatches.new(path, rules_for(conventions, path, added))
      end
      render_review(resolved, files, format, stdout)
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos review: #{ex.message}"
      1
    end

    # Walk the docs (the fresh source of truth) and opportunistically rebuild the
    # index when missing or stale. Matching uses the walked
    # conventions directly, so a failed index write is non-fatal.
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
      # Best-effort cache warming; matching does not depend on the persisted index.
    end

    private def resolve_path(repo_root : Path, fs : Filesystem, conventions : Array(Convention),
                             given : String, stdin_content : String?) : FileMatches
      relative = relativize(repo_root, given)
      content = stdin_content || fs.read?(absolute(repo_root, given))
      FileMatches.new(relative, rules_for(conventions, relative, content))
    end

    private def rules_for(conventions : Array(Convention), relative : String, content : String?) : Array(RuleMatch)
      conventions.compact_map { |convention| rule_for(convention, relative, content) }
    end

    # Resolve how (if at all) `convention` applies to `relative`+`content`. A doc
    # is Layer 2 or Layer 3, never both, so at most one branch fires.
    private def rule_for(convention : Convention, relative : String, content : String?) : RuleMatch?
      fm = convention.frontmatter
      if convention.layer2? && convention.triggers_for_path?(relative)
        hits = fm.paths.select { |glob| Matcher.path_match?(glob, relative) }
        RuleMatch.new(convention.path, 2, hits, convention.verify, convention.body.strip)
      elsif content && convention.layer3? && convention.triggers_for_content?(relative, content)
        hits = fm.contents.select { |source| Matcher.content_match?(source, content) }
        RuleMatch.new(convention.path, 3, hits, convention.verify, convention.body.strip)
      end
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

    # Parse a unified diff into `{new_path, added_lines}` per changed file, in
    # order of appearance. Only
    # added lines within hunks are collected; deletions (`+++ /dev/null`) are
    # skipped.
    private def parse_diff(diff : String) : Array({String, String})
      order = [] of String
      added = {} of String => Array(String)
      current = nil
      in_hunk = false

      diff.each_line do |line|
        if line.starts_with?("+++ ")
          current = diff_target(line)
          if (path = current) && !added.has_key?(path)
            added[path] = [] of String
            order << path
          end
          in_hunk = false
        elsif line.starts_with?("@@")
          in_hunk = true
        elsif in_hunk && (path = current) && line.starts_with?('+')
          added[path] << line[1..]
        end
      end

      order.map { |path| {path, added[path].join('\n')} }
    end

    private def diff_target(line : String) : String?
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
      io << "- #{rule.path} (Layer #{rule.layer})\n"
      verify_items(rule.verify).each { |item| io << "  - [ ] #{item}\n" }
    end

    # Split a `## Verify` section into individual checklist criteria, stripping
    # any existing list markers so each line becomes one `- [ ]` item.
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
        json.field "layer", rule.layer
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
