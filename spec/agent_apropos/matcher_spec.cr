require "../spec_helper"

describe AgentApropos::Matcher do
  describe ".path_match?" do
    it "matches a ** glob across any directory depth" do
      AgentApropos::Matcher.path_match?("app/jobs/**", "app/jobs/mailer.cr").should be_true
      AgentApropos::Matcher.path_match?("app/jobs/**", "app/jobs/sub/deep.cr").should be_true
    end

    it "does not match a path outside the glob" do
      AgentApropos::Matcher.path_match?("app/jobs/**", "app/models/user.cr").should be_false
    end

    it "honours a single * as a single segment" do
      AgentApropos::Matcher.path_match?("src/*.cr", "src/cli.cr").should be_true
      AgentApropos::Matcher.path_match?("src/*.cr", "src/apropos/cli.cr").should be_false
    end
  end

  describe ".matching_paths" do
    it "returns only the patterns that match" do
      AgentApropos::Matcher.matching_paths(["lib/**", "spec/**", "app/**"], "spec/a_spec.cr")
        .should eq(["spec/**"])
    end

    it "is empty when no pattern matches" do
      AgentApropos::Matcher.matching_paths(["lib/**", "spec/**"], "src/x.cr").should be_empty
    end
  end

  describe ".content_match?" do
    it "matches content against a PCRE2 regex source" do
      AgentApropos::Matcher.content_match?("\\btransaction\\b", "db.transaction do").should be_true
    end

    it "does not match when the pattern is absent" do
      AgentApropos::Matcher.content_match?("\\btransaction\\b", "plain text").should be_false
    end

    it "raises an AgentApropos error on an invalid regex source" do
      expect_raises(AgentApropos::Matcher::Error, /invalid regex/) do
        AgentApropos::Matcher.content_match?("(", "anything")
      end
    end

    it "raises an AgentApropos error, not a raw Regex::Error, when PCRE2's match limit is exhausted" do
      catastrophic = "(a+)+$"
      # 100 repetitions of the ambiguous group pushes backtracking state count
      # (~2^n) many orders of magnitude past PCRE2's match limit regardless of
      # build/version, while match time stays flat (PCRE2 aborts once the
      # step count — not the input size — hits the limit, so this isn't slow).
      content = "a" * 100 + "!"
      expect_raises(AgentApropos::Matcher::Error, /failed to match/) do
        AgentApropos::Matcher.content_match?(catastrophic, content)
      end
    end
  end

  describe ".matching_contents" do
    it "returns only the sources that match" do
      AgentApropos::Matcher.matching_contents(["nope", "wor.d"], "hello world").should eq(["wor.d"])
    end

    it "is empty when no source matches" do
      AgentApropos::Matcher.matching_contents(["nope", "zilch"], "hello world").should be_empty
    end
  end

  describe ".triggers" do
    it "is nil when neither paths nor contents are declared" do
      AgentApropos::Matcher.triggers([] of String, [] of String, "src/x.cr", "body").should be_nil
    end

    it "returns the matched globs for a paths-only rule, ignoring content" do
      AgentApropos::Matcher.triggers(["src/**"], [] of String, "src/x.cr", nil).should eq(["src/**"])
    end

    it "returns the matched sources for a contents-only rule, ignoring path" do
      AgentApropos::Matcher.triggers([] of String, ["wor.d"], "any.cr", "hello world").should eq(["wor.d"])
    end

    it "is nil when a contents rule has no content to match against" do
      AgentApropos::Matcher.triggers([] of String, ["wor.d"], "any.cr", nil).should be_nil
    end

    it "ANDs paths and contents, returning both sides' hits" do
      AgentApropos::Matcher.triggers(["src/**"], ["wor.d"], "src/x.cr", "hello world")
        .should eq(["src/**", "wor.d"])
      AgentApropos::Matcher.triggers(["src/**"], ["wor.d"], "lib/x.cr", "hello world").should be_nil
      AgentApropos::Matcher.triggers(["src/**"], ["wor.d"], "src/x.cr", "nothing").should be_nil
    end
  end

  describe ".valid_glob?" do
    it "is true for a well-formed glob" do
      AgentApropos::Matcher.valid_glob?("src/**/*.cr").should be_true
    end

    it "is false for a malformed glob (unterminated character set)" do
      AgentApropos::Matcher.valid_glob?("src/[").should be_false
    end
  end
end
