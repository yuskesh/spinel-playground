#!/usr/bin/env ruby
# E021: compare two measure-group-a.rb outputs file by file (build.stdout,
# build.stderr, every artifact) and rc / signal / facts hash per attempt.
# Both sides must have the same files; each difference is named.
# Exit 0 equal, 1 differences, 2 usage.
require 'json'
left,right=ARGV
abort 'usage: compare-measure-runs LEFT RIGHT' unless right
l=JSON.parse(File.read(File.join(left,'ledger.json'))).to_h{|r|[r['id'],r]}
r=JSON.parse(File.read(File.join(right,'ledger.json')))
abort 'case sets differ' unless l.keys.sort==r.map{|x|x['id']}.sort
checks=0; diffs=[]
r.each do |entry|
  before=l.fetch(entry['id'])
  diffs<<"#{entry['id']}: attempt count" unless before['attempts'].size==entry['attempts'].size
  entry['attempts'].each_with_index do |att,i|
    b=before['attempts'][i] or next
    %w[rc signal facts_sha256].each do |k|
      checks+=1
      diffs<<"#{entry['id']}/#{i}: #{k} #{b[k].inspect} vs #{att[k].inspect}" unless b[k]==att[k]
    end
    files=->(dir){(%w[build.stdout build.stderr]+Dir[File.join(dir,'artifacts','*')].sort.map{|p|'artifacts/'+File.basename(p)})}
    names=(files.(b['dir'])|files.(att['dir'])).sort
    names.each do |n|
      checks+=1
      a=File.join(b['dir'],n); c=File.join(att['dir'],n)
      if !File.exist?(a) || !File.exist?(c) then diffs<<"#{entry['id']}/#{i}/#{n}: missing on one side"
      elsif File.binread(a)!=File.binread(c) then diffs<<"#{entry['id']}/#{i}/#{n}: bytes differ"
      end
    end
  end
end
puts "cases #{r.size}, checks #{checks}, differences #{diffs.size}"
diffs.first(20).each{|d| puts "  #{d}"}
exit(diffs.empty? ? 0 : 1)
