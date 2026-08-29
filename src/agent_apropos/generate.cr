require "./conventions"
require "./index"
require "./skills"
require "./filesystem"
require "./agents"
require "./frontmatter"

module AgentApropos
  module Generate
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]

    def run(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions, wrappers, active = inputs(repo_root, fs, allow_outside)

      write_index(repo_root, fs, conventions, stdout)
      write_wrappers(repo_root, fs, wrappers, active, stdout)
      prune_orphans(repo_root, fs, wrappers.keys, active, stdout)
      sync_shell_hooks(repo_root, fs, removal_declared?(conventions), stdout)
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos generate: #{ex.message}"
      1
    end

    def check(repo_root : Path, fs : Filesystem, stdout : IO, stderr : IO, allow_outside : Bool = false) : Int32
      conventions, wrappers, active = inputs(repo_root, fs, allow_outside)
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

      drift.concat(shell_hook_drift(repo_root, fs, removal_declared?(conventions)))
      report_check(drift, wrappers.size, stdout)
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos generate: #{ex.message}"
      1
    end

    private def inputs(repo_root : Path, fs : Filesystem, allow_outside : Bool) : {Array(Convention), Hash(String, String), Set(Path)}
      conventions = Conventions.walk(repo_root, fs, allow_outside)
      {conventions, Skills.wrappers(conventions), Skills.active_roots(repo_root, fs)}
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

    private def prune_orphans(repo_root, fs, keep : Array(String), active, stdout) : Nil
      Skills::ROOTS.each do |root|
        root_keep = active.includes?(root) ? keep : [] of String
        (existing_slugs(repo_root, fs, root) - root_keep).sort.each do |slug|
          fs.remove(skill_dir(repo_root, root, slug).to_s)
          stdout.puts "skill: removed orphan #{wrapper_display(root, slug)}"
        end
      end
    end

    private def removal_declared?(conventions : Array(Convention)) : Bool
      conventions.any? { |convention| convention.frontmatter.events.includes?(Frontmatter::Event::Removed) }
    end

    private def sync_shell_hooks(repo_root : Path, fs : Filesystem, wire : Bool, stdout : IO) : Nil
      pending_shell_hook_updates(repo_root, fs, wire).each do |agent, path, updated|
        fs.write(path, updated)
        stdout.puts "hook: #{wire ? "wired" : "unwired"} shell removal detection for #{agent.name}"
      end
    end

    private def shell_hook_drift(repo_root : Path, fs : Filesystem, wire : Bool) : Array(String)
      state = wire ? "missing" : "orphaned"
      pending_shell_hook_updates(repo_root, fs, wire).map do |agent, _, _|
        "hook:    #{agent.config_relative.to_posix} (shell removal detection #{state})"
      end
    end

    private def pending_shell_hook_updates(repo_root : Path, fs : Filesystem, wire : Bool) : Array({Agents::Agent, String, String})
      Agents::ALL.compact_map do |agent|
        next unless agent.configured?(repo_root, fs)
        path = repo_root.join(agent.config_relative).to_s
        existing = fs.read?(path)
        updated = agent.sync_shell_hook(existing, agent.config_relative.to_posix.to_s, wire)
        next if updated.nil? || updated == existing
        {agent, path, updated}
      end
    end

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
