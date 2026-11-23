require 'fileutils'
require 'json'
require 'open3'
require 'zlib'
require_relative '../scripts/lib/byte-comparison'
build,src=ARGV.map{|x|File.expand_path(x)}
root=build+'/group-a-controls';FileUtils.rm_rf(root);FileUtils.mkdir_p(root)
$seq=0
run=lambda do |name,text,mutation=false|
 input=root+'/'+name+'.mlir';File.binwrite(input,text)
 output=root+'/'+name+'-output'
 args=[build+'/bin/'+(mutation ? 'spinel-mlir-rmw-mutation' : 'spinel-mlir'),'--emit-dir',output,input]
 stdout,stderr,status=Open3.capture3(*args)
 File.write(root+'/'+name+'.command.json',JSON.pretty_generate({argv:args,rc:status.exitstatus,signal:status.termsig})+"\n")
 File.binwrite(root+'/'+name+'.stdout',stdout);File.binwrite(root+'/'+name+'.stderr',stderr)
 [status,stdout,stderr,output]
end
original=Zlib::GzipReader.open(src+'/Inputs/group-a-ops-types.mlir.gz',&:read)
tables=[{},{}];phase=-1
original.each_line do |line|
 phase+=1 if line.include?('"spinel_facts.table"')
 next unless phase.between?(0,1)&&line.include?('"spinel_facts.node"')
 tables[phase][line[/id = (\d+) : i64/,1].to_i]=line
end
outer=tables[0].keys.find do |id|
 a,b=tables[0][id],tables[1][id]
 next false unless a.include?('file_id = 0 : i64')&&a.include?('kind = "CallNode"')&&b&&a!=b
 old=a[/"receiver" = (\d+) : i64/,1];new=b[/"receiver" = (\d+) : i64/,1]
 old&&new&&old!=new&&tables[0][old.to_i].include?('kind = "ParenthesesNode"')
end
abort 'missing parentheses witness' unless outer
old=tables[0][outer][/"receiver" = (\d+) : i64/,1].to_i
terminal=tables[1][outer][/"receiver" = (\d+) : i64/,1].to_i
statements=tables[0][old][/"body" = (\d+) : i64/,1].to_i
line=tables[0][statements];abort 'not a single statement' unless line.match?(/"body" = \[\d+ : i64\]/)
changed=line.sub(/("body" = \[)(\d+ : i64)(\])/){$1+$2+', '+$2+$3}
# Change only pristine. String#sub with a block preserves MLIR backslash bytes.
two=original.sub(line){changed}
other=tables[0].keys.find{|id|id!=terminal&&tables[0][id].include?('file_id = 0 : i64')&&tables[0][id].include?('kind = "IntegerNode"')}
changed=tables[1][outer].sub('"receiver" = '+terminal.to_s+' : i64','"receiver" = '+other.to_s+' : i64')
wrong=original.sub(tables[1][outer]){changed}
file,row,col=tables[0][outer].match(/loc\("(.*?)":(\d+):(\d+)\)/).captures
[['two-statements',two,'parentheses equivalence requires one statement'],['different-terminal',wrong,'parentheses equivalence terminal differs']].each do |name,text,message|
 status,stdout,stderr,output=run.call(name,text)
 expected="#{File.basename(file)}:#{row}:#{col}: rejected SB001 (UnsupportedConstruct): #{message}\n"
 abort "#{name}: wrong refusal #{stderr}" unless status.exitstatus==1&&stdout.empty?&&ByteComparison.equal?(stderr,expected)&&!File.exist?(output)
end
# Keep RMW and numerical error simultaneously present: widening the scalar map
# is a coherent test-only source/AST mutation, not a claim about producer output.
rmw=Zlib::GzipReader.open(src+'/Inputs/group-a-rmw.mlir.gz',&:read)
wide=rmw.lines.map do |line|
 if line.include?('"spinel_facts.source"')&&line.include?('file_id = 0 : i64')
  line.sub(':u32',':u64')
 elsif line.include?('"spinel_facts.node"')&&line.include?('file_id = 0 : i64')&&line.include?('kind = "SymbolNode"')
  line.sub('"value" = "u32"','"value" = "u64"')
 else
  line
 end
end.join
abort 'RMW mutation did not change source' if wide==rmw
normal=run.call('rmw-first',wide)
mutant=run.call('rmw-after-range',wide,true)
abort 'normal RMW priority' unless normal[0].exitstatus==1&&ByteComparison.include?(normal[2],'SB019 (SharedReadModifyWrite)')&&!File.exist?(normal[3])
abort 'RMW order mutation not detected' unless mutant[0].exitstatus==1&&ByteComparison.include?(mutant[2],'SB014 (SemanticGap)')&&!ByteComparison.include?(mutant[2],'SB019')&&!File.exist?(mutant[3])
puts 'group A controls: two named parentheses refusals and RMW-before-range mutation GREEN'
