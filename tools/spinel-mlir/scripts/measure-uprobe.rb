#!/usr/bin/env ruby
# E040: one immutable consumer for the fixed union and additional integer roots.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'lib/compile-warnings'
abort 'usage: measure-uprobe UNION_PLAN FACTS_LEDGER FRESH_OUT' unless ARGV.size == 3
union, supply, out = ARGV.map { |p| File.expand_path(p) }
repo = File.expand_path('..', __dir__)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
abort 'root forbidden' if Process.uid.zero?
abort 'fresh output required' if File.exist?(out)
abort 'union plan hash' unless sha.call(union) == 'b49c2beb6f1c99d0bee1d2c30399efabb52d3c101522f197ae05be9d9c74dad4'
plan = JSON.parse(File.read(union)).fetch('cases')
abort 'union coverage' unless plan.size == 327 && plan.map { |r| r.fetch('id') }.uniq.size == 327
extra = JSON.parse(File.read(supply)).select { |r| r.fetch('scope') == 'fixed-negative' || %w[up_ints uret_ints].include?(r.fetch('id')) }
abort 'extra coverage' unless extra.size == 9
extra.each do |r|
  abort 'supply success' unless r.fetch('supply_success') && r.fetch('rc') == 0 && r.fetch('verify_rc') == 0
  r['sha256'] = r.fetch('facts_sha256')
end
ids = plan.map { |r| r.fetch('id') }
abort 'overlapping new input' unless (ids & extra.map { |r| r.fetch('id') }).empty?
plan += extra
oracle = JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases').to_h { |r| [r.fetch('id'),r] }
plan.each do |r|
  abort 'facts hash: '+r.fetch('id') unless sha.call(r.fetch('facts')) == r.fetch('sha256')
  abort 'target hash: '+r.fetch('id') if r['target'] && sha.call(r.fetch('target')) != r.fetch('target_sha256')
  if oracle.key?(r.fetch('id'))
    c=oracle.fetch(r.fetch('id'))
    r['source']=c.fetch('source');r['source_sha256']=c.fetch('source_sha256');r['kind']=c.fetch('kind')
  end
end
FileUtils.mkdir_p(out+'/tools')
tools={'consumer'=>'build/bin/spinel-mlir','compiler'=>'build/bpf-mlir/bin/ebpf-compile','normalizer'=>'build/bin/spinel-ir-normalize','mutation'=>'build/bin/spinel-mlir-uprobe-mutation'}
pins={}
tools.each do |name,path|
  from=repo+'/'+path;to=out+'/tools/'+name
  abort 'tool missing: '+name unless File.executable?(from)
  pins[name]=sha.call(from);FileUtils.cp(from,to);File.chmod(0755,to)
  abort 'tool changed: '+name unless sha.call(to)==pins[name] && sha.call(from)==pins[name]
end
File.write(out+'/tools.json',JSON.pretty_generate(pins)+"\n")
File.write(out+'/plan.json',JSON.pretty_generate(plan)+"\n")
entries=[];additional=[];ledger=[]
plan.each do |input|
  id=input.fetch('id');stem=File.basename(input.fetch('source'),'.rb')
  dir=out+'/cases/'+id;run=out+'/runs/'+id
  FileUtils.mkdir_p(dir);FileUtils.mkdir_p(run)
  command=['/usr/bin/timeout','--kill-after=5s','60s',out+'/tools/consumer','--emit-dir',run+'/artifacts',input.fetch('facts')]
  so,se,status=Open3.capture3(*command)
  File.binwrite(dir+'/build.stdout',so);File.binwrite(dir+'/build.stderr',se)
  File.write(dir+'/build.rc',"#{status.exitstatus}\n")
  row=input.merge('command'=>command,'rc'=>status.exitstatus,'signal'=>status.termsig)
  Dir[run+'/artifacts/*'].each { |f| FileUtils.cp(f,dir+'/'+stem+'.'+File.basename(f).delete_prefix('xdpcount.')) }
  if input.fetch('kind')=='positive' && status.success?
    modes=input['scope']=='additional-positive' ? %w[auto off] : %w[auto]
    modes.each do |mode|
      args=[out+'/tools/compiler',stem+'.mlir','--schema',stem+'.schema.json','--line-info='+mode,'-o',stem+'.'+mode+'.bpf.o']
      co,ce,cs=Open3.capture3(*args,chdir:dir)
      File.binwrite(run+'/'+mode+'.stdout',co);File.binwrite(run+'/'+mode+'.stderr',ce)
      row[mode+'_compile']={'command'=>args,'rc'=>cs.exitstatus,'signal'=>cs.termsig}
      if mode=='auto' && cs.success?
        FileUtils.cp(dir+'/'+stem+'.auto.bpf.o',dir+'/'+stem+'.bpf.o')
        File.binwrite(dir+'/build.stderr',CompileWarnings.combine(se,CompileWarnings.render(co,ce)))
      end
    end
  end
  if input['scope']=='additional-positive'
    additional << input.slice('id','source','source_sha256','kind').merge('raw_dir'=>'cases/'+id)
  else
    entries << {id:id,source:input.fetch('source'),source_sha256:input.fetch('source_sha256'),producer_rc:status.exitstatus,dir:'cases/'+id}
  end
  ledger << row
  File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
  File.write(out+'/manifest.json',JSON.pretty_generate({tools:{'ebpf-compile'=>{sha256:pins.fetch('compiler')}},cases:additional})+"\n")
  abort 'STOP abnormal consumer: '+id if status.termsig || ![0,1].include?(status.exitstatus)
  abort 'STOP compiler: '+id if row.values.any? { |v| v.is_a?(Hash) && v.key?('command') && (v['rc']!=0 || v['signal']) }
end
puts JSON.generate({captured:ledger.size,fixed:entries.size,additional:additional.size,rc:ledger.map { |r| r.fetch('rc') }.tally})
