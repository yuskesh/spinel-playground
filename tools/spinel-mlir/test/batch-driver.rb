#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: batch-driver.rb REPO TOOLS FRESH_OUT' unless ARGV.size==3
repo,tools,out=ARGV.map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
FileUtils.mkdir_p(out)
oracle="#{repo}/docs/experiments/results/E003/capture"
manifest=JSON.parse(File.read("#{oracle}/manifest.json"));byid=manifest['cases'].to_h{|c|[c['id'],c]}
positive=manifest['cases'].find{|c|c['source']=='examples/xdpcount/xdpcount.rb'}
negative=manifest['cases'].find{|c|c['source'].end_with?('/no_program.rb')}
driver="#{repo}/scripts/batch-compare.rb";groups="#{repo}/docs/plan/P002_105_inputs.md"
require driver # E024: the identity candidate uses the driver's own named-line rule
normalizer="#{tools}/spinel-ir-normalize";ledger=[];failures=[]
write_candidate=lambda do |dir,cases|
 FileUtils.mkdir_p(dir)
 File.write("#{dir}/candidate.json",JSON.pretty_generate({'version'=>2,'cases'=>cases})+"\n")
end
entry=lambda{|c,dir,rc|{'id'=>c['id'],'source'=>c['source'],'source_sha256'=>c['source_sha256'],'producer_rc'=>rc,'dir'=>dir}}
assert=lambda{|condition,message|failures<<message unless condition}
run=lambda do |name,candidate,compiler,want,status_id=nil,status_want=nil,reason=nil,norm=normalizer,group_file=groups|
 report="#{out}/report-#{name}"
 args=['ruby',driver,'--oracle',oracle,'--candidate',candidate,'--groups',group_file,'--compiler',compiler,'--normalizer',norm,'--report',report]
 o,e,s=Open3.capture3(*args)
 File.binwrite("#{out}/#{name}.stdout",o);File.binwrite("#{out}/#{name}.stderr",e)
 File.write("#{out}/#{name}.rc","#{s.exitstatus}\n")
 summary=File.file?("#{report}/summary.json") ? JSON.parse(File.read("#{report}/summary.json")) : {}
 rows=File.file?("#{report}/cases.json") ? JSON.parse(File.read("#{report}/cases.json")) : []
 row=rows.find{|r|r['id']==status_id}
 assert.call(s.exitstatus==want,"#{name}: expected exit#{want}, got #{s.exitstatus}: #{e}")
 if status_id
  assert.call(row && row['status']==status_want,"#{name}: wrong cell status #{row.inspect}")
  assert.call(row && row['reasons'].any?{|r|r.include?(reason)},"#{name}: missing named reason #{reason}") if reason
 end
 ledger<<{'case'=>name,'expected_exit'=>want,'actual_exit'=>s.exitstatus,'elf_arm'=>summary['elf_arm'],'total'=>summary['total'],'witness'=>row,'global_error'=>summary['global_error']}
 File.write("#{out}/ledger.json",JSON.pretty_generate(ledger)+"\n")
 [summary,rows]
end
partial="#{out}/partial";FileUtils.mkdir_p(partial)
o,e,s=Open3.capture3("#{tools}/spinel-mlir",'--emit-dir',"#{partial}/xdpcount","#{repo}/test/Inputs/xdpcount.spinel.mlir")
File.binwrite("#{out}/producer.stdout",o);File.binwrite("#{out}/producer.stderr",e);File.write("#{out}/producer.rc","#{s.exitstatus}\n")
abort "handwritten producer failed #{e}" unless s.success?
File.binwrite("#{partial}/xdpcount/build.stderr",e) # E024: v2 positives carry their stderr
write_candidate.call(partial,[entry.call(positive,'xdpcount',s.exitstatus)])
%w[saved current].each do |arm|
 summary,rows=run.call("partial-#{arm}",partial,"#{tools}/compiler-#{arm}",3,positive['id'],'matched')
 assert.call(summary['total']=={'matched'=>1,'different'=>0,'error'=>0,'unsupported'=>608},"partial #{arm}: wrong coverage")
 assert.call(rows.count{|r|r['kind']=='positive'&&r['status']=='unsupported'}==104,"partial #{arm}: positive missing count")
 assert.call(rows.count{|r|r['kind']=='negative'&&r['status']=='unsupported'}==504,"partial #{arm}: negative missing count")
 expected=arm=='saved' ? 'saved-ELF' : 'recompiled-Go-ELF'
 assert.call(summary['elf_arm']==expected,"partial #{arm}: wrong ELF arm")
end
# One complete synthetic identity; it is not a new frontend's output.
identity="#{out}/identity";entries=[]
manifest['cases'].each do |c|
 dir="#{identity}/#{c['id']}";FileUtils.mkdir_p(dir)
 source="#{oracle}/#{c['raw_dir']}";stem=File.basename(c['source'],'.rb')
 names=c['kind']=='positive' ? %W[#{stem}.mlir #{stem}.schema.json #{stem}.maps.json] : %w[build.stdout build.stderr]
 names.each{|f|FileUtils.cp("#{source}/#{f}","#{dir}/#{f}")}
 if c['kind']=='positive'
  File.binwrite("#{dir}/build.stderr",BatchCompare.strip_named_wrote(File.binread("#{source}/build.stderr"),c['id'],stem))
 end
 entries<<entry.call(c,c['id'],Integer(File.read("#{source}/build.rc")))
end
write_candidate.call(identity,entries)
summary,rows=run.call('identity-609',identity,"#{tools}/compiler-saved",0)
assert.call(summary['total']=={'matched'=>609,'different'=>0,'error'=>0,'unsupported'=>0},'identity: wrong coverage')
assert.call(rows.all?{|r|r['status']=='matched'},'identity: not every row matched')
# E024: positives with a warning in the saved oracle (SB013 / SB021).
warned_ids=manifest['cases'].select{|c|c['kind']=='positive'}.map{|c|c['id']}.select do |id|
 c=byid.fetch(id)
 !BatchCompare.strip_named_wrote(File.binread("#{oracle}/#{c['raw_dir']}/build.stderr"),id,File.basename(c['source'],'.rb')).empty?
end
assert.call(warned_ids.size==6,"identity: expected 6 warned positives, got #{warned_ids.size}")
rows.select{|r|r['kind']=='positive'}.each do |r|
 assert.call(r['normalizer'].values.all?{|m|m['rc']==0&&m['stdout_bytes']>0},"normalizer distribution #{r['id']}")
 assert.call(r['compiler'].values.all?{|m|m['rc']==0},"compiler distribution #{r['id']}")
 # A positive without warnings has an empty warnings check on both sides; the
 # six warned ones must compare nonempty text (an empty/empty match would not
 # count as having compared their warnings).
 other=r['checks'].reject{|c|c['name']=='warnings'}
 warn=r['checks'].find{|c|c['name']=='warnings'}
 assert.call(other.all?{|c|c['same']&&c['left_bytes']>0&&c['right_bytes']>0},"nonempty/same #{r['id']}")
 assert.call(warn && warn['same'],"warnings same #{r['id']}")
 assert.call(!warned_ids.include?(r['id']) || (warn['left_bytes']>0 && warn['right_bytes']>0),"warnings nonempty #{r['id']}")
end
clone_partial=lambda do |name|
 dir="#{out}/candidate-#{name}";FileUtils.cp_r(partial,dir);dir
end
{'schema'=>'schema.json','maps'=>'maps.json','mlir-op'=>'mlir','mlir-loc'=>'mlir','empty-schema'=>'schema.json','missing-maps'=>'maps.json','producer-failure'=>nil}.each do |name,ext|
 dir=clone_partial.call(name);path="#{dir}/xdpcount/xdpcount.#{ext}"
 case name
 when 'schema','maps';File.open(path,'ab'){|f|f.write(' ')}
 when 'mlir-op';raw=File.read(path);abort 'op mutation missing' unless raw.include?('ebpf.map.atomic_add');File.write(path,raw.sub('ebpf.map.atomic_add','ebpf.map.update'))
 when 'mlir-loc';raw=File.read(path);abort 'loc mutation missing' unless raw.include?('"xdpcount.rb":11:3');File.write(path,raw.sub('"xdpcount.rb":11:3','"xdpcount.rb":12:3'))
 when 'empty-schema';File.write(path,'')
 when 'missing-maps';File.unlink(path)
 when 'producer-failure';m=JSON.parse(File.read("#{dir}/candidate.json"));m['cases'][0]['producer_rc']=1;write_candidate.call(dir,m['cases'])
 end
 error=%w[empty-schema missing-maps].include?(name)
 reason={'schema'=>'schema','maps'=>'maps','mlir-op'=>'structure','mlir-loc'=>'structure','empty-schema'=>'empty-file','missing-maps'=>'missing-file','producer-failure'=>'producer-failed'}[name]
 run.call(name,dir,"#{tools}/compiler-saved",error ? 2 : 1,positive['id'],error ? 'error' : 'different',reason)
end
# E024: a positive's warnings. unused_map prints a conditional SB013; its
# single-case identity matches, one changed character in the warning is named
# `warnings`, and a missing positive build.stderr is a named error.
warned=manifest['cases'].find{|c|c['source'].end_with?('/unused_map.rb')}
wroot="#{out}/warned";wdir="#{wroot}/warned";FileUtils.mkdir_p(wdir)
wsource="#{oracle}/#{warned['raw_dir']}";wstem=File.basename(warned['source'],'.rb')
%W[#{wstem}.mlir #{wstem}.schema.json #{wstem}.maps.json].each{|f|FileUtils.cp("#{wsource}/#{f}","#{wdir}/#{f}")}
File.binwrite("#{wdir}/build.stderr",BatchCompare.strip_named_wrote(File.binread("#{wsource}/build.stderr"),warned['id'],wstem))
abort 'warned case has no warning' unless File.binread("#{wdir}/build.stderr").include?('conditional SB013')
write_candidate.call(wroot,[entry.call(warned,'warned',0)])
run.call('warning-matched',wroot,"#{tools}/compiler-saved",3,warned['id'],'matched')
wmut="#{out}/warning-char";FileUtils.cp_r(wroot,wmut)
path="#{wmut}/warned/build.stderr";raw=File.binread(path)
abort 'warning mutation absent' unless raw.include?('map Spare')
File.binwrite(path,raw.sub('map Spare','map spare'))
run.call('warning-char',wmut,"#{tools}/compiler-saved",1,warned['id'],'different','warnings')
wmiss="#{out}/warning-missing";FileUtils.cp_r(wroot,wmiss);File.unlink("#{wmiss}/warned/build.stderr")
run.call('warning-missing',wmiss,"#{tools}/compiler-saved",2,warned['id'],'error','missing-file')
# A spurious warning: the oracle xdpcount prints none, the candidate one more line.
spurious=clone_partial.call('warning-spurious')
File.open("#{spurious}/xdpcount/build.stderr",'ab'){|f|f.write("spinelbpf: warning: xdpcount.rb:1:1: conditional SB013 (MapDeclShape): spurious\n")}
run.call('warning-spurious',spurious,"#{tools}/compiler-saved",1,positive['id'],'different','warnings')
negroot="#{out}/negative";FileUtils.mkdir_p("#{negroot}/negative")
%w[build.stderr build.stdout].each{|f|FileUtils.cp("#{oracle}/#{negative['raw_dir']}/#{f}","#{negroot}/negative/#{f}")}
write_candidate.call(negroot,[entry.call(negative,'negative',1)])
run.call('negative-matched',negroot,"#{tools}/compiler-saved",3,negative['id'],'matched')
%w[message empty artifact].each do |name|
 dir="#{out}/negative-#{name}";FileUtils.cp_r(negroot,dir)
 case name
 when 'message';path="#{dir}/negative/build.stderr";raw=File.binread(path);abort 'negative mutation absent' unless raw.include?('no eBPF program');File.binwrite(path,raw.sub('no eBPF program','No eBPF program'))
 when 'empty';File.write("#{dir}/negative/build.stderr",'')
 when 'artifact';File.write("#{dir}/negative/should-not-exist.mlir",'module {}')
 end
 reason={'message'=>'diagnostic','empty'=>'empty-file','artifact'=>'negative-success-artifact'}[name]
 run.call("negative-#{name}",dir,"#{tools}/compiler-saved",name=='empty' ? 2 : 1,negative['id'],name=='empty' ? 'error' : 'different',reason)
end
# Explicit compiler shims delegate the pinned executable and change one side.
%w[elf-byte candidate-fail oracle-fail candidate-empty oracle-empty].each do |mode|
 shim="#{out}/#{mode}-compiler.rb"
 File.write(shim,<<~SCRIPT)
  #!/usr/bin/env ruby
  require 'fileutils'
  real=#{("#{tools}/compiler-saved").inspect}
  mode=#{mode.inspect}
  exec(real,*ARGV) if ARGV==['--version']
  index=ARGV.index('-o');abort 'shim missing output' unless index
  output=ARGV[index+1]
  chosen=File.basename(output)==(mode.start_with?('oracle') ? 'oracle.auto.bpf.o' : 'candidate.auto.bpf.o')
  if chosen && mode.end_with?('fail')
    warn 'injected-one-side-compile-failure';exit 1
  end
  if chosen && mode.end_with?('empty')
    File.write(output,'');exit 0
  end
  system(real,*ARGV);rc=$?.exitstatus;exit(rc||2) unless rc==0
  if chosen && mode=='elf-byte'
    bytes=File.binread(output);bytes.setbyte(bytes.bytesize-1,bytes.getbyte(bytes.bytesize-1)^1);File.binwrite(output,bytes)
  end
  exit 0
 SCRIPT
 File.chmod(0755,shim)
 reason=mode=='elf-byte' ? 'elf-auto' : mode.end_with?('fail') ? 'compile-' : 'empty-file'
 run.call(mode,partial,shim,mode=='elf-byte' ? 1 : 2,positive['id'],mode=='elf-byte' ? 'different' : 'error',reason)
end
%w[empty fail].each do |name|
 fake="#{out}/#{name}-normalizer.sh";File.write(fake,"#!/bin/sh\nexit #{name=='empty' ? 0 : 1}\n");File.chmod(0755,fake)
 run.call("normalizer-#{name}",partial,"#{tools}/compiler-saved",2,positive['id'],'error',name=='empty' ? 'normalizer-oracle-empty' : 'normalizer-oracle-failed',fake)
end
badgroups="#{out}/bad-groups.md";File.write(badgroups,File.read(groups)+"\n|H|`examples/xdpcount/xdpcount.rb`|array|xdp|\n")
summary,_=run.call('duplicate-group',partial,"#{tools}/compiler-saved",2,nil,nil,nil,normalizer,badgroups)
assert.call(summary.fetch('global_error','').include?('group-duplicate'),'group duplicate not named')
missinggroups="#{out}/missing-groups.md";File.write(missinggroups,File.read(groups).lines.reject{|l|l.start_with?('|H|`examples/xdpcount/xdpcount.rb`')}.join)
summary,_=run.call('missing-group',partial,"#{tools}/compiler-saved",2,nil,nil,nil,normalizer,missinggroups)
assert.call(summary.fetch('global_error','').include?('group-coverage-mismatch'),'group missing not named')
before=Digest::SHA256.file("#{out}/report-partial-saved/summary.json").hexdigest
o,e,s=Open3.capture3('ruby',driver,'--oracle',oracle,'--candidate',partial,'--groups',groups,'--compiler',"#{tools}/compiler-saved",'--normalizer',normalizer,'--report',"#{out}/report-partial-saved")
assert.call(s.exitstatus==2&&e.include?('report-exists'),'stale report not rejected')
assert.call(before==Digest::SHA256.file("#{out}/report-partial-saved/summary.json").hexdigest,'stale report overwritten')
File.write("#{out}/failures.json",JSON.pretty_generate(failures)+"\n")
File.write("#{out}/summary.json",JSON.pretty_generate({'scenarios'=>ledger.size,'failures'=>failures,'tool_hashes'=>Dir["#{tools}/*"].to_h{|p|[File.basename(p),Digest::SHA256.file(p).hexdigest]}})+"\n")
puts "E009 scenarios=#{ledger.size} failures=#{failures.size}"
abort failures.join("\n") unless failures.empty?
