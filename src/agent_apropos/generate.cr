require "./conventions"
require "./index"
require "./skills"
require "./filesystem"

module AgentApropos
  # `agent-apropos generate`: compile `docs/conventions/**` into the trigger
  # index and the committed skill wrappers, and prune orphaned wrappers. `run`
  # writes; `check` never writes and is the CI drift gate. Both fail *closed* —
  # a malformed doc or slug collision exits non-zero — because generate is an
  # authoring/CI command, not the fail-open hook path. Only writes/checks a
  # `Skills::ROOTS` root whose `Skills.active_roots` includes it — see there
  # for how that's decided from which `init`-generated hook files exist.
  module Generate
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]

    # Rebuild the index when stale and (re)write every skill wrapper, pruning
    # orphans. Progress goes to `stdout`; errors to `stderr`. Returns a process
    # exit code.
    def run(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions = Conventions.walk(repo_root, fs, allow_outside)
      wrappers = Skills.wrappers(conventions)
      active = Skills.active_roots(repo_root, fs)

      write_index(repo_root, fs, conventions, stdout)
      write_wrappers(repo_root, fs, wrappers, active, stdout)
      prune_orphans(repo_root, fs, wrappers.keys, active, stdout)
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos generate: #{ex.message}"
      1
    end

    # Verify the committed skill wrappers byte-match what the current docs
    # produce and that no orphaned wrappers linger. Writes nothing.
    # Exit 0 when clean, 1 with a drift summary otherwise.
    def check(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions = Conventions.walk(repo_root, fs, allow_outside)
      wrappers = Skills.wrappers(conventions)
      active = Skills.active_roots(repo_root, fs)
      drift = [] of String

      Skills::ROOTS.each do |root|
        expected = active.includes?(root) ? wrappers : {} of String => String
        expected.each do |slug, content|
          actual = fs.read?(wrapper_path(repo_root, root, slug).to_s)
          if actual.nil?
            drift << "missing: #{wrapper_display(root, slug)}"
          elsif actual != content
            drift << "stale:   #{wrapper_display(root, slug)}"
          end
        end

        (existing_slugs(repo_root, fs, root) - expected.keys).sort.each do |slug|
          drift << "orphan:  #{wrapper_display(root, slug)}"
        end
      end

      report_check(drift, wrappers.size, stdout)
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos generate: #{ex.message}"
      1
    end

    private def report_check(drift : Array(String), count : Int32, stdout : IO) : Int32
      if drift.empty?
        stdout.puts "generate --check: up to date (#{count} skill wrappers)"
        return 0
      end
      stdout.puts "generate --check: drift detected"
      drift.sort.each { |line| stdout.puts "  #{line}" }
      1
    end

    private def write_index(repo_root, fs, conventions, stdout) : Nil
      path = index_path(repo_root).to_s
      existing = fs.read?(path).try { |json| Index.load(json) }
      return if existing && existing.covers?(conventions)
      fs.write(path, Index.build(conventions).to_document)
      stdout.puts "index: rebuilt (#{conventions.size} docs)"
    end

    private def write_wrappers(repo_root, fs, wrappers, active, stdout) : Nil
      slugs = wrappers.keys.sort!
      Skills::ROOTS.each do |root|
        next unless active.includes?(root)
        slugs.each do |slug|
          content = wrappers[slug]
          path = wrapper_path(repo_root, root, slug).to_s
          next if fs.read?(path) == content
          fs.write(path, content)
          stdout.puts "skill: wrote #{wrapper_display(root, slug)}"
        end
      end
    end

    # A root with no wired consumer keeps nothing: `keep` is emptied for it,
    # so any wrapper left over from before its last consumer was un-wired
    # gets pruned along with genuine orphans.
    private def prune_orphans(repo_root, fs, keep : Array(String), active, stdout) : Nil
      Skills::ROOTS.each do |root|
        root_keep = active.includes?(root) ? keep : [] of String
        (existing_slugs(repo_root, fs, root) - root_keep).sort.each do |slug|
          fs.remove(skill_dir(repo_root, root, slug).to_s)
          stdout.puts "skill: removed orphan #{wrapper_display(root, slug)}"
        end
      end
    end

    # Slugs of the skill wrappers already on disk under one root, derived from
    # their directory names.
    private def existing_slugs(repo_root : Path, fs : Filesystem, root : Path) : Array(String)
      fs.glob(repo_root.join(root), "*/SKILL.md").map do |absolute|
        Path[absolute].parent.basename
      end
    end

    private def index_path(repo_root : Path) : Path
      repo_root.join(INDEX_RELATIVE)
    end

    private def skill_dir(repo_root : Path, root : Path, slug : String) : Path
      repo_root.join(root, slug)
    end

    private def wrapper_path(repo_root : Path, root : Path, slug : String) : Path
      skill_dir(repo_root, root, slug).join("SKILL.md")
    end

    private def wrapper_display(root : Path, slug : String) : String
      root.join(slug, "SKILL.md").to_posix.to_s
    end
  end
end
