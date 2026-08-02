require "./version"
require "./generate"
require "./hook"
require "./review"
require "./git"
require "./init"
require "./lint"
require "./doctor"
require "./help"
require "./environment"
require "./repo_root"
require "./filesystem"

module AgentApropos
  class CLI
    USAGE = <<-USAGE
      agent-apropos — deliver the right conventions to the right moment.

      Usage: agent-apropos <command> [options]

      Commands:
        init        Bootstrap the convention structure into a repo
        generate    Compile frontmatter into the index + skill wrappers
        hook pre    PreToolUse handler  (Layer 2, path-scoped)
        hook post   PostToolUse handler (Layer 3, construct-scoped)
        match       Resolve conventions for given paths
        review      Resolve conventions for a git range
        lint        Validate the convention structure
        doctor      Check the environment
        help        Explain the mental model

      Options:
        --version   Print version and exit
        --help, -h  Print this usage and exit
      USAGE

    def self.run(args : Array(String), stdout : IO = STDOUT, stderr : IO = STDERR, stdin : IO = STDIN) : Int32
      new(stdout, stderr, stdin).run(args)
    end

    def initialize(@stdout : IO, @stderr : IO, @stdin : IO = STDIN)
    end

    def run(args : Array(String)) : Int32
      case first = args.first?
      when nil, "--help", "-h"
        @stdout.puts USAGE
        0
      when "--version", "version"
        @stdout.puts "agent-apropos #{VERSION}"
        0
      else
        dispatch(first, args[1..])
      end
    end

    private def dispatch(command : String, rest : Array(String)) : Int32
      case command
      when "help"     then Help.run(rest, @stdout)
      when "init"     then handle_init(rest)
      when "generate" then handle_generate(rest)
      when "hook"     then handle_hook(rest)
      when "match"    then handle_match(rest)
      when "review"   then handle_review(rest)
      when "lint"     then handle_lint(rest)
      when "doctor"   then handle_doctor(rest)
      else
        @stderr.puts "agent-apropos: unknown command '#{command}'. Run `agent-apropos --help`."
        1
      end
    end

    private def handle_generate(args : Array(String)) : Int32
      check = false
      allow_outside = false
      override : String? = nil

      index = 0
      while index < args.size
        case arg = args[index]
        when "--check"
          check = true
        when "--allow-outside-repo"
          allow_outside = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return usage_error("--repo-root requires a directory") if value.nil?
          override = value
        else
          return usage_error("unknown option '#{arg}'")
        end
        index += 1
      end

      root = override ? Path[override] : AgentApropos.find_repo_root(Path[Dir.current])
      if root.nil?
        @stderr.puts "agent-apropos generate: no repository root found (looked for .git). Pass --repo-root."
        return 1
      end

      fs = Filesystem::Real.new
      if check
        Generate.check(root, fs, @stdout, @stderr, allow_outside)
      else
        Generate.run(root, fs, @stdout, @stderr, allow_outside)
      end
    end

    private def usage_error(message : String) : Int32
      @stderr.puts "agent-apropos generate: #{message}"
      1
    end

    private class InitArgs
      property? force = false
      property? example = false
      property? claude_symlink = false
      property? dry_run = false
      property? allow_outside_repo = false
      property tools : Set(String)? = nil
      property override : String? = nil
    end

    private def handle_init(args : Array(String)) : Int32
      opts = InitArgs.new
      if code = parse_init_args(args, opts)
        return code
      end

      root = resolve_repo_root(opts.override)
      return repo_root_error("init") if root.nil?

      options = Init::Options.new(
        force: opts.force?, example: opts.example?,
        claude_symlink: opts.claude_symlink?, dry_run: opts.dry_run?,
        tools: opts.tools, allow_outside_repo: opts.allow_outside_repo?)
      Init.run(root, Filesystem::Real.new, Environment::Real.new, options, @stdout, @stderr)
    end

    private def parse_init_args(args : Array(String), opts : InitArgs) : Int32?
      index = 0
      while index < args.size
        arg = args[index]
        unless apply_init_flag(arg, opts)
          case arg
          when "--tool"
            index += 1
            if code = parse_init_tool(args[index]?, opts)
              return code
            end
          when "--repo-root"
            index += 1
            value = args[index]?
            return command_error("init", "--repo-root requires a directory") if value.nil?
            opts.override = value
          else
            return command_error("init", "unknown option '#{arg}'")
          end
        end
        index += 1
      end
      nil
    end

    private def apply_init_flag(arg : String, opts : InitArgs) : Bool
      case arg
      when "--force"              then opts.force = true
      when "--example"            then opts.example = true
      when "--claude-symlink"     then opts.claude_symlink = true
      when "--dry-run"            then opts.dry_run = true
      when "--allow-outside-repo" then opts.allow_outside_repo = true
      else                             return false
      end
      true
    end

    private def parse_init_tool(value : String?, opts : InitArgs) : Int32?
      return command_error("init", "--tool requires a value") if value.nil? || value.starts_with?("--")
      unless Init::KNOWN_TOOLS.includes?(value)
        return command_error("init", "unknown tool '#{value}' (#{Init::KNOWN_TOOLS.to_a.sort.join("|")})")
      end
      opts.tools = (opts.tools || Set(String).new) << value
      nil
    end

    private def handle_lint(args : Array(String)) : Int32
      strict = false
      allow_outside = false
      override : String? = nil
      index = 0
      while index < args.size
        case arg = args[index]
        when "--strict"
          strict = true
        when "--allow-outside-repo"
          allow_outside = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return command_error("lint", "--repo-root requires a directory") if value.nil?
          override = value
        else
          return command_error("lint", "unknown option '#{arg}'")
        end
        index += 1
      end

      root = resolve_repo_root(override)
      return repo_root_error("lint") if root.nil?

      Lint.run(root, Filesystem::Real.new, strict, @stdout, @stderr, allow_outside)
    end

    private def handle_doctor(args : Array(String)) : Int32
      allow_outside = false
      override : String? = nil
      index = 0
      while index < args.size
        case arg = args[index]
        when "--allow-outside-repo"
          allow_outside = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return command_error("doctor", "--repo-root requires a directory") if value.nil?
          override = value
        else
          return command_error("doctor", "unknown option '#{arg}'")
        end
        index += 1
      end

      root = resolve_repo_root(override)
      return repo_root_error("doctor") if root.nil?

      Doctor.run(root, Filesystem::Real.new, Environment::Real.new, @stdout, @stderr, allow_outside)
    end

    private def handle_hook(args : Array(String)) : Int32
      event = args.first?
      return 0 unless event == "pre" || event == "post"

      rest = args[1..]
      override = flag_value(rest, "--repo-root")
      tool = flag_value(rest, "--tool")
      allow_outside = rest.includes?("--allow-outside-repo")
      verbose = {"1", "true"}.includes?(ENV["AGENT_APROPOS_VERBOSE"]?)
      fs = Filesystem::Real.new
      now = Time.utc
      if event == "pre"
        Hook.pre(@stdin, @stdout, fs, now, override, verbose, tool, allow_outside)
      else
        Hook.post(@stdin, @stdout, fs, now, override, verbose, tool, allow_outside)
      end
    end

    private def flag_value(args : Array(String), flag : String) : String?
      index = args.index(flag)
      return nil unless index
      value = args[index + 1]?
      return nil if value.nil? || value.starts_with?("--")
      value
    end

    private class MatchArgs
      property format = "paths"
      property? stdin_content = false
      property? allow_outside_repo = false
      property override : String? = nil
      getter paths = [] of String
    end

    private def handle_match(args : Array(String)) : Int32
      opts = MatchArgs.new
      if code = parse_match_args(args, opts)
        return code
      end
      if code = validate_match(opts)
        return code
      end

      root = resolve_repo_root(opts.override)
      return repo_root_error("match") if root.nil?

      content = opts.stdin_content? ? @stdin.gets_to_end : nil
      Review.match(root, Filesystem::Real.new, opts.paths, opts.format, content, @stdout, @stderr, opts.allow_outside_repo?)
    end

    private def parse_match_args(args : Array(String), opts : MatchArgs) : Int32?
      index = 0
      while index < args.size
        case arg = args[index]
        when "--format"
          index += 1
          value = args[index]?
          return match_error("--format requires a value") if value.nil?
          opts.format = value
        when "--stdin-content"
          opts.stdin_content = true
        when "--allow-outside-repo"
          opts.allow_outside_repo = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return match_error("--repo-root requires a directory") if value.nil?
          opts.override = value
        else
          return match_error("unknown option '#{arg}'") if arg.starts_with?("--")
          opts.paths << arg
        end
        index += 1
      end
      nil
    end

    private def validate_match(opts : MatchArgs) : Int32?
      return match_error("expected at least one path") if opts.paths.empty?
      unless MATCH_FORMATS.includes?(opts.format)
        return match_error("unknown --format '#{opts.format}' (paths|json|full)")
      end
      if opts.stdin_content? && opts.paths.size != 1
        return match_error("--stdin-content takes exactly one path")
      end
      nil
    end

    private def handle_review(args : Array(String)) : Int32
      format = "md"
      allow_outside = false
      override : String? = nil
      range : String? = nil

      index = 0
      while index < args.size
        case arg = args[index]
        when "--format"
          index += 1
          value = args[index]?
          return review_error("--format requires a value") if value.nil?
          format = value
        when "--allow-outside-repo"
          allow_outside = true
        when "--repo-root"
          index += 1
          value = args[index]?
          return review_error("--repo-root requires a directory") if value.nil?
          override = value
        else
          return review_error("unknown option '#{arg}'") if arg.starts_with?("--")
          return review_error("only one git range may be given") unless range.nil?
          range = arg
        end
        index += 1
      end

      return review_error("unknown --format '#{format}' (md|json)") unless REVIEW_FORMATS.includes?(format)

      root = resolve_repo_root(override)
      return repo_root_error("review") if root.nil?

      Review.run(root, Filesystem::Real.new, Git::Real.new, range, format, @stdout, @stderr, allow_outside)
    end

    MATCH_FORMATS  = {"paths", "json", "full"}
    REVIEW_FORMATS = {"md", "json"}

    private def resolve_repo_root(override : String?) : Path?
      override ? Path[override] : AgentApropos.find_repo_root(Path[Dir.current])
    end

    private def repo_root_error(command : String) : Int32
      @stderr.puts "agent-apropos #{command}: no repository root found (looked for .git). Pass --repo-root."
      1
    end

    private def command_error(command : String, message : String) : Int32
      @stderr.puts "agent-apropos #{command}: #{message}"
      1
    end

    private def match_error(message : String) : Int32
      @stderr.puts "agent-apropos match: #{message}"
      1
    end

    private def review_error(message : String) : Int32
      @stderr.puts "agent-apropos review: #{message}"
      1
    end
  end
end
