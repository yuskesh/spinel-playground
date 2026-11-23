#!/usr/bin/env ruby
# E014: compare the entry file's pristine node positions in M3 facts with a
# Spinel --dump-ast taken where no require was spliced (SPINEL_NO_BUILTINS).
# Node ids are not compared (the builtins shift them); the (kind, span) rows of
# file 0 are compared in id order. Exit 0 equal, 1 named differences, 2 usage
# or an unreadable input.
dump_path,facts_path,file_arg=ARGV
abort 'usage: check-splice-positions DUMP.ast FACTS.mlir [FILE_ID]' unless facts_path
file_id=Integer(file_arg||'0')
def fail_input(msg) = (warn "check-splice-positions: #{msg}"; exit 2)

nodes={}
File.foreach(dump_path) do |line|
  case line
  when /\AN (\d+) (\S+)\n\z/ then (nodes[$1.to_i]||={})[:kind]=$2
  when /\AI (\d+) (node_line|node_file|node_col|node_end_line|node_end_col) (-?\d+)\n\z/
    (nodes[$1.to_i]||={})[$2.to_sym]=$3.to_i
  end
end
dump=nodes.keys.sort.filter_map do |id|
  n=nodes[id]
  next unless n[:kind] && n[:node_file]==file_id && n[:node_line].to_i>0 && n[:node_end_line].to_i>0
  [n[:kind],n[:node_line],n[:node_col],n[:node_end_line],n[:node_end_col]]
end

facts=[]; table=[]; phase=nil
File.foreach(facts_path) do |line|
  if line.start_with?('  "spinel_facts.table"() ({') then table=[]
  elsif line =~ /\A  \}\) \{phase = "(\w+)"/
    phase=$1; facts=table if phase=='pristine'
  elsif line.start_with?('    "spinel_facts.node"()')
    m=line.match(/\{id = (\d+) : i64, kind = "([^"]+)".*, file_id = (-?\d+) : i64, span = \[([^\]]*)\]/) or fail_input("unparsed node: #{line[0,120]}")
    span=m[4].scan(/-?\d+(?= : i64)/).map(&:to_i)
    table<<[m[1].to_i,m[2],m[3].to_i,span]
  end
end
fail_input('no pristine table') if facts.empty?
mine=facts.sort_by(&:first).filter_map do |_id,kind,fid,span|
  next unless fid==file_id && span.length==4
  [kind,span[0],span[1],span[2],span[3]]
end
fail_input('no located rows in the dump') if dump.empty?
fail_input('no located rows in the facts') if mine.empty?
diffs=[]
[dump.length,mine.length].max.times do |i|
  next if dump[i]==mine[i]
  diffs<<"row #{i}: dump=#{dump[i].inspect} facts=#{mine[i].inspect}"
end
puts "file #{file_id}: dump rows #{dump.length}, facts rows #{mine.length}, differences #{diffs.length}"
diffs.first(20).each{|d| puts "  #{d}"}
exit(diffs.empty? ? 0 : 1)
