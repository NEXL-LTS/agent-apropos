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
  #
  # `FALLBACK_RELATIVE` (`.cache/agent-apropos.yml`) is checked only when the
  # root-level file is absent. It is deliberately undocumented in the public
  # README — real users configure `conventions_dir` via the root file, per
  # the published "Configuration" section. This fallback exists solely for
  # agent-apropos's own e2e/manual-test rig: a root-level `agent-apropos.yml`
  # is a plain, ordinary-looking file a curious agent's own exploration
  # readily finds and reads (observed live), which hands it the exact
  # location of the sample's hidden convention docs. `.cache/` already reads
  # as machine-generated, disposable output (it holds the trigger index and
  # session state), so a config file living there draws far less of that
  # same curiosity, without changing the documented root-file behavior real
  # users depend on.
  module Config
    extend self

    class Error < AgentApropos::Error
    end

    FILENAME                = "agent-apropos.yml"
    FALLBACK_RELATIVE       = Path[".cache", "agent-apropos.yml"]
    DEFAULT_CONVENTIONS_DIR = "docs/conventions"

    # The resolved conventions directory for `repo_root`: whatever
    # `agent-apropos.yml`'s `conventions_dir` says — resolved against `repo_root`
    # when relative, used verbatim when absolute — or the default when the
    # file is absent or sets no `conventions_dir`.
    def conventions_dir(repo_root : Path, fs : Filesystem) : Path
      setting = conventions_dir_setting(repo_root, fs)
      return repo_root.join(DEFAULT_CONVENTIONS_DIR) unless setting

      path = Path[setting]
      path.absolute? ? path : repo_root.join(path)
    end

    # Reads the root-level file first; falls back to `FALLBACK_RELATIVE` only
    # when the root-level file is absent, so an explicit root file always
    # wins over the undocumented fallback. Error messages name whichever of
    # the two was actually read, not always `FILENAME`, so a malformed
    # fallback file doesn't point the reader at the wrong path.
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

    # The name and contents of whichever of `FILENAME` / `FALLBACK_RELATIVE`
    # exists, root file first — `text` is nil when neither is present.
    private def config_source(repo_root : Path, fs : Filesystem) : {String, String?}
      if text = fs.read?(repo_root.join(FILENAME).to_s)
        {FILENAME, text}
      else
        {FALLBACK_RELATIVE.to_s, fs.read?(repo_root.join(FALLBACK_RELATIVE).to_s)}
      end
    end
  end
end
