#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
repo,oracle,producer,verifier,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: capture-uprobe-facts REPO ADDITIONAL_ORACLE PRODUCER VERIFIER FRESH_OUT' unless out
abort 'facts-output-exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'facts-producer-hash' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
base=repo+'/docs/experiments/results/E003/'
fixed=JSON.parse(File.read(base+'capture/manifest.json')).fetch('cases').to_h{|c|[c.fetch('id'),c]}
additional=JSON.parse(File.read(oracle+'/manifest.json'))
plan=additional.fetch('cases').map{|c|c.merge('original'=>oracle+'/'+c.fetch('raw_dir')+'/'+File.basename(c.fetch('source')),'target'=>oracle+'/'+c.fetch('raw_dir')+'/target/cfix','scope'=>'additional-positive')}
names=%w[neg_abs_path neg_dotdot_path neg_missing_file neg_undeclared_n neg_arg_on_user_str neg_str_local neg_str_to_map]
selected=names.map{|n|fixed.fetch('internal_frontend_testdata_uprobe_'+n)}+[fixed.fetch('examples_greetwatch_greetwatch')]
selected.each do |c|
  dir=base+'capture/'+c.fetch('raw_dir')
  target=c.fetch('kind')=='positive' ? dir+'/target/greeter' : oracle+'/positive/up_ints/target/cfix'
  plan<<c.merge('original'=>dir+'/'+File.basename(c.fetch('source')),'target'=>target,'scope'=>c.fetch('kind')=='positive' ? 'E039-dependent' : 'fixed-negative')
end
library=JSON.parse(File.read(base+'inputs-and-library.json')).fetch('ruby_lib')
library.each{|rel,hash|abort 'facts-library-hash' unless sha.call(base+'ruby-lib/'+rel.delete_prefix('ruby/lib/'))==hash}
plan.each do |c|
  abort 'facts-source-hash' unless sha.call(c.fetch('original'))==c.fetch('source_sha256')
  c['target_sha256']=sha.call(c.fetch('target'))
  c['roots']=File.readlines(c.fetch('original')).filter_map do |l|
    m=l.match(/^BPF\.(uprobe|uretprobe)\s+:([A-Za-z_]\w*),/)
    m && m[2]+':obj_BPF::'+(m[1]=='uprobe' ? 'UprobeCtx' : 'UretprobeCtx')
  end
  abort 'facts-root-missing' if c['roots'].empty?
end
abort 'facts-case-set' unless plan.size==12 && plan.map{|c|c['id']}.uniq.size==12
FileUtils.mkdir_p(out+'/source')
library.each do |rel,_|
  target=out+'/source/'+rel;FileUtils.mkdir_p(File.dirname(target));FileUtils.cp(base+'ruby-lib/'+rel.delete_prefix('ruby/lib/'),target)
end
File.write(out+'/plan.json',JSON.pretty_generate({producer:{path:producer,sha256:sha.call(producer)},verifier:{path:verifier,sha256:sha.call(verifier)},library:library,cases:plan})+"\n")
ledger=[]
plan.each do |c|
  dir=out+'/cases/'+c.fetch('id');FileUtils.mkdir_p(dir+'/source/target')
  source=dir+'/source/'+File.basename(c.fetch('source'));FileUtils.cp(c.fetch('original'),source)
  target=dir+'/source/target/'+File.basename(c.fetch('target'));FileUtils.cp(c.fetch('target'),target)
  abort 'facts-target-hash' unless sha.call(target)==c.fetch('target_sha256')
  facts=dir+'/facts.mlir'
  args=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts]+c.fetch('roots').map{|r|'--analysis-root='+r}+[source]
  o,e,s=Open3.capture3({'TMPDIR'=>dir},*args,chdir:dir+'/source')
  File.binwrite(dir+'/producer.stdout',o);File.binwrite(dir+'/producer.stderr',e)
  row={id:c.fetch('id'),scope:c.fetch('scope'),source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),kind:c.fetch('kind'),argv:args,rc:s.exitstatus,signal:s.termsig,facts:facts,bytes:File.size?(facts).to_i,target:target,target_sha256:c.fetch('target_sha256')}
  if s.success? && o.empty? && row[:bytes]>0
    vo,ve,vs=Open3.capture3(verifier,'--verify-only',facts)
    File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
    row.merge!(verify_rc:vs.exitstatus,verify_signal:vs.termsig,facts_sha256:sha.call(facts))
  end
  row[:supply_success]=s.success? && row[:verify_rc]==0 && row[:verify_signal].nil? && row[:bytes]>0
  File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  puts JSON.generate(row.slice(:id,:rc,:verify_rc,:bytes,:supply_success))
end
abort 'STOP uprobe-facts-supply' unless ledger.all?{|r|r[:supply_success]}
