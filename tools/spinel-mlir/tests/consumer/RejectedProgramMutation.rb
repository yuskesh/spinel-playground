require 'open3'
require 'tempfile'
Tempfile.create(['e043-mutation', '.mlir']) do |file|
  facts, status = Open3.capture2('gzip', '-dc', ARGV.fetch(1))
  abort 'fixture decode failed' unless status.success?
  file.binmode
  file.write(facts)
  file.flush
  stdout, stderr, run = Open3.capture3(ARGV.fetch(0), file.path)
  abort 'immediate return mutation survived' unless run.exitstatus == 1 &&
    stderr.b.include?("FAIL only body SB019 continues, finalizer counts\n".b) &&
    stdout.b.include?("rejected program evidence GREEN\n".b)
  puts 'immediate return mutation detected'
end
