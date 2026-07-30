require "../spec_helper"

private ROOT = Path["/repo"]

describe AgentApropos::Config do
  describe ".conventions_dir" do
    it "defaults to docs/conventions when agent-apropos.yml is absent" do
      AgentApropos::Config.conventions_dir(ROOT, InMemoryFS.new).should eq(Path["/repo/docs/conventions"])
    end

    it "resolves a relative conventions_dir against repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: shared-conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/shared-conventions"])
    end

    it "uses an absolute conventions_dir verbatim" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: /var/conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs, allow_outside: true).should eq(Path["/var/conventions"])
    end

    it "raises Config::Error when a relative conventions_dir escapes repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      expect_raises(AgentApropos::Config::Error, /resolves outside the repo root/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "raises Config::Error when an absolute conventions_dir is outside repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: /var/conventions\n"})
      expect_raises(AgentApropos::Config::Error, /resolves outside the repo root/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "allows an escaping conventions_dir when allow_outside is true" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs, allow_outside: true).should eq(Path["/repo/../shared-conventions"])
    end

    it "does not require allow_outside for a conventions_dir that stays under repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: docs/shared\n"})
      AgentApropos::Config.conventions_dir(ROOT, fs).should eq(Path["/repo/docs/shared"])
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
  end

  describe ".outside_repo?" do
    it "is false when agent-apropos.yml is absent" do
      AgentApropos::Config.outside_repo?(ROOT, InMemoryFS.new).should be_false
    end

    it "is false for a conventions_dir that stays under repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: docs/shared\n"})
      AgentApropos::Config.outside_repo?(ROOT, fs).should be_false
    end

    it "is true for a relative conventions_dir that escapes repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      AgentApropos::Config.outside_repo?(ROOT, fs).should be_true
    end

    it "is true for an absolute conventions_dir outside repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: /var/conventions\n"})
      AgentApropos::Config.outside_repo?(ROOT, fs).should be_true
    end
  end
end
