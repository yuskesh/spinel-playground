#!/usr/bin/env ruby
require 'json';require 'digest';require 'open3';require 'fileutils'
resume=ARGV.delete('--resume')
repo,normal,report,out=ARGV.map{|x|File.expand_path(x)}
abort 'usage: check-e027-map-control REPO NORMAL REPORT FRESH_OUT' unless out
abort 'output exists' if File.exist?(out) && !resume
FileUtils.mkdir_p(out)
id='internal_frontend_testdata_pos_loop_map'
p=JSON.parse(File.read(normal+'/plan.json')).find{|r|r['id']==id};abort 'facts hash' unless Digest::SHA256.file(p.fetch('facts')).hexdigest==p.fetch('sha256')
rows=resume ? JSON.parse(File.read(out+'/ledger.json')) : []
run=lambda do |name,args,cwd=nil|
  o,e,s=Open3.capture3(*args,**(cwd ? {chdir:cwd}:{}))
  File.binwrite(out+'/'+name+'.stdout',o);File.binwrite(out+'/'+name+'.stderr',e)
  rows<<{name:name,argv:args,cwd:cwd,rc:s.exitstatus,signal:s.termsig,stdout_bytes:o.bytesize,stderr_bytes:e.bytesize}
  File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n")
  abort 'command '+name unless s.success?
  [o,e]
end
mut=repo+'/build/bin/spinel-mlir-loop-map-mutation'
o,e=resume ? [File.binread(out+'/lower.stdout'),File.binread(out+'/lower.stderr')] : run.call('lower',[mut,'--emit-dir',out+'/artifacts',p.fetch('facts')])
abort 'stdout' unless o.empty?
base=normal+'/cases/'+id
same={warnings: e==File.binread(base+'/build.stderr')}
%w[schema.json maps.json].each{|k|same[k]=File.binread(out+'/artifacts/xdpcount.'+k)==File.binread(base+'/loop_map.'+k)}
abort 'JSON or warning changed' unless same.values.all?
a=resume ? File.binread(out+'/normalize-base.stdout') : run.call('normalize-base',[repo+'/build/bin/spinel-ir-normalize',base+'/loop_map.mlir']).first
b=resume ? File.binread(out+'/normalize-mutation.stdout') : run.call('normalize-mutation',[repo+'/build/bin/spinel-ir-normalize',out+'/artifacts/xdpcount.mlir']).first
# Resolve printer aliases; keep the actual Ruby locations and every other byte.
resolve=lambda do |text|
  definitions={};body=[]
  text.lines.each do |line|
    m=/\A(#loc\d*) = (.+)\n\z/.match(line)
    m ? definitions[m[1]]=m[2] : body<<line
  end
  expand=nil
  expand=lambda do |value,seen|
    value.gsub(/#loc\d*\b/){|key|abort 'loc cycle/missing' if seen.include?(key)||!definitions.key?(key);expand.call(definitions.fetch(key),seen+[key])}
  end
  expand.call(body.join,[])
end
a=resolve.call(a);b=resolve.call(b)
removed=a.lines.select{|l|l.include?('"ebpf.map.atomic_add"')}
abort 'not exactly one map effect' unless removed.size==1 && a.lines.reject{|l|l.include?('"ebpf.map.atomic_add"')}.join==b
FileUtils.mkdir_p(out+'/compile')
%w[mlir schema.json maps.json].each{|k|FileUtils.copy_file(out+'/artifacts/xdpcount.'+k,out+'/compile/loop_map.'+k)}
elf={}
%w[auto off].each do |mode|
 target=out+'/mutation.'+mode+'.bpf.o'
 run.call('compile-'+mode,[repo+'/build/bpf-mlir/bin/ebpf-compile','loop_map.mlir','--schema','loop_map.schema.json','--line-info='+mode,'-o',target],out+'/compile')
 reference=report+'/elf/'+id+'/candidate/candidate.'+mode+'.bpf.o'
 abort 'empty ELF' unless File.size(target)>0&&File.size(reference)>0
 elf[mode]={normal_sha256:Digest::SHA256.file(reference).hexdigest,mutation_sha256:Digest::SHA256.file(target).hexdigest}
 abort 'ELF unchanged' if elf[mode][:normal_sha256]==elf[mode][:mutation_sha256]
end
summary={normal_consumer:JSON.parse(File.read(normal+'/tools.json')),mutation_sha256:Digest::SHA256.file(mut).hexdigest,facts_sha256:p['sha256'],same:same,removed_ir_line:removed.first,elf:elf}
File.write(out+'/summary.json',JSON.pretty_generate(summary)+"\n")
puts 'map effect mutation: JSON/warnings unchanged; exactly one IR operation removed; auto/off ELF differ'
