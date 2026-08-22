require "../../src/agent_apropos/filesystem"

# A full in-memory `Filesystem` for unit specs: `glob` honours the same
# `File.match?` semantics as the real adapter, and writes/reads/removes mutate
# an internal map so generate's disk effects are observable without touching
# disk. `removed` records prune targets for assertions.
class InMemoryFS < AgentApropos::Filesystem
  getter files : Hash(String, String)
  getter removed : Array(String)
  getter symlinks : Hash(String, String)

  def initialize(@files = {} of String => String)
    @removed = [] of String
    @symlinks = {} of String => String
  end

  def glob(base : Path, pattern : String) : Array(String)
    full = base.join(pattern).to_posix.to_s
    @files.keys.select { |key| File.match?(full, key) }
  end

  def read(path : String) : String
    @files[path]
  end

  def read?(path : String) : String?
    @files[path]?
  end

  def write(path : String, content : String) : Nil
    @files[path] = content
  end

  def remove(path : String) : Nil
    @removed << path
    @files.reject! { |key, _| key == path || key.starts_with?("#{path}/") }
  end

  def exists?(path : String) : Bool
    @files.has_key?(path) || @symlinks.has_key?(path) ||
      @files.each_key.any?(&.starts_with?("#{path}/"))
  end

  def symlink(target : String, link_path : String) : Nil
    @symlinks[link_path] = target
  end
end
