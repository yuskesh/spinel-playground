require 'open3'
require 'zlib'
require 'fileutils'
repo_root = File.expand_path(__dir__)
until File.file?(File.join(repo_root, 'scripts/lib/byte-comparison.rb'))
  parent = File.dirname(repo_root)
  abort 'byte comparison helper not found' if parent == repo_root
  repo_root = parent
end
require File.join(repo_root, 'scripts/lib/byte-comparison.rb')
tool, fixture, expected, work = ARGV
abort 'usage: check-sockmap tool facts.gz go.stderr work' unless work
FileUtils.mkdir_p(work)
facts = File.join(work, 'facts.mlir')
File.binwrite(facts, Zlib::GzipReader.open(fixture, &:read))
stdout, stderr, result = Open3.capture3(tool, facts)
File.binwrite(File.join(work,'stdout'),stdout)
File.binwrite(File.join(work,'stderr'),stderr)
File.write(File.join(work,'rc'),"#{result.exitstatus}\n")
abort 'SockMap control failed' unless result.success? &&
  ByteComparison.equal?(stdout, "unused invalid SockMap/custom XDP rejection GREEN\n") &&
  ByteComparison.equal?(stderr, File.binread(expected))
