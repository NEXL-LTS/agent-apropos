require "../spec_helper"

# A body long enough that a single document overruns the character cap on its
# own, so the summarizing branch is reached without relying on how many
# documents a caller happens to pass.
private def oversized_body : String
  "intro paragraph\n\nfiller " + ("x" * AgentApropos::Rendering::CHAR_CAP)
end

describe AgentApropos::Rendering do
  describe ".context" do
    it "is empty for no documents" do
      AgentApropos::Rendering.context([] of {String, String}).should eq("")
    end

    it "labels a document with its path and keeps the body verbatim" do
      AgentApropos::Rendering.context([{"docs/conventions/specs.md", "Write the spec first."}])
        .should eq("Convention (docs/conventions/specs.md):\n\nWrite the spec first.")
    end

    it "joins several documents with the separator, labelling each with its path" do
      rendered = AgentApropos::Rendering.context([
        {"docs/conventions/a.md", "First rule."},
        {"docs/conventions/b.md", "Second rule."},
      ])

      rendered.should eq(
        "Convention (docs/conventions/a.md):\n\nFirst rule." +
        AgentApropos::Rendering::SEPARATOR +
        "Convention (docs/conventions/b.md):\n\nSecond rule."
      )
    end

    it "renders in full at exactly the character cap" do
      # Pad the body so the rendered document lands on the cap itself, which is
      # the last size the full branch is required to handle.
      prefix = "Convention (a.md):\n\n"
      body = "y" * (AgentApropos::Rendering::CHAR_CAP - prefix.size)

      rendered = AgentApropos::Rendering.context([{"a.md", body}])

      rendered.size.should eq(AgentApropos::Rendering::CHAR_CAP)
      rendered.should eq(prefix + body)
    end

    it "summarizes to the first paragraph and cites the path once past the cap" do
      rendered = AgentApropos::Rendering.context([{"docs/conventions/big.md", oversized_body}])

      rendered.should start_with("Several conventions matched but were summarized")
      rendered.should contain("Convention (docs/conventions/big.md): intro paragraph")
      rendered.should contain("(Read the full rule in docs/conventions/big.md.)")
      rendered.should_not contain("xxxx")
    end

    it "summarizes every document, still separated, once past the cap" do
      rendered = AgentApropos::Rendering.context([
        {"a.md", oversized_body},
        {"b.md", "only paragraph"},
      ])

      rendered.should contain("Convention (a.md): intro paragraph")
      rendered.should contain("Convention (b.md): only paragraph")
      rendered.should contain(AgentApropos::Rendering::SEPARATOR)
    end

    it "strips surrounding whitespace from a summarized first paragraph" do
      rendered = AgentApropos::Rendering.context([{"a.md", "  spaced heading  \n\n" + oversized_body}])

      rendered.should contain("Convention (a.md): spaced heading\n")
    end

    it "summarizes a body with no paragraph break to the whole body" do
      body = "single line " + ("z" * AgentApropos::Rendering::CHAR_CAP)

      rendered = AgentApropos::Rendering.context([{"a.md", body}])

      rendered.should contain("Convention (a.md): #{body}")
    end
  end
end
