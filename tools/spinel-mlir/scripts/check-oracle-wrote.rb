#!/usr/bin/env ruby
# E024 precheck: every saved E003 positive build.stderr has exactly the 8 named
# `spinelbpf: wrote <...>/positive/<id>/<file>` lines (the output-path prefix
# E003's reproduction named) and no other wrote line; also list what remains
# after removing them. Exit 0 all 105 conform, 1 otherwise.
require 'json'
capture=ARGV[0] or abort 'usage: check-oracle-wrote E003-capture'
cases=JSON.parse(File.read(File.join(capture,'manifest.json')))['cases'].select{|c|c['kind']=='positive'}
abort 'expected 105 positives' unless cases.size==105
bad=[]; remaining={}
cases.each do |c|
  stem=File.basename(c['source'],'.rb'); id=c['id']
  names=%W[#{stem}.domain.json #{stem}.mlir #{stem}.schema.json #{stem}.maps.json #{stem}.compile_warnings.txt #{stem}.bpf.o #{stem}_embed.S #{stem}_embed.o]
  lines=File.binread(File.join(capture,c['raw_dir'],'build.stderr')).lines
  named=lines.select{|l| l.start_with?('spinelbpf: wrote /') && names.any?{|n| l.end_with?("/positive/#{id}/#{n}\n")}}
  other_wrote=lines.select{|l| l.start_with?('spinelbpf: wrote ')}-named
  bad<<"#{id}: named #{named.size}, other wrote #{other_wrote.size}" unless named.size==8 && named.map{|l|l[/[^\/]+\n\z/]}.uniq.size==8 && other_wrote.empty?
  rest=lines-named
  remaining[id]=rest.size unless rest.empty?
end
puts "positives #{cases.size}, conforming #{cases.size-bad.size}, with remaining lines #{remaining.size}"
remaining.each{|id,n| puts "  remaining #{id}: #{n} line(s)"}
bad.each{|b| puts "  BAD #{b}"}
exit(bad.empty? ? 0 : 1)
