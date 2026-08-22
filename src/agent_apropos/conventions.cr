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
      normalized = normalize_line_endings(text)
      frontmatter, body = Frontmatter.split(normalized)
      new(path, Digest::SHA256.hexdigest(normalized), frontmatter || Frontmatter.new, body)
    end

    private def self.normalize_line_endings(text : String) : String
      text.gsub(/\r\n?/, "\n")
    end

    def scoped? : Bool
      frontmatter.scoped?
    end

    def skill? : Bool
      frontmatter.skill?
    end

    def lint_ignore? : Bool
      frontmatter.lint_ignore?
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
      frontmatter.reference_only?
    end

    def triggers(relative_path : String, content : String?) : Array(String)?
      Matcher.triggers(frontmatter.paths, frontmatter.contents, relative_path, content)
    end

    def triggers?(relative_path : String, content : String?) : Bool
      !triggers(relative_path, content).nil?
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
