require "./errors"

module AgentApropos
  abstract class Git
    class Error < AgentApropos::Error
    end

    abstract def diff(repo_root : Path, range : String) : String

    abstract def symbolic_ref(repo_root : Path, name : String) : String?

    abstract def ref_exists?(repo_root : Path, ref : String) : Bool

    abstract def ls_files(repo_root : Path) : Array(String)?

    abstract def removed_paths(repo_root : Path) : Array(String)

    abstract def blob(repo_root : Path, revision : String, path : String) : String?

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

      def ls_files(repo_root : Path) : Array(String)?
        output = capture?(repo_root, ["ls-files", "-z"])
        if output.nil?
          raise Error.new("git ls-files failed in #{repo_root}") if File.exists?(repo_root.join(".git"))
          return nil
        end
        output.split('\0').reject(&.empty?)
      end

      def removed_paths(repo_root : Path) : Array(String)
        output = capture?(repo_root, ["status", "--porcelain", "-z", "--untracked-files=no"])
        return [] of String unless output
        parse_removed_records(output.split('\0').reject(&.empty?))
      end

      def blob(repo_root : Path, revision : String, path : String) : String?
        capture?(repo_root, ["show", "#{revision}:#{path}"])
      end

      private def parse_removed_records(records : Array(String)) : Array(String)
        removed = [] of String
        i = 0
        while i < records.size
          status = records[i][0, 2]
          # Both R and C carry a second, bare source field; only a rename's source vanished, never a copy's.
          if status.includes?('R') || status.includes?('C')
            removed << status_record_path(records[i]) if status[1]? == 'D'
            records[i + 1]?.try { |source| removed << source if status.includes?('R') }
            i += 2
          elsif tracked_removal_status?(status)
            removed << status_record_path(records[i])
            i += 1
          else
            i += 1
          end
        end
        removed
      end

      private def status_record_path(record : String) : String
        record[3..]
      end

      private def tracked_removal_status?(status : String) : Bool
        status[1]? == 'D' || status == "D "
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
      rescue IO::Error
      end
    end
  end
end
