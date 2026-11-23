#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'zlib'
require_relative 'lib/source-pipeline-union'
supply,out=ARGV.map { |p|File.expand_path(p) }
abort 'usage: prepare-uretprobe-union SUPPLY_LEDGER FRESH_OUT' unless out
abort 'fresh output' if File.exist?(out)
repo=File.expand_path('..',__dir__)
sha=->(p) { Digest::SHA256.file(p).hexdigest }
ledger=JSON.parse(File.read(repo+'/docs/union/ledger.json'))
abort 'baseline601' unless ledger.fetch('total')==601 && ledger.fetch('cases').size==601
FileUtils.mkdir_p(out+'/archives')
plan=[];audit=[]
facts,pipelines=ledger.fetch('cases').partition { |r|!r['facts'].nil? }
facts.group_by { |r|r.fetch('facts').fetch('primary_locator').fetch('archive_path') }.each_with_index do |(archive,rows),index|
  path=repo+'/'+archive;hash=sha.call(path)
  locs=rows.map { |r|r.fetch('facts').fetch('primary_locator') }
  abort 'archive hash' unless locs.all? { |l|l.fetch('archive_sha256')==hash }
  members=locs.map { |l|l.fetch('member') }.uniq
  abort 'unsafe member' if members.any? { |m|m.start_with?('/') || m.split('/').include?('..') }
  dir=out+'/archives/'+index.to_s;FileUtils.mkdir_p(dir)
  so,se,status=Open3.capture3('/usr/bin/tar','-xzf',path,'-C',dir,'--',*members)
  File.binwrite(dir+'/tar.stdout',so);File.binwrite(dir+'/tar.stderr',se)
  abort 'archive extract' unless status.success?
  rows.each do |row|
    loc=row.fetch('facts').fetch('primary_locator');member=dir+'/'+loc.fetch('member')
    abort 'member hash' unless sha.call(member)==loc.fetch('member_sha256')
    raw=case loc.fetch('member_encoding')
        when 'identity' then File.binread(member)
        when 'gzip' then Zlib::GzipReader.open(member,&:read)
        else abort 'encoding'
        end
    abort 'facts hash' unless Digest::SHA256.hexdigest(raw)==row.fetch('facts').fetch('sha256')
    target=out+'/facts/'+row.fetch('id')+'.mlir';FileUtils.mkdir_p(File.dirname(target));File.binwrite(target,raw)
    plan<<{'id'=>row.fetch('id'),'facts'=>target,'sha256'=>row.fetch('facts').fetch('sha256')}
    audit<<{'id'=>row.fetch('id'),'archive'=>archive,'member'=>loc.fetch('member'),'sha256'=>sha.call(target)}
  end
end
abort 'explicit source pipeline count' unless pipelines.size==1
pipelines.each do |row|
  exec=row.fetch('execution');abort 'explicit source kind' unless exec.fetch('kind')=='source_pipeline'
  # Verify all committed raw/source input members, then verify the frozen runtime
  # paths and their full source/library/builtins closure. No absent-facts fallback.
  locators=exec.fetch('primary_locators').values+[exec.fetch('source_inputs').fetch('source')]+
    exec.fetch('source_inputs').fetch('library').values+exec.fetch('source_inputs').fetch('builtins').values
  locators.uniq.each do |loc|
    archive=repo+'/'+loc.fetch('archive_path');abort 'source archive hash' unless sha.call(archive)==loc.fetch('archive_sha256')
    bytes,error,status=Open3.capture3('/usr/bin/tar','-xOzf',archive,'--',loc.fetch('member'))
    abort 'source member hash' unless status.success? && error.empty? && Digest::SHA256.hexdigest(bytes)==loc.fetch('member_sha256')
  end
  input={'id'=>row.fetch('id'),'facts'=>nil,'execution'=>exec.fetch('runtime')}
  SourcePipelineUnion.verify(input)
  plan<<input;audit<<{'id'=>row.fetch('id'),'kind'=>'source_pipeline','raw_and_input_locators_verified'=>locators.uniq.size}
end
new_rows=JSON.parse(File.read(supply));abort 'new5' unless new_rows.size==5
new_rows.each do |row|
  abort 'supply contract' unless row.fetch('rc')==0 && !row['signal'] && row.fetch('verify_rc')==0 && !row['verify_signal'] && sha.call(row.fetch('facts'))==row.fetch('sha256')
  abort 'overlap' if plan.any? { |p|p.fetch('id')==row.fetch('id') }
  plan<<row.slice('id','facts','sha256')
end
abort 'unique606' unless plan.size==606 && plan.map { |r|r.fetch('id') }.uniq.size==606
File.write(out+'/plan.json',JSON.pretty_generate(plan.sort_by { |r|r.fetch('id') })+"\n")
File.write(out+'/materialization.json',JSON.pretty_generate(audit)+"\n")
File.write(out+'/prediction.json',JSON.pretty_generate({baseline:601,new:5,overlap:0,matched:606,different:0,error:0,unsupported:3,exit:3})+"\n")
puts 'baseline601+new5/unique606/hash verified/source_pipeline explicit'
