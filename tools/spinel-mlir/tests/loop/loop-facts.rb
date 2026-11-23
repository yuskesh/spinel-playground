require "fileutils"
require "open3"
require "json"
require "digest"
abort "usage: loop-facts.rb BINARY E008_ARCHIVE NEW_OUTPUT" unless ARGV.size==3
binary,archive,out=ARGV.map{|x|File.expand_path(x)}
# CTest may repeat; use a fresh numbered directory and retain previous logs.
run=0;run+=1 while File.exist?(File.join(out,run.to_s))
out=File.join(out,run.to_s);FileUtils.mkdir_p(out)
member="arms/internal_frontend_testdata_pos_loop_times/0/facts.mlir"
facts,err,status=Open3.capture3("/usr/bin/tar","-xzOf",archive,member)
abort "loop facts archive: #{err}" unless status.success? && !facts.empty?
path=File.join(out,"facts.mlir");File.binwrite(path,facts)
rows=[]
[[],["same-name"]].each_with_index do |extra,i|
  stdout,stderr,rc=Open3.capture3(binary,path,*extra)
  prefix=File.join(out,i.to_s)
  File.binwrite(prefix+".stdout",stdout);File.binwrite(prefix+".stderr",stderr)
  row={mode:extra,rc:rc.exitstatus,signal:rc.termsig}
  File.write(prefix+".json",JSON.pretty_generate(row)+"\n")
  expected= if i==0
    rc.success? && stderr.empty? &&
      stdout=="loop-facts: three bindings, two renamed and one same, unknown blocks preserved\n"
  else
    rc.exitstatus==1 && stdout.empty? &&
      stderr=="loop_times.rb:15:10: rejected SB001 (UnsupportedConstruct): E012 loop local is shadowed by a different block binding\n"
  end
  abort "loop facts #{i} differs: #{stderr}" unless expected
  rows<<row
end
File.write(File.join(out,"inputs.json"),JSON.pretty_generate({
  binary:Digest::SHA256.file(binary).hexdigest,
  archive:Digest::SHA256.file(archive).hexdigest,
  facts:Digest::SHA256.hexdigest(facts),rows:rows})+"\n")
puts "loop facts bindings and same-name foreign parameter: GREEN"
