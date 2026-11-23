#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
oracle,clone,producer,verifier,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: capture-bcc-facts ORACLE CLONE PRODUCER VERIFIER FRESH_OUT' unless out
abort 'fresh output' if File.exist?(out)
repo=File.expand_path('..',__dir__);sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'M3 hash' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
builtins=File.expand_path('../builtins',File.dirname(producer))
expected=JSON.parse(File.read(repo+'/docs/experiments/results/E040/builtins-sha256.json'))
actual=Dir[builtins+'/**/*'].select{|p|File.file?(p)}.to_h{|p|[p.delete_prefix(builtins+'/'),sha.call(p)]}
abort 'builtins closure' unless expected==actual
records=JSON.parse(File.read(oracle+'/manifest.json')).fetch('cases');abort '21 positive' unless records.size==21&&records.all?{|r|r['kind']=='positive'}
ctx={'tracepoint'=>'TracepointCtx','kprobe'=>'KprobeCtx','kretprobe'=>'KretprobeCtx','tp_btf'=>'TpBtfCtx','ksyscall'=>'KsyscallCtx','fentry'=>'FentryCtx','fexit'=>'FexitCtx','raw_tp'=>'RawTpCtx'}
library=JSON.parse(File.read(repo+'/docs/experiments/results/E003/inputs-and-library.json')).fetch('ruby_lib')
FileUtils.mkdir_p(out)
library.each do |path,hash|
  abort 'library source' unless sha.call(clone+'/'+path)==hash
  target=out+'/source/'+path;FileUtils.mkdir_p(File.dirname(target));FileUtils.cp(clone+'/'+path,target)
end
prepared=records.map do |row|
  dir=oracle+'/'+row.fetch('raw_dir');stem=File.basename(row.fetch('source'),'.rb')
  source=dir+'/'+stem+'.rb';abort 'source hash' unless sha.call(source)==row.fetch('source_sha256')
  schema=dir+'/'+stem+'.schema.json';programs=JSON.parse(File.read(schema)).fetch('core').fetch('programs')
  declarations=File.readlines(source).filter_map{|line|m=line.match(/^BPF\.(tracepoint|kprobe|kretprobe|tp_btf|ksyscall|fentry|fexit|raw_tp)\s+:([A-Za-z_]\w*)/);m&&[m[2],m[1]]}
  abort 'declaration/schema root set' unless declarations.sort==programs.map{|p|[p.fetch('name'),p.fetch('kind')]}.sort
  roots=declarations.map{|name,kind|name+':obj_BPF::'+ctx.fetch(kind)}
  abort 'root empty/duplicate' if roots.empty?||roots.uniq.size!=roots.size
  target=out+'/source/'+row.fetch('source');FileUtils.mkdir_p(File.dirname(target));FileUtils.cp(source,target)
  row.merge('source_path'=>target,'schema_sha256'=>sha.call(schema),'roots'=>roots)
end
File.write(out+'/inputs.json',JSON.pretty_generate({producer_sha256:sha.call(producer),verifier_sha256:sha.call(verifier),library:library,builtins:expected,cases:prepared})+"\n")
ledger=[];plan=[]
prepared.each do |row|
  dir=out+'/cases/'+row.fetch('id');FileUtils.mkdir_p(dir+'/tmp');facts=dir+'/facts.mlir'
  argv=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts,*row.fetch('roots').map{|r|'--analysis-root='+r},row.fetch('source_path')]
  so,se,status=Open3.capture3({'TMPDIR'=>dir+'/tmp','LC_ALL'=>'C'},*argv,chdir:out+'/source')
  File.binwrite(dir+'/producer.stdout',so);File.binwrite(dir+'/producer.stderr',se)
  result=row.merge('argv'=>argv,'rc'=>status.exitstatus,'signal'=>status.termsig,'facts'=>facts,'bytes'=>File.size?(facts).to_i)
  ledger<<result
  if status.success?&&so.empty?&&result['bytes']>0
    vo,ve,vs=Open3.capture3(verifier,'--verify-only',facts)
    File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
    result.merge!('verify_rc'=>vs.exitstatus,'verify_signal'=>vs.termsig,'sha256'=>sha.call(facts))
    plan<<result.slice('id','facts','sha256') if vs.success?
  end
  File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
end
File.write(out+'/consumer-plan.json',JSON.pretty_generate(plan)+"\n")
File.write(out+'/continue-cases.json',JSON.pretty_generate(plan.map{|r|r.fetch('id')})+"\n")
File.write(out+'/groups.md',prepared.map{|r|'|H|`'+r.fetch('source')+'`|'}.join("\n")+"\n")
contract={version:1,corpus:'bcc-wave1',positive:21,negative:0,oracle_manifest_sha256:sha.call(oracle+'/manifest.json'),cases:records.map{|r|r.slice('id','source','source_sha256')}}
File.write(out+'/corpus-contract.json',JSON.pretty_generate(contract)+"\n")
puts JSON.generate({observed:ledger.size,producer_rc:ledger.map{|r|r['rc']}.tally,verified:plan.size})
