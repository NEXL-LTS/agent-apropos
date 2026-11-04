---
skill: true
description: "Use when the user asks for a rich explanation of a code change, diff, branch, or PR. Produces HTML output."
---

# Explain a diff as an HTML page

Write an interactive explanation of the code change as one HTML page with four
sections.

1. **Background.** Explore the surrounding code, then explain the existing
   system. Start with a beginner-level overview, marked as skippable, then
   narrow to the parts the change touches.
2. **Intuition.** Explain the core idea of the change, not every detail. Use
   concrete examples with toy data, and use diagrams freely.
3. **Code.** Walk through the changes at a high level, grouped and ordered so
   they are easy to follow.
4. **Quiz.** Write five multiple-choice questions of medium difficulty. A
   reader should need to understand the change to answer them, but avoid trick
   questions. When the reader clicks an answer, show whether it is right and
   explain why.

## Format

- Produce one self-contained HTML file with inline CSS and JavaScript. Use a
  single long page with section headers and a table of contents, not tabs.
  Make it readable on a phone.
- Save it outside the repo, and start the filename with today's date so the
  files sort by time, for example `/tmp/2026-01-12-explanation-<slug>.html`.
- Write in classic style, with the clarity of Martin Kleppmann. Each section
  should lead into the next.
- Pick a few diagram types and reuse them throughout. Two that work well are a
  simplified mock of the UI, for UI changes, and a system diagram of data flow
  between components with example data on it.
- Build diagrams from HTML elements, never ASCII art. Use HTML lists for lists.
- Put code in `<pre>` tags. A custom-styled `div` needs `white-space: pre-wrap`,
  or the browser collapses its newlines. Before saving, check that every code
  block has `white-space: pre` or `pre-wrap`.
- Use callouts for key concepts, definitions, and important edge cases.
