require "spec"
require "ameba/spec/support"
require "../../tool/lint/rules/comment_block"

module Ameba::Rule::Apropos
  describe CommentBlock do
    subject = CommentBlock.new

    it "passes for a lone single-line comment" do
      expect_no_issues subject, <<-CRYSTAL
        # a single line
        a = 1
        CRYSTAL
    end

    it "passes for a trailing comment on a code line" do
      expect_no_issues subject, <<-CRYSTAL
        a = 1 # trailing, not a block
        CRYSTAL
    end

    it "fails for two consecutive comment-only lines" do
      expect_issue subject, <<-CRYSTAL
        # block start
        # ^{} error: Multi-line comment block [...]
        # block continues
        a = 1
        CRYSTAL
    end

    it "fails for a longer run of comment-only lines" do
      expect_issue subject, <<-CRYSTAL
        # one
        # ^{} error: Multi-line comment block [...]
        # two
        # three
        # four
        a = 1
        CRYSTAL
    end

    it "does not merge two single-line comments separated by a blank line" do
      expect_no_issues subject, <<-CRYSTAL
        # first

        # second
        a = 1
        CRYSTAL
    end

    it "does not merge two single-line comments separated by code" do
      expect_no_issues subject, <<-CRYSTAL
        # first
        a = 1
        # second
        b = 2
        CRYSTAL
    end

    it "does not flag an ameba:disable directive" do
      expect_no_issues subject, <<-CRYSTAL
        # ameba:disable Lint/UselessAssign
        a = 1
        CRYSTAL
    end

    it "does not flag a stack of disable/enable directives" do
      expect_no_issues subject, <<-CRYSTAL
        # ameba:disable Lint/UselessAssign
        # ameba:disable Lint/UnusedArgument
        a = 1
        # ameba:enable Lint/UselessAssign
        # ameba:enable Lint/UnusedArgument
        CRYSTAL
    end

    it "does not let a directive bridge two comment runs" do
      expect_no_issues subject, <<-CRYSTAL
        # first block
        # ameba:disable Lint/UselessAssign
        a = 1
        # ameba:enable Lint/UselessAssign
        b = 2
        CRYSTAL
    end

    it "starts a new run right after a directive line" do
      expect_issue subject, <<-CRYSTAL
        # ameba:disable Lint/UselessAssign
        # second block
        # ^{} error: Multi-line comment block [...]
        # second block cont
        a = 1
        CRYSTAL
    end
  end
end
