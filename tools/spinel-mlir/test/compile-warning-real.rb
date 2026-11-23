# E030: exercise actual compiler output once; ordinary lit uses the unit test.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative '../scripts/lib/compile-warnings'
require_relative '../scripts/lib/byte-comparison'
pin,compiler,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: compile-warning-real PINNED_BPF_REPO COMPILER FRESH_OUT' unless out
abort 'real-warning-output-exists' if File.exist?(out)
abort 'real-warning-compiler-hash' unless Digest::SHA256.file(compiler).hexdigest=='60853aa9b02a252a3e6bacdf88bcdf76d6fb57621177b651e18433c8b7b9222b'
fixtures={
  'idx'=>['kernel/nonroot/idx','idx_const.mlir',{11=>['%z = arith.constant 0 : i64','idx.rb',12,10],26=>['}','idx.rb',19,11]}],
  'm1'=>['test/Target/EBPF/Inputs/m1fit/c5_end','a_two_c5_end.mlir',{33=>['}','m1.rb',28,7],50=>['}','m1.rb',42,7]}]
}
fix=' — known fixes (bpf-mlir): keep a constant default out of the index, e.g. put the ref.index inside the present region (E274); leave room after a record array up to the next power of two (E285)'
index='the index of ebpf.ref.index can be a constant on one path and a non-constant value on another — loaders without CAP_PERFMON were observed to reject this pointer arithmetic on some kernels (E254 / E274); keep the default out of the index (put the ref.index inside the present region) or make the default non-constant'
mask='the mask range of this ebpf.ref.index ("hist", up to byte 36) reaches past the 24-byte record, so avoiding the non-root speculative-path rejection depends on register allocation (E284); leaving room after the array up to the next power of two in the schema record puts it in the guaranteed range'
want={
  'idx'=>'spinelbpf: warning: idx.rb:19:11: conditional SB021 (CompileWarning): ebpf-compile: '+index+' (note at idx.rb:12:10: the constant index comes from here)'+fix+"\n",
  'm1'=>[28,42].map{|line|'spinelbpf: warning: m1.rb:'+line.to_s+':7: conditional SB021 (CompileWarning): ebpf-compile: '+mask+fix+"\n"}.join
}
FileUtils.mkdir_p(out)
ledger=[]
fixtures.each do |name,(dir,file,locations)|
  work=out+'/'+name;FileUtils.mkdir_p(work)
  lines=File.readlines(pin+'/'+dir+'/'+file,chomp:true)
  locations.each do |i,(shape,source,line,col)|
    abort 'real-warning-fixture-shape' unless lines.fetch(i).strip==shape
    lines[i]+=" loc(\"#{source}\":#{line}:#{col})"
  end
  File.write(work+'/'+name+'.mlir',lines.join("\n")+"\n")
  FileUtils.copy_file(pin+'/'+dir+'/schema.json',work+'/'+name+'.schema.json')
  argv=[compiler,name+'.mlir','--schema',name+'.schema.json','--line-info=auto','-o',name+'.bpf.o']
  o,e,s=Open3.capture3(*argv,chdir:work)
  File.binwrite(work+'/compile.stdout',o);File.binwrite(work+'/compile.stderr',e)
  row={name:name,argv:argv,cwd:work,rc:s.exitstatus,signal:s.termsig,compiler_sha256:Digest::SHA256.file(compiler).hexdigest}
  File.write(work+'/command.json',JSON.pretty_generate(row)+"\n")
  abort 'STOP real-warning-compile' unless s.success? && o.empty? && File.size?(work+'/'+name+'.bpf.o')
  rendered=CompileWarnings.render(o,e)
  File.binwrite(work+'/actual.txt',rendered);File.binwrite(work+'/want.txt',want.fetch(name))
  abort 'STOP real-warning-byte-difference' unless ByteComparison.equal?(rendered,want.fetch(name))
  row[:warnings]=rendered.lines.size;row[:same]=true
  # The only mutation changes the first actual warning body by one ASCII byte.
  mutated=e.sub('warning: the','warning: The')
  abort 'real-warning-mutation-shape' if ByteComparison.equal?(mutated,e)
  changed=CompileWarnings.render(o,mutated)
  diffs=rendered.bytes.zip(changed.bytes).each_index.select{|i|rendered.getbyte(i)!=changed.getbyte(i)}
  abort 'STOP real-warning-sensitivity' unless rendered.bytesize==changed.bytesize && diffs.size==1
  File.binwrite(work+'/mutant.stderr',mutated);File.binwrite(work+'/mutant.txt',changed)
  row[:mutation]={name:'warning-body-first-byte',different_bytes:diffs.size,other_lines_unchanged:ByteComparison.equal?(rendered.lines.drop(1).join,changed.lines.drop(1).join)}
  ledger<<row;File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
end
abort 'real-warning-count' unless ledger.sum{|r|r[:warnings]}==3
puts JSON.generate({fixtures:ledger.size,warnings:3,same:true})
