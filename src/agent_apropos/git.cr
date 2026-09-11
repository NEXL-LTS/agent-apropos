require "./errors"
require "./filesystem"

module AgentApropos
  abstract class Git
    class Error < AgentApropos::Error
    end

    abstract class Process
      abstract def run(args : Array(String), chdir : String) : String?

      class Real < Process
        def run(args : Array(String), chdir : String) : String?
          stdout = IO::Memory.new
          status = ::Process.run(
            "git", args,
            chdir: chdir, output: stdout, error: ::Process::Redirect::Close
          )
          status.success? ? stdout.to_s : nil
        rescue IO::Error
        end
      end
    end

    abstract def diff(repo_root : Path, range : String) : String

    abstract def symbolic_ref(repo_root : Path, name : String) : String?

    abstract def ref_exists?(repo_root : Path, ref : String) : Bool

    abstract def ls_files(repo_root : Path) : Array(String)?

    abstract def removed_paths(repo_root : Path, fs : Filesystem) : Array(String)

    abstract def blob(repo_root : Path, revision : String, path : String) : String?

    class Real < Git
      def initialize(@process : Process = Process::Real.new)
      end

      def diff(repo_root : Path, range : String) : String
        capture(repo_root, ["diff", "--no-color", range])
      end

      def symbolic_ref(repo_root : Path, name : String) : String?
        capture?(repo_root, ["symbolic-ref", "--short", name]).try(&.strip).presence
      end

      def ref_exists?(repo_root : Path, ref : String) : Bool
        !capture?(repo_root, ["rev-parse", "--verify", "--quiet", ref]).nil?
      end

      def ls_files(repo_root : Path) : Array(String)?
        output = capture?(repo_root, ["ls-files", "-z"])
        if output.nil?
          raise Error.new("git ls-files failed in #{repo_root}") if File.exists?(repo_root.join(".git"))
          return nil
        end
        output.split('\0').reject(&.empty?)
      end

      def removed_paths(repo_root : Path, fs : Filesystem) : Array(String)
        output = capture?(repo_root, ["status", "--porcelain", "-z", "--untracked-files=no"])
        return [] of String unless output
        records = Deque(String).new(output.split('\0').reject(&.empty?))
        # Git's status codes alone don't prove a path is gone from disk; every candidate is checked directly.
        parse_removed_records(records).reject { |relative| fs.exists?(repo_root.join(relative).to_s) }
      end

      def blob(repo_root : Path, revision : String, path : String) : String?
        capture?(repo_root, ["show", "#{revision}:#{path}"])
      end

      private def parse_removed_records(records : Deque(String)) : Array(String)
        candidates = [] of String
        until records.empty?
          record = records.shift
          candidates << status_record_path(record)
          if record[0]? == 'R' || record[0]? == 'C'
            source = records.shift?
            candidates << source if source
          end
        end
        candidates
      end

      private def status_record_path(record : String) : String
        record[3..]
      end

      private def capture(repo_root : Path, args : Array(String)) : String
        capture?(repo_root, args) || raise Error.new("git #{args.join(' ')} failed")
      end

      private def capture?(repo_root : Path, args : Array(String)) : String?
        @process.run(args, repo_root.to_s)
      end
    end
  end
end
