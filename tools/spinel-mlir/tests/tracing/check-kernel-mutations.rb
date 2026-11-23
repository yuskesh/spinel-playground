require 'zlib'
require 'fileutils'
require 'open3'
require 'json'
repo=File.expand_path(__dir__)
repo=File.dirname(repo) until File.file?(File.join(repo,'scripts/lib/byte-comparison.rb')) || File.dirname(repo)==repo
require File.join(repo,'scripts/lib/byte-comparison.rb')
tool,field,arg,presence,work=ARGV
abort 'usage: mutations TOOL FIELD_GZ ARG_GZ PRESENCE_GZ WORK' unless work
FileUtils.mkdir_p(work)
fixtures=[field,arg,presence].each_with_index.map do |path,i|
  target=File.join(work,"facts-#{i}.mlir")
  File.binwrite(target,Zlib::GzipReader.open(path,&:read));target
end
rows=[]
[
  ['signed-base',0,0,'expected=[-2147483648, 2147483647] observed=[-2147483648, 2147483647] range-difference=0'],
  ['signed-unsigned',0,1,'expected=[-2147483648, 2147483647] observed=[0, 4294967295] range-difference=1'],
  ['u16-base',1,0,'expected=[0, 65535] observed=[0, 65535] range-difference=0'],
  ['u16-full-i64',1,1,'expected=[0, 65535] observed=[-9223372036854775808, 9223372036854775807] range-difference=1'],
  ['presence-base',2,0,'expected-checks=1 observed-checks=1 unchecked-casts=0 structure-difference=0'],
  ['presence-omitted',2,1,'expected-checks=1 observed-checks=0 unchecked-casts=1 structure-difference=1']
].each do |mode,index,rc,observation|
  command=[tool,fixtures[index],mode]
  stdout,stderr,status=Open3.capture3(*command)
  File.binwrite(File.join(work,mode+'.stdout'),stdout)
  File.binwrite(File.join(work,mode+'.stderr'),stderr)
  rows<<{mode:mode,argv:command,rc:status.exitstatus,signal:status.termsig,observation:observation}
  File.write(File.join(work,'ledger.json'),JSON.pretty_generate(rows)+"\n")
  abort 'mutation control '+mode+' failed' unless status.exitstatus==rc && !status.signaled? &&
    ByteComparison.equal?(stdout,"#{mode} #{observation}\n")
end
puts 'kernel mutations 3/3 named differences; baselines 3/3 GREEN'
