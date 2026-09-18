require "../spec_helper"

private def convention(path : String, frontmatter : String, body : String = "body\n") : AgentApropos::Convention
  AgentApropos::Convention.parse(path, "---\n#{frontmatter}\n---\n#{body}")
end

describe AgentApropos::Index do
  describe ".build" do
    it "captures classification, triggers, and skill metadata per doc" do
      conventions = [
        convention("docs/conventions/a.md", %(paths: ["app/**"])),
        convention("docs/conventions/b.md", %(contents: ['\\bTODO\\b'])),
        convention("docs/conventions/workflows/c.md", %(skill: true\ndescription: "Use when C")),
      ]
      index = AgentApropos::Index.build(conventions)

      index.schema_version.should eq(AgentApropos::Index::SCHEMA_VERSION)
      index.docs.map(&.path).should eq([
        "docs/conventions/a.md",
        "docs/conventions/b.md",
        "docs/conventions/workflows/c.md",
      ])

      index.docs[0].paths.should eq(["app/**"])
      index.docs[1].contents.should eq(["\\bTODO\\b"])

      skill = index.docs[2]
      skill.skill?.should be_true
      skill.description.should eq("Use when C")
      skill.hash.should eq(conventions[2].hash)
    end
  end

  describe "serialization" do
    it "round-trips through the deterministic document form" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      document = AgentApropos::Index.build(conventions).to_document

      document.ends_with?("\n").should be_true
      document.should contain("\"schema_version\": 3")

      loaded = AgentApropos::Index.load(document)
      loaded.should_not be_nil
      loaded.as(AgentApropos::Index).docs.first.path.should eq("docs/conventions/a.md")
    end

    it "is byte-stable across builds" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      AgentApropos::Index.build(conventions).to_document
        .should eq(AgentApropos::Index.build(conventions).to_document)
    end
  end

  describe ".load" do
    it "returns nil for malformed JSON" do
      AgentApropos::Index.load("{not json").should be_nil
    end

    it "returns nil on a schema-version mismatch (forces rebuild)" do
      stale = %({"schema_version": 999, "docs": []})
      AgentApropos::Index.load(stale).should be_nil
    end

    it "returns nil for a schema 1 cache, so pre-merge layer entries self-invalidate" do
      stale = %({"schema_version": 1, "docs": []})
      AgentApropos::Index.load(stale).should be_nil
    end

    it "returns nil for a schema 2 cache written before the removal event, forcing a rebuild" do
      stale = %({"schema_version": 2, "docs": []})
      AgentApropos::Index.load(stale).should be_nil
    end
  end

  describe "Entry#triggers" do
    it "resolves a path-only entry from the path alone" do
      entry = AgentApropos::Index.build([convention("a.md", %(paths: ["app/**"]))]).docs.first
      entry.triggers("app/m.cr", nil).should eq(["app/**"])
      entry.triggers("src/m.cr", nil).should be_nil
    end

    it "ANDs path and content when the entry declares both" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(paths: ["app/**"]\ncontents: ['\\bx\\b'])),
      ]).docs.first
      entry.triggers("app/m.cr", "x").should eq(["app/**", "\\bx\\b"])
      entry.triggers("app/m.cr", "y").should be_nil
    end

    it "is nil for an entry with no triggers" do
      entry = AgentApropos::Index.build([
        convention("workflows/c.md", %(skill: true\ndescription: "Use when C")),
      ]).docs.first
      entry.triggers("any.cr", "any").should be_nil
    end

    it "an entry's events round-trip through the index document" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [write, removed]\npaths: ["app/**"])),
      ]).docs.first
      reloaded = AgentApropos::Index.load(AgentApropos::Index.new([entry]).to_document)
        .as(AgentApropos::Index).docs.first
      reloaded.events.should eq(Set{AgentApropos::Frontmatter::Event::Write, AgentApropos::Frontmatter::Event::Removed})
    end

    it "covers AE6: a doc with no on: key does not trigger for a removal" do
      entry = AgentApropos::Index.build([convention("a.md", %(paths: ["app/**"]))]).docs.first
      entry.triggers("app/m.cr", nil, AgentApropos::Frontmatter::Event::Removed).should be_nil
    end

    it "a write-only entry does not trigger for a removal" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [write]\npaths: ["app/**"])),
      ]).docs.first
      entry.triggers("app/m.cr", nil, AgentApropos::Frontmatter::Event::Removed).should be_nil
    end

    it "a removal-only entry does not trigger for a write" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [removed]\npaths: ["app/**"])),
      ]).docs.first
      entry.triggers("app/m.cr", nil).should be_nil
    end

    it "a both-events entry triggers for each event" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [write, removed]\npaths: ["app/**"])),
      ]).docs.first
      entry.triggers("app/m.cr", nil).should eq(["app/**"])
      entry.triggers("app/m.cr", nil, AgentApropos::Frontmatter::Event::Removed).should eq(["app/**"])
    end

    it "ANDs path and content on a removal when content is supplied" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [removed]\npaths: ["app/**"]\ncontents: ['\\bx\\b'])),
      ]).docs.first
      entry.triggers("app/m.cr", "x", AgentApropos::Frontmatter::Event::Removed)
        .should eq(["app/**", "\\bx\\b"])
      entry.triggers("app/m.cr", "y", AgentApropos::Frontmatter::Event::Removed).should be_nil
    end

    it "a removal-only entry with a matching path and no content returns its path hits" do
      entry = AgentApropos::Index.build([
        convention("a.md", %(on: [removed]\npaths: ["app/**"])),
      ]).docs.first
      entry.triggers("app/m.cr", nil, AgentApropos::Frontmatter::Event::Removed).should eq(["app/**"])
    end
  end

  describe "#covers?" do
    it "is true when every doc path and hash is unchanged" do
      conventions = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      AgentApropos::Index.build(conventions).covers?(conventions).should be_true
    end

    it "is false when a doc's content hash changed" do
      original = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      edited = [convention("docs/conventions/a.md", %(paths: ["lib/**"]))]
      AgentApropos::Index.build(original).covers?(edited).should be_false
    end

    it "is false when a doc was added or removed" do
      one = [convention("docs/conventions/a.md", %(paths: ["src/**"]))]
      two = one + [convention("docs/conventions/b.md", %(paths: ["lib/**"]))]
      AgentApropos::Index.build(one).covers?(two).should be_false
    end
  end
end
