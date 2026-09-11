require "../../src/agent_apropos/git"

# Records each command Git::Real asked it to run, so argument construction and
# ordering can be pinned directly without a real git process.
class FakeProcess < AgentApropos::Git::Process
  getter calls = [] of Array(String)

  def initialize(@output : String? = "")
  end

  def run(args : Array(String), chdir : String) : String?
    @calls << args
    @output
  end
end
