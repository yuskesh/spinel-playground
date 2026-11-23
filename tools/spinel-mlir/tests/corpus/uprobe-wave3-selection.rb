require 'json';require_relative '../../scripts/lib/release-corpus'
clone=ARGV.fetch(0);selection=JSON.parse(File.read(File.expand_path('../../docs/experiments/results/E080/selection.json',__dir__)));pin=selection.fetch('oracle_commit')
%w[p002 bcc].each{|name|raise 'default source inventory changed '+name unless ReleaseCorpus.inventory(clone,pin,name)==selection.fetch(name+'_inventory')}
rows=ReleaseCorpus.inventory(clone,pin,'uprobe-wave3').fetch('cases');wanted=selection.fetch('new_or_changed');keys=%w[id kind source source_sha256];raise 'twenty source identities' unless rows.map{|r|r.slice(*keys)}.sort_by{|r|r['id']}==wanted.map{|r|r.slice(*keys)}.sort_by{|r|r['id']}
fixtures=ReleaseCorpus.inventory(clone,pin,'uprobe-wave3-fixtures').fetch('cases');raise 'three fixture identities' unless fixtures.map{|r|r.slice(*keys)}==selection.fetch('new_auxiliary').map{|r|r.slice(*keys)}
aux=ReleaseCorpus.inventory(clone,pin,'kernel-path-aux-v080').fetch('cases');raise 'six auxiliary identities' unless aux.map{|r|r.slice(*keys)}.sort_by{|r|r['id']}==selection.fetch('old_auxiliary').map{|r|r.slice(*keys)}.sort_by{|r|r['id']}
puts 'PASS default P002710/bcc35 unchanged; wave3 twenty/three; auxiliary six identities'
