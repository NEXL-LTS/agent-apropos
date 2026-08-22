---
paths: ["**/*.cr"]
contents: ['flag\?\(:\w+\)']
---

# Compile-time platform branches

**Rule:** Don't add a `{% if flag?(:...) %}`-style branch for a platform CI
doesn't actually build and run specs on. Today that's Linux and Windows:
`ci.yml` runs `crystal spec` on `ubuntu-latest` (plus the coverage gate) and on
`windows-latest` (build plus specs, no coverage). The macOS leg in `release.yml`
only compiles and smoke-tests `--version` — `crystal spec` never runs there. If
a branch can't be exercised by CI, prefer code that simply fails to compile on
that platform over carrying an unverified fallback.

**Why:** The compiler discards the untaken branch of a `flag?` macro
conditional for the current build target before compilation even reaches
kcov, so a branch nothing builds also can't show up as *uncovered* — it's
invisible to the 100% line-coverage gate rather than caught by it. "100%
coverage" then silently means "100% coverage of whichever platform CI
happens to run," not what it claims to mean.

**Watch out:** A Windows CI leg is not a licence to branch on Windows. Prefer a
primitive that works everywhere: `Filesystem::Real#append`'s POSIX-only
`O_NOFOLLOW` open was retired rather than given a Windows fallback, and
`init --claude-symlink` keys on whether the OS refuses the symlink rather than
on which OS it is. Also note this applies to any `flag?(:platform)` check, not
just Unix vs Windows — a `flag?(:darwin)`-only branch is still unverified, since
the macOS release leg never runs the spec suite.

**Watch out:** A *spec* can be platform-coupled without any `flag?` at all. A
path literal like `/repo` is absolute in POSIX flavour but not in Windows
flavour, where an absolute path needs a drive or UNC anchor — so `Path#expand`
and `Path#absolute?` take a different branch for it. Use `SpecPaths.absolute`
(`spec/support/spec_paths.cr`) for a root that means the same thing on both,
rather than guarding the example with a platform check.

## Verify

- Every `flag?(:...)` branch added actually compiles and runs under
  `crystal spec` in CI (currently: the Linux and Windows branches qualify).
- No new branch exists for a platform that isn't spec-tested in CI (macOS), and
  no new branch exists where attempting the operation and handling refusal would
  have done the same job.
