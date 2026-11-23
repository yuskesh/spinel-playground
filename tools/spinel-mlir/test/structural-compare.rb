#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: structural-compare.rb NORMALIZER REPO FRESH_OUT' unless ARGV.size==3
tool,repo,out=ARGV.map{|p|File.expand_path(p)}
abort 'output exists' if File.exist?(out)
FileUtils.mkdir_p("#{out}/tmp")
ENV['TMPDIR']="#{out}/tmp"
ledger=[]
def normalize(tool,file,prefix)
 o,e,s=Open3.capture3(tool,file)
 File.binwrite(prefix+'.stdout',o);File.binwrite(prefix+'.stderr',e)
 File.write(prefix+'.rc',"#{s.exitstatus}\n")
 [o,e,s.exitstatus]
end
run_pair=lambda do |name,left,right,equal|
 dir="#{out}/#{name}";FileUtils.mkdir_p(dir)
 File.write("#{dir}/left.mlir",left);File.write("#{dir}/right.mlir",right)
 lo,le,lr=normalize(tool,"#{dir}/left.mlir","#{dir}/left")
 ro,re,rr=normalize(tool,"#{dir}/right.mlir","#{dir}/right")
 abort "#{name}: pair must parse/verify successfully: #{lr}/#{rr} #{le} #{re}" unless lr==0 && rr==0 && !lo.empty? && !ro.empty?
 same=lo==ro
 first=lo.lines.zip(ro.lines).find_index{|a,b|a!=b}
 ledger<<{'case'=>name,'expected'=>equal ? 'equal' : 'different','left_rc'=>lr,'right_rc'=>rr,'observed'=>same ? 'equal' : 'different','first_different_line'=>first && first+1}
 File.write("#{out}/ledger.json",JSON.pretty_generate(ledger)+"\n")
 abort "#{name}: wrong structural result" unless same==equal
 lo
end
base=<<~MLIR
  ebpf.program @p "xdp" {
  ^entry(%ctx: !ebpf.ctx<"xdp">):
    %a = arith.constant 7 : i64 loc("fixture.rb":3:3)
    %b = arith.constant 2 : i64 loc("fixture.rb":4:3)
    %r = arith.subi %a, %b : i64 loc("fixture.rb":5:3)
    %c = arith.constant true
    %v = ebpf.if %c -> i64 {
      ebpf.if.yield %a : i64
    } else {
      ebpf.if.yield %b : i64
    }
    ebpf.verdict "pass" loc("fixture.rb":12:3)
  } loc("fixture.rb":1:1)
MLIR
run_pair.call('op-name',base,base.sub('arith.subi','arith.addi'),false)
run_pair.call('type',base,base.gsub('i64','i32'),false)
run_pair.call('attribute',base,base.sub('constant 7','constant 8'),false)
run_pair.call('operand-order',base,base.sub('arith.subi %a, %b','arith.subi %b, %a'),false)
run_pair.call('region',base,base.sub('ebpf.if.yield %a','ebpf.if.yield %b'),false)
other=<<~MLIR
  ebpf.program @q "xdp" {
  ^entry(%ctx: !ebpf.ctx<"xdp">):
    ebpf.verdict "drop" loc("other.rb":3:3)
  } loc("other.rb":1:1)
MLIR
run_pair.call('declaration-order',base+other,other+base,false)
run_pair.call('symbol',base,base.sub('@p','@renamed_symbol'),false)
run_pair.call('location-file',base,base.sub('"fixture.rb":12:3','"other.rb":12:3'),false)
run_pair.call('location-line',base,base.sub('"fixture.rb":12:3','"fixture.rb":13:3'),false)
run_pair.call('location-column',base,base.sub('"fixture.rb":12:3','"fixture.rb":12:4'),false)
argloc=base.sub('%ctx: !ebpf.ctx<"xdp">','%ctx: !ebpf.ctx<"xdp"> loc("argument.rb":2:8)')
run_pair.call('block-argument-location',argloc,argloc.sub('"argument.rb":2:8','"argument.rb":2:9'),false)
fused=base.sub('loc("fixture.rb":12:3)','loc(fused["fixture.rb":12:3, "second.rb":7:1])')
named=base.sub('loc("fixture.rb":12:3)','loc("named"("fixture.rb":12:3))')
run_pair.call('fused-location',fused,fused.sub('"second.rb":7:1','"second.rb":8:1'),false)
run_pair.call('named-location',named,named.sub('"named"','"changed-name"'),false)
# Explicit locations that happen to name the *original* input remain explicit.
explicit=base.sub('"fixture.rb":12:3',"\"#{out}/explicit-original/left.mlir\":12:3")
run_pair.call('explicit-original',explicit,explicit.sub(':12:3',':12:4'),false)
run_pair.call('composite-style',fused,"// style\n\n"+fused.gsub('%ctx','%renamed_ctx'),true)
capture="#{repo}/docs/experiments/results/E003/capture"
manifest=JSON.parse(File.read("#{capture}/manifest.json"))
inventory=JSON.parse(File.read("#{capture}/sha256.json"))
cases=manifest['cases'].select{|c|c['kind']=='positive'}
abort "positive count #{cases.size}" unless cases.size==105
cases.each do |c|
 rel="#{c['raw_dir']}/#{File.basename(c['source'],'.rb')}.mlir"
 raw=File.binread("#{capture}/#{rel}")
 abort "oracle hash #{c['id']}" unless Digest::SHA256.hexdigest(raw)==inventory.fetch(rel)
 names={}
 changed=raw.gsub(/"(?:\\.|[^"\\])*"|\/\/[^\n]*|%[A-Za-z0-9_.$-]+/) do |token|
  token.start_with?('%') ? (names[token] ||= "%renamed#{names.size}") : token
 end
 changed="// E005 whitespace, comment and SSA-only fixture\n\n"+changed.lines.map{|line|'  '+line+"\n"}.join
 abort "no style transform #{c['id']}" if changed==raw
 run_pair.call("corpus-#{c['id']}",raw,changed,true)
end
canonical=run_pair.call('idempotence',base,"\n"+base,true)
run_pair.call('canonical-reparse',canonical,base,true)
invalid={
 'syntax'=>'ebpf.program @broken {',
 'unknown-op'=>'"unregistered.invalid"() : () -> ()',
 'type-mismatch'=>base.sub('arith.subi %a, %b : i64','arith.subi %a, %b : i32'),
 'region-verifier'=>base.sub('ebpf.if.yield %a : i64','ebpf.if.yield'),
 'reserved-location'=>base.sub('"fixture.rb":12:3','"__spinel_ir_normalize_input__.mlir":12:3'),
 'reserved-fused'=>fused.sub('"second.rb":7:1','"path/__spinel_ir_normalize_input__.mlir":7:1')
}
invalid.each do |name,text|
 dir="#{out}/reject-#{name}";FileUtils.mkdir_p(dir);File.write("#{dir}/input.mlir",text)
 o,e,rc=normalize(tool,"#{dir}/input.mlir","#{dir}/result")
 expected=name.start_with?('reserved') ? 'normalizer-reserved-location' : 'normalizer-invalid-input'
 abort "#{name}: rejection not observed" unless rc!=0 && o.empty? && e.include?(expected)
 ledger<<{'case'=>"reject-#{name}",'rc'=>rc,'diagnostic'=>expected,'observed'=>'rejected'}
end
o,e,rc=normalize(tool,"#{out}/absent.mlir","#{out}/absent")
abort 'missing file not rejected' unless rc==2 && o.empty? && e.include?('normalizer-input-io')
ledger<<{'case'=>'missing-file','rc'=>rc,'diagnostic'=>'normalizer-input-io','observed'=>'rejected'}
driver="#{repo}/scripts/compare-mlir.rb"
[['equal',"#{out}/idempotence/left.mlir","#{out}/idempotence/right.mlir",0,'structural-equal'],
 ['different',"#{out}/op-name/left.mlir","#{out}/op-name/right.mlir",1,'structural-different'],
 ['invalid',"#{out}/reject-syntax/input.mlir","#{out}/reject-syntax/input.mlir",2,'structural-input-failed']].each do |name,left,right,want,word|
 o,e,s=Open3.capture3('ruby',driver,tool,left,right)
 File.binwrite("#{out}/driver-#{name}.stdout",o);File.binwrite("#{out}/driver-#{name}.stderr",e)
 abort "driver #{name}" unless s.exitstatus==want && (o+e).include?(word)
 ledger<<{'case'=>"driver-#{name}",'rc'=>s.exitstatus,'diagnostic'=>word}
end
%w[empty failed].each do |name|
 fake="#{out}/#{name}-normalizer.sh"
 File.write(fake,"#!/bin/sh\nexit #{name=='empty' ? 0 : 1}\n");File.chmod(0755,fake)
 o,e,s=Open3.capture3('ruby',driver,fake,"#{out}/idempotence/left.mlir","#{out}/idempotence/right.mlir")
 word=name=='empty' ? 'structural-empty-normal-form' : 'structural-input-failed'
 abort "driver #{name}" unless s.exitstatus==2 && e.include?(word)
 ledger<<{'case'=>"driver-#{name}",'rc'=>s.exitstatus,'diagnostic'=>word}
end
abort 'temporary files remain' unless Dir.children("#{out}/tmp").empty?
File.write("#{out}/ledger.json",JSON.pretty_generate(ledger)+"\n")
File.write("#{out}/summary.json",JSON.pretty_generate({'normalizer_sha256'=>Digest::SHA256.file(tool).hexdigest,'corpus'=>cases.size,'checks'=>ledger.size,'temporary_entries'=>0})+"\n")
puts "E005 corpus=#{cases.size} checks=#{ledger.size} all expected observations matched"
