require "yaml"
require "./errors"
require "./filesystem"

module AgentApropos
  module Config
    extend self

    class Error < AgentApropos::Error
    end

    FILENAME                = "agent-apropos.yml"
    FALLBACK_RELATIVE       = Path[".cache", "agent-apropos.yml"]
    DEFAULT_CONVENTIONS_DIR = "docs/conventions"

    def conventions_dir(repo_root : Path, fs : Filesystem, allow_outside : Bool = false) : Path
      resolved = resolve(repo_root, fs)
      return resolved if allow_outside || within_repo?(repo_root, resolved)

      raise Error.new(
        "#{FILENAME}: conventions_dir (#{resolved.normalize}) resolves outside the repo root " \
        "(#{repo_root.normalize}); pass --allow-outside-repo if this is intentional")
    end

    def outside_repo?(repo_root : Path, fs : Filesystem) : Bool
      !within_repo?(repo_root, resolve(repo_root, fs))
    end

    private def resolve(repo_root : Path, fs : Filesystem) : Path
      setting = conventions_dir_setting(repo_root, fs)
      return repo_root.join(DEFAULT_CONVENTIONS_DIR) unless setting

      path = Path[setting]
      path.absolute? ? path : repo_root.join(path)
    end

    private def within_repo?(repo_root : Path, resolved : Path) : Bool
      relative = resolved.normalize.relative_to(repo_root.normalize).to_posix.to_s
      relative != ".." && !relative.starts_with?("../")
    end

    private def conventions_dir_setting(repo_root : Path, fs : Filesystem) : String?
      name, text = config_source(repo_root, fs)
      return nil unless text

      parsed =
        begin
          YAML.parse(text)
        rescue ex : YAML::ParseException
          raise Error.new("#{name} is not valid YAML: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new("#{name} must be a YAML mapping") unless hash

      value = parsed["conventions_dir"]?
      return nil unless value
      value.as_s? || raise Error.new("#{name}: conventions_dir must be a string")
    end

    private def config_source(repo_root : Path, fs : Filesystem) : {String, String?}
      if text = fs.read?(repo_root.join(FILENAME).to_s)
        {FILENAME, text}
      else
        {FALLBACK_RELATIVE.to_s, fs.read?(repo_root.join(FALLBACK_RELATIVE).to_s)}
      end
    end
  end
end
