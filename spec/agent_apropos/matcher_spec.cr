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

  describe ".any_path_match?" do
    it "is true when any pattern matches" do
      AgentApropos::Matcher.any_path_match?(["lib/**", "spec/**"], "spec/a_spec.cr").should be_true
    end

    it "is false when no pattern matches" do
      AgentApropos::Matcher.any_path_match?(["lib/**", "spec/**"], "src/x.cr").should be_false
    end

    it "is false for an empty pattern list" do
      AgentApropos::Matcher.any_path_match?([] of String, "anything.cr").should be_false
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
  end

  describe ".any_content_match?" do
    it "is true when any source matches" do
      AgentApropos::Matcher.any_content_match?(["nope", "wor.d"], "hello world").should be_true
    end

    it "is false for an empty source list" do
      AgentApropos::Matcher.any_content_match?([] of String, "content").should be_false
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

  describe ".valid_glob?" do
    it "is true for a well-formed glob" do
      AgentApropos::Matcher.valid_glob?("src/**/*.cr").should be_true
    end

    it "is false for a malformed glob (unterminated character set)" do
      AgentApropos::Matcher.valid_glob?("src/[").should be_false
    end
  end
end
