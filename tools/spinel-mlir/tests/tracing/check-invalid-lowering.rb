require 'zlib'
require 'fileutils'
require 'open3'
tool,fixture,work=ARGV
abort 'usage: check-invalid-lowering TOOL FACTS_GZ WORK' unless work
FileUtils.mkdir_p(work)
facts=File.join(work,'facts.mlir')
File.binwrite(facts,Zlib::GzipReader.open(fixture,&:read))
stdout,stderr,status=Open3.capture3(tool,facts)
File.binwrite(File.join(work,'stdout'),stdout);File.binwrite(File.join(work,'stderr'),stderr)
File.write(File.join(work,'rc'),status.exitstatus.to_s+"\n")
abort 'invalid lowering did not fail loudly' unless status.exitstatus==1 && stdout.b=="post-lowering invalid verdict: MLIR error=1 artifacts=0\n".b && stderr.b.include?("verdict \"pass\" is not valid for program kind \"fentry\"".b) && !stderr.b.include?('SB017'.b)
puts 'post-lowering verifier failure / no duplicate SB017 GREEN'
