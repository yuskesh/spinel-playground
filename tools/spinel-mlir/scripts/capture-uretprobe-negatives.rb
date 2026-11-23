#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
tools, verifier, target, out, mode = ARGV
abort 'usage: capture-uretprobe-negatives TOOLS VERIFIER CFIX FRESH_OUT [--plan-only]' unless out && (!mode || mode == '--plan-only')
tools, verifier, target, out = [tools,verifier,target,out].map { |p| File.expand_path(p) }
repo = File.expand_path('..',__dir__)
abort 'fresh output required' if File.exist?(out)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
producer = tools+'/bin/spinel'
abort 'producer hash' unless sha.call(producer) == 'b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
abort 'cfix hash' unless sha.call(target) == 'a5808d550a0cc8c15e30df9ba2d5659574db67d624a44c514c2909233a5ab140'
builtins = JSON.parse(File.read(repo+'/docs/experiments/results/E040/builtins-sha256.json'))
abort 'builtins closure' unless Dir[tools+'/builtins/*'].map { |p| File.basename(p) }.sort == builtins.keys.sort
builtins.each { |name,hash| abort 'builtin hash' unless sha.call(tools+'/builtins/'+name) == hash }
base = repo+'/docs/experiments/results/E003/'
library = JSON.parse(File.read(base+'inputs-and-library.json')).fetch('ruby_lib')
library.each { |path,hash| abort 'library hash' unless sha.call(base+'ruby-lib/'+path.delete_prefix('ruby/lib/')) == hash }
oracle = JSON.parse(File.read(base+'capture/manifest.json')).fetch('cases').to_h { |r| [r.fetch('id'),r] }
plan = %w[abs_path arg dotdot missing_file str_arg].map do |name|
  row = oracle.fetch('internal_frontend_testdata_uprobe_neg_uret_'+name)
  source = base+'capture/'+row.fetch('raw_dir')+'/'+File.basename(row.fetch('source'))
  abort 'source hash' unless sha.call(source) == row.fetch('source_sha256')
  roots = File.readlines(source).filter_map { |line| m=line.match(/^BPF\.uretprobe\s+:([A-Za-z_]\w*),/);m && m[1]+':obj_BPF::UretprobeCtx' }
  abort 'explicit root' unless roots == ['on_r:obj_BPF::UretprobeCtx']
  row.merge('original'=>source,'roots'=>roots)
end
FileUtils.mkdir_p(out)
File.write(out+'/plan.json',JSON.pretty_generate({producer:producer,producer_sha256:sha.call(producer),verifier_sha256:sha.call(verifier),target:target,target_sha256:sha.call(target),builtins:builtins,library:library,cases:plan})+"\n")
if mode
  puts 'planned5/executed0: source/library/builtins/producer/target hashes verified'
  exit
end
library.each do |path,hash|
  to=out+'/source/'+path;FileUtils.mkdir_p(File.dirname(to));FileUtils.cp(base+'ruby-lib/'+path.delete_prefix('ruby/lib/'),to)
  abort 'copied library' unless sha.call(to)==hash
end
ledger=[]
plan.each do |row|
  dir=out+'/cases/'+row.fetch('id');FileUtils.mkdir_p(dir+'/source/target');FileUtils.mkdir_p(dir+'/tmp')
  source=dir+'/source/'+File.basename(row.fetch('source'));FileUtils.cp(row.fetch('original'),source)
  binary=dir+'/source/target/cfix';FileUtils.cp(target,binary)
  abort 'copied inputs' unless sha.call(source)==row.fetch('source_sha256') && sha.call(binary)==sha.call(target) && !File.exist?(dir+'/source/target/nope')
  facts=dir+'/facts.mlir'
  argv=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts,*row.fetch('roots').map { |r| '--analysis-root='+r },source]
  so,se,status=Open3.capture3({'TMPDIR'=>dir+'/tmp'},*argv,chdir:dir+'/source')
  File.binwrite(dir+'/producer.stdout',so);File.binwrite(dir+'/producer.stderr',se)
  result=row.merge('argv'=>argv,'cwd'=>dir+'/source','rc'=>status.exitstatus,'signal'=>status.termsig,'facts'=>facts,'bytes'=>File.size?(facts).to_i,'target'=>binary,'target_sha256'=>sha.call(binary))
  ledger<<result;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  abort 'STOP producer '+row.fetch('id') unless status.success? && so.empty? && result['bytes']>0
  vo,ve,vs=Open3.capture3(verifier,'--verify-only',facts)
  File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
  result.merge!('verify_rc'=>vs.exitstatus,'verify_signal'=>vs.termsig,'sha256'=>sha.call(facts))
  File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  abort 'STOP verify '+row.fetch('id') unless vs.success?
end
puts 'captured5/producer0/verify0'
