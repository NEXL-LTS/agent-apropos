# TEMPORARY — U1 spike probe. Deleted with .github/workflows/windows-spike.yml.
#
# Exercises the Tier 3 stdlib surfaces the plan assumes work on Windows, so an
# assumption that is actually a gap shows up as a named line rather than as a
# mystery spec failure.
require "file_utils"

def probe(name : String, &)
  print name.ljust(46)
  puts "OK  #{yield}"
rescue ex
  puts "FAIL  #{ex.class}: #{ex.message}"
end

dir = File.tempname("apropos-spike")
Dir.mkdir_p(File.join(dir, "docs", "conventions"))
File.write(File.join(dir, "docs", "conventions", "a.md"), "---\npaths: [\"src/**\"]\n---\nbody\n")

probe("Dir.glob(String pattern, native seps)") do
  Dir.glob(Path[dir].join("docs", "**/*.md").to_s).size
end
probe("Dir.glob(Path pattern)") { Dir.glob(Path[dir].join("docs", "**/*.md")).size }
probe("Dir.glob(String pattern, to_posix)") do
  Dir.glob(Path[dir].join("docs", "**/*.md").to_posix.to_s).size
end
probe("Path#join keeps the pattern verbatim") { Path[dir].join("docs", "**/*.md").to_s }
probe("Dir.glob(*/SKILL.md via Path)") do
  Dir.mkdir_p(File.join(dir, ".claude", "skills", "ship"))
  File.write(File.join(dir, ".claude", "skills", "ship", "SKILL.md"), "x")
  Dir.glob(Path[dir].join(".claude", "skills", "*/SKILL.md")).size
end
probe("Path#relative_to + to_posix") do
  Path[File.join(dir, "docs", "conventions", "a.md")].relative_to(Path[dir]).to_posix.to_s
end
probe("File.rename over an existing target") do
  a = File.join(dir, "t1")
  b = File.join(dir, "t2")
  File.write(a, "x")
  File.write(b, "y")
  File.rename(a, b)
  File.read(b)
end
probe("File.symlink") do
  File.symlink(File.join(dir, "t2"), File.join(dir, "link"))
  File.symlink?(File.join(dir, "link"))
end
probe("Process.run with chdir") do
  io = IO::Memory.new
  Process.run("git", ["rev-parse", "--show-toplevel"], chdir: dir, output: io, error: Process::Redirect::Close)
  io.to_s.strip.empty? ? "(non-zero exit, as expected outside a repo)" : io.to_s.strip
end
probe("Process.run resolving git on PATH") do
  io = IO::Memory.new
  Process.run("git", ["--version"], output: io)
  io.to_s.strip
end
probe("Process.find_executable(\"git\")") { Process.find_executable("git").inspect }
probe("Process.find_executable(\"sh\")") { Process.find_executable("sh").inspect }
probe("File::DEFAULT_CREATE_PERMISSIONS") { File::DEFAULT_CREATE_PERMISSIONS.value }
probe("Time.utc / Time::Span arithmetic") { (Time.utc - 7.days).to_unix }
probe("backslash abs path relative_to + to_posix") do
  Path[File.join(dir, "src", "bar.cr")].expand.relative_to(Path[dir]).to_posix.to_s
end
probe("File.match?(POSIX glob, POSIX relpath)") { File.match?("src/**/*.cr", "src/bar.cr") }
probe("symlink over an existing link raises") do
  File.symlink(File.join(dir, "t2"), File.join(dir, "link"))
  "no error raised"
rescue ex
  "#{ex.class}: #{ex.message}"
end

FileUtils.rm_rf(dir)
