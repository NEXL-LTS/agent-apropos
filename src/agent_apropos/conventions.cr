require "digest/sha256"
require "./frontmatter"
require "./matcher"
require "./filesystem"
require "./config"

module AgentApropos
  # One parsed convention doc: its repo-relative path, a content hash
  # for staleness detection, the parsed frontmatter, and the body.
  # Layer classification and trigger decisions are derived here so the AND
  # semantics live in exactly one tested place.
  struct Convention
    getter path : String
    getter hash : String
    getter frontmatter : Frontmatter
    getter body : String

    def initialize(@path : String, @hash : String, @frontmatter : Frontmatter, @body : String)
    end

    # Parse raw doc text into a Convention. `path` is the repo-relative,
    # POSIX-separator identifier used in index entries and injection headers.
    # The hash covers the whole file so any edit — frontmatter or body — is
    # detected as drift.
    def self.parse(path : String, text : String) : Convention
      frontmatter, body = Frontmatter.split(text)
      new(path, Digest::SHA256.hexdigest(text), frontmatter || Frontmatter.new, body)
    end

    # Layer 2: path-scoped. Fires on any edit to a matching path. A doc that
    # also declares `contents` is path-scoped Layer 3, not Layer 2.
    def layer2? : Bool
      !frontmatter.paths.empty? && frontmatter.contents.empty?
    end

    # Layer 3: construct-scoped. Any doc with a `contents` trigger, whether
    # repo-wide (contents only) or path-scoped (contents + paths).
    def layer3? : Bool
      !frontmatter.contents.empty?
    end

    def skill? : Bool
      frontmatter.skill?
    end

    # The text under an optional `## Verify` heading in the body,
    # harvested by `review` as checklist criteria. The section runs until the next
    # heading (any level) or end of doc. Returns nil when absent or empty.
    def verify : String?
      capturing = false
      captured = [] of String
      body.each_line do |line|
        if capturing
          break if line.starts_with?('#')
          captured << line
        elsif line.strip == "## Verify"
          capturing = true
        end
      end
      return nil unless capturing

      text = captured.join('\n').strip
      text.empty? ? nil : text
    end

    # Reference-only: reachable by link, never triggered.
    def reference_only? : Bool
      !layer2? && !layer3? && !skill?
    end

    # PreToolUse decision: does this Layer 2 rule apply to `relative_path`?
    def triggers_for_path?(relative_path : String) : Bool
      layer2? && Matcher.any_path_match?(frontmatter.paths, relative_path)
    end

    # PostToolUse decision: does this Layer 3 rule apply to written `content`?
    # When the rule also declares `paths`, the file path must match too (AND).
    def triggers_for_content?(relative_path : String, content : String) : Bool
      return false unless layer3?
      return false unless Matcher.any_content_match?(frontmatter.contents, content)
      frontmatter.paths.empty? || Matcher.any_path_match?(frontmatter.paths, relative_path)
    end
  end

  # Discovers and parses every convention doc in a repo. All disk
  # access goes through an injected `Filesystem`; the walk is sorted so the
  # resulting order is byte-stable across platforms.
  module Conventions
    extend self

    def walk(repo_root : Path, fs : Filesystem = Filesystem::Real.new, allow_outside : Bool = false) : Array(Convention)
      base = Config.conventions_dir(repo_root, fs, allow_outside)
      fs.glob(base, "**/*.md").sort.map do |absolute|
        Convention.parse(relativize(repo_root, absolute), fs.read(absolute))
      end
    end

    private def relativize(repo_root : Path, absolute : String) : String
      Path[absolute].relative_to(repo_root).to_posix.to_s
    end
  end
end
