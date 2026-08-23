# agent-apropos development tasks.
#
# Point the Crystal compile cache at a project-local, gitignored dir so every
# target works regardless of whether the global ~/.cache/crystal is writable.
# Override by exporting CRYSTAL_CACHE_DIR yourself before invoking make.
CRYSTAL_CACHE_DIR ?= $(CURDIR)/.cache/crystal
export CRYSTAL_CACHE_DIR

# Where `make install` drops the binary. Default to the per-user bin dir that is
# already on PATH in the devcontainer; override with `make install PREFIX=/usr/local`.
PREFIX ?= $(HOME)/.local

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## Install shard and npm dependencies
	shards install
	npm install

.PHONY: build
build: ## Build the agent-apropos binary (debug)
	shards build agent-apropos

.PHONY: release
release: ## Build the agent-apropos binary (release)
	crystal build --release src/agent_apropos.cr -o bin/agent-apropos

.PHONY: install
install: release ## Build the release binary and install it to PREFIX/bin (on PATH)
	@mkdir -p "$(PREFIX)/bin"
	install -m 0755 bin/agent-apropos "$(PREFIX)/bin/agent-apropos"
	@echo ">> installed agent-apropos to $(PREFIX)/bin/agent-apropos"

.PHONY: spec
spec: ## Run the spec suite
	crystal spec

bin/ameba-apropos: tool/lint/main.cr $(wildcard tool/lint/rules/*.cr)
	crystal build tool/lint/main.cr -o bin/ameba-apropos

.PHONY: lint
lint: bin/ameba-apropos ## Run ameba (zero findings required)
	./bin/ameba
	./bin/ameba-apropos

.PHONY: coverage
coverage: ## Run specs under kcov and enforce the coverage gate
	./scripts/coverage.sh

.PHONY: dup
dup: ## Check src/**/*.cr for code duplication (jscpd; zero clones required)
	npm run lint:dup

# Mutation gate: fails when a mutant survives on the lines the current change
# touched. Deliberately NOT part of `check` — `check` is the fast local gate,
# and a mutation run is minutes, not seconds. CI blocks on the same script.
#
# Usage:
#   make mutate                        # the changed lines, same as CI
#   make mutate ARGS="--base main"     # against a different base
#   make mutate ARGS="src/agent_apropos/index.cr"   # a whole file (backfill sweep)
.PHONY: mutate
mutate: ## Run the mutation gate on the changed lines (see docs/mutation-testing.md)
	./scripts/mutate.sh $(ARGS)

# Deterministic bats tests for the devcontainer's host-side initializeCommand
# (.devcontainer/initialize.sh). Offline and credential-free, unlike the live
# `e2e` target below, so this one does belong in `check`. bats and the
# bats-support/bats-assert libraries ship in the devcontainer image; default
# BATS_LIB_PATH to their install location so the target works even when that
# env var is not exported into the current shell.
.PHONY: devcontainer-spec
devcontainer-spec: ## Run the bats tests for .devcontainer/initialize.sh
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats .devcontainer/tests

# Deterministic bats tests for the repo's own Claude Code hook scripts under
# .claude/hooks/. Same story as devcontainer-spec: offline, credential-free, and
# therefore part of `check`.
.PHONY: hooks-spec
hooks-spec: ## Run the bats tests for .claude/hooks/
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats .claude/hooks/tests

# Deterministic bats tests for install.sh's platform gate. Same story as the two
# suites above: offline and credential-free, so it belongs in `check`. The
# network-dependent half of the installer is covered by the release workflow's
# self-test against a freshly built artifact.
#
# Named per suite rather than `bats tests`, so tests/ can hold more than one.
.PHONY: installer-spec
installer-spec: ## Run the bats tests for install.sh
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats tests/install_sh.bats

# The runner's own bats suite. Offline and stub-driven — no engine, no
# compiler — so it belongs in `check` alongside the other shell suites.
.PHONY: mutate-spec
mutate-spec: ## Run the bats tests for scripts/mutate.sh
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats tests/mutate.bats

# The rules' bats suite drives the real engine and the real compiler, because
# what the rules produce against Crystal source is the thing under test. That
# makes it minutes rather than seconds, so it stays out of `check` and runs in
# the mutation CI job instead.
.PHONY: mutate-rules-spec
mutate-rules-spec: ## Run the bats tests for tool/mutate/crystal.rules (slow; needs the engine)
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats tests/mutate_rules.bats

.PHONY: plans-spec
plans-spec: ## Run the bats tests for scripts/check-plans-empty.sh
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats tests/check_plans_empty.bats

# Gate on docs/plans/ holding no committed plan: a plan is deleted in the PR
# that implements it. Only tracked files count, so writing a plan doesn't fail
# the local gate while you're still writing it.
.PHONY: plans-check
plans-check: ## Fail if any plan doc is committed under docs/plans/
	./scripts/check-plans-empty.sh

.PHONY: check
check: lint spec dup devcontainer-spec hooks-spec installer-spec mutate-spec plans-spec plans-check ## Lint + spec + duplication + devcontainer + hook + installer + mutation-runner + plans checks (the fast local gate)

# End-to-end test: stands up a sample repo wired with agent-apropos's hooks and
# proves agent-apropos injects conventions and steers a real `claude` run. Local/advisory —
# the live phases need the `claude` CLI + credentials and skip cleanly without
# them, so this is intentionally NOT part of `check` or CI. See e2e/README.md.
.PHONY: e2e
e2e: ## Run the end-to-end test (needs claude CLI; skips live phases without it)
	bash e2e/run.sh

.PHONY: clean
clean: ## Remove build artifacts and local caches
	rm -rf bin lib .shards .cache coverage
