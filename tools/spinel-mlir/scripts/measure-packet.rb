#!/usr/bin/env ruby
# Capture C12/core49 + existing A46 exactly once, without obtaining new facts.
require 'json'
require 'fileutils'
require 'digest'
require 'open3'
repo, scratch, old_ledger, out, extra_plan = ARGV
abort 'usage: measure-packet REPO SCRATCH A_LEDGER FRESH_OUT' unless out
repo,scratch,old_ledger,out=[repo,scratch,old_ledger,out].map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
oracle=JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases').to_h{|c|[c.fetch('id'),c]}
positive=JSON.parse(File.read(scratch+'/positive-facts/manifest.json'))
negative=File.readlines(scratch+'/negative-supply-01/ledger.jsonl').map{|l|JSON.parse(l)}
old=JSON.parse(File.read(old_ledger))
abort 'input coverage' unless positive.size==12&&negative.size==49&&old.size==46
plan=[]
positive.each{|c|plan<<{id:c.fetch('id'),facts:c.fetch('facts'),sha256:sha.call(c.fetch('facts')),origin:c.fetch('archive')}}
negative.each do |c|
  abort 'negative supply failure' unless c.fetch('supply_success')
  plan<<{id:c.fetch('id'),facts:scratch+'/negative-supply-01/arms/'+c.fetch('id')+'/facts.mlir',sha256:c.fetch('facts_sha256'),origin:'E015 negative supply once'}
end
old.each{|c|plan<<{id:c.fetch('id'),facts:c.fetch('facts'),sha256:c.fetch('attempts').first.fetch('facts_sha256'),origin:'E010/E018 fixed ledger'}}
if extra_plan
  JSON.parse(File.read(extra_plan)).each{|c|plan<<c.transform_keys(&:to_sym)}
end
abort 'duplicate case' unless plan.map{|c|c[:id]}.uniq.size==plan.size
plan.each{|c|abort 'facts changed' unless sha.call(c[:facts])==c[:sha256];oracle.fetch(c[:id])}
FileUtils.mkdir_p(out+'/tools')
tool=out+'/tools/spinel-mlir'
original=repo+'/build/bin/spinel-mlir';tool_sha=sha.call(original)
FileUtils.copy_file(original,tool);File.chmod(0755,tool)
abort 'tool changed' unless sha.call(tool)==tool_sha&&sha.call(original)==tool_sha
File.write(out+'/preflight.json',JSON.pretty_generate({consumer_sha256:tool_sha,old_ledger_sha256:sha.call(old_ledger),cases:plan})+"\n")
entries=[]; rows=[]
plan.each do |p|
  c=oracle.fetch(p[:id]);dir=out+'/runs/'+c.fetch('id');FileUtils.mkdir_p(dir)
  argv=[tool,'--emit-dir',dir+'/artifacts',p[:facts]]
  o,e,st=Open3.capture3('/usr/bin/timeout','--kill-after=5s','60s',*argv)
  File.binwrite(dir+'/build.stdout',o);File.binwrite(dir+'/build.stderr',e)
  row={id:c.fetch('id'),kind:c.fetch('kind'),argv:argv,rc:st.exitstatus,signal:st.termsig,
       stdout_bytes:o.bytesize,stderr_bytes:e.bytesize,facts_sha256:p[:sha256],origin:p[:origin]}
  File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
  # Keep all raw, even after a mismatch; do not rerun cells to erase a failure.
  target=out+'/cases/'+c.fetch('id');FileUtils.mkdir_p(target)
  FileUtils.copy_file(dir+'/build.stdout',target+'/build.stdout');FileUtils.copy_file(dir+'/build.stderr',target+'/build.stderr')
  if File.directory?(dir+'/artifacts')
    Dir[dir+'/artifacts/*'].sort.each do |file|
      suffix=File.basename(file).delete_prefix('xdpcount.')
      FileUtils.copy_file(file,target+'/'+File.basename(c.fetch('source'),'.rb')+'.'+suffix)
    end
  end
  rows<<row
  entries<<{id:c.fetch('id'),source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),producer_rc:st.exitstatus,dir:'cases/'+c.fetch('id')}
  File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n")
  File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
  abort "STOP abnormal process #{c['id']}" if st.termsig||![0,1].include?(st.exitstatus)
end
puts JSON.generate({captured:rows.size,positive:rows.select{|r|r[:kind]=='positive'}.map{|r|r[:rc]}.tally,
                    negative:rows.select{|r|r[:kind]=='negative'}.map{|r|r[:rc]}.tally})
