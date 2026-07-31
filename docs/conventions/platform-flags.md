---
paths: ["**/*.cr"]
contents: ['flag\?\(:\w+\)']
---

# Compile-time platform branches

**Rule:** Don't add a `{% if flag?(:...) %}`-style branch for a platform CI
doesn't actually build and run specs on. Today that's everything except
Linux: `ci.yml` runs `crystal spec`/the coverage gate only on `ubuntu-latest`;
the macOS leg in `release.yml` only compiles and smoke-tests `--version`
(`crystal spec` never runs there); Windows has no CI leg at all. If a branch
can't be exercised by CI, prefer code that simply fails to compile on that
platform over carrying an unverified fallback.

**Why:** The compiler discards the untaken branch of a `flag?` macro
conditional for the current build target before compilation even reaches
kcov, so a branch nothing builds also can't show up as *uncovered* — it's
invisible to the 100% line-coverage gate rather than caught by it. "100%
coverage" then silently means "100% coverage of whichever platform CI
happens to run," not what it claims to mean.

**Watch out:** applies to any `flag?(:platform)` check, not just Unix vs
Windows — a `flag?(:darwin)`-only branch is equally unverified, since the
macOS release leg never runs the spec suite either.

## Verify

- Every `flag?(:...)` branch added actually compiles and runs under
  `crystal spec` in CI (currently: only the Unix/Linux branch qualifies).
- No new branch exists solely for a platform that isn't shipped yet
  (Windows) or isn't spec-tested in CI (macOS).
