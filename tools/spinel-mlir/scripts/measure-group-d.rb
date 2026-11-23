#!/usr/bin/env ruby
# E030: acquire a candidate v2; comparison belongs to batch-compare.rb.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'lib/compile-warnings'
repo,supply,consumer,compiler,out=ARGV
abort 'usage: measure-group-d REPO FIXED_SUPPLY CONSUMER COMPILER FRESH_OUT' unless out
repo,supply,consumer,compiler,out=[repo,supply,consumer,compiler,out].map{|p|File.expand_path(p)}
abort 'candidate-output-exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
inputs=JSON.parse(File.read(supply+'/ledger.json'))
abort 'candidate-input-coverage' unless inputs.size==76 && inputs.map{|r|r.fetch('id')}.uniq.size==76 && inputs.count{|r|r.fetch('kind')=='positive'}==18
oracle=JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases').to_h{|r|[r.fetch('id'),r]}
inputs.each do |r|
  abort 'candidate-supply-failure' unless r.fetch('supply_success') && r.fetch('rc')==0 && r.fetch('verify_rc')==0 && File.size?(r.fetch('facts'))
  abort 'candidate-facts-hash' unless sha.call(r.fetch('facts'))==r.fetch('facts_sha256')
  c=oracle.fetch(r.fetch('id'))
  abort 'candidate-source-identity' unless %w[source source_sha256 kind].all?{|key|c.fetch(key)==r.fetch(key)}
end
FileUtils.mkdir_p(out+'/tools')
tool_hashes={}
{consumer:consumer,compiler:compiler}.each do |name,path|
  abort 'candidate-tool-missing' unless File.executable?(path)
  tool_hashes[name]=sha.call(path)
  FileUtils.copy_file(path,out+'/tools/'+name.to_s);File.chmod(0755,out+'/tools/'+name.to_s)
  abort 'candidate-tool-copy-hash' unless sha.call(out+'/tools/'+name.to_s)==tool_hashes[name] && sha.call(path)==tool_hashes[name]
end
o,e,s=Open3.capture3(out+'/tools/compiler','--version')
File.binwrite(out+'/compiler-version.stdout',o);File.binwrite(out+'/compiler-version.stderr',e)
abort 'candidate-compiler-pin' unless s.success? && o.include?('99d631a57738730dc9710e656f21e41a0f67da23')
File.write(out+'/inputs.json',JSON.pretty_generate({supply_ledger_sha256:sha.call(supply+'/ledger.json'),tools:tool_hashes,cases:inputs})+"\n")
entries=[];ledger=[]
inputs.each do |input|
  id=input.fetch('id');c=oracle.fetch(id);stem=File.basename(c.fetch('source'),'.rb')
  dir=out+'/runs/'+id;target=out+'/cases/'+id;FileUtils.mkdir_p(dir);FileUtils.mkdir_p(target)
  args=['/usr/bin/timeout','--kill-after=5s','60s',out+'/tools/consumer','--emit-dir',dir+'/artifacts',input.fetch('facts')]
  stdout,stderr,status=Open3.capture3(*args)
  File.binwrite(dir+'/consumer.stdout',stdout);File.binwrite(dir+'/consumer.stderr',stderr)
  row={id:id,kind:c.fetch('kind'),argv:args,rc:status.exitstatus,signal:status.termsig,facts_sha256:input.fetch('facts_sha256'),stdout_bytes:stdout.bytesize,stderr_bytes:stderr.bytesize}
  File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
  File.binwrite(target+'/build.stdout',stdout);File.binwrite(target+'/build.stderr',stderr)
  if File.directory?(dir+'/artifacts')
    Dir[dir+'/artifacts/*'].sort.each do |file|
      suffix=File.basename(file).delete_prefix('xdpcount.')
      FileUtils.copy_file(file,target+'/'+stem+'.'+suffix)
    end
  end
  if c.fetch('kind')=='positive' && status.success?
    abort 'STOP candidate-success-stdout' unless stdout.empty?
    %w[mlir schema.json maps.json].each{|ext|abort 'STOP candidate-empty-artifact' unless File.size?(target+'/'+stem+'.'+ext)}
    command=['/usr/bin/timeout','--kill-after=5s','60s',out+'/tools/compiler',stem+'.mlir','--schema',stem+'.schema.json','--line-info=auto','-o',stem+'.bpf.o']
    co,ce,cs=Open3.capture3(*command,chdir:target)
    File.binwrite(dir+'/compile.stdout',co);File.binwrite(dir+'/compile.stderr',ce)
    row[:compile]={argv:command,cwd:target,rc:cs.exitstatus,signal:cs.termsig,stdout_bytes:co.bytesize,stderr_bytes:ce.bytesize}
    File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
    abort 'STOP candidate-warning-compile-failed' unless cs.success? && File.size?(target+'/'+stem+'.bpf.o')
    File.binwrite(target+'/'+stem+'.compile_warnings.txt',ce)
    warning=CompileWarnings.render(co,ce)
    File.binwrite(dir+'/sb021.stderr',warning)
    File.binwrite(target+'/build.stderr',CompileWarnings.combine(stderr,warning))
    row[:sb021]=warning.lines.size
  end
  File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
  entries<<{id:id,source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),producer_rc:status.exitstatus,dir:'cases/'+id}
  ledger<<row
  File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
  File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  abort 'STOP candidate-abnormal-process' if status.termsig || ![0,1].include?(status.exitstatus)
end
puts JSON.generate({captured:ledger.size,positive:ledger.select{|c|c[:kind]=='positive'}.map{|c|c[:rc]}.tally,negative:ledger.select{|c|c[:kind]=='negative'}.map{|c|c[:rc]}.tally})
