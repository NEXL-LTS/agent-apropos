require "../../src/agent_apropos/git"

# A fake git that records the range it was asked to diff and returns canned
# output, so the pure logic that consumes git (range resolution, diff parsing,
# rendering, the lint dead-glob check) is unit-testable without a real repo.
# `Git::Real` itself is covered in git_spec.
class FakeGit < AgentApropos::Git
  getter diffed_range : String? = nil

  def initialize(@diff_text : String = "", @symbolic : String? = nil,
                 @refs : Array(String) = [] of String, @diff_raises : Bool = false,
                 @tracked : Array(String)? = [] of String, @ls_files_raises : Bool = false)
  end

  def diff(repo_root : Path, range : String) : String
    @diffed_range = range
    raise AgentApropos::Git::Error.new("diff boom") if @diff_raises
    @diff_text
  end

  def symbolic_ref(repo_root : Path, name : String) : String?
    @symbolic
  end

  def ref_exists?(repo_root : Path, ref : String) : Bool
    @refs.includes?(ref)
  end

  def ls_files(repo_root : Path) : Array(String)?
    raise AgentApropos::Git::Error.new("ls-files boom") if @ls_files_raises
    @tracked
  end
end
