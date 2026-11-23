require 'json'
require 'digest'
require 'fileutils'
require 'open3'
oracle,r005,consumer,out=ARGV
abort 'usage: prepare-fmod-inputs ORACLE R005_CAP CONSUMER FRESH_OUT' unless out
abort 'fresh output required' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
repo=File.expand_path('..',__dir__)
manifest=JSON.parse(File.binread(oracle+'/manifest.json'))
expected=JSON.parse(File.binread(repo+'/docs/researches/results/R005/ledger.json')).fetch('cases').to_h{|r|[r.fetch('id'),r]}
FileUtils.mkdir_p(out+'/facts')
plan=[];audit=[]
manifest.fetch('cases').each do |row|
  short=File.basename(row.fetch('source'),'.rb');record=expected.fetch(short)
  source=r005+'/cases/'+short+'/facts.mlir'
  abort 'fixed R005 hash '+short unless sha.call(source)==record.fetch('facts_sha256')
  target=out+'/facts/'+row.fetch('id')+'.mlir';FileUtils.copy_file(source,target)
  stdout,stderr,status=Open3.capture3(consumer,'--verify-only',target)
  File.binwrite(out+'/facts/'+short+'.verify.stdout',stdout)
  File.binwrite(out+'/facts/'+short+'.verify.stderr',stderr)
  abort 'STOP facts verify '+short unless status.success?&&stdout.empty?&&stderr.empty?
  plan<<{id:row.fetch('id'),facts:target,sha256:sha.call(target)}
  audit<<{id:row.fetch('id'),kind:row.fetch('kind'),facts:{sha256:sha.call(target)}}
end
File.write(out+'/new13-plan.json',JSON.pretty_generate(plan)+"\n")
File.write(out+'/new13-audit-ledger.json',JSON.pretty_generate({total:audit.size,cases:audit})+"\n")
contract={version:1,corpus:'fmod-ret',positive:1,negative:12,oracle_manifest_sha256:sha.call(oracle+'/manifest.json'),cases:manifest.fetch('cases').map{|r|r.slice('id','source','source_sha256')}}
File.write(out+'/new13-contract.json',JSON.pretty_generate(contract)+"\n")
File.write(out+'/new13-groups.md',manifest.fetch('cases').select{|r|r['kind']=='positive'}.map{|r|"|G|`#{r.fetch('source')}`|\n"}.join)
require_relative 'lib/corpus-contract'
CorpusContract.verify(out+'/new13-contract.json',oracle+'/manifest.json',manifest.fetch('cases'))
puts 'fixed R00513 hash/verify/source-contract verified; M3 recapture0'
