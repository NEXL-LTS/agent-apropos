require "yaml"
require "./errors"
require "./filesystem"

module AgentApropos
  # Repo-level settings, read from `agent-apropos.yml` at the repo root when
  # present. Optional — a repo with no `agent-apropos.yml` gets every default
  # unchanged. Deliberately small: the only setting today is where the
  # convention docs live, so a repo can keep them outside its own tree (a
  # monorepo's shared docs, or — agent-apropos's own e2e fixture — outside the
  # sample git repo entirely, so a CLI agent's auto-included directory
  # listing never reveals the mechanism under test).
  #
  # A malformed `agent-apropos.yml` raises `Config::Error` rather than silently
  # falling back to the default — an authoring-time mistake should never be
  # indistinguishable from "no config" — so `generate`/`lint`/`match`/
  # `review` (which already propagate `AgentApropos::Error` and fail closed) need
  # no changes to handle it, and `hook`'s existing blanket rescue makes it
  # fail open there for free.
  module Config
    extend self

    class Error < AgentApropos::Error
    end

    FILENAME                = "agent-apropos.yml"
    DEFAULT_CONVENTIONS_DIR = "docs/conventions"

    # The resolved conventions directory for `repo_root`: whatever
    # `agent-apropos.yml`'s `conventions_dir` says — resolved against `repo_root`
    # when relative, used verbatim when absolute — or the default when the
    # file is absent or sets no `conventions_dir`.
    #
    # A setting that escapes `repo_root` (an absolute path elsewhere, or a
    # relative one with enough `../` to walk out of the tree) is a
    # legitimate feature for read-only commands (a monorepo's shared docs,
    # agent-apropos's own e2e fixture) but is also exactly what a hostile
    # `agent-apropos.yml` — checked into a repo someone just cloned — would set
    # to steer a write command's output to an attacker-chosen path. So it is
    # gated behind `allow_outside`, which every caller must pass explicitly
    # (surfaced as each command's own `--allow-outside-repo` flag) rather
    # than defaulting to trust.
    def conventions_dir(repo_root : Path, fs : Filesystem, allow_outside : Bool = false) : Path
      resolved = resolve(repo_root, fs)
      return resolved if allow_outside || within_repo?(repo_root, resolved)

      # Normalized for display, same as the `within_repo?` check itself —
      # otherwise a relative escape prints as e.g. `/repo/../shared-conventions`,
      # which reads as "under /repo" at a glance instead of the escape it is.
      raise Error.new(
        "#{FILENAME}: conventions_dir (#{resolved.normalize}) resolves outside the repo root " \
        "(#{repo_root.normalize}); pass --allow-outside-repo if this is intentional")
    end

    # Whether `agent-apropos.yml`'s configured conventions_dir (or the default,
    # which never escapes) resolves outside `repo_root` — without raising.
    # Used by `init` to decide whether the hook commands it wires need
    # `--allow-outside-repo` baked in to keep working after a permitted
    # out-of-tree setup.
    def outside_repo?(repo_root : Path, fs : Filesystem) : Bool
      !within_repo?(repo_root, resolve(repo_root, fs))
    end

    private def resolve(repo_root : Path, fs : Filesystem) : Path
      setting = conventions_dir_setting(repo_root, fs)
      return repo_root.join(DEFAULT_CONVENTIONS_DIR) unless setting

      path = Path[setting]
      path.absolute? ? path : repo_root.join(path)
    end

    # Lexical containment check (no filesystem access, so it works identically
    # against `InMemoryFS` paths that don't exist on disk): normalizing both
    # sides collapses any `..`/`.` segments before comparing, so an
    # absolute escape and a relative `../`-escape are caught the same way.
    private def within_repo?(repo_root : Path, resolved : Path) : Bool
      relative = resolved.normalize.relative_to(repo_root.normalize).to_posix.to_s
      relative != ".." && !relative.starts_with?("../")
    end

    private def conventions_dir_setting(repo_root : Path, fs : Filesystem) : String?
      text = fs.read?(repo_root.join(FILENAME).to_s)
      return nil unless text

      parsed =
        begin
          YAML.parse(text)
        rescue ex : YAML::ParseException
          raise Error.new("#{FILENAME} is not valid YAML: #{ex.message}")
        end
      hash = parsed.as_h?
      raise Error.new("#{FILENAME} must be a YAML mapping") unless hash

      value = parsed["conventions_dir"]?
      return nil unless value
      value.as_s? || raise Error.new("#{FILENAME}: conventions_dir must be a string")
    end
  end
end
