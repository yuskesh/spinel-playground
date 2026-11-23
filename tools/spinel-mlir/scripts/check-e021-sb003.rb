#!/usr/bin/env ruby
# E021: for each named E003 negative, produce facts once with the pinned
# producer (root from the one `BPF.xdp :name` line), run the consumer once, and
# compare rc / stdout / the whole build.stderr with the saved oracle. A match
# needs consumer rc != 0, empty stdout, no published artifact and byte-equal
# stderr. Exit 0 all match, 1 named differences, 3 contract stop.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
repo,library,producer,consumer,output,*ids=ARGV
abort 'usage: check-e021-sb003 repo ruby-lib producer consumer new-output ID...' if ids.empty?
abort 'output exists' if File.exist?(output)
sha=->(p){Digest::SHA256.file(p).hexdigest}
abort 'producer pin mismatch' unless sha.(producer)=='b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
capture=File.join(repo,'docs/experiments/results/E003/capture')
cases=JSON.parse(File.read(File.join(capture,'manifest.json')))['cases'].to_h{|c|[c['id'],c]}
src=File.join(output,'source'); FileUtils.mkdir_p(src)
lib=JSON.parse(File.read(File.join(repo,'docs/experiments/results/E003/inputs-and-library.json'))).fetch('ruby_lib')
lib.each do |rel,want|
  from=File.join(library,rel); abort "library hash #{rel}" unless sha.(from)==want
  to=File.join(src,rel); FileUtils.mkdir_p(File.dirname(to)); FileUtils.cp(from,to)
end
File.write(File.join(output,'pins.json'),JSON.pretty_generate({producer:sha.(producer),consumer:sha.(consumer)})+"\n")
rows=[]
ids.each do |id|
  c=cases.fetch(id); abort "#{id} is not negative" unless c['kind']=='negative'
  dir=File.join(output,'cases',id); FileUtils.mkdir_p(dir)
  from=File.join(capture,c['raw_dir'],File.basename(c['source']))
  abort "source hash #{id}" unless sha.(from)==c['source_sha256']
  to=File.join(src,c['source']); FileUtils.mkdir_p(File.dirname(to)); FileUtils.cp(from,to)
  roots=File.read(to).scan(/^BPF\.xdp :([a-z_0-9]+)/).flatten
  abort "root #{id}" unless roots.size==1
  facts=File.join(dir,'facts.mlir')
  _,pe,ps=Open3.capture3(producer,'-I',File.join(src,'ruby/lib'),"--emit-mlir=#{facts}","--analysis-root=#{roots[0]}:obj_BPF::XdpMd",to,chdir:src)
  File.write(File.join(dir,'producer.stderr'),pe)
  row={id:id,producer_rc:ps.exitstatus,facts_bytes:File.file?(facts) ? File.size(facts) : 0}
  if ps.exitstatus!=0 || row[:facts_bytes]==0
    rows<<row.merge(stop:'producer'); break
  end
  row[:facts_sha256]=sha.(facts)
  out,err,st=Open3.capture3(consumer,'--emit-dir',File.join(dir,'artifacts'),facts)
  File.binwrite(File.join(dir,'build.stdout'),out); File.binwrite(File.join(dir,'build.stderr'),err)
  want=File.binread(File.join(capture,c['raw_dir'],'build.stderr'))
  artifacts=File.directory?(File.join(dir,'artifacts')) ? Dir[File.join(dir,'artifacts','*')].size : 0
  row.merge!(consumer_rc:st.exitstatus,stdout_bytes:out.bytesize,stderr_bytes:err.bytesize,artifacts:artifacts,
    stderr_equal:err.b==want.b,match:st.exitstatus!=0 && out.empty? && artifacts==0 && err.b==want.b)
  rows<<row
  puts "#{id} producer=#{row[:producer_rc]} consumer=#{row[:consumer_rc]} stdout=#{row[:stdout_bytes]} artifacts=#{artifacts} stderr_equal=#{row[:stderr_equal]}"
end
File.write(File.join(output,'ledger.json'),JSON.pretty_generate(rows)+"\n")
stop=rows.any?{|r|r[:stop]}
puts JSON.generate({cases:rows.size,matched:rows.count{|r|r[:match]},stop:stop})
exit(stop ? 3 : rows.all?{|r|r[:match]} ? 0 : 1)
