#!/usr/bin/env ruby
# Capture only; comparison remains in measure-union.rb / batch-compare.rb.
require 'json'; require 'digest'; require 'fileutils'; require 'open3'
inventory_path,roots_path,clone,producer,verifier,out,mode=ARGV
abort 'usage: capture-release-facts INVENTORY ROOTS CLONE PRODUCER VERIFIER FRESH_OUT [--plan-only]' unless out && (mode.nil? || mode=='--plan-only')
inventory_path,roots_path,clone,producer,verifier,out=[inventory_path,roots_path,clone,producer,verifier,out].map { |p| File.expand_path(p) }
abort 'fresh output required' if File.exist?(out)
repo=File.expand_path('..',__dir__)
require_relative 'lib/release-corpus'
sha=->(p) { Digest::SHA256.file(p).hexdigest }
j=JSON.parse(File.binread(inventory_path));root_plan=JSON.parse(File.binread(roots_path))
abort 'inventory source set changed' unless ReleaseCorpus.inventory(clone,j.fetch('oracle_commit'),j.fetch('corpus'))==j
abort 'roots ID set' unless root_plan.keys.sort==j.fetch('cases').map { |r| r.fetch('id') }.sort
abort 'producer hash' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
abort 'tools executable' unless [producer,verifier,'/usr/bin/timeout'].all? { |p| File.executable?(p) }
builtins=File.expand_path('../builtins',File.dirname(producer))
expected=JSON.parse(File.binread(repo+'/docs/experiments/results/E040/builtins-sha256.json'))
actual=Dir[builtins+'/**/*'].select { |p| File.file?(p) }.sort.to_h { |p| [p.delete_prefix(builtins+'/'),sha.call(p)] }
abort 'builtins closure' unless expected==actual
library=Dir[clone+'/ruby/lib/**/*'].select { |p| File.file?(p) }.sort.to_h { |p| [p.delete_prefix(clone+'/ruby/lib/'),sha.call(p)] }
abort 'library empty' if library.empty?
cases=j.fetch('cases').map do |r|
  roots=root_plan.fetch(r.fetch('id'))
  abort 'invalid root profile' unless roots.is_a?(Array) && roots.uniq==roots && roots.size<=16 && roots.all? { |x| x.match?(/\A[A-Za-z_]\w*:obj_BPF::\w+\z/) }
  r.merge('roots'=>roots)
end
FileUtils.mkdir_p(out+'/source/ruby/lib')
FileUtils.cp_r(clone+'/ruby/lib/.',out+'/source/ruby/lib')
cases.each do |r|
  target=out+'/source/'+r.fetch('source');FileUtils.mkdir_p(File.dirname(target))
  if r.key?('derived_content');File.binwrite(target,r.fetch('derived_content'))
  else
    FileUtils.copy_file(clone+'/'+r.fetch('source'),target)
    dependency=File.dirname(clone+'/'+r.fetch('source'))+'/target'
    FileUtils.cp_r(dependency,File.dirname(target)) if File.directory?(dependency) && !File.exist?(File.dirname(target)+'/target')
  end
  abort 'source copy hash' unless sha.call(target)==r.fetch('source_sha256')
end
File.write(out+'/inputs.json',JSON.pretty_generate({inventory_sha256:sha.call(inventory_path),roots_sha256:sha.call(roots_path),producer:producer,producer_sha256:sha.call(producer),verifier:verifier,verifier_sha256:sha.call(verifier),library:library,builtins:expected,cases:cases})+"\n")
if mode=='--plan-only';puts JSON.generate({planned:cases.size,executed:0});exit;end
ledger=[];plan=[]
cases.each do |r|
  id=r.fetch('id');source=out+'/source/'+r.fetch('source')
  if id=='internal_frontend_testdata_neg_require_relative'
    execution={kind:'source_pipeline',source:source,source_sha256:r.fetch('source_sha256'),producer:producer,producer_sha256:sha.call(producer),library:out+'/source/ruby/lib',library_sha256:library,builtins:builtins,builtins_sha256:actual,roots:r.fetch('roots')}
    plan<<{id:id,facts:nil,execution:execution};ledger<<r.merge('execution'=>'source_pipeline-deferred-to-measure')
  else
    dir=out+'/cases/'+id;FileUtils.mkdir_p(dir+'/tmp');facts=dir+'/facts.mlir'
    argv=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts,*r.fetch('roots').map { |x| '--analysis-root='+x },source]
    so,se,s=Open3.capture3({'TMPDIR'=>dir+'/tmp'},*argv,chdir:out+'/source')
    File.binwrite(dir+'/producer.stdout',so);File.binwrite(dir+'/producer.stderr',se)
    row=r.merge('argv'=>argv,'rc'=>s.exitstatus,'signal'=>s.termsig,'facts'=>facts,'bytes'=>File.size?(facts).to_i)
    ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    abort 'STOP producer '+id unless s.success? && !s.termsig && so.empty? && row['bytes']>0
    vo,ve,vs=Open3.capture3(verifier,'--verify-only',facts)
    File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
    row.merge!('verify_rc'=>vs.exitstatus,'verify_signal'=>vs.termsig,'sha256'=>sha.call(facts))
    File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    abort 'STOP verify '+id unless vs.success? && !vs.termsig
    plan<<row.slice('id','facts','sha256')
  end
  File.write(out+'/consumer-plan.json',JSON.pretty_generate(plan)+"\n")
  puts id; $stdout.flush
end
File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
puts JSON.generate({total:ledger.size,facts:plan.count { |r| r[:facts] || r['facts'] },source_pipeline:plan.count { |r| r[:execution] }})
