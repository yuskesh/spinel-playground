#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: capture-packet-diagnostics TOOLS VERIFIER FRESH_OUT [--plan-only]' unless (3..4).cover?(ARGV.size)
tools,verifier,out=ARGV.take(3).map { |p| File.expand_path(p) }
plan_only=ARGV[3]=='--plan-only'
repo=File.expand_path('..',__dir__)
abort 'fresh output required' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
producer=tools+'/bin/spinel'
abort 'M3 hash' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
builtins=JSON.parse(File.read(repo+'/docs/experiments/results/E040/builtins-sha256.json'))
abort 'builtins set' unless Dir[tools+'/builtins/*'].map { |p| File.basename(p) }.sort==builtins.keys.sort
builtins.each { |p,h| abort 'builtins hash' unless sha.call(tools+'/builtins/'+p)==h }
base=repo+'/docs/experiments/results/E003/'
inventory=repo+'/docs/experiments/results/E042/inventory.json'
abort 'inventory hash' unless sha.call(inventory)=='b4d6883b5208dcf461da46c18d19882cbc555cbffc14ed7da24a8707b3cf5df8'
features=['packet root の arity / direction 診断','packet context の非対応 call / setter 診断','program 末尾の kind 別 verdict 診断','packet-adjust status-placement diagnostics','packet check の condition 内代入診断','socket-filter wrong-verdict precheck']
oracle=JSON.parse(File.read(base+'capture/manifest.json')).fetch('cases').to_h { |r| [r.fetch('id'),r] }
selected=JSON.parse(File.read(inventory)).fetch('cases').select { |r| features.include?(r.fetch('feature')) }
types={'xdp'=>'XdpMd','tcx'=>'SkBuff','cgroup_skb'=>'CgroupSkb','flow_dissector'=>'FlowCtx','socket_filter'=>'SocketFilterCtx','sk_lookup'=>'SkLookupCtx','netfilter'=>'NfCtx'}
plan=selected.map do |r|
  c=oracle.fetch(r.fetch('id'));dir=base+'capture/'+c.fetch('raw_dir')
  source=dir+'/'+File.basename(c.fetch('source'))
  abort 'source hash' unless sha.call(source)==c.fetch('source_sha256')
  text=File.read(source)
  declarations=text.lines.filter_map { |line| m=line.match(/^BPF\.(\w+)\s+:([A-Za-z_]\w*)/);m && [m[1],m[2]] }
  abort 'explicit root missing' if declarations.empty?
  roots=declarations.map { |kind,name| name+':obj_BPF::'+types.fetch(kind) }.uniq
  c.merge('original'=>source,'roots'=>roots,'feature'=>r.fetch('feature'),'oracle_stderr_sha256'=>sha.call(dir+'/build.stderr'),'reuse'=>false)
end
abort 'selection coverage' unless plan.size==30 && plan.map { |r|r.fetch('id') }.uniq.size==30
library=JSON.parse(File.read(base+'inputs-and-library.json')).fetch('ruby_lib')
library.each { |p,h| abort 'library hash' unless sha.call(base+'ruby-lib/'+p.delete_prefix('ruby/lib/'))==h }
FileUtils.mkdir_p(out)
File.write(out+'/plan.json',JSON.pretty_generate({producer_sha256:sha.call(producer),builtins:builtins,verifier_sha256:sha.call(verifier),library:library,cases:plan})+"\n")
if plan_only
  puts JSON.generate({planned:30,executed:0});exit
end
library.each do |p,_|
  target=out+'/source/'+p;FileUtils.mkdir_p(File.dirname(target));FileUtils.cp(base+'ruby-lib/'+p.delete_prefix('ruby/lib/'),target)
end
ledger=[]
plan.each do |r|
  dir=out+'/cases/'+r.fetch('id');FileUtils.mkdir_p(dir)
  source=dir+'/'+File.basename(r.fetch('source'));FileUtils.cp(r.fetch('original'),source)
  facts=dir+'/facts.mlir'
  command=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts]+r.fetch('roots').map { |root| '--analysis-root='+root }+[source]
  so,se,s=Open3.capture3(*command)
  File.binwrite(dir+'/producer.stdout',so);File.binwrite(dir+'/producer.stderr',se)
  row=r.merge('command'=>command,'rc'=>s.exitstatus,'signal'=>s.termsig,'facts'=>facts,'bytes'=>File.size?(facts).to_i)
  if s.success? && row['bytes']>0
    vo,ve,vs=Open3.capture3(verifier,'--verify-only',facts)
    File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
    row.merge!('verify_rc'=>vs.exitstatus,'verify_signal'=>vs.termsig,'sha256'=>sha.call(facts))
  end
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  abort 'STOP packet diagnostic facts: '+r.fetch('id') unless s.success? && so.empty? && row['bytes']>0 && row['verify_rc']==0 && !row['verify_signal']
end
puts JSON.generate({captured:ledger.size,producer_rc:ledger.map { |r|r.fetch('rc') }.tally})
