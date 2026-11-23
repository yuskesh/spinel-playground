require 'zlib'
require 'fileutils'
require 'open3'
repo_root = File.expand_path(__dir__)
until File.file?(File.join(repo_root, 'scripts/lib/byte-comparison.rb'))
  parent = File.dirname(repo_root)
  abort 'byte comparison helper not found' if parent == repo_root
  repo_root = parent
end
require File.join(repo_root, 'scripts/lib/byte-comparison.rb')
tool,fixture,work=ARGV
abort 'usage: check-sockmap-policy TOOL FACTS_GZ WORK' unless work
FileUtils.mkdir_p(work)
facts=File.join(work,'facts.mlir')
File.binwrite(facts,Zlib::GzipReader.open(fixture,&:read))
%w[duplicate-evidence indirect wrong-receiver missing-exporter].each do |mode|
  stdout,stderr,status=Open3.capture3(tool,facts,'sk_lookup','',mode)
  File.binwrite(File.join(work,mode+'.stdout'),stdout)
  File.binwrite(File.join(work,mode+'.stderr'),stderr)
  expected=case mode
  when 'wrong-receiver' then 'assign receiver is not a declared map'
  when 'missing-exporter' then 'map exporter is not registered'
  else 'call evidence does not match the explicit callee policy'
  end
  expected_rc=mode=='missing-exporter' ? 1 : 0
  abort "SockMap #{mode} failed" unless status.exitstatus==expected_rc && ByteComparison.equal?(stdout,"SockMap #{mode} rejection GREEN\n") && ByteComparison.include?(stderr,"rejected SB001 (UnsupportedConstruct): #{expected}")
end
puts 'SockMap policy/export controls 4/4 GREEN'
