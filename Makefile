# agent-apropos development tasks.
#
# Point the Crystal compile cache at a project-local, gitignored dir so every
# target works regardless of whether the global ~/.cache/crystal is writable.
# Override by exporting CRYSTAL_CACHE_DIR yourself before invoking make.
CRYSTAL_CACHE_DIR ?= $(CURDIR)/.cache/crystal
export CRYSTAL_CACHE_DIR

CRYTIC_VERSION := ~> 9.0
MUTATION_TARGETS := matcher frontmatter index session_state review

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

# Mutation testing is advisory-only and never gates CI. Crytic is
# installed on demand into the gitignored .crytic/ so it stays out of the main
# dependency graph. If it fails to build against the target Crystal, this target
# prints the manual-mutation checklist instead of failing.
#
# Usage:
#   make mutate SUBJECT=src/agent_apropos/matcher.cr
#   make mutate                      # lists the recommended mutation targets
.PHONY: mutate
mutate: .crytic/bin/crytic ## Run crytic on SUBJECT=<file> (advisory; see docs/mutation-testing.md)
ifndef SUBJECT
	@echo "Usage: make mutate SUBJECT=src/agent_apropos/<module>.cr"
	@echo "Recommended mutation targets (pure logic):"
	@for m in $(MUTATION_TARGETS); do echo "  src/agent_apropos/$$m.cr"; done
else
	./.crytic/bin/crytic test -s $(SUBJECT)
endif

# Build crytic on demand. On failure, fall back to the documented manual
# mutation workflow rather than breaking the developer's build.
.crytic/bin/crytic:
	@echo ">> installing crytic ($(CRYTIC_VERSION)) into .crytic/ ..."
	@mkdir -p .crytic
	@printf 'name: agent-apropos-mutation\nversion: 0.1.0\ncrystal: ">= 1.20"\ndependencies:\n  crytic:\n    github: hanneskaeufler/crytic\n    version: %s\n' '$(CRYTIC_VERSION)' > .crytic/shard.yml
	@cd .crytic && shards install || { \
		echo ""; \
		echo "!! crytic failed to build against this Crystal toolchain."; \
		echo "!! Fall back to a manual mutation session — see docs/mutation-testing.md."; \
		exit 1; \
	}

# Deterministic bats tests for the devcontainer's host-side initializeCommand
# (.devcontainer/initialize.sh). Offline and credential-free, unlike the live
# `e2e` target below, so this one does belong in `check`. bats and the
# bats-support/bats-assert libraries ship in the devcontainer image; default
# BATS_LIB_PATH to their install location so the target works even when that
# env var is not exported into the current shell.
.PHONY: devcontainer-spec
devcontainer-spec: ## Run the bats tests for .devcontainer/initialize.sh
	BATS_LIB_PATH="$${BATS_LIB_PATH:-/usr/local/lib/bats}" bats .devcontainer/tests

.PHONY: check
check: lint spec dup devcontainer-spec ## Lint + spec + duplication + devcontainer checks (the fast local gate)

# End-to-end test: stands up a sample repo wired with agent-apropos's hooks and
# proves agent-apropos injects conventions and steers a real `claude` run. Local/advisory —
# the live phases need the `claude` CLI + credentials and skip cleanly without
# them, so this is intentionally NOT part of `check` or CI. See e2e/README.md.
.PHONY: e2e
e2e: ## Run the end-to-end test (needs claude CLI; skips live phases without it)
	bash e2e/run.sh

.PHONY: clean
clean: ## Remove build artifacts and local caches
	rm -rf bin lib .shards .crytic .cache coverage
