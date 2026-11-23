#!/usr/bin/env ruby
require_relative 'compare-root-facts'
require 'fileutils'
require 'open3'
require 'digest'
repo,scratch,out=ARGV
abort 'usage: check-packet-controls REPO SCRATCH FRESH_OUT' unless out
repo,scratch,out=[repo,scratch,out].map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
FileUtils.mkdir_p(out)
oracle=JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases').to_h{|c|[c.fetch('id'),c]}
pos=JSON.parse(File.read(scratch+'/positive-facts/manifest.json')).to_h{|c|[c.fetch('id'),c]}
ledger=[]
run=lambda do |name,tool,facts,emit|
  dir=out+'/'+name;FileUtils.mkdir_p(dir)
  argv=[tool]+(emit ? ['--emit-dir',dir+'/artifacts',facts] : ['--verify-only',facts])
  stdout,stderr,st=Open3.capture3('/usr/bin/timeout','--kill-after=5s','60s',*argv)
  File.binwrite(dir+'/build.stdout',stdout);File.binwrite(dir+'/build.stderr',stderr)
  row={name:name,argv:argv,tool_sha256:Digest::SHA256.file(tool).hexdigest,facts_sha256:Digest::SHA256.file(facts).hexdigest,
    rc:st.exitstatus,signal:st.termsig,stdout_bytes:stdout.bytesize,stderr_bytes:stderr.bytesize,artifacts:File.directory?(dir+'/artifacts')}
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
  [row,stderr]
end
entries=[]
[['offset-upper-bound','internal_frontend_testdata_neg_pk_off_edge',scratch+'/negative-supply-01/arms/internal_frontend_testdata_neg_pk_off_edge/facts.mlir'],
 ['masked-control','internal_frontend_testdata_pos_pkt_off_masked',pos.fetch('internal_frontend_testdata_pos_pkt_off_masked').fetch('facts')]].each do |name,id,facts|
  row,err=run.call(name,repo+'/build/bin/spinel-mlir-offset-mutation',facts,true)
  if name=='offset-upper-bound'
    abort 'STOP offset mutation observation' unless row[:rc]==1&&row[:signal].nil?&&!row[:artifacts]&&!err.include?('SB023')&&err.include?('the window at constant offset 65522')
  else
    abort 'STOP masked control' unless row[:rc]==0&&row[:signal].nil?&&row[:artifacts]
  end
  c=oracle.fetch(id);dir=out+'/cases/'+id;FileUtils.mkdir_p(dir)
  %w[stdout stderr].each{|channel|FileUtils.copy_file(out+'/'+name+'/build.'+channel,dir+'/build.'+channel)}
  Dir[out+'/'+name+'/artifacts/*'].each{|f|FileUtils.copy_file(f,dir+'/'+File.basename(c.fetch('source'),'.rb')+'.'+File.basename(f).delete_prefix('xdpcount.'))}
  entries<<{id:id,source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),producer_rc:row[:rc],dir:'cases/'+id}
end
File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
# Synthetic malformed-call control only: remove the attach Symbol from the
# root argument list in BOTH fact tables, leaving the original source untouched.
original=pos.fetch('internal_frontend_testdata_pos_tc_ingress').fetch('facts')
facts=RootFacts.new(original)
root=facts.nodes.values.find{|n|n['kind']=='CallNode'&&n.fetch('strings')['name']=='tcx'}
abort 'TCX control root missing' unless root
argid=root.fetch('refs').fetch('arguments')
argnode=facts.nodes.fetch(argid);args=argnode.fetch('arrays').fetch('arguments')
abort 'TCX baseline arity' unless args.size==2
changes=0
text=File.read(original).lines.map do |line|
  if line.include?("id = #{argid} : i64, kind = \"ArgumentsNode\"")
    changes+=1;line.sub(/"arguments" = \[[^\]]*\]/,"\"arguments\" = [#{args.first} : i64]")
  else
    line
  end
end.join
abort 'TCX control expected two table edits' unless changes==2
bad=out+'/tcx-missing-attach.mlir';File.write(bad,text)
verify,_=run.call('tcx-arity-verify',repo+'/build/bin/spinel-mlir',bad,false)
abort 'STOP synthetic arity facts invalid' unless verify[:rc]==0&&verify[:signal].nil?
rejected,err=run.call('tcx-arity-rejected',repo+'/build/bin/spinel-mlir',bad,true)
abort 'STOP synthetic arity accepted/wrong cause' unless rejected[:rc]==1&&rejected[:signal].nil?&&!rejected[:artifacts]&&err.include?('SB008 (ProgramShape): BPF.tcx has invalid root arguments')
puts JSON.generate({controls:ledger.size,offset:'SB023 disappears; downstream packet verifier rejects',masked:'candidate captured; E009 five-artifact comparison still required',tcx_arity:'verify0; named SB008; no artifacts'})
