# agent-apropos

agent-apropos is a single deterministic binary that delivers the right documentation to
the right moment. It implements a layered documentation structure (defined in
`docs/conventions/README.md`): it compiles convention-doc frontmatter into a
trigger index, generates skill wrappers, serves as a Claude Code hook handler
that injects path- and construct-scoped rules at edit time, and resolves the
conventions that apply to a diff for review. Written in Crystal; ships as a
static Linux/macOS binary. See `README.md` for the user-facing overview.

## Commands

Use `make` — it points `CRYSTAL_CACHE_DIR` at a project-local dir so targets work
even where the global Crystal cache is not writable.

- `make deps` — install shard dependencies
- `make build` — build the `agent-apropos` binary (debug); `make release` for the static-oriented release build
- `make spec` — run the spec suite
- `make lint` — run ameba (zero findings required)
- `make check` — lint + spec (the fast local gate)
- `make coverage` — run specs under kcov and enforce the 100% line-coverage gate
- `make mutate SUBJECT=src/agent_apropos/<module>.cr` — advisory mutation testing (see `docs/mutation-testing.md`)
- `make e2e` (or `bash e2e/run.sh`) — the **live** end-to-end suite: this is what "e2e tests" means
  in this repo. A bats suite (`e2e/tests/`) that runs real, authenticated CLI agents (Claude Code,
  OpenCode, and GitHub Copilot CLI by default; Gemini is opt-in via `E2E_GEMINI=1`) against a sample
  repo (`e2e/project/`) and asserts the model's own output is actually steered by a wired convention.
  Local/opt-in only — not part of `make check` or CI, since it needs live credentials. Read
  `e2e/README.md` before touching it. Don't confuse it with `spec/integration/` (deterministic,
  subprocess-level, runs in `make spec`).

## Universal rules

- Development is spec-first: write the failing spec, then the implementation. Every milestone ends green — specs pass, coverage 100%, ameba clean.
- Hook code paths must **fail open**: on any internal error, exit 0 and emit nothing. A conventions tool must never block or break an edit. Never let an exception escape a `hook` subcommand.
- Isolate all filesystem, stdin, and process I/O behind small injectable adapters so error paths are unit-testable. Do not call `STDIN`/`STDOUT`/`File` directly from logic modules; pass IO in.
- `generate` output must be byte-stable across runs and platforms (sorted walks, LF endings, no timestamps). Determinism is a prerequisite for the `--check` drift gate.
- Do not put anything in this file that a linter or formatter can enforce — that belongs in tooling. Formatting is enforced by `crystal tool format`; do not document style here.
- Write Windows-aware path code (use `Path`, never hardcode `/`), even though the Windows binary ships later.

## Pull requests

Keep PR descriptions simple and high-level — a short Summary only. Do not include a Test plan / checklist section.

## Where scoped guidance lives

Task- and file-scoped conventions are **not** in this file. They live in
`docs/conventions/` and are surfaced automatically at edit time by agent-apropos's own
hooks (`agent-apropos hook pre`/`agent-apropos hook post`, wired in `.claude/settings.json`;
run `make install` so they resolve on PATH). Read `docs/conventions/README.md`
for how the layers and frontmatter work.
