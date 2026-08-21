# Plan: lint dead `paths` globs, with a `lint: ignore` escape

## Problem

`lint` validates that a `paths` glob is well-formed (`Matcher.valid_glob?`,
error-level) but never that it *hits* anything. A doc scoped to a renamed or
deleted directory stays in the repo silently, never fires, and nothing flags it.

## Decisions

- **Severity: error.** A dead glob means the doc is inert; CI's existing
  `./bin/agent-apropos lint` step (`.github/workflows/ci.yml:86`) already fails
  on errors, so no `--strict` change is needed.
- **Applies in shared-conventions mode too.** No exemption when
  `conventions_dir` resolves outside the repo — `Config.outside_repo?` is not
  consulted.
- **`lint: ignore` is the only escape, and it suppresses everything about that
  doc** — including `skill: true` without a `description` and an invalid glob.
  The single principle: *suppression requires reading the frontmatter, so
  anything that stops the frontmatter from parsing cannot be suppressed.* That
  is bad YAML, an unterminated `---` fence, and wrong-typed keys
  (`paths: "src/**"`, `skill: "yes"`) — all raise `Frontmatter::Error` out of
  `Frontmatter.split` before any `lint:` key is visible.
- Only the exact value `ignore` suppresses. An unrecognized value
  (`lint: strict`) is itself an error finding.

## File list source

Match with `Matcher.path_match?` — the same function the pre/post hooks use —
over a list from `git ls-files`, so lint can never disagree with the hook about
what a glob matches.

Rejected: `fs.glob` per pattern. `Dir.glob` skips dotfiles unless the pattern
component starts with `.`, so `paths: ["**/*.yml"]` covering `.github/` would be
reported dead when the hook *would* fire on it. False positives are how a new
check gets ignored.

## Changes

**`src/agent_apropos/git.cr`** — add `abstract def ls_files(repo_root : Path) :
Array(String)?`. `Real` runs `capture?(repo_root, ["ls-files", "-z"])` and splits
on NUL (NUL-safe against quoted/unicode paths, unlike default `ls-files`
output), returning `nil` when git or the repo isn't there. `nil` means skip the
check entirely — a non-git checkout must not hard-fail lint.

**`src/agent_apropos/frontmatter.cr`** — `"lint"` joins `KNOWN_KEYS`; parse as a
string; expose `lint_ignore?`. An unrecognized value becomes a lint *finding*,
not a `Frontmatter::Error` — raising there kills `Frontmatter.split`, and since
hooks fail open, a typo would silently stop the doc from ever injecting.

**`src/agent_apropos/conventions.cr`** — `Convention#lint_ignore?` delegating to
the frontmatter, alongside `skill?`.

**`src/agent_apropos/lint.cr`** — `run`/`collect` take a `git : Git`. Parse
findings always report; then `linted = conventions.reject(&.lint_ignore?)` feeds
both `doc_findings` and `wrapper_findings`. `doc_findings` gains a per-glob
error, skipping globs that already failed `valid_glob?` so nothing is reported
twice, and early-exiting per glob with `any?`:

    error  docs/conventions/x.md: path glob matches no tracked file: "src/**/*.rb"

**`src/agent_apropos/cli.cr`** — pass `Git::Real.new` in `handle_lint`.

## Traps

- **Orphan false positive.** Dropping an ignored doc from the expected-wrapper
  set makes its existing `SKILL.md` appear in `existing_slugs - expected.keys`
  as `orphaned generated wrapper` (`lint.cr:120`) — a new error *caused* by the
  escape hatch. Ignored docs' slugs must be subtracted from the orphan diff too,
  not just from `expected`.
- **Findings with no doc to carry the key still report.** The root-file budget
  checks `AGENTS.md`/`CLAUDE.md`, which have no frontmatter, so `lint: ignore`
  cannot reach them.
- **`lint: ignore` does not quiet `generate`.** `generate.cr:52` hands the
  *unfiltered* convention list to `Skills.wrappers`, which raises at
  `skills.cr:44` for `skill: true` without a `description`. Lint filters those
  out before that call (`lint.cr:112`), so with `lint: ignore` lint says clean
  while `agent-apropos generate` hard-fails. Not a hole — CI's `generate
  --check` step runs immediately before `lint` — but the error surfaces from a
  different command than the one that was silenced. Leave `generate` alone
  rather than teach it a lint key.

## Specs

`spec/agent_apropos/lint_spec.cr` needs a `Git` double; `FakeGit`
(`spec/agent_apropos/review_spec.cr:25`) gains `ls_files` and is probably worth
lifting into `spec/support/`. Cases:

- dead glob → error; live glob → clean
- `lint: ignore` suppresses the dead-glob error
- `lint: ignore` also suppresses `skill: true` without `description`, and an
  invalid glob
- `lint: ignore` does **not** suppress bad YAML / an unterminated fence / a
  wrong-typed key
- `lint: ignore` on a skill doc does not make its wrapper look orphaned
- unrecognized `lint:` value → error, and does not suppress
- `ls_files` returning `nil` → check skipped, no findings
- invalid glob reported once, not twice

## Docs

- `docs/conventions/README.md` — the frontmatter block and the
  combination-semantics list.
- `README.md:259` — the `lint` row.

## Expected fallout on first run

A doc written ahead of the code it governs now hard-fails until someone adds
`lint: ignore` and remembers to remove it. And because the check uses the hook's
own matcher, it will flag globs that look right to a human but that
`File.match?` does not actually hit; those are true positives (the doc never
fired) and will read as false alarms until someone traces one.
