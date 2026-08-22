require "../spec_helper"

# The process/PATH adapter is covered in-process (kcov does not measure the
# subprocess integration specs), using `git` — the one external command the
# integration specs already require, and the only one guaranteed present on
# every CI image this suite runs on, Windows included — and a name that cannot
# resolve.
describe AgentApropos::Environment::Real do
  env = AgentApropos::Environment::Real.new

  it "resolves an executable on PATH and returns nil for a missing one" do
    env.which("git").should_not be_nil
    env.which("agent-apropos-definitely-absent-xyz").should be_nil
  end

  it "captures stdout on success" do
    env.run_capture("git", ["--version"]).to_s.should contain("git version")
  end

  it "returns nil on a non-zero exit" do
    env.run_capture("git", ["rev-parse", "--verify", "refs/heads/agent-apropos-no-such-ref"]).should be_nil
  end

  it "returns nil when the command cannot be launched" do
    env.run_capture("agent-apropos-definitely-absent-xyz", [] of String).should be_nil
  end
end
