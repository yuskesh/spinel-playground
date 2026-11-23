#!/usr/bin/env ruby
# Record observed canonical report rows; this never compares or changes artifacts.
require 'json';require 'digest'
inventory,supply,measurement,report,packaging,out=ARGV
abort 'usage: make-release-ledger INVENTORY SUPPLY MEASUREMENT REPORT PACKAGING OUT' unless ARGV.size==6
abort 'ledger output exists' if File.exist?(out)
sha=->(p) { Digest::SHA256.file(p).hexdigest }
j=JSON.parse(File.binread(inventory));plan=JSON.parse(File.binread(supply+'/consumer-plan.json')).to_h { |r| [r.fetch('id'),r] }
rows=JSON.parse(File.binread(report+'/cases.json'));rows=rows.fetch('cases') if rows.is_a?(Hash)
index=rows.to_h { |r| [r.fetch('id'),r] }
abort 'ledger ID set' unless index.keys.sort==j.fetch('cases').map { |r| r.fetch('id') }.sort && index.size==rows.size && plan.keys.sort==index.keys.sort
package=JSON.parse(File.binread(packaging));tools=JSON.parse(File.binread(measurement+'/tools.json'))
primary=lambda do |member,hash|
  {kind:'archive_member',archive_paths:package.fetch('archive_paths'),archive_sha256:package.fetch('archive_sha256'),member:member,member_sha256:hash}
end
cases=j.fetch('cases').map do |input|
  id=input.fetch('id');p=plan.fetch(id);r=index.fetch(id)
  abort 'ledger report identity' unless r.slice('id','kind','source')==input.slice('id','kind','source')
  abort 'ledger report status' unless %w[matched different error unsupported].include?(r.fetch('status'))
  record=input.slice('id','kind','source','source_sha256').merge('status'=>r.fetch('status'),'reasons'=>r.fetch('reasons'),
    'source_locator'=>primary.call(File.basename(supply)+'/source/'+input.fetch('source'),input.fetch('source_sha256')),
    'report'=>primary.call(File.basename(report)+'/cases.json',sha.call(report+'/cases.json')).merge(row_id:id))
  if p.dig('execution','kind')=='source_pipeline'
    record['facts']=nil;record['execution']={kind:'source_pipeline',primary_locator:primary.call(File.basename(measurement)+'/runs/'+id+'/pipeline/execution.json',sha.call(measurement+'/runs/'+id+'/pipeline/execution.json'))}
  else
    f=p.fetch('facts');abort 'ledger facts hash' unless sha.call(f)==p.fetch('sha256')
    record['facts']={sha256:p.fetch('sha256'),primary_locator:primary.call(File.basename(supply)+'/cases/'+id+'/facts.mlir',p.fetch('sha256')),secondary_locator:{kind:'scratch_file',path:f,sha256:p.fetch('sha256')}}
  end
  record
end
ledger={version:1,purpose:package.fetch('purpose'),corpus:j.fetch('corpus'),oracle_commit:j.fetch('oracle_commit'),consumer_basis_main:package.fetch('consumer_basis_main'),oracle_manifest_sha256:JSON.parse(File.binread(report+'/summary.json')).fetch('oracle_manifest_sha256'),total:cases.size,counts:cases.map { |r| r.fetch('kind') }.tally.merge(cases.map { |r| r.fetch('status') }.tally),tools:tools,cases:cases}
File.binwrite(out,JSON.pretty_generate(ledger)+"\n")
puts JSON.generate(ledger.slice(:corpus,:total,:counts))
