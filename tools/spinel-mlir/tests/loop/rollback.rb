require 'zlib'
require 'fileutils'
require 'open3'
tool,fixture,work=ARGV
FileUtils.mkdir_p(work)
path=work+'/facts.mlir'
File.binwrite(path,Zlib::GzipReader.open(fixture,&:read))
o,e,s=Open3.capture3(tool,path)
File.binwrite(work+'/stdout',o);File.binwrite(work+'/stderr',e)
abort 'rollback mutation wrong refusal' unless s.exitstatus==1&&o.empty?&&e=="FAIL probe-state-rollback\n"
puts 'probe-state-rollback mutation: exact RED observed'
