#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'open3'
require 'fileutils'
require 'zlib'
repo,producer,verifier,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: capture-dependent-loops REPO PRODUCER VERIFIER FRESH_OUT' unless out
abort 'output exists' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'producer pin changed' unless sha.call(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
selection=JSON.parse(File.read(repo+'/docs/experiments/results/E027/selection.json')).fetch('negative')
abort 'negative selection changed' unless selection.size==6
FileUtils.mkdir_p(out+'/source/ruby')
FileUtils.cp_r(repo+'/docs/experiments/results/E003/ruby-lib',out+'/source/ruby/lib')
FileUtils.mkdir_p(out+'/tools');tool=out+'/tools/spinel-mlir';FileUtils.copy_file(verifier,tool);File.chmod(0755,tool)
inputs={producer_sha256:sha.call(producer),verifier_sha256:sha.call(tool),runner_sha256:sha.call(__FILE__),
  library:Dir[out+'/source/ruby/lib/**/*'].select{|p|File.file?(p)}.sort.to_h{|p|[p,sha.call(p)]},
  patches:Dir[repo+'/patches/M*-*.patch'].sort.to_h{|p|[File.basename(p),sha.call(p)]}}
File.write(out+'/inputs.json',JSON.pretty_generate(inputs)+"\n")
rows=[]
selection.each do |c|
  id=c.fetch('id');dir=out+'/arms/'+id;FileUtils.mkdir_p(dir)
  source=repo+'/docs/experiments/results/E003/capture/negative/'+id+'/'+File.basename(c.fetch('source'))
  abort 'source hash mismatch' unless sha.call(source)==c.fetch('source_sha256')
  text=File.binread(source);roots=text.scan(/^BPF\.xdp\s+:([a-zA-Z_]\w*)\s*$/).flatten
  abort 'ambiguous static root' unless roots.size==1
  path=out+'/source/'+c.fetch('source');FileUtils.mkdir_p(File.dirname(path));FileUtils.copy_file(source,path)
  facts=dir+'/facts.mlir'
  args=['/usr/bin/timeout','--kill-after=5s','60s',producer,'-I',out+'/source/ruby/lib','--emit-mlir='+facts,'--analysis-root='+roots.first+':obj_BPF::XdpMd',path]
  o,e,s=Open3.capture3(*args,chdir:out+'/source')
  File.binwrite(dir+'/build.stdout',o);File.binwrite(dir+'/build.stderr',e)
  row={id:id,source:c.fetch('source'),source_sha256:c.fetch('source_sha256'),argv:args,rc:s.exitstatus,signal:s.termsig,
    facts: facts,facts_bytes:File.file?(facts)?File.size(facts):0,facts_sha256:File.file?(facts)?sha.call(facts):nil,
    producer_sha256:inputs[:producer_sha256]}
  rows<<row;File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n")
  abort 'STOP producer '+id unless s.success? && o.empty? && row[:facts_bytes]>0
  vo,ve,vs=Open3.capture3(tool,'--verify-only',facts)
  File.binwrite(dir+'/verify.stdout',vo);File.binwrite(dir+'/verify.stderr',ve)
  row[:verify_rc]=vs.exitstatus;row[:verify_signal]=vs.termsig
  File.write(out+'/ledger.json',JSON.pretty_generate(rows)+"\n")
  abort 'STOP verify '+id unless vs.success? && vo.empty? && ve.empty?
  Zlib::GzipWriter.open(facts+'.gz'){|gz|gz.write(File.binread(facts))}
end
File.write(out+'/complete.json',JSON.pretty_generate({complete:true,cases:rows.size})+"\n")
puts 'captured six successful nonempty facts with six successful verifier arms'
