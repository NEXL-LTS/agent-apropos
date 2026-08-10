---
skill: true
description: "Use when the user asks to cut, publish, or tag a release of agent-apropos, to bump the version consistently and drive the tag-triggered release workflow in the one order that produces generated notes."
---

# Cutting a release

**Rule:** A release is a pushed annotated tag `vX.Y.Z` — that is the publishing
trigger `.github/workflows/release.yml` uses. (`workflow_dispatch` exists to
rehearse the pipeline without publishing.) Never publish without an explicit ask;
it is outward-facing and hard to reverse. Then follow this order, because two
steps of it race:

1. **Bump the version in the change's own PR, not in a release commit.** Three
   places must agree, and nothing checks that they do: `shard.yml`'s `version:`,
   `VERSION` in `src/agent_apropos/version.cr`, and the `ARG
   AGENT_APROPOS_VERSION=vX.Y.Z` Dockerfile pin in `README.md`. A behavior change
   users can observe earns a minor bump.
2. **Merge, then sync and confirm green.** `git checkout main && git pull`, then
   wait for CI on the merge commit itself (`gh run watch <id> --exit-status`) —
   not on the PR head, and not on a local `make check`, which can fail for
   toolchain reasons CI does not share. Re-read the three version files off
   merged `main` before tagging.
3. **Tag annotated, matching the existing tags:** `git tag -a vX.Y.Z -m vX.Y.Z
   && git push origin vX.Y.Z`. `gh release create` without a pushed tag makes a
   lightweight one, which every prior release is not.
4. **Create the release immediately after the push:** `gh release create vX.Y.Z
   --verify-tag --title vX.Y.Z --generate-notes`. This is the race. The tag push
   already started the workflow, whose `action-gh-release` step will *create* the
   release with an empty body if it gets there first, and `gh release create`
   then fails because it already exists. Winning is easy — the build legs take
   several minutes — but do this step next, not after checking on anything else.
   `--generate-notes` is what produces the "What's Changed" + Full Changelog body
   every previous release has; the workflow never generates notes itself.
5. **Wait for the build and verify the assets.** All four legs must go green
   (`linux-x86_64`, `linux-arm64`, `darwin-arm64`, `darwin-x86_64`), each
   attaching a binary plus its `.sha256` — eight assets. Confirm the release is
   neither a draft nor a prerelease.

**Why:** The tag is load-bearing in a way that is easy to get wrong once and
then live with: it both starts the build and names the release, so a lightweight
tag or an empty-bodied release can only be fixed after the fact, and a version
mismatch ships a binary whose `--version` disagrees with the tag users installed
it by. The step-3/step-4 ordering exists because the workflow and the release
creation are two writers to one release object, and only one of them knows how
to generate notes.

**Watch out:** Don't run the release workflow via `workflow_dispatch` expecting
a release — its `Attach to release` steps are gated on `startsWith(github.ref,
'refs/tags/')`, so a branch run builds and uploads workflow artifacts only. That
is the right way to rehearse the pipeline without publishing.

## Verify

- `shard.yml`, `src/agent_apropos/version.cr`, and `README.md`'s Dockerfile pin
  all name the version being tagged, as merged on `main`.
- CI passed on the merge commit that the tag points at.
- The tag is annotated (`git for-each-ref refs/tags/vX.Y.Z --format='%(objecttype)'`
  reports `tag`, not `commit`).
- The release body carries generated notes, not an empty body.
- Eight assets are attached — four binaries, four `.sha256` — and the release is
  not a draft or prerelease.
