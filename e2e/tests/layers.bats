#!/usr/bin/env bats
#
# Layered live e2e — proves agent-apropos steers a real CLI agent, per case.
#
# Cases are grouped in one file (expected artifact + prompt + target file +
# the register_live_tests call live together) so a case's full intent is
# visible in one place, not spread across per-case files.
#
# Each case registers a with/without pair of live tests per agent in
# E2E_AGENTS (helpers.bash) via register_live_tests — see there for how the
# CLI-agent matrix is generated. Deterministic delivery of the payload -> rule
# / generate -> skill-wrapper mapping is covered by the Crystal spec suite
# (spec/agent_apropos/hook_spec.cr, spec/integration/hook_spec.cr,
# spec/agent_apropos/generate_spec.cr, spec/integration/generate_spec.cr) — this
# file only proves a real CLI agent's output is actually steered.
#
# Each case's expected artifact is a realistic project convention (a
# decorator, a custom exception, a registry call, an audit wrapper) rather
# than an arbitrary token. A model can't produce it by chance — it names a
# module/symbol that only exists because the rule said so — but it also isn't
# inert text, so a pass proves the convention's *behavior* landed, not just
# that a string got copied. The "two rules, one file" case has two
# expected artifacts (one per rule) — see assert_contains_all in helpers.bash.

bats_load_library bats-support
bats_load_library bats-assert
load helpers

setup() { ensure_agent_apropos; }

# --- Path-scoped rule (src/**) ------------------------------------------------
# Claude Code delivers via PreToolUse; OpenCode delivers via tool.execute.before
# + client.session.prompt(noReply:true) from the generated plugin.
#
# Convention: every new function under src/ (the public surface) must be
# wrapped in @trace_call (src/telemetry.py). Nothing in the file being edited
# hints at this — the existing shout() predates the requirement.
export EXPECT_L2="@trace_call"
export PROMPT_L2="Add a function shout_twice(text) to src/util.py that returns text uppercased and repeated twice."
register_live_tests "Path rule" EXPECT_L2 PROMPT_L2 src/util.py

# --- Two path rules, one file — auth + throttle on api/** --------------------
# Two independent path-scoped rules, api-auth-rule.md and api-throttle-rule.md,
# both declare paths: ["api/**"], so both fire on the same edit — proving more
# than one path rule can land on a single file, not just one per path.
#
# Convention: every new handler under api/ must be wrapped in BOTH
# @require_auth (api/auth.py) and @rate_limited (api/throttle.py) — and
# @rate_limited must be the outermost decorator (listed above @require_auth),
# so an unauthenticated flood is rejected by the cheap rate limiter before it
# ever reaches the auth check. That ordering is the counter-intuitive part: it
# reverses the "auth gates first" instinct, and only reading both rule docs
# (not exploring ping(), which predates either requirement) reveals it.
# EXPECT_L2B lists both required decorators (assert_contains_all, helpers.bash)
# — presence of both is asserted; the specific stacking order is documented in
# the rule docs but not separately checked here.
export EXPECT_L2B=$'@rate_limited\n@require_auth'
export PROMPT_L2B="Add a function get_status() to api/handlers.py that returns a handler status dict."
register_live_tests "Path rules (two)" EXPECT_L2B PROMPT_L2B api/handlers.py

# --- Content-scoped rule (NotImplementedError) -------------------------------
# Claude Code delivers via PostToolUse; OpenCode delivers via tool.execute.after
# + client.session.prompt(noReply:true) from the generated plugin.
#
# Convention: don't raise the bare NotImplementedError for a deliberate stub —
# raise StubNotImplemented (scripts/errors.py) instead, so tooling can tell a
# deferred stub apart from a real bug. The model's natural first draft IS the
# trigger condition, so agent-apropos has to change what it already wrote, not just
# decorate it.
export EXPECT_L3="StubNotImplemented("
export PROMPT_L3="Add a stub function sync() to scripts/jobs.py that raises NotImplementedError."
register_live_tests "Content rule" EXPECT_L3 PROMPT_L3 scripts/jobs.py

# --- Path + content (AND) — audited queries in db/** -------------------------
# Same delivery mechanism as the content rule above, but the frontmatter combines
# `paths: ["db/**"]` with `contents: ['\bconn\.execute\(']` — it fires only
# when BOTH match. A path-only rule would fire on any edit under db/ (even
# ones that don't touch a query); a content-only rule would fire on
# conn.execute( anywhere in the tree (e.g. a one-off migration script, where
# the audit wrapper isn't the convention). Only the AND of both is correct.
export EXPECT_L3B="audited_query("
export PROMPT_L3B="Add a function get_order(conn, order_id) to db/queries.py that looks up an order by id."
register_live_tests "Path+content rule" EXPECT_L3B PROMPT_L3B db/queries.py

# --- Intent skill, delivered as a generated SKILL.md wrapper -----------------
# Skills are written to .claude/skills/<name>/SKILL.md by agent-apropos generate.
# OpenCode reads this same path natively (no plugin required), so the same
# generated wrapper serves both Claude Code and OpenCode.
#
# Convention: new calc operations must register in the dispatch table
# (lib/registry.py), not just be defined as a bare function. add/multiply
# predate the registry and haven't been migrated.
export EXPECT_L4="register_operation("
export PROMPT_L4="Add a new arithmetic operation divide(a, b) to the calc library in lib/calc.py."
register_live_tests "Intent skill" EXPECT_L4 PROMPT_L4 lib/calc.py
