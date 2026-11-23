require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative '../scripts/batch-compare'
oracle,inputs,compiler,normalizer,out=ARGV.map{|p|File.expand_path(p)}
abort 'usage: bcc-driver ORACLE INPUTS COMPILER NORMALIZER FRESH_OUT' unless out
abort 'fresh controls' if File.exist?(out)
repo=File.expand_path('..',__dir__);records=JSON.parse(File.read(oracle+'/manifest.json')).fetch('cases')
FileUtils.mkdir_p(out)
run=lambda do |name,candidate,want,contract=true|
  args=['/usr/bin/ruby',repo+'/scripts/batch-compare.rb','--oracle',oracle,'--candidate',candidate,'--groups',inputs+'/groups.md','--compiler',compiler,'--normalizer',normalizer,'--report',out+'/report-'+name]
  args+=['--corpus-contract',inputs+'/corpus-contract.json'] if contract
  so,se,status=Open3.capture3(*args)
  File.binwrite(out+'/'+name+'.stdout',so);File.binwrite(out+'/'+name+'.stderr',se)
  summary=JSON.parse(File.read(out+'/report-'+name+'/summary.json'))
  abort 'control exit '+name unless status.exitstatus==want
  {name:name,argv:args,rc:status.exitstatus,total:summary.fetch('total'),global_error:summary['global_error']}
end
identity=out+'/identity';FileUtils.mkdir_p(identity)
entries=records.map do |row|
  id=row.fetch('id');stem=File.basename(row.fetch('source'),'.rb');dir=identity+'/cases/'+id;FileUtils.mkdir_p(dir)
  Dir[oracle+'/'+row.fetch('raw_dir')+'/*'].select{|p|File.file?(p)}.each{|p|FileUtils.cp(p,dir+'/'+File.basename(p))}
  stderr=File.binread(dir+'/build.stderr');File.binwrite(dir+'/build.stderr',BatchCompare.strip_named_wrote(stderr,id,stem))
  {id:id,source:row.fetch('source'),source_sha256:row.fetch('source_sha256'),producer_rc:0,dir:'cases/'+id}
end
File.write(identity+'/candidate.json',JSON.pretty_generate({version:2,cases:entries})+"\n")
ledger=[run.call('identity',identity,0),run.call('default-rejects-21',identity,2,false)]
first=entries.first;stem=File.basename(first.fetch(:source),'.rb')
%w[maps-byte empty].each do |name|
  dir=out+'/'+name;FileUtils.mkdir_p(dir+'/cases/'+first.fetch(:id))
  Dir[identity+'/'+first.fetch(:dir)+'/*'].select{|p|File.file?(p)}.each{|p|FileUtils.cp(p,dir+'/'+first.fetch(:dir)+'/'+File.basename(p))}
  path=dir+'/'+first.fetch(:dir)+'/'+stem+(name=='empty' ? '.schema.json' : '.maps.json')
  bytes=File.binread(path)
  changed=bytes.dup
  changed.setbyte(changed.bytesize-1,changed.getbyte(changed.bytesize-1)==10 ? 32 : 10)
  File.binwrite(path,name=='empty' ? '' : changed)
  abort 'maps mutation absent' if name=='maps-byte'&&File.binread(path)==bytes
  File.write(dir+'/candidate.json',JSON.pretty_generate({version:2,cases:[first]})+"\n")
  ledger<<run.call(name,dir,name=='empty' ? 2 : 1)
end
abort 'identity count' unless ledger[0][:total]=={'matched'=>21,'different'=>0,'error'=>0,'unsupported'=>0}
abort 'default contract' unless ledger[1][:global_error]=='oracle-case-count'
abort 'byte count' unless ledger[2][:total]=={'matched'=>0,'different'=>1,'error'=>0,'unsupported'=>20}
abort 'empty count' unless ledger[3][:total]=={'matched'=>0,'different'=>0,'error'=>1,'unsupported'=>20}
File.write(out+'/ledger.json',JSON.pretty_generate(ledger)+"\n")
puts 'bcc driver: identity21/default-609-guard/maps-byte/empty controls passed'
