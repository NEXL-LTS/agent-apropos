require "./errors"

module AgentApropos
  abstract class Git
    class Error < AgentApropos::Error
    end

    abstract def diff(repo_root : Path, range : String) : String

    abstract def symbolic_ref(repo_root : Path, name : String) : String?

    abstract def ref_exists?(repo_root : Path, ref : String) : Bool

    class Real < Git
      def diff(repo_root : Path, range : String) : String
        capture(repo_root, ["diff", "--no-color", range])
      end

      def symbolic_ref(repo_root : Path, name : String) : String?
        capture?(repo_root, ["symbolic-ref", "--short", name]).try(&.strip).presence
      end

      def ref_exists?(repo_root : Path, ref : String) : Bool
        !capture?(repo_root, ["rev-parse", "--verify", "--quiet", ref]).nil?
      end

      private def capture(repo_root : Path, args : Array(String)) : String
        capture?(repo_root, args) || raise Error.new("git #{args.join(' ')} failed")
      end

      private def capture?(repo_root : Path, args : Array(String)) : String?
        stdout = IO::Memory.new
        status = Process.run(
          "git", args,
          chdir: repo_root.to_s, output: stdout, error: Process::Redirect::Close
        )
        status.success? ? stdout.to_s : nil
      end
    end
  end
end
