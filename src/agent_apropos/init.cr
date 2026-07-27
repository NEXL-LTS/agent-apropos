require "json"
require "./errors"
require "./filesystem"
require "./environment"
require "./config"
require "./agents"

module AgentApropos
  # `agent-apropos init`: bootstrap the convention structure into a repo.
  # Idempotent — safe to re-run; a scaffold file is written only when absent
  # unless `--force` is given, and the `.claude/settings.json` and `.gitignore`
  # merges are additive (foreign keys and other hooks are preserved). `--dry-run`
  # prints what would change and writes nothing.
  #
  # Per-tool hook wiring (Claude Code's `.claude/settings.json`, OpenCode's
  # generated plugin, Gemini CLI's `.gemini/settings.json`, GitHub Copilot
  # CLI's `.github/hooks/*.json`, Codex CLI's `.codex/hooks.json`) is
  # tool-agnostic: pass `--tool claude` / `--tool opencode` / `--tool gemini`
  # / `--tool copilot` / `--tool codex` (repeatable) to wire specific agents
  # explicitly, or omit `--tool` entirely to auto-detect by probing PATH for
  # each supported agent. This keeps init easy to extend as more agents
  # (Cursor CLI, ...) land.
  #
  # Gemini CLI's hook system has no pre-edit context-injection event (its
  # `BeforeTool` output schema only supports overriding tool arguments or
  # blocking the call — see `merge_gemini_settings`), so both Layer 2 and
  # Layer 3 are wired onto its `AfterTool` event. Layer 2 still fires, just
  # after the edit instead of before it — the same timing degradation
  # `doctor.cr` already documents for older Claude Code versions.
  #
  # GitHub Copilot CLI has the identical limitation on its own `preToolUse`
  # event (output schema is `permissionDecision`/`modifiedArgs` only — no
  # context field), so it gets the same treatment onto `postToolUse` — see
  # `scaffold_copilot`.
  #
  # init is an authoring command, so it fails **closed**: a malformed existing
  # `settings.json` is an error, not a silent overwrite.
  module Init
    extend self

    class Error < AgentApropos::Error
    end

    # CLI agents init knows how to wire hooks for, delegated to
    # `Agents::ALL` (one `Agents::Agent` subclass each). Extend that array,
    # not this set, as more emitters land (Cursor CLI, ...).
    KNOWN_TOOLS = Agents.names

    # Parsed flags for one `init` invocation. `tools: nil` means auto-detect;
    # a non-nil set (from one or more `--tool`) is used verbatim, ignoring PATH.
    record Options,
      force : Bool = false,
      example : Bool = false,
      claude_symlink : Bool = false,
      dry_run : Bool = false,
      tools : Set(String)? = nil

    CACHE_IGNORE_ENTRY = ".cache/agent-apropos/"

    # Printed once per run to point at the bootstrapping prompt — most repos
    # arrive with docs already scattered across READMEs/wikis/comments, and an
    # agent can sort those into layers faster than a human writing from scratch.
    # A fully-qualified URL, not a relative "README.md#..." — this section
    # lives in *agent-apropos's own* README, not the target repo's, and terminals
    # only auto-hyperlink absolute URLs.
    NEXT_STEPS_HINT = "next     have your agent bootstrap docs/conventions/ from your existing " \
                      "docs — see https://github.com/NEXL-LTS/agent-apropos#bootstrapping-from-an-existing-codebase"

    def run(repo_root : Path, fs : Filesystem, env : Environment, options : Options, stdout : IO, stderr : IO) : Int32
      tools = resolve_tools(env, options.tools)
      report_tools(stdout, options.tools, tools)
      scaffold(repo_root, fs, options, stdout)
      Agents::ALL.each { |agent| agent.scaffold(repo_root, fs, options, stdout) if tools.includes?(agent.name) }
      merge_gitignore(repo_root, fs, options, stdout)
      write_examples(repo_root, fs, options, stdout) if options.example
      link_claude(repo_root, fs, options, stdout) if options.claude_symlink
      stdout.puts NEXT_STEPS_HINT unless options.dry_run
      0
    rescue ex : AgentApropos::Error
      stderr.puts "agent-apropos init: #{ex.message}"
      1
    end

    # An explicit `--tool` selection is used verbatim (even if the named agent
    # is not actually on PATH — e.g. bootstrapping a repo for a teammate's
    # setup). Otherwise probe PATH for each known agent.
    private def resolve_tools(env : Environment, explicit : Set(String)?) : Set(String)
      return explicit if explicit
      KNOWN_TOOLS.select { |tool| env.which(tool) }.to_set
    end

    # Only narrate auto-detection — an explicit `--tool` selection was the
    # user's own words, so echoing it back adds nothing.
    private def report_tools(stdout : IO, explicit : Set(String)?, detected : Set(String)) : Nil
      return unless explicit.nil?
      if detected.empty?
        stdout.puts "auto     no supported CLI agent found on PATH; pass --tool claude / --tool opencode to wire one explicitly"
      else
        stdout.puts "auto     detected #{detected.to_a.sort.join(", ")}"
      end
    end

    private def scaffold(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs)
      create(repo_root, fs, options, stdout, "#{conventions}/README.md", CONVENTIONS_README)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/.gitkeep", "")
      create(repo_root, fs, options, stdout, ".claude/skills/.gitkeep", SKILLS_GITKEEP)
      # The root file is the user's own Layer 1 content — never overwrite it, even
      # under --force; only scaffold it when absent.
      create(repo_root, fs, options, stdout, "AGENTS.md", AGENTS_SKELETON, force_allowed: false)
    end

    private def write_examples(repo_root : Path, fs : Filesystem, options : Options, stdout : IO) : Nil
      conventions = conventions_relative(repo_root, fs)
      create(repo_root, fs, options, stdout, "#{conventions}/example-path-rule.md", EXAMPLE_L2)
      create(repo_root, fs, options, stdout, "#{conventions}/example-content-rule.md", EXAMPLE_L3)
      create(repo_root, fs, options, stdout, "#{conventions}/workflows/example-skill.md", EXAMPLE_SKILL)
    end

    # The conventions directory, relative to `repo_root` (with `../` segments
    # when `agent-apropos.yml` points outside it) — `create`'s single relative-path
    # parameter needs this rather than the resolved absolute `Path` `Config`
    # returns, since it both derives the write location (joined back onto
    # `repo_root`) and the printed display string from the same value.
    private def conventions_relative(repo_root : Path, fs : Filesystem) : String
      Config.conventions_dir(repo_root, fs).relative_to(repo_root).to_posix.to_s
    end

    # Write a scaffold file when absent (or when `--force` and `force_allowed`),
    # otherwise report it as already present.
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

    # Reconcile a merge target: write only when the merged content differs from
    # what is on disk, so re-running is a no-op. Public — each `Agents::Agent`
    # subclass's own `#scaffold` calls this to write/merge its settings file.
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

    # Parse an existing settings file into a mutable root hash (or an empty
    # one when absent), raising `Init::Error` on malformed JSON — init is an
    # authoring command, so it fails **closed**. Public — shared by every
    # `Agents::Agent` whose wiring lives in a shared JSON settings file
    # (Claude, Gemini).
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

    # Alias CLAUDE.md → AGENTS.md so the same Layer 1 file serves both loaders.
    # Absent-only: an existing CLAUDE.md (real file or link) is left untouched.
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

      ## The four layers

      | Layer | For | Trigger | Delivered by |
      | --- | --- | --- | --- |
      | 1 Root file | Universal rules | Always loaded | `AGENTS.md` |
      | 2 Path-scoped | Guidance for a path / file type | File **path** | PreToolUse hook |
      | 3 Construct-scoped | Guidance for an API / construct | Written **content** (regex), optionally AND path | PostToolUse hook |
      | 4 Intent skills | Task-nature guidance | Skill match | Generated `.claude/skills/*/SKILL.md` |

      ## Frontmatter

      ```yaml
      ---
      paths: ["src/**"]              # Layer 2: inject when editing a matching path
      contents: ['\\bTODO\\b']        # Layer 3: inject when written code matches (PCRE2)
      skill: true                    # Layer 4: generate a skill wrapper
      description: "Use when ..."    # required iff skill: true; must start with "Use when"
      ---
      ```

      - `paths` only → Layer 2 (fires on any edit to a matching path)
      - `contents` only → Layer 3 (fires when written code matches, anywhere)
      - `paths` + `contents` → **AND** (path-scoped Layer 3)
      - `skill: true` is independent and may combine with either
      - no frontmatter → reference-only: reachable by link, never triggered

      ## Writing a rule

      - One concern per file; keep it short — tight rules get read, long ones get skimmed.
      - State **what** the rule is, **why** it exists, and a verification criterion.
      - Add an optional `## Verify` heading; `agent-apropos review` harvests it as a checklist item.

      Claude Code delivers Layer 2 via PreToolUse `additionalContext`; run
      `agent-apropos doctor` to verify the version. OpenCode delivers Layer 2 via
      `tool.execute.before` and Layer 3 via `tool.execute.after`, injecting
      context with `noReply: true` through the generated plugin. Gemini CLI and
      GitHub Copilot CLI both have no pre-edit context-injection event (Gemini's
      `BeforeTool` and Copilot's `preToolUse` can only override arguments or
      block/allow the call), so both Layer 2 and Layer 3 deliver via their
      post-edit hook instead (`AfterTool` for Gemini, `postToolUse` for Copilot)
      — Layer 2 still fires, just after the edit rather than before it. Codex
      CLI's own PreToolUse *can* inject context, so it delivers Layer 2 the same
      way Claude Code does; its `apply_patch` tool can bundle several files'
      edits into one call, which agent-apropos matches and injects per file.
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

      Keep modules small and single-purpose. This is an example Layer 2 rule: it is
      injected whenever a file under `src/` is edited. Replace it with a real
      convention or delete it.

      ## Verify

      - The change keeps one concern per file.
      MD

    EXAMPLE_L3 = <<-MD
      ---
      contents: ['\\bTODO\\b']
      ---

      # Leftover TODOs

      This is an example Layer 3 rule: it is injected when written content matches
      the `contents` regex (here, a stray `TODO`). Replace it with a real
      construct-scoped convention or delete it.
      MD

    EXAMPLE_SKILL = <<-MD
      ---
      skill: true
      description: "Use when shipping a change end to end"
      ---

      # Shipping a change

      This is an example Layer 4 skill doc. `agent-apropos generate` turns it into a
      `.claude/skills/example-skill/SKILL.md` wrapper. Replace it with a real
      workflow or delete it.
      MD
  end
end
