require 'json'
require 'fileutils'
require 'open3'
require_relative '../../scripts/lib/byte-comparison'
mode, tool, archive, work = ARGV
abort 'usage: MODE TOOL ARCHIVE WORK' unless work
FileUtils.rm_rf(work) if File.directory?(work)
FileUtils.mkdir_p(work)
abort 'extract' unless system('/usr/bin/tar','-xzf',archive,'-C',work,'capture-01/cases')
if mode == 'unknown'
  # The companion unit test independently expects the original Unknown label.
  stdout, stderr, status = Open3.capture3(tool, ARGV.fetch(4))
  named = 'FAIL Probe replay retains original label/name/path'
  okay = status.exitstatus == 1 && ByteComparison.include?(stderr,named)
else
  stem = mode == 'origins' ? 'rmw_local_loop' : 'loop_ringbuf'
  dir = work+'/capture-01/cases/internal_frontend_testdata_neg_'+stem
  stdout, stderr, status = Open3.capture3('/usr/bin/timeout','--kill-after=2s','20s',tool,'--emit-dir',dir+'/artifacts',dir+'/facts.mlir')
  artifacts = Dir[dir+'/artifacts/*']
  okay = if mode == 'origins'
    status.success? && stdout.empty? && stderr.empty? && artifacts.size == 3 && artifacts.all? { |p| File.size(p) > 0 }
  elsif mode == 'precheck'
    status.exitstatus == 1 && stdout.empty? && artifacts.empty? &&
      ByteComparison.include?(stderr,"'ebpf.ringbuf.reserve' op is not allowed inside ebpf.loop") &&
      !ByteComparison.include?(stderr,'rejected SB030')
  else
    abort 'unknown mode'
  end
end
File.binwrite(work+'/stdout',stdout); File.binwrite(work+'/stderr',stderr)
File.write(work+'/rc',"#{status.exitstatus}\n")
abort 'mutation not observed: '+mode unless okay && !status.termsig
puts 'named mutation detected: '+mode
