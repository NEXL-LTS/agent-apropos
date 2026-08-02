---
paths: ["src/agent_apropos/filesystem.cr"]
contents: ['O_NOFOLLOW']
---

# `Filesystem::Real#append`'s atomic no-follow open

**Rule:** Don't replace `append`'s `LibC::O_NOFOLLOW` open with a
check-then-open pattern (e.g. `File.symlink?` followed by a plain
`File.write`/`open`). Keep opening the target with `O_NOFOLLOW` directly.

**Why:** A check-then-open has a TOCTOU window where a symlink can be
swapped in between the check and the open. `O_NOFOLLOW` closes that window
by having the kernel refuse the open atomically (`Errno::ELOOP`) if the
target turns out to be a symlink, so "refuses to append through a symlink"
holds even under a concurrent attacker, not just in the single-threaded
case a spec can exercise. `append` is used only for the best-effort
`--verbose` hook log — never for an artifact whose bytes must be stable,
which goes through `write`'s atomic temp-file-plus-rename instead — but
that log path is still attacker-reachable through the same symlink-swap
race, so the atomicity matters here too.

**Watch out:** `LibC::O_NOFOLLOW` assumes POSIX semantics — Unix-only.
Don't add a Windows fallback for this without real Windows CI to verify it
against (see `docs/conventions/platform-flags.md`); an unverified fallback
is worse than a platform that simply doesn't compile there yet.

## Verify

- `append` still opens the target with `O_NOFOLLOW` (or an equivalent
  atomic no-follow-symlink open), not a separate existence/symlink check
  followed by a plain open.
- No Windows-specific branch was added here without real Windows CI to
  exercise it.
