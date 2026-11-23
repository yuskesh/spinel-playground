# E039 H6: a mutant build of spinel-output-str-test on greetwatch must lower,
# verify and pass the probe check, then fail exactly at the IR comparison with
# Go — a named observation, not only a non-zero exit (rc 1 before the
# comparison is not counted as detection).
require 'zlib'
require 'fileutils'
require 'open3'
tool, fixture, oracle, work, source_dir = ARGV
abort 'usage: output-str-mutation MUTANT_TOOL FACTS_GZ ORACLE WORK [SOURCE_DIR]' unless work
FileUtils.mkdir_p(work)
path = File.join(work, 'facts.mlir')
File.binwrite(path, Zlib::GzipReader.open(fixture, &:read))
out, err, status = Open3.capture3(tool, 'positive', path, oracle, *source_dir)
File.write(File.join(work, 'stdout'), out)
File.write(File.join(work, 'stderr'), err)
lines = out.lines.map(&:chomp)
before = ['ok greetwatch lowers: ', 'ok greetwatch prints nothing: ', 'ok greetwatch verifies',
          'ok the binding was probed (1)']
missing = before.reject { |l| lines.include?(l) }
abort "mutant stopped before the IR comparison: missing #{missing}" unless missing.empty?
abort 'mutant exited 0' if status.success?
abort 'mutant did not fail at the IR comparison' unless lines.include?("FAIL IR equals Go's (locations elided)")
puts "detected: #{File.basename(tool)} differs from Go's IR"
