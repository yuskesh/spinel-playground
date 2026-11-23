require 'fileutils';require 'zlib';require 'open3'
tool,rec,mc,work=ARGV
FileUtils.mkdir_p(work)
inputs=[rec,mc].each_with_index.map{|p,i|out=work+"/facts#{i}.mlir";File.binwrite(out,Zlib::GzipReader.open(p,&:read));out}
o,e,s=Open3.capture3(tool,*inputs)
File.binwrite(work+'/stdout',o);File.binwrite(work+'/stderr',e)
if ENV['E033_EXPECT_RED']=='1'
 abort 'wrong initial RED' unless s.exitstatus==1&&o.empty?&&e=="FAIL ktime-handler\n"
 puts 'ktime handler absent: exact RED'
elsif ENV['E033_EXPECT_LOC_RED']=='1'
 abort 'wrong loc mutation RED' unless s.exitstatus==1&&o.empty?&&e=="FAIL ktime-oracle-loc\n"
 puts 'ktime loc-only mutation: exact RED'
else
 abort "helper test rc=#{s.exitstatus}: #{e}" unless s.success?&&e.empty?&&o.start_with?('PASS ktime helper:')
 puts o
end
