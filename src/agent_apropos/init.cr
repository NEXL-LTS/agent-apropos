require "json"
require "./errors"
require "./filesystem"
require "./environment"
require "./config"
require "./agents"

module AgentApropos
  module Init
    extend self

    class Error < AgentApropos::Error
    end

    KNOWN_TOOLS = Agents.names

    record Options,
      force : Bool = false,
      example : Bool = false,
      claude_symlink : Bool = false,
      dry_run : Bool = false,
      tools : Set(String)? = nil,
      allow_outside_repo : Bool = false

    CACHE_IGNORE_ENTRY = ".cache/agent-apropos/"

    NEXT_STEPS_HINT = "next     have your agent bootstrap docs/conventions/ from your existing " \
                      "docs — see https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase"

    def run(repo_root : Path, fs : Filesystem, env : Environment, options : Options, stdout : IO, stderr : IO) : Int32
      tools = resolve_tools(env, options.tools)
      report_tools(stdout, options.tools, tools)
      scaffold(repo_root, fs, options, stdout)
      agent_options = with_hook_flag(repo_root, fs, options)
      Agents::ALL.each { |agent| agent.scaffold(repo_root, fs, agent_options, stdout) if tools.includes?(agent.name) }
      merge_gitignore(repo_root, fs, options, stdout)
      write_examples(repo_root, fs, options, stdout) if options.example
      link_claude(repo_root, fs, options, stdout) if options.claude_symlink
      stdout.puts NEXT_STEPS_HINT unless options.dry_run
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos init: #{ex.message}"
      1
    end

    private def resolve_tools(env : Environment, explicit : Set(String)?) : Set(String)
      return explicit if explicit
      KNOWN_TOOLS.select { |tool| env.which(tool) }.to_set
    end

    private def report_tools(stdout : IO, explicit : Set(String)?, detected : Set(String)) : Nil
      return unless explicit.nil?
      if detected.empty?
        stdout.puts "auto     no supported CLI agent found on PATH; pass --tool claude / --tool opencode to wire one explicitly"
      else
        stdout.puts "auto     detected #{detected.to_a.sort.join(", ")}"
      end
    end

    private def with_hook_flag(repo_root : Path, fs : Filesystem, options : Options) : Options
      return options unless options.allow_outside_repo
      Options.new(
        force: options.force, example: options.example,
        claude_symlink: options.claude_symlink, dry_run: options.dry_run,
        tools: options.tools, allow_outside_repo: Config.outside_repo?(repo_root, fs))
    end

    private def scaffold(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs, options)
      create(repo_root, fs, options, stdout, "#{conventions}/README.md", CONVENTIONS_README)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/.gitkeep", "")
      create(repo_root, fs, options, stdout, ".claude/skills/.gitkeep", SKILLS_GITKEEP)
      create(repo_root, fs, options, stdout, "AGENTS.md", AGENTS_SKELETON, force_allowed: false)
    end

    private def write_examples(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs, options)
      create(repo_root, fs, options, stdout, "#{conventions}/example-path-rule.md", EXAMPLE_L2)
      create(repo_root, fs, options, stdout, "#{conventions}/example-content-rule.md", EXAMPLE_L3)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/example-skill.md", EXAMPLE_SKILL)
    end

    private def conventions_relative(repo_root : Path, fs : Filesystem, options : Options) : String
      Config.conventions_dir(repo_root, fs, options.allow_outside_repo).relative_to(repo_root).to_posix.to_s
    end

    private def create(repo_root : Path, fs : Filesystem, options : Options, stdout : IO,
                       relative : String, content : String, force_allowed : Bool = true) : Nil
      path = repo_root.join(relative).to_s
      display = Path[relative].to_posix.to_s
      if fs.exists?(path) && !(force_allowed && options.force)
        stdout.puts "exists   #{display}"
        return
      end
      verb = fs.exists?(path) ? "update" : "create"
      apply(fs, options, stdout, path, content, verb, display)
    end

    def sync(fs : Filesystem, options : Options, stdout : IO,
             path : String, content : String, existing : String?, display : String) : Nil
      if existing == content
        stdout.puts "current  #{display}"
        return
      end
      apply(fs, options, stdout, path, content, existing.nil? ? "create" : "update", display)
    end

    private def apply(fs : Filesystem, options : Options, stdout : IO,
                      path : String, content : String, verb : String, display : String) : Nil
      if options.dry_run
        stdout.puts "would #{verb} #{display}"
      else
        fs.write(path, content)
        stdout.puts "#{verb}d  #{display}"
      end
    end

    def settings_root(existing : String?, label : String) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if existing.nil?
      parsed =
        begin
          JSON.parse(existing)
        rescue ex : JSON::ParseException
          raise Error.new("existing #{label} is not valid JSON: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new("#{label} must be a JSON object") if hash.nil?
      hash.dup
    end

    private def merge_gitignore(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      path = repo_root.join(".gitignore").to_s
      existing = fs.read?(path)
      sync(fs, options, stdout, path, merged_gitignore(existing), existing, ".gitignore")
    end

    private def merged_gitignore(existing : String?) : String
      if existing.nil?
        return "# agent-apropos trigger index + session state (regenerated; not committed).\n" \
               "#{CACHE_IGNORE_ENTRY}\n"
      end
      return existing if existing.each_line.any? { |line| line.strip == CACHE_IGNORE_ENTRY }
      separator = existing.empty? || existing.ends_with?('\n') ? "" : "\n"
      "#{existing}#{separator}#{CACHE_IGNORE_ENTRY}\n"
    end

    private def link_claude(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      link = repo_root.join("CLAUDE.md").to_s
      if fs.exists?(link)
        stdout.puts "exists   CLAUDE.md"
        return
      end
      if options.dry_run
        stdout.puts "would link CLAUDE.md -> AGENTS.md"
      else
        fs.symlink("AGENTS.md", link)
        stdout.puts "linked   CLAUDE.md -> AGENTS.md"
      end
    end

    CONVENTIONS_README = <<-MD
      # Conventions

      This directory is the single source of truth for scoped guidance — the
      judgment calls a linter or formatter cannot enforce. It implements the Agent
      Documentation Structure Standard. Universal, always-apply rules live in the
      root `AGENTS.md`; anything a tool can enforce lives in that tool.

      ## The three layers

      | Layer | For | Trigger | Delivered by |
      | --- | --- | --- | --- |
      | 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
      | 2 Scoped rules | Guidance for a path, an API / construct, or both | A **write** to a matching **path** and/or matching written **content** (regex) | Pre/PostToolUse hooks |
      | 3 Intent skills | Task-nature guidance | Skill match | Generated `.claude/skills/*/SKILL.md` |

      ## Frontmatter

      ```yaml
      ---
      paths: ["src/**"]              # inject when writing to a matching path
      contents: ['\\bTODO\\b']        # inject when written code matches (PCRE2)
      skill: true                    # Layer 3: generate a skill wrapper
      description: "Use when ..."    # required iff skill: true; must start with "Use when"
      ---
      ```

      - `paths` only → fires on any write to a matching path
      - `contents` only → fires when written code matches, anywhere
      - `paths` + `contents` → **AND**: both must match
      - `skill: true` is independent and may combine with either
      - no frontmatter → reference-only: reachable by link, never triggered

      Rules are injected only when the agent **writes**. A read injects nothing;
      it only tells agent-apropos that a convention doc is already in the model's
      context, so no later write re-injects it.

      ## Writing a rule

      - One concern per file; keep it short — tight rules get read, long ones get skimmed.
      - State **what** the rule is, **why** it exists, and a verification criterion.
      - Add an optional `## Verify` heading; `agent-apropos review` harvests it as a checklist item.

      Claude Code delivers via PreToolUse `additionalContext`; run
      `agent-apropos doctor` to verify the version. OpenCode delivers via
      `tool.execute.before` and `tool.execute.after`, injecting context with
      `noReply: true` through the generated plugin. Gemini CLI and GitHub
      Copilot CLI both have no pre-edit context-injection event (Gemini's
      `BeforeTool` and Copilot's `preToolUse` can only override arguments or
      block/allow the call), so they deliver via their post-edit hook instead
      (`AfterTool` for Gemini, `postToolUse` for Copilot) — rules still fire,
      just after the edit rather than before it. Codex CLI's own PreToolUse
      *can* inject context, so it delivers the same way Claude Code does; its
      `apply_patch` tool can bundle several files' edits into one call, which
      agent-apropos matches and injects per file.
      MD

    AGENTS_SKELETON = <<-MD
      # Project

      <!-- Layer 1: universal, always-loaded rules. Keep this tight — a bloated
           root file gets skimmed. Scoped guidance belongs in docs/conventions/. -->

      ## Commands

      ## Universal rules

      ## Where scoped guidance lives

      Task- and file-scoped conventions are **not** in this file. They live in
      `docs/conventions/` and are surfaced automatically at edit time by agent-apropos's
      hooks. See `docs/conventions/README.md`.
      MD

    SKILLS_GITKEEP = <<-MD
      # Generated skill wrappers live here.
      #
      # `agent-apropos generate` writes `<slug>/SKILL.md` for every `skill: true` doc in
      # docs/conventions/. Do not edit these by hand — edit the source doc instead;
      # `agent-apropos generate --check` fails if a wrapper drifts from its source.
      MD

    EXAMPLE_L2 = <<-MD
      ---
      paths: ["src/**"]
      ---

      # Source files

      Keep modules small and single-purpose. This is an example path-scoped rule: it
      is injected whenever a file under `src/` is written. Replace it with a real
      convention or delete it.

      ## Verify

      - The change keeps one concern per file.
      MD

    EXAMPLE_L3 = <<-MD
      ---
      contents: ['\\bTODO\\b']
      ---

      # Leftover TODOs

      This is an example content-scoped rule: it is injected when written content
      matches the `contents` regex (here, a stray `TODO`). Replace it with a real
      construct-scoped convention or delete it.
      MD

    EXAMPLE_SKILL = <<-MD
      ---
      skill: true
      description: "Use when shipping a change end to end"
      ---

      # Shipping a change

      This is an example intent-skill doc. `agent-apropos generate` turns it into a
      `.claude/skills/example-skill/SKILL.md` wrapper. Replace it with a real
      workflow or delete it.
      MD
  end
end
