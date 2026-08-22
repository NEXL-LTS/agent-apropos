# Path literals that mean the same thing on POSIX and on Windows.
#
# A bare "/repo" is absolute in POSIX flavour but not in Windows flavour, where
# an absolute path needs a drive or UNC anchor. Code under test that calls
# Path#absolute? or Path#expand therefore takes a different branch for the two,
# so a spec written against "/repo" is a statement about the host rather than
# about the code. Anchoring to the host's own filesystem root keeps one literal
# meaning one thing, without the compile-time platform branch
# docs/conventions/platform-flags.md forbids.
module SpecPaths
  extend self

  ANCHOR = Path[Dir.tempdir].anchor || Path["/"]

  # An absolute path under the host's filesystem root, in POSIX form so it can
  # be interpolated into JSON payloads and in-memory filesystem keys.
  def absolute(*parts : String) : String
    ANCHOR.join(*parts).to_posix.to_s
  end
end
