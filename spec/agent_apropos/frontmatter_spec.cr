require "../spec_helper"

# Split and cast in one step; `.as` fails the example clearly if the block is
# unexpectedly absent (ameba forbids `not_nil!`).
private def split_doc(text : String) : {AgentApropos::Frontmatter, String}
  frontmatter, body = AgentApropos::Frontmatter.split(text)
  {frontmatter.as(AgentApropos::Frontmatter), body}
end

describe AgentApropos::Frontmatter do
  describe ".split" do
    it "returns no frontmatter for a doc without a leading fence" do
      fm, body = AgentApropos::Frontmatter.split("# Title\n\nprose\n")
      fm.should be_nil
      body.should eq("# Title\n\nprose\n")
    end

    it "separates the frontmatter block from the body, preserving body bytes" do
      fm, body = split_doc("---\npaths: [\"src/**\"]\n---\n# Rule\n\nbody\n")
      fm.paths.should eq(["src/**"])
      body.should eq("# Rule\n\nbody\n")
    end

    it "handles an empty frontmatter block as reference-only" do
      fm, body = split_doc("---\n---\nbody\n")
      fm.reference_only?.should be_true
      body.should eq("body\n")
    end

    it "handles a closing fence at end-of-file with no trailing body" do
      fm, body = split_doc("---\nskill: true\n---")
      fm.skill?.should be_true
      body.should eq("")
    end

    it "tolerates CRLF line endings and trailing spaces on the fence" do
      fm, body = split_doc("--- \r\npaths: [\"a/**\"]\r\n--- \r\nbody\r\n")
      fm.paths.should eq(["a/**"])
      body.should eq("body\r\n")
    end

    it "raises on an unterminated frontmatter block" do
      expect_raises(AgentApropos::Frontmatter::Error, /unterminated/) do
        AgentApropos::Frontmatter.split("---\npaths: [\"a\"]\nno closing fence\n")
      end
    end

    it "requires exactly three dashes to open a fence, not merely a line of dashes" do
      fm, body = AgentApropos::Frontmatter.split("----\npaths: [\"a\"]\n---\nbody\n")
      fm.should be_nil
      body.should eq("----\npaths: [\"a\"]\n---\nbody\n")
    end

    it "requires exactly three dashes to close a fence, not a longer dash line partway through" do
      expect_raises(AgentApropos::Frontmatter::Error, /invalid YAML/) do
        AgentApropos::Frontmatter.split("---\npaths: [\"a\"]\n----\nmore: 1\n---\nbody\n")
      end
    end
  end

  describe ".parse" do
    it "returns an empty frontmatter for blank or comment-only YAML" do
      AgentApropos::Frontmatter.parse("").reference_only?.should be_true
      AgentApropos::Frontmatter.parse("# just a comment\n").reference_only?.should be_true
    end

    it "reads all known keys" do
      fm = AgentApropos::Frontmatter.parse(<<-YAML)
        paths: ["app/jobs/**", "lib/**"]
        contents: ['\\.transaction\\b']
        skill: true
        description: "Use when doing X"
        YAML
      fm.paths.should eq(["app/jobs/**", "lib/**"])
      fm.contents.should eq(["\\.transaction\\b"])
      fm.skill?.should be_true
      fm.description.should eq("Use when doing X")
      fm.unknown_keys.should be_empty
    end

    it "collects unknown keys, sorted, for the linter" do
      fm = AgentApropos::Frontmatter.parse("zebra: 1\napple: 2\npaths: [\"a\"]\n")
      fm.unknown_keys.should eq(["apple", "zebra"])
    end

    it "does not report `lint` as an unknown key" do
      fm = AgentApropos::Frontmatter.parse("lint: ignore\npaths: [\"a\"]\n")
      fm.unknown_keys.should be_empty
    end

    it "treats explicitly-null values as absent" do
      fm = AgentApropos::Frontmatter.parse("paths:\ncontents:\nskill:\ndescription:\n")
      fm.paths.should be_empty
      fm.contents.should be_empty
      fm.skill?.should be_false
      fm.description.should be_nil
    end

    it "raises on invalid YAML" do
      expect_raises(AgentApropos::Frontmatter::Error, /invalid YAML/) do
        AgentApropos::Frontmatter.parse("paths: [unterminated\n")
      end
    end

    it "raises when the top level is not a mapping" do
      expect_raises(AgentApropos::Frontmatter::Error, /must be a mapping/) do
        AgentApropos::Frontmatter.parse("just a scalar")
      end
    end

    it "raises when paths is not a list" do
      expect_raises(AgentApropos::Frontmatter::Error, /`paths` must be a list/) do
        AgentApropos::Frontmatter.parse("paths: nope\n")
      end
    end

    it "raises when a paths entry is not a string" do
      expect_raises(AgentApropos::Frontmatter::Error, /`paths` entries must be strings/) do
        AgentApropos::Frontmatter.parse("paths: [1, 2]\n")
      end
    end

    it "raises when contents is not a list" do
      expect_raises(AgentApropos::Frontmatter::Error, /`contents` must be a list/) do
        AgentApropos::Frontmatter.parse("contents: nope\n")
      end
    end

    it "raises when skill is not a boolean" do
      expect_raises(AgentApropos::Frontmatter::Error, /`skill` must be a boolean/) do
        AgentApropos::Frontmatter.parse("skill: yesterday\n")
      end
    end

    it "raises when description is not a string" do
      expect_raises(AgentApropos::Frontmatter::Error, /`description` must be a string/) do
        AgentApropos::Frontmatter.parse("description: [1]\n")
      end
    end

    it "defaults `on` to write-only when the key is absent" do
      fm = AgentApropos::Frontmatter.parse("paths: [\"a\"]\n")
      fm.events.should eq(Set{AgentApropos::Frontmatter::Event::Write})
    end

    it "parses `on: [removed]` as removal-only" do
      fm = AgentApropos::Frontmatter.parse("on: [removed]\n")
      fm.events.should eq(Set{AgentApropos::Frontmatter::Event::Removed})
    end

    it "parses `on: [write, removed]` as both events" do
      fm = AgentApropos::Frontmatter.parse("on: [write, removed]\n")
      fm.events.should eq(Set{AgentApropos::Frontmatter::Event::Write, AgentApropos::Frontmatter::Event::Removed})
    end

    it "does not duplicate a repeated event" do
      fm = AgentApropos::Frontmatter.parse("on: [removed, removed]\n")
      fm.events.should eq(Set{AgentApropos::Frontmatter::Event::Removed})
    end

    it "parses `on: []` as no events" do
      fm = AgentApropos::Frontmatter.parse("on: []\n")
      fm.events.should be_empty
    end

    it "raises when `on` is not a list" do
      expect_raises(AgentApropos::Frontmatter::Error, /`on` must be a list/) do
        AgentApropos::Frontmatter.parse("on: removed\n")
      end
    end

    it "raises when an `on` entry is not a string" do
      expect_raises(AgentApropos::Frontmatter::Error, /`on` entries must be strings/) do
        AgentApropos::Frontmatter.parse("on: [1]\n")
      end
    end

    it "raises naming the value when `on` holds an unrecognized event" do
      expect_raises(AgentApropos::Frontmatter::Error, /`on`.*delete/) do
        AgentApropos::Frontmatter.parse("on: [delete]\n")
      end
    end

    it "recognizes a quoted \"on\" key the same as the bare, YAML-boolean-coerced key" do
      fm = AgentApropos::Frontmatter.parse(%("on": [removed]\n))
      fm.events.should eq(Set{AgentApropos::Frontmatter::Event::Removed})
    end

    it "does not report a quoted \"on\" key as unknown" do
      fm = AgentApropos::Frontmatter.parse(%("on": [removed]\n))
      fm.unknown_keys.should be_empty
    end

    it "does not affect skill? or reference_only? on its own" do
      fm = AgentApropos::Frontmatter.parse("on: [removed]\n")
      fm.skill?.should be_false
      fm.reference_only?.should be_true
    end

    it "does not affect reference_only? alongside paths" do
      fm = AgentApropos::Frontmatter.parse("on: [removed]\npaths: [\"a/**\"]\n")
      fm.reference_only?.should be_false
    end
  end

  describe "#scoped?" do
    it "is true when a path or content trigger is declared" do
      AgentApropos::Frontmatter.new(paths: ["a/**"]).scoped?.should be_true
      AgentApropos::Frontmatter.new(contents: ["x"]).scoped?.should be_true
    end

    it "is false for a skill-only or empty frontmatter" do
      AgentApropos::Frontmatter.new(skill: true).scoped?.should be_false
      AgentApropos::Frontmatter.new.scoped?.should be_false
    end
  end

  describe "#reference_only?" do
    it "is true only when there is no trigger and no skill" do
      AgentApropos::Frontmatter.new.reference_only?.should be_true
    end

    it "is false when any path, content, or skill flag is present" do
      AgentApropos::Frontmatter.new(paths: ["a/**"]).reference_only?.should be_false
      AgentApropos::Frontmatter.new(contents: ["x"]).reference_only?.should be_false
      AgentApropos::Frontmatter.new(skill: true).reference_only?.should be_false
    end
  end
end
