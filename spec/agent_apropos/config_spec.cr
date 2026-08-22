require "../spec_helper"

private ROOT = Path["/repo"]

# Single-quoted in YAML because a double-quoted scalar would treat a Windows
# backslash as an escape.
private OUTSIDE_DIR = SpecPaths.absolute("var", "conventions")

private def outside_yaml : String
  "conventions_dir: '#{OUTSIDE_DIR}'\n"
end

# Compared in POSIX form: `Path#join` inserts the host's own separator, so
# `Path` equality against a `/`-written literal is a statement about the host
# rather than about Config.
private def conventions_dir(fs : AgentApropos::Filesystem, allow_outside : Bool = false) : String
  AgentApropos::Config.conventions_dir(ROOT, fs, allow_outside).to_posix.to_s
end

describe AgentApropos::Config do
  describe ".conventions_dir" do
    it "defaults to docs/conventions when agent-apropos.yml is absent" do
      conventions_dir(InMemoryFS.new).should eq("/repo/docs/conventions")
    end

    it "resolves a relative conventions_dir against repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: shared-conventions\n"})
      conventions_dir(fs).should eq("/repo/shared-conventions")
    end

    it "uses an absolute conventions_dir verbatim" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => outside_yaml})
      AgentApropos::Config.conventions_dir(ROOT, fs, allow_outside: true).to_posix.to_s.should eq(OUTSIDE_DIR)
    end

    it "raises Config::Error when a relative conventions_dir escapes repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      expect_raises(AgentApropos::Config::Error, /resolves outside the repo root/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "raises Config::Error when an absolute conventions_dir is outside repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => outside_yaml})
      expect_raises(AgentApropos::Config::Error, /resolves outside the repo root/) do
        AgentApropos::Config.conventions_dir(ROOT, fs)
      end
    end

    it "allows an escaping conventions_dir when allow_outside is true" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: ../shared-conventions\n"})
      conventions_dir(fs, allow_outside: true).should eq("/repo/../shared-conventions")
    end

    it "does not require allow_outside for a conventions_dir that stays under repo_root" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "conventions_dir: docs/shared\n"})
      conventions_dir(fs).should eq("/repo/docs/shared")
    end

    it "defaults when agent-apropos.yml has no conventions_dir key" do
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => "other_key: whatever\n"})
      conventions_dir(fs).should eq("/repo/docs/conventions")
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
      conventions_dir(fs, allow_outside: true).should eq("/repo/../shared-conventions")
    end

    it "prefers agent-apropos.yml over .cache/agent-apropos.yml when both are present" do
      fs = InMemoryFS.new({
        "/repo/agent-apropos.yml"        => "conventions_dir: ../root-conventions\n",
        "/repo/.cache/agent-apropos.yml" => "conventions_dir: ../fallback-conventions\n",
      })
      conventions_dir(fs, allow_outside: true).should eq("/repo/../root-conventions")
    end

    it "raises Config::Error on malformed YAML in the .cache/agent-apropos.yml fallback" do
      fs = InMemoryFS.new({"/repo/.cache/agent-apropos.yml" => "key: [unterminated\n"})
      expect_raises(AgentApropos::Config::Error, /not valid YAML/) do
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
      fs = InMemoryFS.new({"/repo/agent-apropos.yml" => outside_yaml})
      AgentApropos::Config.outside_repo?(ROOT, fs).should be_true
    end
  end
end
