#!/usr/bin/env ruby
# E025 completion: fixed saved facts, each union case once with one tool.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
repo,plan_path,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: measure-example-union REPO PLAN FRESH_OUT' unless out
abort 'output exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
plan=JSON.parse(File.read(plan_path))
abort 'duplicate case' unless plan.map{|r|r.fetch('id')}.uniq.size==plan.size
oracle=JSON.parse(File.read(repo+'/docs/experiments/results/E003/capture/manifest.json')).fetch('cases').to_h{|r|[r.fetch('id'),r]}
plan.each{|r|abort 'facts hash '+r.fetch('id') unless sha.call(r.fetch('facts'))==r.fetch('sha256');oracle.fetch(r.fetch('id'))}
FileUtils.mkdir_p(out+'/tools');FileUtils.copy_file(plan_path,out+'/plan.json')
tool=out+'/tools/spinel-mlir';FileUtils.copy_file(repo+'/build/bin/spinel-mlir',tool);File.chmod(0755,tool)
tool_sha=sha.call(tool)
File.write(out+'/tools.json',JSON.pretty_generate({consumer_sha256:tool_sha,runner_sha256:sha.call(__FILE__),tree:Open3.capture2('git','-C',repo,'rev-parse','HEAD').first.strip})+"\n")
rows=[];entries=[]
plan.each do |p|
  id=p.fetch('id');record=oracle.fetch(id);dir=out+'/runs/'+id;FileUtils.mkdir_p(dir)
  args=['/usr/bin/timeout','--kill-after=5s','60s',tool,'--emit-dir',dir+'/artifacts',p.fetch('facts')]
  stdout,stderr,status=Open3.capture3(*args)
  File.binwrite(dir+'/build.stdout',stdout);File.binwrite(dir+'/build.stderr',stderr)
  row=p.merge('argv'=>args,'rc'=>status.exitstatus,'signal'=>status.termsig,'consumer_sha256'=>tool_sha,
    'artifacts'=>Dir[dir+'/artifacts/*'].to_h{|f|[File.basename(f),{bytes:File.size(f),sha256:sha.call(f)}]})
  File.write(dir+'/execution.json',JSON.pretty_generate(row)+"\n");rows<<row
  File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n")
  positive=record.fetch('kind')=='positive'
  expected=positive ? 0 : 1
  okay=status.exitstatus==expected && !status.termsig && stdout.empty?
  okay &&=positive ? row['artifacts'].size==3 && row['artifacts'].values.all?{|a|a[:bytes]>0} : row['artifacts'].empty?
  unless okay
    File.write(out+'/stop.txt',"STOP "+id+": rc/artifact contract\n");warn "STOP "+id;exit 1
  end
  target=out+'/cases/'+id;FileUtils.mkdir_p(target)
  %w[build.stdout build.stderr].each{|f|FileUtils.copy_file(dir+'/'+f,target+'/'+f)}
  stem=File.basename(record.fetch('source'),'.rb')
  Dir[dir+'/artifacts/*'].each{|f|FileUtils.copy_file(f,target+'/'+stem+'.'+File.basename(f).delete_prefix('xdpcount.'))}
  entries<<{id:id,source:record.fetch('source'),source_sha256:record.fetch('source_sha256'),producer_rc:status.exitstatus,dir:'cases/'+id}
  File.write(out+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
end
puts JSON.generate({captured:rows.size,consumer_sha256:tool_sha})
