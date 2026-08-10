require "../spec_helper"

private def run_help(args : Array(String)) : {Int32, String}
  stdout = IO::Memory.new
  code = AgentApropos::Help.run(args, stdout)
  {code, stdout.to_s}
end

# The command names named in the CLI's USAGE text — the documented surface the
# help explainer must cover. `hook pre`/`hook post` share the top-level `hook`.
private def usage_command_names : Set(String)
  names = Set(String).new
  capturing = false
  AgentApropos::CLI::USAGE.each_line do |line|
    capturing = true if line.includes?("Commands")
    capturing = false if line.strip.starts_with?("Options:")
    next unless capturing
    stripped = line.strip
    next if stripped.empty? || stripped.starts_with?("Commands")
    first = stripped.split(/\s+/).first
    names << first if first =~ /\A[a-z]+\z/
  end
  names
end

describe AgentApropos::Help do
  describe ".run (prose)" do
    it "prints the mental-model explainer and exits 0" do
      code, stdout = run_help([] of String)
      code.should eq(0)
      stdout.should contain("What agent-apropos is")
      stdout.should contain("Why it exists")
      stdout.should contain("The three layers")
      stdout.should contain("Where things live")
      stdout.should contain("If you're an AI agent reading this")
      stdout.should contain("docs/conventions/README.md")
    end

    it "renders one line per layer" do
      _, stdout = run_help([] of String)
      stdout.should contain("Layer 1 — Root file")
      stdout.should contain("Layer 3 — Intent skills")
    end
  end

  describe ".run (json)" do
    it "emits the same content as structured JSON and exits 0" do
      code, stdout = run_help(["--format", "json"])
      code.should eq(0)
      parsed = JSON.parse(stdout)
      parsed["what"].as_s.should contain("deterministic")
      parsed["why"].as_s.should_not be_empty
      parsed["layers"].as_a.size.should eq(3)
      parsed["paths"].as_h.has_key?("docs/conventions/").should be_true
      parsed["agent_note"].as_s.should contain("human-authored")
      parsed["learn_more"].as_s.should_not be_empty
    end

    it "accepts a bare --format as selecting JSON" do
      _, stdout = run_help(["--format"])
      JSON.parse(stdout)["what"].should_not be_nil
    end

    it "lists every command the CLI exposes (no silent omissions)" do
      _, stdout = run_help(["--format", "json"])
      json_names = JSON.parse(stdout)["commands"].as_a.map(&.["name"].as_s).to_set
      usage_command_names.each do |name|
        json_names.should contain(name)
      end
    end
  end

  describe ".run (per command)" do
    it "prints the mental-model note for a known command and defers to --help" do
      code, stdout = run_help(["review"])
      code.should eq(0)
      stdout.should contain("agent-apropos review —")
      stdout.should contain("Run `agent-apropos review --help` for exact flags.")
    end

    it "reports an unknown command but still exits 0 (help never fails)" do
      code, stdout = run_help(["frobnicate"])
      code.should eq(0)
      stdout.should contain("no such command 'frobnicate'")
      stdout.should contain("init")
    end

    it "ignores unknown flags rather than failing" do
      code, stdout = run_help(["--bogus"])
      code.should eq(0)
      stdout.should contain("What agent-apropos is")
    end
  end
end
