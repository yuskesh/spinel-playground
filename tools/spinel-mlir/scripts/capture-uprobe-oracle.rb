#!/usr/bin/env ruby
# Additional positives only: never add these four to the fixed 609-case corpus.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
mode=ARGV.delete('--dry-run')
repo,tools,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: capture-uprobe-oracle FIXED_GO_CLONE TOOLS FRESH_OUT' unless out
abort 'oracle-output-exists' if File.exist?(out)
pin='0ae550f4d92ebeb606f00576119ef9633c961019'
head,hs=Open3.capture2('git','-C',repo,'rev-parse','HEAD')
abort 'oracle-source-pin' unless hs.success? && head.strip==pin
expected={
  'spinelbpf'=>'1551c90db2b111af5c98da21b4f83b1396a3ef4ae3a25e6434b60ec84ef5123f',
  'spinel-go'=>'8892247dd0d29f858723f26c9a6be2a9418021cd8009726b1e1b0556656bf074',
  'ebpf-compile'=>'60853aa9b02a252a3e6bacdf88bcdf76d6fb57621177b651e18433c8b7b9222b',
  'ebpf-schema-check'=>'38bce45bc7de525dce74ae0df379b387b78e45611c521f5f899ef81d2efa4bc1'
}
sha=->(p){Digest::SHA256.file(p).hexdigest}
builtins=JSON.parse(File.read(File.expand_path('../docs/experiments/results/E040/builtins-sha256.json',__dir__)))
check=lambda do
  expected.each{|name,hash|abort 'oracle-tool-hash: '+name unless File.executable?(tools+'/'+name)&&sha.call(tools+'/'+name)==hash}
  root=tools+'/builtins'
  abort 'oracle-builtins-directory' unless File.directory?(root)
  files=Dir.glob(root+'/**/*').select{|p|File.file?(p)}.map{|p|p.delete_prefix(root+'/')}.sort
  abort 'oracle-builtins-file-set' unless files==builtins.keys.sort
  builtins.each{|name,hash|abort 'oracle-builtins-hash: '+name unless sha.call(root+'/'+name)==hash}
end
check.call
source=repo+'/internal/frontend/testdata/uprobe'
target=source+'/target/cfix';target_sha='a5808d550a0cc8c15e30df9ba2d5659574db67d624a44c514c2909233a5ab140'
abort 'oracle-target-hash' unless sha.call(target)==target_sha
if mode
  puts JSON.generate({dry_run:true,tools:expected.size,builtins:builtins.size,target_sha256:target_sha,execution:0})
  exit 0
end
FileUtils.mkdir_p(out)
meta={outside_fixed_609:true,commit:pin,tools:expected.to_h{|k,v|[k=='spinel-go' ? 'spinel' : k,{sha256:v}]},builtins:builtins,target_sha256:target_sha,cases:[]}
env={'SPINELBPF_ROOT'=>repo,'SPINEL'=>tools+'/spinel-go','EBPF_COMPILE'=>tools+'/ebpf-compile','LLVM_PREFIX'=>'/opt/llvm-23.1.1','GOPROXY'=>'off','GOSUMDB'=>'off','LC_ALL'=>'C'}
%w[up_ints uret_ints up_str up_discard].each do |name|
  dir=out+'/positive/'+name;FileUtils.mkdir_p(dir+'/target')
  FileUtils.copy_file(source+'/'+name+'.rb',dir+'/'+name+'.rb')
  FileUtils.copy_file(target,dir+'/target/cfix')
  abort 'oracle-copied-target-hash' unless sha.call(dir+'/target/cfix')==target_sha
  check.call
  argv=[tools+'/spinelbpf','build',name+'.rb']
  stdout,stderr,status=Open3.capture3(env,*argv,chdir:dir)
  File.binwrite(dir+'/build.stdout',stdout);File.binwrite(dir+'/build.stderr',stderr);File.write(dir+'/build.rc',status.exitstatus.to_s+"\n")
  row={id:name,kind:'positive',source:'internal/frontend/testdata/uprobe/'+name+'.rb',source_sha256:sha.call(dir+'/'+name+'.rb'),raw_dir:'positive/'+name,argv:argv,rc:status.exitstatus,signal:status.termsig}
  meta[:cases]<<row;File.write(out+'/manifest.json',JSON.pretty_generate(meta)+"\n")
  abort 'STOP additional-positive-build: '+name unless status.success?
  %w[mlir schema.json maps.json bpf.o].each{|ext|abort 'STOP additional-positive-empty' unless File.size?(dir+'/'+name+'.'+ext)}
  FileUtils.copy_file(dir+'/'+name+'.bpf.o',dir+'/'+name+'.auto.bpf.o');File.write(dir+'/auto.rc',"0\n")
  check.call
  off=[tools+'/ebpf-compile',name+'.mlir','--schema',name+'.schema.json','--line-info=off','-o',name+'.off.bpf.o']
  o,e,s=Open3.capture3(*off,chdir:dir)
  File.binwrite(dir+'/off.stdout',o);File.binwrite(dir+'/off.stderr',e);File.write(dir+'/off.rc',s.exitstatus.to_s+"\n")
  abort 'STOP additional-positive-off-compile: '+name unless s.success? && File.size?(dir+'/'+name+'.off.bpf.o')
end
puts JSON.generate({additional_oracle:meta[:cases].size,fixed_609_unchanged:true})
