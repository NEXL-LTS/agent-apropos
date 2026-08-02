require "file_utils"

module AgentApropos
  abstract class Filesystem
    class Error < AgentApropos::Error
    end

    abstract def glob(base : Path, pattern : String) : Array(String)

    abstract def read(path : String) : String

    abstract def read?(path : String) : String?

    abstract def write(path : String, content : String) : Nil

    abstract def append(path : String, content : String) : Nil

    abstract def remove(path : String) : Nil

    abstract def exists?(path : String) : Bool

    abstract def symlink(target : String, link_path : String) : Nil

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
