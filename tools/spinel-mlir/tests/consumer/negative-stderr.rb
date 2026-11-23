# E054: lower a saved negative facts fixture with spinel-mlir; the run fails,
# writes no artifact, and its stderr equals Go's build.stderr byte for byte.
# With --mutant WANT the same run must instead differ from Go, and its stderr
# must contain WANT (a named observation — a bare non-zero exit is not one).
require 'zlib'
require 'fileutils'
require 'open3'
require_relative '../../scripts/lib/byte-comparison' # docs/consumer_hooks.md
mutant = ARGV.delete('--mutant') && ARGV.shift
tool, fixture, oracle, work = ARGV
abort 'usage: negative-stderr TOOL FACTS_GZ GO_STDERR WORK [--mutant WANT]' unless work
FileUtils.mkdir_p(work)
facts = File.join(work, 'facts.mlir')
File.binwrite(facts, Zlib::GzipReader.open(fixture, &:read))
out = File.join(work, 'out')
FileUtils.rm_rf(out)
# ByteComparison compares bytes whatever the encodings (Go's stderr is binary).
stdout, stderr, status = Open3.capture3(tool, '--emit-dir', out, facts, binmode: true)
File.binwrite(File.join(work, 'stderr'), stderr)
abort "the run exited #{status.exitstatus.inspect}, not 1" unless status.exitstatus == 1
abort 'the run wrote artifacts' unless Dir[out + '/*'].empty?
abort 'the run wrote stdout' unless stdout.empty?
want = File.binread(oracle)
if mutant
  abort 'mutant stderr equals Go — not detected' if ByteComparison.equal?(stderr, want)
  abort "mutant stderr lacks #{mutant.inspect}" unless ByteComparison.include?(stderr, mutant)
  puts "detected: stderr differs from Go and contains #{mutant.inspect}"
else
  abort "stderr differs from Go:\n--- ours\n#{stderr.b}--- Go\n#{want.b}" unless ByteComparison.equal?(stderr, want)
  puts 'ok stderr equals Go byte for byte'
end
