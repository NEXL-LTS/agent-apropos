module AgentApropos
  module Rendering
    extend self

    CHAR_CAP = 10_000

    SEPARATOR = "\n\n---\n\n"

    def context(docs : Array({String, String})) : String
      full = docs.map { |(path, body)| "Convention (#{path}):\n\n#{body}" }.join(SEPARATOR)
      full.size <= CHAR_CAP ? full : summarized(docs)
    end

    private def summarized(docs : Array({String, String})) : String
      header = "Several conventions matched but were summarized to fit the context budget; " \
               "read the cited files for the full text.\n\n"
      blocks = docs.map do |(path, body)|
        "Convention (#{path}): #{first_paragraph(body)}\n(Read the full rule in #{path}.)"
      end
      header + blocks.join(SEPARATOR)
    end

    private def first_paragraph(body : String) : String
      body.split("\n\n", 2).first.strip
    end
  end
end
