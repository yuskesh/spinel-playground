require 'open3'
require 'json'
require 'fileutils'
# Active input supply is explicit. This test never runs or rewrites the producer.
abort 'usage: group-a.rb BUILD FACTS ORACLE OUTPUT' unless ARGV.size==4
build,facts,oracle,out=ARGV.map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
FileUtils.mkdir_p(out)
cmd=[build+'/bin/spinel-mlir','--emit-dir',out+'/candidate',facts]
stdout,stderr,status=Open3.capture3(*cmd)
File.write(out+'/command.json',JSON.pretty_generate({argv:cmd,rc:status.exitstatus,signal:status.termsig})+"\n")
File.binwrite(out+'/stdout',stdout);File.binwrite(out+'/stderr',stderr)
abort "group-a emit expected success, rc=#{status.exitstatus}: #{stderr}" unless status.success?
%w[schema.json maps.json].each do |suffix|
 got=Dir[out+'/candidate/*.'+suffix];want=Dir[oracle+'/*.'+suffix]
 abort "missing or multiple #{suffix}" unless got.size==1&&want.size==1
 abort "#{suffix} differs" unless File.binread(got[0])==File.binread(want[0])
end
puts 'group-a declaration artifacts equal'
