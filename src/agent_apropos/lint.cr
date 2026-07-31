require "./errors"
require "./frontmatter"
require "./conventions"
require "./config"
require "./matcher"
require "./skills"
require "./filesystem"

module AgentApropos
  # `agent-apropos lint`: validate the convention structure against the
  # standard's quality bar and exit non-zero on any error. It is a CI command, so
  # it fails **closed** — but it reports *every* problem it can find rather than
  # stopping at the first, so a malformed doc becomes a finding, not a crash.
  module Lint
    extend self

    ROOT_FILES = {"AGENTS.md", "CLAUDE.md"}

    # Line budgets: a root file over 150 lines or a skill doc over 500
    # lines is a warning (`--strict` promotes warnings to errors).
    ROOT_FILE_MAX = 150
    SKILL_DOC_MAX = 500

    # One lint result: `:error` fails the run; `:warning` is advisory unless
    # `--strict` promotes it.
    record Finding, severity : Symbol, location : String, message : String

    # `Config::Error` (a malformed `agent-apropos.yml`) propagates here uncaught
    # elsewhere in this module — lint is an authoring/CI command, so it fails
    # *closed* on it just like a malformed convention doc.
    def run(repo_root : Path, fs : Filesystem, strict : Bool, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      report(collect(repo_root, fs, allow_outside), strict, stdout)
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos lint: #{ex.message}"
      1
    end

    private def collect(repo_root : Path, fs : Filesystem, allow_outside : Bool) : Array(Finding)
      conventions, findings = parse_docs(repo_root, fs, allow_outside)
      conventions.each { |convention| findings.concat(doc_findings(convention)) }
      findings.concat(root_file_findings(repo_root, fs))
      findings.concat(wrapper_findings(repo_root, fs, conventions, allow_outside))
      findings
    end

    # Parse every doc, tolerating a malformed one by turning its parse error into
    # a finding so the rest of the suite still runs.
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

    private def doc_findings(convention : Convention) : Array(Finding)
      fm = convention.frontmatter
      findings = [] of Finding

      unless fm.unknown_keys.empty?
        findings << Finding.new(:warning, convention.path,
          "unknown frontmatter keys: #{fm.unknown_keys.join(", ")}")
      end

      if convention.skill? && fm.description.nil?
        findings << Finding.new(:error, convention.path, "`skill: true` requires a `description`")
      end

      if (description = fm.description) && !description.starts_with?("Use when")
        findings << Finding.new(:error, convention.path, %(`description` must start with "Use when"))
      end

      fm.paths.each do |glob|
        unless Matcher.valid_glob?(glob)
          findings << Finding.new(:error, convention.path, "invalid path glob: #{glob.inspect}")
        end
      end

      fm.contents.each do |source|
        Matcher.compile(source)
      rescue ex : Matcher::Error
        findings << Finding.new(:error, convention.path, ex.message.to_s)
      end

      if triggered?(fm) && convention.body.strip.empty?
        findings << Finding.new(:error, convention.path, "declares triggers but has an empty body")
      end

      if convention.skill? && line_count(convention.body) > SKILL_DOC_MAX
        findings << Finding.new(:warning, convention.path, "skill doc is over #{SKILL_DOC_MAX} lines")
      end

      findings
    end

    private def triggered?(fm : Frontmatter) : Bool
      !fm.paths.empty? || !fm.contents.empty?
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

    # Generated skill wrappers must byte-match what the current docs produce — the
    # same check as `generate --check`. A slug collision or missing
    # description makes the whole wrapper set undecidable, so it is reported as a
    # single error and drift comparison is skipped.
    private def wrapper_findings(repo_root : Path, fs : Filesystem,
                                 conventions : Array(Convention), allow_outside : Bool) : Array(Finding)
      skill_docs = conventions.select { |convention| convention.skill? && convention.frontmatter.description }
      wrappers =
        begin
          Skills.wrappers(skill_docs)
        rescue ex : Skills::Error
          location = Config.conventions_dir(repo_root, fs, allow_outside).relative_to(repo_root).to_posix.to_s
          return [Finding.new(:error, location, ex.message.to_s)]
        end

      findings = [] of Finding
      Skills::ROOTS.each do |root|
        wrappers.each do |slug, content|
          actual = fs.read?(repo_root.join(root, slug, "SKILL.md").to_s)
          if actual.nil?
            findings << Finding.new(:error, wrapper_display(root, slug), "missing generated wrapper (run `agent-apropos generate`)")
          elsif actual != content
            findings << Finding.new(:error, wrapper_display(root, slug), "stale generated wrapper (run `agent-apropos generate`)")
          end
        end

        (existing_slugs(repo_root, fs, root) - wrappers.keys).sort.each do |slug|
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
