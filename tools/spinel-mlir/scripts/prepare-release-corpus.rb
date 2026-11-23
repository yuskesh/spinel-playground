#!/usr/bin/env ruby
require_relative 'lib/release-corpus'
require 'fileutils'
clone,pin,out,flag,prefix=ARGV
abort 'usage: prepare-release-corpus CLONE EXACT_PIN FRESH_OUT [--register PREFIX]' unless ARGV.size==3 || (ARGV.size==5 && flag=='--register' && prefix.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/))
clone,out=[clone,out].map { |p| File.expand_path(p) }
abort 'fresh output required' if File.exist?(out)
inventories=%w[p002 bcc].to_h { |name| [name, ReleaseCorpus.inventory(clone,pin,name)] }
FileUtils.mkdir_p(out)
inventories.each do |name, inventory|
  File.write(out+'/'+name+'-inventory.json',JSON.pretty_generate(inventory)+"\n")
  File.write(out+'/'+name+'-groups.md',inventory.fetch('cases').select { |r| r['kind']=='positive' }.map { |r| '|H|`'+r.fetch('source')+'`|' }.join("\n")+"\n")
end
if flag
  path=File.join(__dir__,'lib/corpus-contracts.json');profiles=JSON.parse(File.binread(path))
  entries=inventories.to_h do |kind,inventory|
    name=prefix+'-'+kind
    raise 'release profile already registered: '+name if profiles.key?(name)
    rows=inventory.fetch('cases')
    [name,{'positive_ids'=>rows.select { |r| r['kind']=='positive' }.map { |r| r.fetch('id') },'negative_ids'=>rows.select { |r| r['kind']=='negative' }.map { |r| r.fetch('id') },'oracle_manifest_sha256'=>'0'*64}]
  end
  File.binwrite(path,JSON.pretty_generate(profiles.merge(entries))+"\n")
end
puts JSON.generate(inventories.transform_values { |j| j.fetch('cases').map { |r| r.fetch('kind') }.tally })
