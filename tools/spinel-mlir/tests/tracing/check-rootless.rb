require 'zlib'
require 'fileutils'
require 'open3'
repo_root=File.expand_path(__dir__)
until File.file?(File.join(repo_root,'scripts/lib/byte-comparison.rb'))
  parent=File.dirname(repo_root)
  abort 'byte comparison helper not found' if parent==repo_root
  repo_root=parent
end
require File.join(repo_root,'scripts/lib/byte-comparison.rb')
tool,fixture,work=ARGV
abort 'usage: check-rootless TOOL FACTS_GZ WORK' unless work
FileUtils.mkdir_p(work);facts=File.join(work,'facts.mlir')
File.binwrite(facts,Zlib::GzipReader.open(fixture,&:read))
%w[reject multiple mark-only unmarked-error valid].each do |mode|
  stdout,stderr,status=Open3.capture3(tool,facts,mode)
  File.binwrite(File.join(work,mode+'.stdout'),stdout)
  File.binwrite(File.join(work,mode+'.stderr'),stderr)
  expected=case mode
  when 'reject','multiple' then 'rejected SB033 (KernelTypeShape): rootless-control rejection'
  when 'valid' then 'kt_member_order.rb: rejected SB008 (ProgramShape): no eBPF program: declare one with `BPF.xdp :name` at the top level'
  else 'rejected SB017 (InternalEmitter): consumer lowering failed without a diagnostic'
  end
  calls=mode=='multiple' ? 2 : 1
  abort 'rootless '+mode+' failed' unless status.success? && ByteComparison.equal?(stdout,"rootless #{mode} calls=#{calls} failure/no-programs GREEN\n") && ByteComparison.include?(stderr,expected) && !ByteComparison.include?(stderr,'conditional')
end
puts 'rootless declaration controls 5/5 GREEN'
