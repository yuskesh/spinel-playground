require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative '../scripts/lib/corpus-contract'
oracle,contract_path,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: shared-corpus-entry ORACLE BCC_CONTRACT FRESH_OUT' unless out
abort 'fresh test output' if File.exist?(out)
FileUtils.mkdir_p(out)
manifest=oracle+'/manifest.json';records=JSON.parse(File.read(manifest)).fetch('cases')
contract=JSON.parse(File.read(contract_path));ledger=[]
test=lambda do |name,want,&block|
  begin
    value=block.call;got=value==:accepted ? 'accepted' : value
  rescue RuntimeError=>error
    got=error.message
  end
  ledger<<{name:name,expected:want,observed:got,same:got==want}
end
test.call('bcc-return-byte-unchanged','accepted') do
  ret=CorpusContract.verify(contract_path,manifest,records)
  JSON.generate(ret)==JSON.generate(contract) ? :accepted : 'changed-return'
end
changed=Marshal.load(Marshal.dump(contract));changed['corpus']='unknown-profile'
File.write(out+'/unknown.json',JSON.pretty_generate(changed)+"\n")
test.call('unknown-name','corpus-unknown-name'){CorpusContract.verify(out+'/unknown.json',manifest,records);:accepted}
changed_records=Marshal.load(Marshal.dump(records));changed_records[0]['id']='unregistered-id'
test.call('registered-ID-set','corpus-id-set'){CorpusContract.verify(contract_path,manifest,changed_records);:accepted}
new_manifest=out+'/changed-manifest.json';File.binwrite(new_manifest,File.binread(manifest)+"\n")
changed=Marshal.load(Marshal.dump(contract));changed['oracle_manifest_sha256']=Digest::SHA256.file(new_manifest).hexdigest
File.write(out+'/changed-contract.json',JSON.pretty_generate(changed)+"\n")
test.call('registered-manifest-hash','corpus-oracle-hash'){CorpusContract.verify(out+'/changed-contract.json',new_manifest,records);:accepted}
repo=File.expand_path('..',__dir__)
facts=out+'/dummy-facts.mlir';File.write(facts,"fixture-only\n");hash=Digest::SHA256.file(facts).hexdigest
plan=[{id:'fixture-negative',facts:facts,sha256:hash}]
audit={total:1,cases:[{id:'fixture-negative',kind:'negative',facts:{sha256:hash}}]}
File.write(out+'/plan.json',JSON.pretty_generate(plan)+"\n");File.write(out+'/audit-ledger.json',JSON.pretty_generate(audit)+"\n")
base=['/usr/bin/ruby',repo+'/scripts/measure-union.rb',repo,out+'/plan.json',repo+'/scripts/lib/compile-warnings.rb']
[['explicit-subset',true,0],['default-ledger-not-replaced',false,1]].each do |name,explicit,want|
  args=base+[out+'/'+name,'--consumer-only','--consumer','/bin/false','--target-main','HEAD']
  args+=['--audit-ledger',out+'/audit-ledger.json'] if explicit
  so,se,status=Open3.capture3(*args)
  File.binwrite(out+'/'+name+'.stdout',so);File.binwrite(out+'/'+name+'.stderr',se)
  same=status.exitstatus==want
  if explicit&&same
    result=JSON.parse(File.read(out+'/'+name+'/summary.json'))
    same &&= result.fetch('executed')==1&&result.fetch('finding_cases')==0
  elsif !explicit&&same
    same &&= se.include?('audit requires complete pinned ledger')
  end
  ledger<<{name:name,expected_rc:want,observed_rc:status.exitstatus,same:same,fixture_only:true}
end
File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
puts JSON.generate(ledger)
exit(ledger.all?{|r|r[:same]} ? 0 : 1)
