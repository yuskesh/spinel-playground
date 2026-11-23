#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "json"
require "open3"
require "zlib"
abort "usage: capture-loop-negative-facts.rb REPO PRODUCER VERIFIER NEW_OUTPUT PRIOR_OUTPUT" unless ARGV.size==5
repo,producer,verifier,output,prior=ARGV.map{|p|File.expand_path(p)}
abort "output exists" if File.exist?(output)
abort "wrong producer pin" unless Digest::SHA256.file(producer).hexdigest=="b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223"
selection=JSON.parse(File.read(File.join(repo,"docs/experiments/results/E012/selection.json")))
abort "negative set differs" unless selection["negative"].size==15
oldHash="9da45682ceda5b2994d464d62c015a3a7164f360366189e9b44a90be941c78e2"
priorInputs=JSON.parse(File.read(File.join(prior,"inputs.json")))
abort "prior producer pin differs" unless priorInputs.any?{|r|r["sha256"]==oldHash}
reused=selection["negative"].take(6).map do |c|
  dir=File.join(prior,c["id"])
  row=JSON.parse(File.read(File.join(dir,"execution.json")))
  verify=JSON.parse(File.read(File.join(dir,"verify.json")))
  abort "prior arm failed #{c["id"]}" unless row["rc"]==0 && row["bytes"]>0 && verify["rc"]==0
  raise "prior facts empty" unless Zlib::GzipReader.open(File.join(dir,"facts.mlir.gz")){|gz|gz.read.bytesize}==row["bytes"]
  row.merge("producer_sha256"=>oldHash,"reused"=>true,"raw_dir"=>dir,
    "facts_gzip_sha256"=>Digest::SHA256.file(File.join(dir,"facts.mlir.gz")).hexdigest)
end
remaining=selection["negative"].drop(6)
abort "remaining set differs" unless remaining.size==9
FileUtils.mkdir_p(output)
sourceRoot=File.join(output,"source")
library=File.join(sourceRoot,"ruby/lib")
FileUtils.mkdir_p(File.dirname(library))
FileUtils.cp_r(File.join(repo,"docs/experiments/results/E003/ruby-lib"),library)
inputs=Dir.glob(File.join(library,"**/*")).select{|p|File.file?(p)}.map{|p|{path:p,sha256:Digest::SHA256.file(p).hexdigest}}
selection["negative"].each do |c|
  original=File.join(repo,"docs/experiments/results/E003/capture",c["raw_dir"],File.basename(c["source"]))
  abort "source hash differs #{c["id"]}" unless Digest::SHA256.file(original).hexdigest==c["source_sha256"]
  text=File.binread(original)
  abort "unexpected root signature #{c["id"]}" unless text.match?(/def prog\(ctx\)/) && text.match?(/BPF\.xdp :prog/)
  target=File.join(sourceRoot,c["source"])
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.copy_file(original,target)
  inputs<<{path:target,sha256:c["source_sha256"]}
end
inputs<<{path:producer,sha256:Digest::SHA256.file(producer).hexdigest}
inputs<<{path:verifier,sha256:Digest::SHA256.file(verifier).hexdigest}
inputs<<{path:__FILE__,sha256:Digest::SHA256.file(__FILE__).hexdigest}
File.write(File.join(output,"inputs.json"),JSON.pretty_generate(inputs)+"\n")
ledger=File.open(File.join(output,"ledger.jsonl"),"w")
reused.each{|row|ledger.puts(JSON.generate(row))};ledger.flush
complete=false
begin
  remaining.each do |c|
    dir=File.join(output,c["id"]);FileUtils.mkdir_p(dir)
    target=File.join(dir,"facts.mlir")
    args=["/usr/bin/timeout","--kill-after=5s","60s",producer,"-I",library,
          "--emit-mlir="+target,"--analysis-root=prog:obj_BPF::XdpMd",File.join(sourceRoot,c["source"])]
    stdout,stderr,status=Open3.capture3({"LC_ALL"=>"C"},*args,chdir:sourceRoot)
    File.binwrite(File.join(dir,"stdout"),stdout);File.binwrite(File.join(dir,"stderr"),stderr)
    row={id:c["id"],producer_sha256:Digest::SHA256.file(producer).hexdigest,reused:false,argv:args,cwd:sourceRoot,rc:status.exitstatus,signal:status.termsig,
         bytes:File.file?(target)?File.size(target):0}
    File.write(File.join(dir,"execution.json"),JSON.pretty_generate(row)+"\n")
    ledger.puts(JSON.generate(row));ledger.flush
    raise "STOP producer #{c["id"]}: rc=#{status.exitstatus}" unless status.success? && stdout.empty? && row[:bytes]>0
    vo,ve,vs=Open3.capture3(verifier,"--verify-only",target)
    File.binwrite(File.join(dir,"verify.stdout"),vo);File.binwrite(File.join(dir,"verify.stderr"),ve)
    File.write(File.join(dir,"verify.json"),JSON.pretty_generate({rc:vs.exitstatus,signal:vs.termsig})+"\n")
    Zlib::GzipWriter.open(target+".gz"){|gz|gz.write(File.binread(target))}
    File.unlink(target)
    raise "STOP verify #{c["id"]}: #{ve}" unless vs.success? && vo.empty? && ve.empty?
  end
  complete=true
  puts "E012 negative facts: 6 reused + 9 new successful nonempty producer arms and verifier arms"
rescue StandardError=>error
  File.write(File.join(output,"stop.txt"),error.message+"\n")
  warn error.message
ensure
  ledger.close
  File.write(File.join(output,"complete.json"),JSON.pretty_generate({complete:complete})+"\n")
end
exit(complete ? 0 : 1)
