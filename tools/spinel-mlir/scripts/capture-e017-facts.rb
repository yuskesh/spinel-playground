#!/usr/bin/env ruby
# E017 H8: produce facts once for the active group-E inputs with a pinned
# producer. Sources and the Ruby library are copied after their E003 hashes are
# checked; each case runs with its one explicit BPF.xdp root. The consumer is
# not run (verify only). Exit 0 when the run completed, 3 on a contract stop.
require 'json'
require 'digest'
require 'fileutils'
repo,library,producer,tool,output=ARGV
abort 'usage: capture-e017-facts repo ruby-lib-source-root producer tool new-output' unless output
abort 'output exists' if File.exist?(output)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'producer pin mismatch' unless sha.(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
capture=File.join(repo,'docs/experiments/results/E003/capture')
manifest=JSON.parse(File.read(File.join(capture,'manifest.json')))['cases'].to_h{|c|[c['id'],c]}
lib=JSON.parse(File.read(File.join(repo,'docs/experiments/results/E003/inputs-and-library.json'))).fetch('ruby_lib')
results=File.join(repo,'docs/experiments/results/E017')
active=File.readlines(File.join(results,'positive-selection.tsv')).drop(1).map{|l|l.chomp.split("\t")}.select{|r|r[4]=='yes'}.map{|r|r[0]}+
       File.readlines(File.join(results,'negative-selection.tsv')).drop(1).map{|l|l.chomp.split("\t")}.select{|r|r[9]=='yes'}.map{|r|r[0]}
abort "active count #{active.size}" unless active.size==26
src=File.join(output,'source')
lib.each do |rel,want|
  from=File.join(library,rel); abort "library hash #{rel}" unless sha.(from)==want
  to=File.join(src,rel); FileUtils.mkdir_p(File.dirname(to)); FileUtils.cp(from,to)
end
File.write(File.join(output,'pins.json'),JSON.pretty_generate({producer:{path:producer,sha256:sha.(producer)},tool:{path:tool,sha256:sha.(tool)},cases:active.size})+"\n")
ledger=File.open(File.join(output,'ledger.jsonl'),'w'); stop=nil
active.each do |id|
  c=manifest.fetch(id)
  from=File.join(capture,c['raw_dir'],File.basename(c['source']))
  abort "source hash #{id}" unless sha.(from)==c['source_sha256']
  to=File.join(src,c['source']); FileUtils.mkdir_p(File.dirname(to)); FileUtils.cp(from,to)
  roots=File.read(to).scan(/^BPF\.xdp :([a-z_0-9]+)/).flatten
  abort "root count #{id}" unless roots.size==1 && File.read(to).scan(/^BPF\.[a-z_]+ :/).size==1
  dir=File.join(output,'cases',id); FileUtils.mkdir_p(dir); facts=File.join(dir,'facts.mlir')
  args=[producer,'-I',File.join(src,'ruby/lib'),"--emit-mlir=#{facts}","--analysis-root=#{roots[0]}:obj_BPF::XdpMd",to]
  system('/usr/bin/timeout','--kill-after=5s','60s',*args,chdir:src,out:File.join(dir,'stdout'),err:File.join(dir,'stderr'))
  st=$?
  row={id:id,kind:c['kind'],root:roots[0],rc:st.exitstatus,signal:st.termsig,stdout_bytes:File.size(File.join(dir,'stdout')),artifact_bytes:File.file?(facts) ? File.size(facts) : 0}
  if row[:artifact_bytes]>0
    row[:sha256]=sha.(facts)
    system(tool,'--verify-only',facts,out:File.join(dir,'verify.stdout'),err:File.join(dir,'verify.stderr'))
    row[:verify_rc]=$?.exitstatus
    text=File.read(facts)
    row[:status]=text[/spinel_facts\.status = "(\w+)"/,1]
    row[:splices]=text.scan('"spinel_facts.splice"').size
  end
  row[:stderr]=File.readlines(File.join(dir,'stderr')).reject{|l|l.start_with?('MLIR source-inventory')}.map(&:chomp)
  ledger.puts(JSON.generate(row)); ledger.flush
  puts "#{id} rc=#{row[:rc]} verify=#{row[:verify_rc].inspect} status=#{row[:status].inspect} bytes=#{row[:artifact_bytes]}"
  if st.signaled? || ![0,1].include?(st.exitstatus) || row[:stdout_bytes]!=0 || (st.exitstatus==0 && row[:artifact_bytes]==0)
    stop="#{id} contract"; break
  end
end
ledger.close
rows=File.readlines(File.join(output,'ledger.jsonl')).map{|l|JSON.parse(l)}
summary={cases:rows.size,expected:active.size,stop:stop,rc:rows.group_by{|r|r['rc']}.transform_values(&:size),
  verify:rows.group_by{|r|r['verify_rc']}.transform_values(&:size),status:rows.group_by{|r|r['status']}.transform_values(&:size),
  nonempty:rows.count{|r|r['artifact_bytes']>0},splices:rows.group_by{|r|r['splices']}.transform_values(&:size)}
File.write(File.join(output,'summary.json'),JSON.pretty_generate(summary)+"\n")
puts JSON.generate(summary)
exit(stop ? 3 : 0)
