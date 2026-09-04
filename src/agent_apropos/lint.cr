require "./errors"
require "./frontmatter"
require "./conventions"
require "./config"
require "./matcher"
require "./skills"
require "./filesystem"
require "./git"

module AgentApropos
  module Lint
    extend self

    ROOT_FILES = {"AGENTS.md", "CLAUDE.md"}

    ROOT_FILE_MAX = 150
    SKILL_DOC_MAX = 500

    record Finding, severity : Symbol, location : String, message : String

    def run(repo_root : Path, fs : Filesystem, git : Git, strict : Bool,
            stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      report(collect(repo_root, fs, git, allow_outside), strict, stdout)
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos lint: #{ex.message}"
      1
    end

    private def collect(repo_root : Path, fs : Filesystem, git : Git, allow_outside : Bool) : Array(Finding)
      conventions, findings = parse_docs(repo_root, fs, allow_outside)
      ignored, linted = conventions.partition(&.lint_ignore?)
      tracked = git.ls_files(repo_root)
      linted.each { |convention| findings.concat(doc_findings(convention, tracked)) }
      findings.concat(root_file_findings(repo_root, fs))
      findings.concat(wrapper_findings(repo_root, fs, linted, ignored, allow_outside))
      findings
    end

    private def parse_docs(repo_root : Path, fs : Filesystem, allow_outside : Bool) : {Array(Convention), Array(Finding)}
      conventions = [] of Convention
      findings = [] of Finding
      fs.glob(Config.conventions_dir(repo_root, fs, allow_outside), "**/*.md").sort.each do |absolute|
        relative = Path[absolute].relative_to(repo_root).to_posix.to_s
        begin
          conventions << Convention.parse(relative, fs.read(absolute))
        rescue ex : Frontmatter::Error
          findings << Finding.new(:error, relative, ex.message.to_s)
        end
      end
      {conventions, findings}
    end

    private def doc_findings(convention : Convention, tracked : Array(String)?) : Array(Finding)
      fm = convention.frontmatter
      findings = key_findings(convention)
      findings.concat(skill_findings(convention))
      fm.paths.each { |glob| findings.concat(glob_findings(convention, glob, tracked)) }

      fm.contents.each do |source|
        Matcher.compile(source)
      rescue ex : Matcher::Error
        findings << Finding.new(:error, convention.path, ex.message.to_s)
      end

      if fm.scoped? && convention.body.strip.empty?
        findings << Finding.new(:error, convention.path, "declares triggers but has an empty body")
      end

      findings.concat(event_findings(convention))
      findings
    end

    private def event_findings(convention : Convention) : Array(Finding)
      fm = convention.frontmatter
      if fm.events.empty?
        return [Finding.new(:error, convention.path, "`on:` declares no events, so this doc can never fire")]
      end

      if fm.events != Set{Frontmatter::Event::Write} && !fm.scoped?
        return [Finding.new(:error, convention.path, "declares `on:` events with no `paths` or `contents` to match")]
      end

      [] of Finding
    end

    private def key_findings(convention : Convention) : Array(Finding)
      fm = convention.frontmatter
      findings = [] of Finding

      unless fm.unknown_keys.empty?
        findings << Finding.new(:warning, convention.path,
          "unknown frontmatter keys: #{fm.unknown_keys.join(", ")}")
      end

      if (lint = fm.lint) && !fm.lint_ignore?
        findings << Finding.new(:error, convention.path,
          "unrecognized `lint` value: #{lint.inspect} (only #{Frontmatter::LINT_IGNORE.inspect} is supported)")
      end

      findings
    end

    private def skill_findings(convention : Convention) : Array(Finding)
      fm = convention.frontmatter
      findings = [] of Finding

      if convention.skill? && fm.description.nil?
        findings << Finding.new(:error, convention.path, "`skill: true` requires a `description`")
      end

      if (description = fm.description) && !description.starts_with?("Use when")
        findings << Finding.new(:error, convention.path, %(`description` must start with "Use when"))
      end

      if convention.skill? && line_count(convention.body) > SKILL_DOC_MAX
        findings << Finding.new(:warning, convention.path, "skill doc is over #{SKILL_DOC_MAX} lines")
      end

      findings
    end

    private def glob_findings(convention : Convention, glob : String, tracked : Array(String)?) : Array(Finding)
      unless Matcher.valid_glob?(glob)
        return [Finding.new(:error, convention.path, "invalid path glob: #{glob.inspect}")]
      end
      return [] of Finding if tracked.nil? || tracked.any? { |path| Matcher.path_match?(glob, path) }
      [Finding.new(:error, convention.path, "path glob matches no tracked file: #{glob.inspect}")]
    end

    private def root_file_findings(repo_root : Path, fs : Filesystem) : Array(Finding)
      findings = [] of Finding
      ROOT_FILES.each do |name|
        content = fs.read?(repo_root.join(name).to_s)
        next unless content
        count = line_count(content)
        if count > ROOT_FILE_MAX
          findings << Finding.new(:warning, name, "root file is #{count} lines (budget #{ROOT_FILE_MAX})")
        end
      end
      findings
    end

    private def wrapper_findings(repo_root : Path, fs : Filesystem, conventions : Array(Convention),
                                 ignored : Array(Convention), allow_outside : Bool) : Array(Finding)
      skill_docs = conventions.select { |convention| convention.skill? && convention.frontmatter.description }
      wrappers =
        begin
          Skills.wrappers(skill_docs)
        rescue ex : Skills::Error
          location = Config.conventions_dir(repo_root, fs, allow_outside).relative_to(repo_root).to_posix.to_s
          return [Finding.new(:error, location, ex.message.to_s)]
        end

      ignored_slugs = ignored.select(&.skill?).map { |convention| Skills.slug_for(convention.path) }
      active = Skills.active_roots(repo_root, fs)
      findings = [] of Finding
      Skills::ROOTS.each do |root|
        expected = active.includes?(root) ? wrappers : {} of String => String
        expected.each do |slug, content|
          actual = fs.read?(repo_root.join(root, slug, "SKILL.md").to_s)
          if actual.nil?
            findings << Finding.new(:error, wrapper_display(root, slug), "missing generated wrapper (run `agent-apropos generate`)")
          elsif actual != content
            findings << Finding.new(:error, wrapper_display(root, slug), "stale generated wrapper (run `agent-apropos generate`)")
          end
        end

        (existing_slugs(repo_root, fs, root) - expected.keys - ignored_slugs).sort.each do |slug|
          findings << Finding.new(:error, wrapper_display(root, slug), "orphaned generated wrapper (run `agent-apropos generate`)")
        end
      end
      findings
    end

    private def existing_slugs(repo_root : Path, fs : Filesystem, root : Path) : Array(String)
      fs.glob(repo_root.join(root), "*/SKILL.md").map { |absolute| Path[absolute].parent.basename }
    end

    private def wrapper_display(root : Path, slug : String) : String
      root.join(slug, "SKILL.md").to_posix.to_s
    end

    private def line_count(text : String) : Int32
      text.lines.size
    end

    private def report(findings : Array(Finding), strict : Bool, stdout : IO) : Int32
      findings.sort_by! { |finding| {finding.location, finding.message} }
      findings.each { |finding| stdout.puts "#{label(finding.severity)}  #{finding.location}: #{finding.message}" }

      errors = findings.count { |finding| finding.severity == :error }
      warnings = findings.count { |finding| finding.severity == :warning }
      if findings.empty?
        stdout.puts "lint: clean"
      else
        stdout.puts "lint: #{errors} error(s), #{warnings} warning(s)"
      end

      errors > 0 || (strict && warnings > 0) ? 1 : 0
    end

    private def label(severity : Symbol) : String
      severity == :error ? "error" : "warn "
    end
  end
end
