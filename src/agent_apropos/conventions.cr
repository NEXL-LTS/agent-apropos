require "digest/sha256"
require "./frontmatter"
require "./matcher"
require "./filesystem"
require "./config"

module AgentApropos
  struct Convention
    getter path : String
    getter hash : String
    getter frontmatter : Frontmatter
    getter body : String

    def initialize(@path : String, @hash : String, @frontmatter : Frontmatter, @body : String)
    end

    def self.parse(path : String, text : String) : Convention
      frontmatter, body = Frontmatter.split(text)
      new(path, Digest::SHA256.hexdigest(text), frontmatter || Frontmatter.new, body)
    end

    def layer2? : Bool
      !frontmatter.paths.empty? && frontmatter.contents.empty?
    end

    def layer3? : Bool
      !frontmatter.contents.empty?
    end

    def skill? : Bool
      frontmatter.skill?
    end

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

    def reference_only? : Bool
      !layer2? && !layer3? && !skill?
    end

    def triggers_for_path?(relative_path : String) : Bool
      layer2? && Matcher.any_path_match?(frontmatter.paths, relative_path)
    end

    def triggers_for_content?(relative_path : String, content : String) : Bool
      return false unless layer3?
      return false unless Matcher.any_content_match?(frontmatter.contents, content)
      frontmatter.paths.empty? || Matcher.any_path_match?(frontmatter.paths, relative_path)
    end
  end

  module Conventions
    extend self

    def walk(repo_root : Path, fs : Filesystem = Filesystem::Real.new,
             allow_outside : Bool = false, tolerant : Bool = false) : Array(Convention)
      base = Config.conventions_dir(repo_root, fs, allow_outside)
      fs.glob(base, "**/*.md").sort.compact_map do |absolute|
        parse(repo_root, fs, absolute, tolerant)
      end
    end

    private def parse(repo_root : Path, fs : Filesystem, absolute : String, tolerant : Bool) : Convention?
      Convention.parse(relativize(repo_root, absolute), fs.read(absolute))
    rescue ex : Frontmatter::Error
      raise ex unless tolerant
      nil
    end

    private def relativize(repo_root : Path, absolute : String) : String
      Path[absolute].relative_to(repo_root).to_posix.to_s
    end
  end
end
