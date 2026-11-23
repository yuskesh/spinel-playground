#!/usr/bin/env ruby
require 'json'
require 'fileutils'
require 'open3'
require 'digest'
abort 'usage: check-uprobe-mutation MEASURE FRESH_OUT' unless ARGV.size==2
measure,out=ARGV.map { |p| File.expand_path(p) }
abort 'fresh output required' if File.exist?(out)
FileUtils.mkdir_p(out)
input=JSON.parse(File.read(measure+'/plan.json')).find { |r| r.fetch('id')=='up_ints' }
abort 'facts hash' unless Digest::SHA256.file(input.fetch('facts')).hexdigest==input.fetch('sha256')
args=[measure+'/tools/mutation','--emit-dir',out+'/artifacts',input.fetch('facts')]
so,se,s=Open3.capture3(*args)
File.binwrite(out+'/consumer.stdout',so);File.binwrite(out+'/consumer.stderr',se)
row={command:args,rc:s.exitstatus,signal:s.termsig}
File.write(out+'/ledger.json',JSON.pretty_generate(row)+"\n")
abort 'STOP mutation consumer' unless s.success? && File.size?(out+'/artifacts/xdpcount.mlir')
compiler=[measure+'/tools/compiler','xdpcount.mlir','--schema','xdpcount.schema.json','--line-info=auto','-o','xdpcount.auto.bpf.o']
co,ce,cs=Open3.capture3(*compiler,chdir:out+'/artifacts')
File.binwrite(out+'/compile.stdout',co);File.binwrite(out+'/compile.stderr',ce)
row[:compile]={command:compiler,rc:cs.exitstatus,signal:cs.termsig}
forms=[measure+'/cases/up_ints/up_ints.mlir',out+'/artifacts/xdpcount.mlir'].map.with_index do |path,i|
  no,ne,ns=Open3.capture3(measure+'/tools/normalizer',path)
  File.binwrite(out+"/#{i}.normal",no);File.binwrite(out+"/#{i}.stderr",ne)
  row["normalizer#{i}"]={rc:ns.exitstatus,bytes:no.bytesize}
  abort 'STOP mutation normalizer' unless ns.success? && !no.empty?
  no
end
# The only intended structural change is the extension of arg 2. The other
# argument operations and their extensions must remain byte-identical.
expected=forms[0].sub('arith.extui','arith.extsi')
row[:single_named_change]=forms[0].scan('arith.extui').size==1 && expected==forms[1] && forms[0]!=forms[1]
row[:elf_different]=cs.success? && File.size?(out+'/artifacts/xdpcount.auto.bpf.o') && File.binread(measure+'/cases/up_ints/up_ints.auto.bpf.o')!=File.binread(out+'/artifacts/xdpcount.auto.bpf.o')
File.write(out+'/ledger.json',JSON.pretty_generate(row)+"\n")
abort 'STOP mutation sensitivity' unless cs.success? && row[:single_named_change] && row[:elf_different]
puts JSON.generate(row)
