require "../spec_helper"

private ROOT = Path["/repo"]

describe AgentApropos::Config do
  describe ".conventions_dir" do
    it "defaults to docs/conventions when agent-apropos.yml is absent" do
      AgentApropos::Config.conventions_dir(ROOT, InMemoryFS.new).should eq(Path["/repo/docs/conventions"])
    end

    it "resolves a relative conventions_dir against repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/../shared-conventions"])
    end

    it "uses an absolute conventions_dir verbatim" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: /var/conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/var/conventions"])
    end

    it "defaults when agent-apropos.yml has no conventions_dir key" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "other_key: whatever\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/docs/conventions"])
    end

    it "raises Config::Error on malformed YAML" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "key: [unterminated\n"})
      expect_raises(AgentApropos::Config::Error, /not valid YAML/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "raises Config::Error when the document is not a mapping" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "- just\n- a\n- list\n"})
      expect_raises(AgentApropos::Config::Error, /must be a YAML mapping/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "raises Config::Error when conventions_dir is not a string" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir:\n  - a\n  - b\n"})
      expect_raises(AgentApropos::Config::Error, /must be a string/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "falls back to .cache/agent-apropos.yml when agent-apropos.yml is absent" do
      fs = InMemoryFS.new({"/repo/.cache/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/../shared-conventions"])
    end

    it "prefers agent-apropos.yml over .cache/agent-apropos.yml when both are present" do
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml"        => "conventions_dir: ../root-conventions\n",
        "/repo/.cache/agent-apropos.yml" => "conventions_dir: ../fallback-conventions\n",
      })
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/../root-conventions"])
    end

    it "raises Config::Error on malformed YAML in the .cache/agent-apropos.yml fallback" do
      fs = InMemoryFS.new({"/repo/.cache/agent-apropos.yml" => "key: [unterminated\n"})
      expect_raises(AgentApropos::Config::Error, /not valid YAML/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end
  end
end
