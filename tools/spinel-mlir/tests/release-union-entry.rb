# All cases stop in preflight; no consumer/compiler/producer runs.
require 'json';require 'digest';require 'fileutils';require 'open3'
repo,oracle,contract,out=ARGV
abort 'usage: release-union-entry REPO ORACLE CONTRACT FRESH_OUT' unless out && !File.exist?(out)
FileUtils.mkdir_p(out)
id=JSON.parse(File.binread(repo+'/docs/union/ledger.json')).fetch('cases').first.fetch('id')
facts=out+'/fixture.mlir';File.binwrite(facts,'fixture is not passed to any product')
File.binwrite(out+'/plan.json',JSON.pretty_generate([{id:id,facts:facts,sha256:'0'*64}])+"\n")
File.binwrite(out+'/allow.json',JSON.pretty_generate([id])+"\n")
File.binwrite(out+'/unplanned.json',JSON.pretty_generate([id,'unplanned'])+"\n")
c=JSON.parse(File.binread(contract));c['oracle_manifest_sha256']='0'*64
File.binwrite(out+'/bad-contract.json',JSON.pretty_generate(c)+"\n")
base=['/usr/bin/ruby',repo+'/scripts/measure-union.rb',repo,out+'/plan.json',repo+'/scripts/lib/compile-warnings.rb']
records=[]
[
 ['default-refuses-accepted',[],out+'/allow.json','continue-cases contains accepted union ID'],
 ['named-reaches-facts-gate',['--oracle',oracle,'--corpus-contract',contract],out+'/allow.json','facts hash '+id],
 ['named-invalid-contract',['--oracle',oracle,'--corpus-contract',out+'/bad-contract.json'],out+'/allow.json','corpus-oracle-hash'],
 ['named-refuses-unplanned',['--oracle',oracle,'--corpus-contract',contract],out+'/unplanned.json','continue-cases contains unplanned ID']
].each do |name,options,allowed,expected|
  so,se,s=Open3.capture3(*base,out+'/'+name,*options,'--continue-cases',allowed)
  File.binwrite(out+'/'+name+'.stdout',so);File.binwrite(out+'/'+name+'.stderr',se)
  okay=s.exitstatus==1 && !s.termsig && so.empty? && se.include?(expected) && !File.exist?(out+'/'+name)
  records<<{name:name,rc:s.exitstatus,expected:expected,passed:okay}
end
File.binwrite(out+'/summary.json',JSON.pretty_generate({cases:records,product_execution:0})+"\n")
abort 'release union preflight control failed' unless records.all? { |r| r[:passed] }
puts 'release union preflight: 4/4 GREEN; product execution0'
