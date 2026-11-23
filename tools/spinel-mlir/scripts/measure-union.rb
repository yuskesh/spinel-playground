#!/usr/bin/env ruby
# Source: docs/experiments/results/E020/measure-union.rb @ 2e67b8dd; copied without logic changes.
# Adapted from E016 batch/plan-and-measure.rb: explicit frozen plan, with the
# same compiler warning stage (SB021); fail immediately on a broken arm.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
if ARGV.include?('--consumer-only')
  require_relative 'lib/consumer-sanitizers'
  exit ConsumerSanitizers.run(ARGV)
end
repo,plan_path,warnings,out,*options=ARGV
abort 'duplicate inspection option' if options.count('--inspection')>1
inspection=!!options.delete('--inspection')
require_relative 'lib/union-inspection' if inspection
abort 'usage: measure-union REPO PLAN WARNINGS FRESH_OUT [--continue-cases ALLOW_JSON] [--oracle DIR --corpus-contract JSON]' unless out && options.size.even?
settings={}
options.each_slice(2) do |key,value|
  abort 'invalid/duplicate union option' unless %w[--continue-cases --oracle --corpus-contract].include?(key) && value && !settings.key?(key)
  settings[key]=value
end
abort 'oracle and corpus-contract must be paired' unless settings.key?('--oracle')==settings.key?('--corpus-contract')
repo,plan_path,warnings,out=[repo,plan_path,warnings,out].map{|p|File.expand_path(p)}
abort 'fresh output required' if File.exist?(out)
require warnings
sha=->(p){Digest::SHA256.file(p).hexdigest}
plan=JSON.parse(File.read(plan_path))
abort 'duplicate id' unless plan.map{|r|r.fetch('id')}.uniq.size==plan.size
allowed=[]
if settings['--continue-cases']
  allowed=JSON.parse(File.read(settings.fetch('--continue-cases')))
  abort 'continue-cases must be unique string IDs' unless allowed.is_a?(Array)&&allowed.all?{|id|id.is_a?(String)}&&allowed.uniq.size==allowed.size
  accepted=JSON.parse(File.read(repo+'/docs/union/ledger.json')).fetch('cases').map{|r|r.fetch('id')}
  abort 'continue-cases contains accepted union ID' unless settings['--corpus-contract'] || (allowed&accepted).empty?
  abort 'continue-cases contains unplanned ID' unless (allowed-plan.map{|r|r.fetch('id')}).empty?
end
oracle_path=settings['--oracle'] ? File.expand_path(settings['--oracle'])+'/manifest.json' : repo+'/docs/experiments/results/E003/capture/manifest.json'
records=JSON.parse(File.read(oracle_path)).fetch('cases')
if settings['--corpus-contract']
  require_relative 'lib/corpus-contract'
  CorpusContract.verify(settings.fetch('--corpus-contract'),oracle_path,records)
end
oracle=records.to_h{|r|[r.fetch('id'),r]}
plan.each do |r|
  if r.dig('execution','kind')=='source_pipeline'
    require_relative 'lib/source-pipeline-union'
    SourcePipelineUnion.verify(r)
  else
    abort 'facts hash '+r.fetch('id') unless sha.call(r.fetch('facts'))==r.fetch('sha256')
  end
  record=oracle.fetch(r.fetch('id'))
  if r.dig('execution','kind')=='source_pipeline'
    abort 'source pipeline oracle source hash '+r.fetch('id') unless r.fetch('execution').fetch('source_sha256')==record.fetch('source_sha256')
  end
end
FileUtils.mkdir_p(out+'/tools');FileUtils.copy_file(plan_path,out+'/plan.json')
pins={warnings_sha256:sha.call(warnings),runner_sha256:sha.call(__FILE__)}
{'consumer'=>'build/bin/spinel-mlir','compiler'=>'build/bpf-mlir/bin/ebpf-compile','normalizer'=>'build/bin/spinel-ir-normalize'}.each do |name,path|
  from=repo+'/'+path;to=out+'/tools/'+name;h=sha.call(from)
  FileUtils.copy_file(from,to);File.chmod(0755,to)
  abort 'tool changed '+name unless sha.call(from)==h&&sha.call(to)==h
  pins[name]=h
end
File.write(out+'/tools.json',JSON.pretty_generate(pins)+"\n")
if plan.any?{|r|r.dig('execution','kind')=='source_pipeline'}
  FileUtils.mkdir_p(out+'/tools/lib')
  (%w[compile-spinel.rb lib/source-pipeline.rb]+(inspection ? ['lib/inspection-report.rb'] : [])).each do |path|
    from=repo+'/scripts/'+path;to=out+'/tools/'+path
    h=sha.call(from);FileUtils.copy_file(from,to)
    abort 'source pipeline tool changed' unless sha.call(from)==h&&sha.call(to)==h
    pins['source_pipeline/'+path]=h
  end
  pins['source_pipeline/union_helper']=sha.call(File.expand_path('lib/source-pipeline-union.rb',__dir__))
  File.write(out+'/tools.json',JSON.pretty_generate(pins)+"\n")
end
entries=[];ledger=[];failures=[]
plan.each do |input|
  id=input.fetch('id');record=oracle.fetch(id);stem=File.basename(record.fetch('source'),'.rb')
  dir=out+'/cases/'+id;run=out+'/runs/'+id;FileUtils.mkdir_p(dir);FileUtils.mkdir_p(run)
  if input.dig('execution','kind')=='source_pipeline'
    row=SourcePipelineUnion.capture(input,out,dir,run,inspection)
    ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    abort 'STOP source pipeline '+id unless record.fetch('kind')=='negative'&&row['rc']==1&&!row['signal']&&File.zero?(dir+'/build.stdout')&&row['artifacts'].empty?&&row.dig('source_pipeline','adapter','rc')==1
    if inspection
      row['inspection']=UnionInspection.verify(run,record,input,row.fetch('rc'))
      File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    end
    entries<<{id:id,source:record.fetch('source'),source_sha256:record.fetch('source_sha256'),producer_rc:row['rc'],dir:'cases/'+id}
    File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
    next
  end
  argv=['/usr/bin/timeout','--kill-after=5s','60s',out+'/tools/consumer','--emit-dir',run+'/artifacts',input.fetch('facts')]
  argv.insert(-2,'--inspect-dir',run+'/inspection') if inspection
  stdout,stderr,status=Open3.capture3(*argv)
  File.binwrite(dir+'/build.stdout',stdout);File.binwrite(dir+'/build.stderr',stderr)
  artifacts=Dir[run+'/artifacts/*'];positive=record.fetch('kind')=='positive'
  row=input.merge('argv'=>argv,'rc'=>status.exitstatus,'signal'=>status.termsig,'artifacts'=>artifacts.to_h{|p|[File.basename(p),{bytes:File.size(p),sha256:sha.call(p)}]})
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  okay=status.exitstatus==(positive ? 0 : 1)&&!status.termsig&&stdout.empty?
  if inspection
    names=%w[mlir schema.json maps.json records.txt uprobe_targets.json].map{|x|stem+'.'+x}
    okay &&=positive ? artifacts.map{|p|File.basename(p)}.sort==names.sort&&artifacts.all?{|p|p.end_with?('.records.txt')||File.size(p)>0} : artifacts.empty?
    if okay
      row['inspection']=UnionInspection.verify(run,record,input,status.exitstatus)
      File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    end
  else
    okay &&=positive ? artifacts.size==3&&artifacts.all?{|p|File.size(p)>0} : artifacts.empty?
  end
  unless okay
    tolerable=allowed.include?(id)&&[0,1].include?(status.exitstatus)&&!status.termsig&&stdout.empty?
    abort 'STOP consumer '+id unless tolerable
    row['expectation_failure']='consumer-rc-or-artifacts'
    failures<<{id:id,stage:'consumer',rc:status.exitstatus,artifacts:artifacts.map{|p|File.basename(p)}}
    File.write(out+'/expectation-failures.json',JSON.pretty_generate(failures)+"\n")
    File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  end
  artifacts.each do |p|
    if inspection
      suffix=File.basename(p).delete_prefix(stem+'.')
      next unless %w[mlir schema.json maps.json].include?(suffix)
    else suffix=File.basename(p).delete_prefix('xdpcount.')
    end
    FileUtils.copy_file(p,dir+'/'+stem+'.'+suffix)
  end
  if positive && okay
    command=[out+'/tools/compiler',stem+'.mlir','--schema',stem+'.schema.json','--line-info=auto','-o',stem+'.bpf.o']
    co,ce,cs=Open3.capture3(*command,chdir:dir)
    File.binwrite(run+'/compile.stdout',co);File.binwrite(run+'/compile.stderr',ce)
    row['compile_argv']=command;row['compile_rc']=cs.exitstatus;row['compile_signal']=cs.termsig
    File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    compiled=cs.success?&&File.file?(dir+'/'+stem+'.bpf.o')&&File.size(dir+'/'+stem+'.bpf.o')>0
    unless compiled
      abort 'STOP compiler '+id unless allowed.include?(id)&&cs.exitstatus==1&&!cs.termsig
      row['expectation_failure']='compiler'
      failures<<{id:id,stage:'compiler',rc:cs.exitstatus}
      File.write(out+'/expectation-failures.json',JSON.pretty_generate(failures)+"\n")
      File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
    end
    File.binwrite(dir+'/build.stderr',CompileWarnings.combine(stderr,CompileWarnings.render(co,ce))) if compiled
  end
  entries<<{id:id,source:record.fetch('source'),source_sha256:record.fetch('source_sha256'),producer_rc:status.exitstatus,dir:'cases/'+id}
  File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
end
puts JSON.generate({captured:ledger.size,rc:ledger.map{|r|r.fetch('rc')}.tally})
