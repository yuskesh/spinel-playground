require 'open3'
require 'tmpdir'
consumer,facts=ARGV
abort 'usage: fmod-ret CONSUMER FIXED_FACTS' unless facts
Dir.mktmpdir('fmod-ret-') do |dir|
  out=dir+'/output'
  stdout,stderr,status=Open3.capture3(consumer,'--emit-dir',out,facts)
  abort "fmod-ret-root: rc=#{status.exitstatus} #{stderr}" unless status.success? && stdout.empty?
  ir=File.binread(out+'/xdpcount.mlir')
  abort 'fmod-ret-select/return' unless ir.include?('arith.select') && ir.scan('ebpf.return').size==2 && ir.include?('"fexit"')
end
