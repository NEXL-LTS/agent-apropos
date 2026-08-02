require "json"
require "./conventions"
require "./index"
require "./environment"
require "./filesystem"
require "./check"
require "./agents"

module AgentApropos
  module Doctor
    extend self

    INDEX_RELATIVE = Path[".cache", "agent-apropos", "index.json"]
    PROBE_RELATIVE = Path[".cache", "agent-apropos", ".doctor-probe"]

    def run(repo_root : Path, fs : Filesystem, env : Environment, stdout : IO, stderr : IO,
            allow_outside : Bool = false) : Int32
      checks = [agent_apropos_check(env)] +
               Agents::ALL.flat_map(&.checks(repo_root, fs, env)) +
               [index_check(repo_root, fs, allow_outside), cache_check(repo_root, fs)]
      report(checks, stdout)
    end

    private def agent_apropos_check(env : Environment) : Check
      if path = env.which("agent-apropos")
        Check.new(:ok, "agent-apropos", "on PATH at #{path}")
      else
        Check.new(:warn, "agent-apropos", "not found on PATH; hooks invoke `agent-apropos`")
      end
    end

    private def index_check(repo_root : Path, fs : Filesystem, allow_outside : Bool) : Check
      json = fs.read?(repo_root.join(INDEX_RELATIVE).to_s)
      return Check.new(:warn, "index", "not built; run `agent-apropos generate`") unless json

      index = Index.load(json)
      return Check.new(:warn, "index", "unreadable; run `agent-apropos generate`") unless index

      conventions =
        begin
          Conventions.walk(repo_root, fs, allow_outside)
        rescue AgentApropos::Error
          return Check.new(:warn, "index", "cannot evaluate freshness; run `agent-apropos lint`, " \
                                           "or pass --allow-outside-repo if conventions_dir is outside the repo root")
        end

      if index.covers?(conventions)
        Check.new(:ok, "index", "fresh")
      else
        Check.new(:warn, "index", "stale; run `agent-apropos generate`")
      end
    end

    private def cache_check(repo_root : Path, fs : Filesystem) : Check
      probe = repo_root.join(PROBE_RELATIVE).to_s
      fs.write(probe, "ok")
      fs.remove(probe)
      Check.new(:ok, "cache", ".cache/agent-apropos is writable")
    rescue
      Check.new(:fail, "cache", ".cache/agent-apropos is not writable")
    end

    private def report(checks : Array(Check), stdout : IO) : Int32
      checks.each { |check| stdout.puts "#{marker(check.status)}  #{check.name}: #{check.detail}" }
      failures = checks.count { |check| check.status == :fail }
      warnings = checks.count { |check| check.status == :warn }
      stdout.puts "doctor: #{failures} failure(s), #{warnings} warning(s)"
      failures > 0 ? 1 : 0
    end

    private def marker(status : Symbol) : String
      case status
      when :ok
        "ok  "
      when :warn
        "warn"
      else
        "fail"
      end
    end
  end
end
