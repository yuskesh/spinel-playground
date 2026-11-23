#!/usr/bin/env ruby
# E025: one ready example, saved facts, no producer rerun.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: measure-example REPO ID FACTS EXPECTED_SHA FRESH_OUT' unless ARGV.size==5
repo,id,facts,want,out=ARGV
repo,facts,out=[repo,facts,out].map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'facts hash mismatch' unless sha.call(facts)==want
cases=JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases')
record=cases.find{|c|c.fetch('id')==id}
abort 'not a positive example' unless record && record.fetch('kind')=='positive' && record.fetch('source').start_with?('examples/')
FileUtils.mkdir_p(out+'/tools')
tool=out+'/tools/spinel-mlir'
FileUtils.copy_file(repo+'/build/bin/spinel-mlir',tool);File.chmod(0755,tool)
FileUtils.copy_file(facts,out+'/facts.mlir')
abort 'facts copy changed' unless sha.call(out+'/facts.mlir')==want
argv=['/usr/bin/timeout','--kill-after=5s','60s',tool,'--emit-dir',out+'/artifacts',out+'/facts.mlir']
stdout,stderr,status=Open3.capture3(*argv)
File.binwrite(out+'/build.stdout',stdout);File.binwrite(out+'/build.stderr',stderr)
row={id:id,source:record.fetch('source'),source_sha256:record.fetch('source_sha256'),
     facts_origin:facts,facts_sha256:want,consumer_sha256:sha.call(tool),
     tree:Open3.capture2('git','-C',repo,'rev-parse','HEAD').first.strip,
     argv:argv,rc:status.exitstatus,signal:status.termsig,
     stdout_bytes:stdout.bytesize,stderr_bytes:stderr.bytesize,
     artifacts:Dir[out+'/artifacts/*'].to_h{|p|[File.basename(p),{bytes:File.size(p),sha256:sha.call(p)}]}}
File.write(out+'/ledger.json',JSON.pretty_generate(row)+"\n")
unless status.success? && stdout.empty? && row[:artifacts].size==3 && row[:artifacts].values.all?{|a|a[:bytes]>0}
  File.write(out+'/stop.txt',"STOP positive example: rc/three nonempty artifacts\n")
  warn "STOP #{id}: rc=#{status.exitstatus}";exit 1
end
target=out+'/cases/'+id;FileUtils.mkdir_p(target)
%w[build.stdout build.stderr].each{|p|FileUtils.copy_file(out+'/'+p,target+'/'+p)}
stem=File.basename(record.fetch('source'),'.rb')
Dir[out+'/artifacts/*'].each do |p|
  FileUtils.copy_file(p,target+'/'+stem+'.'+File.basename(p).delete_prefix('xdpcount.'))
end
File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:[{
  id:id,source:record.fetch('source'),source_sha256:record.fetch('source_sha256'),
  producer_rc:status.exitstatus,dir:'cases/'+id}]})+"\n")
puts "captured #{id}: rc0, three nonempty artifacts; comparison pending"
