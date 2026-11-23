#!/usr/bin/env ruby
# Materialization only: all product execution stays in measure-union.rb.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'zlib'
abort 'usage: prepare-packet-diagnostic-union SUPPLY_LEDGER FRESH_OUT' unless ARGV.size==2
supply,out=ARGV.map { |p| File.expand_path(p) }
repo=File.expand_path('..',__dir__)
abort 'fresh output required' if File.exist?(out)
ledger=JSON.parse(File.read(repo+'/docs/union/ledger.json'))
sha=->(p){Digest::SHA256.file(p).hexdigest}
rows=ledger.fetch('cases')
abort 'ledger count' unless rows.size==ledger.fetch('total') && rows.map { |r|r.fetch('id') }.uniq.size==rows.size
FileUtils.mkdir_p(out+'/archives')
plan=[];audit=[]
groups=rows.group_by { |r| r.fetch('facts').fetch('primary_locator').fetch('archive_path') }
groups.each_with_index do |(archive, cases),index|
  path=repo+'/'+archive;locs=cases.map { |r| r.fetch('facts').fetch('primary_locator') }
  abort 'archive hash: '+archive unless locs.all? { |l|l.fetch('archive_sha256')==sha.call(path) }
  members=locs.map { |l|l.fetch('member') }.uniq
  abort 'unsafe archive member' if members.any? { |m|m.start_with?('/') || m.split('/').include?('..') }
  dir=out+'/archives/'+index.to_s;FileUtils.mkdir_p(dir)
  so,se,s=Open3.capture3('/usr/bin/tar','-xzf',path,'-C',dir,'--',*members)
  File.binwrite(dir+'/tar.stdout',so);File.binwrite(dir+'/tar.stderr',se)
  abort 'archive extract: '+archive unless s.success?
  cases.each do |r|
    facts=r.fetch('facts');loc=facts.fetch('primary_locator');member=dir+'/'+loc.fetch('member')
    abort 'member hash' unless sha.call(member)==loc.fetch('member_sha256')
    raw=case loc.fetch('member_encoding')
    when 'identity' then File.binread(member)
    when 'gzip' then Zlib::GzipReader.open(member,&:read)
    else abort 'unknown member encoding'
    end
    abort 'facts hash' unless Digest::SHA256.hexdigest(raw)==facts.fetch('sha256')
    target=out+'/facts/'+r.fetch('id')+'.mlir';FileUtils.mkdir_p(File.dirname(target));File.binwrite(target,raw)
    plan<<{id:r.fetch('id'),facts:target,sha256:facts.fetch('sha256')}
    audit<<{id:r.fetch('id'),archive:archive,member:loc.fetch('member'),sha256:facts.fetch('sha256')}
  end
end
by_id=plan.to_h { |r|[r.fetch(:id),r] }
additional=JSON.parse(File.read(supply))
abort 'supply count' unless additional.size==30
overlap=[]
additional.each do |r|
  abort 'supply contract' unless r.fetch('rc')==0 && r.fetch('verify_rc')==0 && !r['signal'] && !r['verify_signal'] && sha.call(r.fetch('facts'))==r.fetch('sha256')
  if by_id.key?(r.fetch('id'))
    overlap<<r.fetch('id')
  else
    by_id[r.fetch('id')]={id:r.fetch('id'),facts:r.fetch('facts'),sha256:r.fetch('sha256')}
  end
end
File.write(out+'/plan.json',JSON.pretty_generate(by_id.values.sort_by { |r|r.fetch(:id) })+"\n")
File.write(out+'/materialization.json',JSON.pretty_generate(audit)+"\n")
prediction={baseline:rows.size,new_selection:30,overlap:overlap,expected_matched:by_id.size,expected_unsupported:609-by_id.size,expected_different:0,expected_error:0,expected_exit:3}
File.write(out+'/prediction.json',JSON.pretty_generate(prediction)+"\n")
puts JSON.generate(prediction)
