require "json"
require "fileutils"
require "open3"
require "digest"
require "zlib"
abort "usage: controls-group-b.rb REPO NEW_OUT" unless ARGV.size==2
repo,out=ARGV.map{|p|File.expand_path(p)}
abort "output exists" if File.exist?(out)
FileUtils.mkdir_p(out)
id="internal_frontend_testdata_pos_loop_times"
baseline=repo+"/build/group-b-current/runs/"+id+"/artifacts"
facts=Zlib::GzipReader.open(repo+"/build/group-b-current/runs/"+id+"/facts.mlir.gz",&:read)
input=out+"/facts.mlir";File.binwrite(input,facts)
commands=[]
run=lambda do |name,args,cwd=nil|
  stdout,stderr,status=Open3.capture3(*args,**(cwd ? {chdir:cwd}:{}))
  File.binwrite(out+"/"+name+".stdout",stdout)
  File.binwrite(out+"/"+name+".stderr",stderr)
  row={name:name,argv:args,cwd:cwd,rc:status.exitstatus,signal:status.termsig}
  commands<<row;File.write(out+"/commands.json",JSON.pretty_generate(commands)+"\n")
  [stdout,stderr,status.exitstatus]
end
begin
  stdout,stderr,rc=run.call("count",[repo+"/build/bin/spinel-mlir-loop-mutation","--emit-dir",out+"/count",input])
  raise "count producer failed" unless rc==0 && stdout.empty? && stderr.empty?
  %w[schema.json maps.json].each do |name|
    raise "count changed "+name unless File.binread(out+"/count/xdpcount."+name)==File.binread(baseline+"/xdpcount."+name)
  end
  original,err,rc=run.call("normalize-original",[repo+"/build/bin/spinel-ir-normalize",baseline+"/xdpcount.mlir"])
  raise "original normalization failed" unless rc==0 && !original.empty? && err.empty?
  mutated,err,rc=run.call("normalize-count",[repo+"/build/bin/spinel-ir-normalize",out+"/count/xdpcount.mlir"])
  raise "count normalization failed" unless rc==0 && !mutated.empty? && err.empty?
  raise "count does not differ only at count 4 to 3" unless original.scan("count = 4 : i64").size==1 &&
    original.sub("count = 4 : i64","count = 3 : i64")==mutated
  elf=[]
  %w[auto off].each do |mode|
    _,err,rc=run.call("compile-count-"+mode,[repo+"/build/bpf-mlir/bin/ebpf-compile","xdpcount.mlir",
      "--schema","xdpcount.schema.json","--line-info="+mode,"-o","count."+mode+".o"],out+"/count")
    raise "count ELF compile failed: "+err unless rc==0
    path=out+"/count/count."+mode+".o"
    normal=repo+"/build/group-b-first-batch/elf/"+id+"/candidate/candidate."+mode+".bpf.o"
    raise "count ELF empty or unchanged" unless File.size(path)>0 && File.binread(path)!=File.binread(normal)
    elf<<{mode:mode,normal:Digest::SHA256.file(normal).hexdigest,count:Digest::SHA256.file(path).hexdigest}
  end
  changed=0
  missing=facts.lines.map do |line|
    if line.include?('"spinel_facts.evidence"') && line.include?("node_id = 2148 : i64") &&
       line.include?('kind = "BlockNode"')
      changed+=1;line.sub(", inlined = true","")
    else line end
  end.join
  raise "inlined mutation not unique" unless changed==1 && missing!=facts
  File.binwrite(out+"/missing-inlined.mlir",missing)
  stdout,stderr,rc=run.call("missing-inlined",[repo+"/build/bin/spinel-mlir","--emit-dir",out+"/missing-output",out+"/missing-inlined.mlir"])
  expected="loop_times.rb:8:3: rejected SB001 (UnsupportedConstruct): E012 loop block lacks inlined evidence\n"
  raise "inlined wrong named refusal: "+stderr unless rc==1 && stdout.empty? &&
    stderr.b==expected.b && Dir.glob(out+"/missing-output/*").empty?
  File.write(out+"/results.json",JSON.pretty_generate({count_only:true,schema_maps_same:true,elf_different:elf,missing_inlined_exact:true})+"\n")
  puts "count 4->3 only, auto/off ELF differ, and missing-inlined exact SB001: GREEN"
rescue StandardError=>error
  File.write(out+"/stop.txt",error.message+"\n");warn error.message;exit 1
end
