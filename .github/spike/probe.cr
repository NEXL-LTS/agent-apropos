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

probe("Dir.glob(**/*.md)") { Dir.glob(File.join(dir, "docs", "**", "*.md")).size }
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

FileUtils.rm_rf(dir)
