#!/usr/bin/env ruby
# E015: acquire only the selected negative real facts, once, after M3 correction.
require 'json'
require 'digest'
require 'fileutils'
repo, producer, verifier, out = ARGV
abort 'usage: capture-packet-negative REPO PRODUCER VERIFIER FRESH_OUT' unless out
repo, producer, verifier, out = [repo,producer,verifier,out].map { |p| File.expand_path(p) }
abort 'output exists' if File.exist?(out)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
abort 'producer hash mismatch' unless sha.call(producer) == 'b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
abort 'missing tool' unless [producer,verifier,'/usr/bin/timeout'].all? { |p| File.executable?(p) }
cases = JSON.parse(File.read(repo+'/docs/experiments/results/E015/preflight/negative.json')).select { |c| c['scope']=='core' }
abort 'negative core coverage' unless cases.size==49
library = JSON.parse(File.read(repo+'/docs/experiments/results/E003/inputs-and-library.json')).fetch('ruby_lib')
ctx = {'xdp'=>'XdpMd','tcx'=>'SkBuff','flow_dissector'=>'FlowCtx'}
plan = cases.map do |c|
  path = repo+'/docs/experiments/results/E003/capture/'+c.fetch('raw_dir')+'/'+File.basename(c.fetch('source'))
  abort "source hash #{c['id']}" unless sha.call(path)==c.fetch('source_sha256')
  roots = File.read(path).lines.filter_map do |line|
    m = line.match(/^BPF\.(xdp|tcx|flow_dissector)\s+:([A-Za-z_]\w*)(?:,\s*:(ingress|egress))?\s*$/)
    m && {method:m[2],kind:m[1],attach:m[3],request:"#{m[2]}:obj_BPF::#{ctx.fetch(m[1])}"}
  end
  abort "unrequestable root #{c['id']}" unless roots.size==1
  c.merge('original'=>path,'requests'=>roots)
end
FileUtils.mkdir_p(out+'/source/ruby/lib/native')
library.each do |relative, expected|
  source = repo+'/docs/experiments/results/E003/ruby-lib/'+relative.delete_prefix('ruby/lib/')
  abort "library hash #{relative}" unless sha.call(source)==expected
  target = out+'/source/'+relative
  FileUtils.mkdir_p(File.dirname(target)); FileUtils.copy_file(source,target)
end
plan.each do |c|
  target = out+'/source/'+c.fetch('source')
  FileUtils.mkdir_p(File.dirname(target)); FileUtils.copy_file(c.fetch('original'),target)
end
File.write(out+'/plan.json',JSON.pretty_generate({producer_sha256:sha.call(producer),verifier_sha256:sha.call(verifier),cases:plan})+"\n")
File.open(out+'/ledger.jsonl','w') do |ledger|
  plan.each do |c|
    dir = out+'/arms/'+c.fetch('id'); FileUtils.mkdir_p(dir)
    target = dir+'/facts.mlir'
    argv = [producer,'-I',out+'/source/ruby/lib',"--emit-mlir=#{target}"] +
      c.fetch('requests').map { |r| '--analysis-root='+r.fetch(:request) } + [out+'/source/'+c.fetch('source')]
    system('/usr/bin/timeout','--kill-after=5s','60s',*argv,chdir:out+'/source',out:dir+'/stdout',err:dir+'/stderr')
    st = $?
    row = {id:c.fetch('id'),argv:argv,rc:st.exitstatus,signal:st.termsig,stdout_bytes:File.size(dir+'/stdout'),
           artifact_bytes:File.file?(target) ? File.size(target) : 0}
    File.write(dir+'/command.json',JSON.pretty_generate(row)+"\n")
    if row[:rc]==0 && row[:signal].nil? && row[:stdout_bytes]==0 && row[:artifact_bytes]>0
      row[:facts_sha256]=sha.call(target)
      system(verifier,'--verify-only',target,out:dir+'/verify.stdout',err:dir+'/verify.stderr')
      row[:verify_rc]=$?.exitstatus; row[:verify_signal]=$?.termsig
    end
    row[:supply_success]=row[:rc]==0 && row[:verify_rc]==0 && row[:signal].nil? && row[:verify_signal].nil? && row[:artifact_bytes]>0
    ledger.puts(JSON.generate(row));ledger.flush
    puts "#{row[:id]} producer=#{row[:rc]} verify=#{row[:verify_rc]} bytes=#{row[:artifact_bytes]}"
    abort "STOP negative facts supply #{c['id']}" unless row[:supply_success]
  end
end
