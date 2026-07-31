require "file_utils"

module AgentApropos
  # The filesystem boundary. Logic modules never touch `File`/`Dir`
  # directly — they receive a `Filesystem`, so error and edge paths are
  # unit-testable with a fake and `Real` is the only code that hits disk.
  abstract class Filesystem
    # Raised when a filesystem operation refuses to proceed for safety
    # reasons (e.g. `append` finding a symlink at the destination).
    class Error < AgentApropos::Error
    end

    # List files under `base` matching a glob `pattern` (results unsorted;
    # callers sort for determinism).
    abstract def glob(base : Path, pattern : String) : Array(String)

    # Read a file's full contents as a string.
    abstract def read(path : String) : String

    # Read a file if it exists, else nil. Lets callers treat an absent index or
    # skill wrapper the same as an empty one without a separate existence check.
    abstract def read?(path : String) : String?

    # Write `content` to `path`, creating parent directories as needed. Callers
    # supply LF-terminated, byte-stable content (determinism). The write
    # is atomic (temp file + rename) so a concurrent hook never observes a
    # half-written index or session file.
    abstract def write(path : String, content : String) : Nil

    # Append `content` to `path`, creating parent directories as needed. Used
    # only for the best-effort `--verbose` hook log; never on an
    # artifact whose bytes must be stable.
    abstract def append(path : String, content : String) : Nil

    # Remove a file or directory tree at `path`; a no-op if it does not exist
    # (used to prune orphaned skill wrappers).
    abstract def remove(path : String) : Nil

    # Does something exist at `path`? True for a regular file, a directory, or a
    # (possibly dangling) symlink. `init` uses this to stay idempotent — a
    # scaffold file is written only when absent.
    abstract def exists?(path : String) : Bool

    # Create a symlink at `link_path` pointing at `target`. Used by
    # `init --claude-symlink` to alias `CLAUDE.md → AGENTS.md`.
    abstract def symlink(target : String, link_path : String) : Nil

    # The production adapter: the only place `Dir`/`File` are called.
    class Real < Filesystem
      def glob(base : Path, pattern : String) : Array(String)
        Dir.glob(base.join(pattern).to_s)
      end

      def read(path : String) : String
        File.read(path)
      end

      def read?(path : String) : String?
        File.read(path) if File.exists?(path)
      end

      def write(path : String, content : String) : Nil
        target = Path[path]
        dir = target.dirname
        Dir.mkdir_p(dir)
        temp = Path[dir].join(".#{target.basename}.#{Process.pid}.tmp").to_s
        File.write(temp, content)
        File.rename(temp, path)
      end

      def append(path : String, content : String) : Nil
        Dir.mkdir_p(Path[path].dirname)
        {% if flag?(:unix) %}
          append_nofollow(path, content)
        {% else %}
          raise Error.new("refusing to append through a symlink: #{path}") if File.symlink?(path)
          File.open(path, "a", &.print(content))
        {% end %}
      end

      {% if flag?(:unix) %}
        # Opens with `O_NOFOLLOW` so a symlink swapped in after `mkdir_p` (a
        # TOCTOU window a plain symlink-then-open check can't close) is
        # rejected atomically by the kernel instead of silently followed.
        private def append_nofollow(path : String, content : String) : Nil
          fd = LibC.open(path, LibC::O_WRONLY | LibC::O_APPEND | LibC::O_CREAT | LibC::O_NOFOLLOW,
            File::DEFAULT_CREATE_PERMISSIONS.value)
          if fd == -1
            raise Error.new("refusing to append through a symlink: #{path}") if Errno.value == Errno::ELOOP
            raise Error.new("failed to open #{path}: #{Errno.value}")
          end
          io = IO::FileDescriptor.new(fd)
          begin
            io.print(content)
          ensure
            io.close
          end
        end
      {% end %}

      def remove(path : String) : Nil
        FileUtils.rm_rf(path)
      end

      def exists?(path : String) : Bool
        File.exists?(path) || File.symlink?(path) || Dir.exists?(path)
      end

      def symlink(target : String, link_path : String) : Nil
        Dir.mkdir_p(Path[link_path].dirname)
        File.symlink(target, link_path)
      end
    end
  end
end
