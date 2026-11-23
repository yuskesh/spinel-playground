#!/usr/bin/env ruby
# E014 addendum B: compare control/candidate facts line by line. The only
# allowed differences are the root ProgramNode (id 0) and StatementsNode (id 1)
# node lines of both phases, which in the candidate must carry no position
# (node_end_line "0", file_id = -1, span = [], loc(unknown)). Any other
# difference is named. Exit 0 when every pair matches the prediction, 1 otherwise.
require 'json'
pairs=ARGV.each_slice(2).to_a
abort 'usage: check-crossfile-lines CONTROL CANDIDATE [CONTROL CANDIDATE ...]' if pairs.empty? || pairs.last.size!=2
root_line=/\A    "spinel_facts\.node"\(\) \{id = ([01]) : i64, kind = "(ProgramNode|StatementsNode)"/
bad=0
pairs.each do |a,b|
  x=File.readlines(a); y=File.readlines(b)
  problems=[]; changed=[]
  problems<<"line count #{x.size} vs #{y.size}" if x.size!=y.size
  [x.size,y.size].min.times do |i|
    next if x[i]==y[i]
    m=x[i].match(root_line); n=y[i].match(root_line)
    if m && n && m[1]==n[1] && m[2]==n[2] &&
       y[i].include?('"node_end_line" = "0"') && y[i].include?('file_id = -1 : i64, span = []') && y[i].end_with?("loc(unknown)\n") &&
       x[i].sub(/"node_end_line" = "\d+"/,'').sub(/file_id = -?\d+ : i64, span = \[[^\]]*\]/,'').sub(/loc\(.*\)\n\z/,'')==
       y[i].sub(/"node_end_line" = "\d+"/,'').sub(/file_id = -?\d+ : i64, span = \[[^\]]*\]/,'').sub(/loc\(.*\)\n\z/,'')
      changed<<"#{m[2]}##{m[1]}"
    else
      problems<<"line #{i+1}: unexpected difference"
    end
  end
  problems<<"changed root lines #{changed.sort.inspect} (want 2 ProgramNode#0 and 2 StatementsNode#1)" unless changed.sort==%w[ProgramNode#0 ProgramNode#0 StatementsNode#1 StatementsNode#1]
  puts "#{b}: #{problems.empty? ? 'ok (4 root lines)' : problems.first(5).join('; ')}"
  bad+=1 unless problems.empty?
end
puts "pairs #{pairs.size}, mismatched #{bad}"
exit(bad==0 ? 0 : 1)
