require 'open3'
require 'zlib'
require 'fileutils'
tool, compressed, dir = ARGV
FileUtils.mkdir_p(dir)
facts=File.join(dir, 'facts.mlir')
Zlib::GzipReader.open(compressed){|g|File.binwrite(facts,g.read)}
o,e,s=Open3.capture3(tool,facts)
File.binwrite(File.join(dir,'stdout'),o.b)
File.binwrite(File.join(dir,'stderr'),e.b)
File.write(File.join(dir,'rc'),s.exitstatus.to_s+"\n")
abort 'immediate-return mutant did not trigger continuation control' unless
  s.exitstatus==1 && e.b.include?('FAIL declaration-continuation reaches Spare'.b)
puts 'immediate-return mutation caught by continuation control GREEN'
