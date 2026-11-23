#!/usr/bin/env ruby
# Freeze the canonical capture's manifest into the existing named-contract table.
require 'json';require 'digest';require 'fileutils'
inventory,oracle,name,out=ARGV
abort 'usage: seal-release-corpus INVENTORY ORACLE REGISTERED_NAME FRESH_OUT' unless ARGV.size==4
abort 'fresh output required' if File.exist?(out)
j=JSON.parse(File.binread(inventory));manifest=oracle+'/manifest.json';meta=JSON.parse(File.binread(manifest))
rows=meta.fetch('cases');wanted=j.fetch('cases').map { |r| r.slice('id','kind','source','source_sha256') }
abort 'oracle inventory changed' unless rows.map { |r| r.slice('id','kind','source','source_sha256') }==wanted
abort 'oracle commit changed' unless meta.fetch('commit')==j.fetch('oracle_commit')
repo=File.expand_path('..',__dir__);path=repo+'/scripts/lib/corpus-contracts.json';profiles=JSON.parse(File.binread(path));profile=profiles.fetch(name)
%w[positive negative].each do |kind|
  abort 'profile ID set' unless profile.fetch(kind+'_ids').sort==rows.select { |r| r['kind']==kind }.map { |r| r.fetch('id') }.sort
end
hash=Digest::SHA256.file(manifest).hexdigest
abort 'profile already sealed differently' unless [hash,'0'*64].include?(profile.fetch('oracle_manifest_sha256'))
# Zero is only a preparatory table value. CorpusContract.verify rejects it for any real manifest.
profile['oracle_manifest_sha256']=hash
File.binwrite(path,JSON.pretty_generate(profiles)+"\n")
FileUtils.mkdir_p(out)
contract={version:1,corpus:name,positive:profile.fetch('positive_ids').size,negative:profile.fetch('negative_ids').size,oracle_manifest_sha256:hash,cases:rows.map { |r| r.slice('id','source','source_sha256') }}
File.binwrite(out+'/corpus-contract.json',JSON.pretty_generate(contract)+"\n")
File.binwrite(out+'/allow.json',JSON.pretty_generate(rows.map { |r| r.fetch('id') })+"\n")
File.binwrite(out+'/groups.md',rows.select { |r| r['kind']=='positive' }.map { |r| '|H|`'+r.fetch('source')+'`|' }.join("\n")+"\n")
require_relative 'lib/corpus-contract'
CorpusContract.verify(out+'/corpus-contract.json',manifest,rows)
puts JSON.generate({corpus:name,total:rows.size,manifest_sha256:hash})
