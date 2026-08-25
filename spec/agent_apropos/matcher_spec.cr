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

    # The verdict must not depend on where matching stopped. "![" used to pass
    # because `!` is a literal that mismatched the substituted sample on the
    # first character, so the parser returned before it ever reached the `[`.
    it "gives the same verdict to an unterminated bracket whatever precedes it" do
      AgentApropos::Matcher.valid_glob?("![").should eq(AgentApropos::Matcher.valid_glob?("[abc"))
      AgentApropos::Matcher.valid_glob?("![").should be_false
    end

    it "is false for an unterminated bracket behind any leading literal" do
      ["!", "^", "-", ",", "}"].each do |lead|
        AgentApropos::Matcher.valid_glob?("#{lead}[").should be_false
      end
    end

    it "is false for a character set that only looks closed" do
      AgentApropos::Matcher.valid_glob?("[]").should be_false
      AgentApropos::Matcher.valid_glob?("[[").should be_false
      AgentApropos::Matcher.valid_glob?("[a\\]").should be_false
    end

    # "[]" is not an empty set: the matcher reads that first "]" as the set's
    # first member, so the set never closes. Behind a literal that stops the
    # match walk, nothing else is left to notice.
    it "is false for [] however early the match walk stops" do
      AgentApropos::Matcher.valid_glob?("\\a[]").should be_false
      AgentApropos::Matcher.valid_glob?("{[]").should be_false
      AgentApropos::Matcher.valid_glob?("[]]]").should be_true
    end

    it "is false for a trailing backslash with nothing to escape" do
      AgentApropos::Matcher.valid_glob?("a\\").should be_false
      AgentApropos::Matcher.valid_glob?("\\").should be_false
    end

    # Well-formedness is the only question this answers. The matcher accepts an
    # empty pattern (it simply matches nothing), and lint already reports an
    # empty `paths:` entry through its "matches no tracked file" check, with a
    # message that says what is actually wrong.
    it "calls the empty pattern well-formed, leaving lint to reject it as useless" do
      AgentApropos::Matcher.valid_glob?("").should be_true
      AgentApropos::Matcher.path_match?("", "anything").should be_false
    end

    it "keeps a negated character class valid" do
      AgentApropos::Matcher.valid_glob?("[!a]").should be_true
      AgentApropos::Matcher.valid_glob?("[^a-z]").should be_true
    end

    it "keeps the globs this repo's own conventions declare valid" do
      ["src/**", "**/*.cr", "docs/**/*.md", "[a-z]*.cr", "spec/**", "app/jobs/**",
       "{a,b}", "a{b,c}d", "\\[literal]", "[]]", "[a\\]b]", "[-a]", "[a-]"].each do |pattern|
        AgentApropos::Matcher.valid_glob?(pattern).should be_true
      end
    end

    it "is false once brace nesting passes the depth the matcher supports" do
      AgentApropos::Matcher.valid_glob?("{" * 10 + "a" + "}" * 10).should be_true
      AgentApropos::Matcher.valid_glob?("{" * 11 + "a" + "}" * 11).should be_false
    end

    # The verdict is a claim about the pattern, so it must not turn on where
    # some path happened to stop matching it. Two properties over a
    # brute-forced pattern space say that: a pattern the matcher can be shown
    # to reject is always invalid, and a leading run of literals never changes
    # the answer — which is exactly what "![" got wrong.
    describe "over a brute-forced pattern space" do
      alphabet = ["a", "*", "?", "[", "]", "!", "^", "-", "\\", "{", "}", ",", "/"]
      # Three characters, not four. This spec is matcher.cr's sibling, so the
      # mutation gate re-runs it once per surviving mutant — a second of extra
      # work here is paid hundreds of times there. The one four-character shape
      # this space would have caught has its own named example above.
      patterns = alphabet.dup
      2.times do
        patterns += patterns.flat_map { |prefix| alphabet.map { |letter| "#{prefix}#{letter}" } }
      end
      patterns.uniq!

      path_alphabet = ["a", "z", "[", "]", "!", "^", "-", "{", "}", ",", "/", "."]
      paths = path_alphabet + path_alphabet.flat_map { |head| path_alphabet.map { |tail| "#{head}#{tail}" } }

      it "rejects every pattern File.match? can be shown to reject" do
        rejected = 0

        patterns.each do |pattern|
          raised = paths.any? do |path|
            begin
              File.match?(pattern, path)
              false
            rescue File::BadPatternError
              true
            end
          end
          next unless raised

          rejected += 1
          AgentApropos::Matcher.valid_glob?(pattern)
            .should be_false, "valid_glob?(#{pattern.inspect}) accepted a pattern File.match? rejects"
        end

        rejected.should be > 100
      end

      it "gives the same verdict however many literals lead the pattern" do
        patterns.each do |pattern|
          verdict = AgentApropos::Matcher.valid_glob?(pattern)

          ["a", "z", "!", "^", "-", ",", "}", "/", "."].each do |lead|
            AgentApropos::Matcher.valid_glob?("#{lead}#{pattern}")
              .should eq(verdict), "a leading #{lead.inspect} changed the verdict for #{pattern.inspect}"
          end
        end
      end
    end
  end
end
