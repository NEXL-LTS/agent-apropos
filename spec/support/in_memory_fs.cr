require "../../src/agent_apropos/filesystem"

# A full in-memory `Filesystem` for unit specs: `glob` honours the same
# `File.match?` semantics as the real adapter, and writes/reads/removes mutate
# an internal map so generate's disk effects are observable without touching
# disk. `removed` records prune targets for assertions.
#
# Every path is keyed in POSIX form, so the examples' `/repo/...` literals match
# whatever separators `Path#join` produced on the host — the production code
# hands this double a native path, which is `\repo\...` on Windows.
class InMemoryFS < AgentApropos::Filesystem
  getter files : Hash(String, String)
  getter removed : Array(String)
  getter symlinks : Hash(String, String)

  def initialize(files = {} of String => String)
    @files = files.transform_keys { |path| InMemoryFS.key(path) }
    @removed = [] of String
    @symlinks = {} of String => String
  end

  def self.key(path : String) : String
    Path[path].to_posix.to_s
  end

  def glob(base : Path, pattern : String) : Array(String)
    full = base.join(pattern).to_posix.to_s
    @files.keys.select { |key| File.match?(full, key) }
  end

  def read(path : String) : String
    @files[InMemoryFS.key(path)]
  end

  def read?(path : String) : String?
    @files[InMemoryFS.key(path)]?
  end

  def write(path : String, content : String) : Nil
    @files[InMemoryFS.key(path)] = content
  end

  def remove(path : String) : Nil
    key = InMemoryFS.key(path)
    @removed << key
    @files.reject! { |existing, _| existing == key || existing.starts_with?("#{key}/") }
  end

  def exists?(path : String) : Bool
    key = InMemoryFS.key(path)
    @files.has_key?(key) || @symlinks.has_key?(key) ||
      @files.each_key.any?(&.starts_with?("#{key}/"))
  end

  def symlink(target : String, link_path : String) : Nil
    @symlinks[InMemoryFS.key(link_path)] = target
  end
end
