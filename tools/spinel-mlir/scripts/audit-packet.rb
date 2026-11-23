#!/usr/bin/env ruby
# Independent stdlib audit of saved observations. Does not execute any compiler.
require 'json'
require 'digest'
root,out=ARGV
abort 'usage: audit-packet SCRATCH OUTPUT_JSON' unless out
loadj=->(p){JSON.parse(File.read(root+'/'+p))}
assert=->(v,s){abort "packet audit: #{s}" unless v}
union=loadj.call('report-02/summary.json')
rows=loadj.call('report-02/cases.json')
a=loadj.call('report-a-02/summary.json')
controls=loadj.call('controls-report-01/summary.json')
control_rows=loadj.call('controls-report-01/cases.json')
assert.call(union.fetch('exit')==3&&union.fetch('total')=={'matched'=>107,'different'=>0,'error'=>0,'unsupported'=>502},'union counts')
assert.call(a.fetch('exit')==3&&a.fetch('total')=={'matched'=>46,'different'=>0,'error'=>0,'unsupported'=>563},'A counts')
assert.call(controls.fetch('exit')==1&&controls.fetch('total')=={'matched'=>1,'different'=>1,'error'=>0,'unsupported'=>607},'control counts')
positive=rows.select{|r|r['kind']=='positive'&&r['status']=='matched'}
negative=rows.select{|r|r['kind']=='negative'&&r['status']=='matched'}
assert.call(positive.size==26&&negative.size==81,'matched partition')
normalizers=[];compiles=[]
positive.each do |r|
  assert.call(r.values_at('producer_rc','oracle_producer_rc')==[0,0],r['id']+' producer')
  checks=r.fetch('checks')
  assert.call(checks.map{|c|c.fetch('name')}.sort==%w[elf-auto elf-off maps schema structure].sort,r['id']+' five checks')
  assert.call(checks.all?{|c|c.fetch('same')&&c.fetch('left_bytes')>0&&c.fetch('right_bytes')>0&&c.fetch('left_sha256')==c.fetch('right_sha256')},r['id']+' nonempty equal')
  ns=r.fetch('normalizer').values
  assert.call(ns.size==2&&ns.all?{|n|n['rc']==0&&n['signal'].nil?&&n['stdout_bytes']>0},r['id']+' normalize')
  cs=r.fetch('compiler').values
  assert.call(cs.size==4&&cs.all?{|c|c['rc']==0&&c['signal'].nil?},r['id']+' compile')
  normalizers.concat(ns);compiles.concat(cs)
end
negative.each do |r|
  assert.call(r.values_at('producer_rc','oracle_producer_rc')==[1,1],r['id']+' rejection rc')
  diagnostic=r.fetch('checks').find{|c|c['name']=='diagnostic'}
  assert.call(diagnostic&&diagnostic['same']&&diagnostic['left_bytes']>0&&diagnostic['right_bytes']>0,r['id']+' diagnostic')
end
masked=control_rows.find{|r|r['id']=='internal_frontend_testdata_pos_pkt_off_masked'}
changed=control_rows.find{|r|r['id']=='internal_frontend_testdata_neg_pk_off_edge'}
assert.call(masked['status']=='matched'&&masked.fetch('checks').size==5,'masked five checks')
assert.call(changed['status']=='different'&&changed['reasons']==['diagnostic'],'offset unique difference')
ledger=loadj.call('controls-01/ledger.json')
assert.call(ledger.map{|r|r['rc']}==[1,0,0,1]&&ledger.all?{|r|r['signal'].nil?},'control observations')
bad=File.binread(root+'/controls-01/offset-upper-bound/build.stderr')
assert.call(!bad.include?('SB023')&&bad.include?('the window at constant offset 65522'),'offset named sensitivity')
assert.call(union['elf_arm']=='recompiled-Go-ELF'&&union['compiler_sha256']=='60853aa9b02a252a3e6bacdf88bcdf76d6fb57621177b651e18433c8b7b9222b','ELF arm')
summary={union:union.fetch('total'),group_c:union.fetch('groups').fetch('C'),group_a_report:a.fetch('total'),
  positive_producer_pairs:positive.size,negative_producer_pairs:negative.size,
  normalizer_rc0_nonempty:normalizers.size,compiler_rc0:compiles.size,
  artifact_nonempty_equal:positive.sum{|r|r.fetch('checks').size},
  mutation_unique_differences:1,masked_five_equal:true,tcx_arity:{facts_verify:0,consumer:1,diagnostic:'SB008',artifacts:false},
  elf_arm:union.fetch('elf_arm'),compiler_sha256:union.fetch('compiler_sha256'),
  boundary:'No producer/lowering/compile rerun. Existing E009 v1 does not compare positive warnings; E024 owns that extension.'}
File.write(out,JSON.pretty_generate(summary)+"\n")
puts JSON.generate(summary)
