#!/usr/bin/env ruby
# E030: all roots in one M3 run; source/library are the E003 frozen bytes.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
repo,producer,verifier,out,mode=ARGV
abort 'usage: capture-group-d REPO PRODUCER VERIFIER FRESH_OUT [--inventory-only]' unless out && (mode.nil? || mode=='--inventory-only')
repo,producer,verifier,out=[repo,producer,verifier,out].map{|p|File.expand_path(p)}
abort 'capture-output-exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'capture-producer-hash' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
abort 'capture-tool-missing' unless [producer,verifier,'/usr/bin/timeout'].all?{|p|File.executable?(p)}
base=repo+'/docs/experiments/results/E003/'
oracle=JSON.parse(File.read(base+'capture/manifest.json')).fetch('cases').to_h{|c|[c.fetch('id'),c]}
selection=%w[positive negative].flat_map do |kind|
  rows=JSON.parse(File.read(repo+'/docs/experiments/results/E030/selection/'+kind+'.json'))
  abort 'capture-selection-count' unless rows.size==(kind=='positive' ? 18 : 58)
  rows.map{|c|c.merge('kind'=>kind)}
end
abort 'capture-selection-duplicate' unless selection.map{|c|c.fetch('id')}.uniq.size==76
plan=selection.map do |c|
  expected=oracle.fetch(c.fetch('id'))
  abort 'capture-source-identity' unless %w[source source_sha256 kind].all?{|k|c.fetch(k)==expected.fetch(k)}
  original=base+'capture/'+expected.fetch('raw_dir')+'/'+File.basename(c.fetch('source'))
  abort 'capture-source-hash' unless sha.call(original)==c.fetch('source_sha256')
  declarations=File.readlines(original).select{|l|l.match?(/^BPF\.(xdp|tcx|flow_dissector)\b/)}
  roots=declarations.map do |line|
    m=line.match(/^BPF\.xdp\s+:([A-Za-z_]\w*)\s*$/)
    abort 'capture-unrequestable-root: '+c.fetch('id') unless m
    {method:m[1],kind:'xdp',type:'obj_BPF::XdpMd',request:m[1]+':obj_BPF::XdpMd'}
  end
  abort 'capture-no-root: '+c.fetch('id') if roots.empty?
  c.merge('original'=>original,'roots'=>roots,'reuse'=>false,'reuse_boundary'=>'E008 M1+M2 single-root / E013 profile differs; obtain fixed M3 all-roots once')
end
library=JSON.parse(File.read(base+'inputs-and-library.json')).fetch('ruby_lib')
library.each do |relative,expected|
  abort 'capture-library-path' unless relative.start_with?('ruby/lib/') && !relative.split('/').include?('..')
  file=base+'ruby-lib/'+relative.delete_prefix('ruby/lib/')
  abort 'capture-library-hash: '+relative unless sha.call(file)==expected
end
FileUtils.mkdir_p(out)
File.write(out+'/plan.json',JSON.pretty_generate({producer:{path:producer,sha256:sha.call(producer)},verifier:{path:verifier,sha256:sha.call(verifier)},library:library,cases:plan})+"\n")
if mode=='--inventory-only'
  puts JSON.generate({inputs:plan.size,positive:18,negative:58,roots:plan.sum{|c|c.fetch('roots').size},new_execution:0})
  exit 0
end
library.each do |relative,_|
  target=out+'/source/'+relative;FileUtils.mkdir_p(File.dirname(target))
  FileUtils.copy_file(base+'ruby-lib/'+relative.delete_prefix('ruby/lib/'),target)
end
plan.each do |c|
  target=out+'/source/'+c.fetch('source');FileUtils.mkdir_p(File.dirname(target));FileUtils.copy_file(c.fetch('original'),target)
end
ledger=[]
plan.each do |c|
  dir=out+'/cases/'+c.fetch('id');FileUtils.mkdir_p(dir)
  facts=dir+'/facts.mlir'
  argv=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts]+c.fetch('roots').map{|r|'--analysis-root='+r.fetch(:request)}+[out+'/source/'+c.fetch('source')]
  o,e,s=Open3.capture3(*argv,chdir:out+'/source')
  File.binwrite(dir+'/producer.stdout',o);File.binwrite(dir+'/producer.stderr',e)
  row={id:c.fetch('id'),kind:c.fetch('kind'),source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),argv:argv,cwd:out+'/source',rc:s.exitstatus,signal:s.termsig,stdout_bytes:o.bytesize,facts:facts,facts_bytes:File.file?(facts) ? File.size(facts) : 0}
  if row[:rc]==0 && !s.termsig && o.empty? && row[:facts_bytes]>0
    row[:facts_sha256]=sha.call(facts)
    vout,verr,vs=Open3.capture3(verifier,'--verify-only',facts)
    File.binwrite(dir+'/verify.stdout',vout);File.binwrite(dir+'/verify.stderr',verr)
    row.merge!(verify_rc:vs.exitstatus,verify_signal:vs.termsig)
  end
  row[:supply_success]=row[:rc]==0 && row[:signal].nil? && row[:facts_bytes]>0 && row[:verify_rc]==0 && row[:verify_signal].nil?
  File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  puts JSON.generate(row.slice(:id,:rc,:verify_rc,:facts_bytes,:supply_success))
end
summary={total:ledger.size,success:ledger.count{|c|c[:supply_success]},failed:ledger.reject{|c|c[:supply_success]}.map{|c|c[:id]}}
File.write(out+'/summary.json',JSON.pretty_generate(summary)+"\n")
abort 'STOP group-D-facts-supply' unless summary[:success]==76
