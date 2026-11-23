require 'open3'
require 'tmpdir'
require 'zlib'
require 'json'
require_relative '../scripts/lib/byte-comparison'
build,src=ARGV.map{|p|File.expand_path(p)}
abort 'usage: packet.rb BUILD TEST_SOURCE' unless src
repo=File.dirname(src)
work=Dir.mktmpdir('packet-contract-',build)
run=lambda do |name,*argv|
  o,e,s=Open3.capture3(*argv)
  File.binwrite(work+'/'+name+'.stdout',o);File.binwrite(work+'/'+name+'.stderr',e)
  File.write(work+'/'+name+'.json',JSON.pretty_generate({argv:argv,rc:s.exitstatus,signal:s.termsig})+"\n")
  [o,e,s]
end
facts={}
%w[bounds offset-edge].each do |name|
  facts[name]=work+'/'+name+'.mlir'
  File.binwrite(facts[name],Zlib::GzipReader.open(src+'/Inputs/packet-'+name+'.mlir.gz',&:read))
end
_,err,status=run.call('emit',build+'/bin/spinel-mlir','--emit-dir',work+'/artifacts',facts['bounds'])
abort "packet boundary emit failed: #{err}" unless status.success?
oracle=repo+'/docs/experiments/results/E003/capture/positive/internal_frontend_testdata_pos_pkt_bounds/pkt_bounds'
%w[schema.json maps.json].each do |suffix|
  got=File.binread(work+'/artifacts/xdpcount.'+suffix)
  abort "packet #{suffix} differs/empty" unless !got.empty?&&got==File.binread(oracle+'.'+suffix)
end
forms=[]
[oracle+'.mlir',work+'/artifacts/xdpcount.mlir'].each_with_index do |path,i|
  o,e,s=run.call('normalize-'+i.to_s,build+'/bin/spinel-ir-normalize',path)
  abort "packet normalize failed/empty: #{e}" unless s.success?&&!o.empty?
  forms<<o
end
abort 'packet boundary structure differs' unless forms[0]==forms[1]
_,err,status=run.call('reject',build+'/bin/spinel-mlir','--emit-dir',work+'/rejected-artifacts',facts['offset-edge'])
want=File.binread(repo+'/docs/experiments/results/E003/capture/negative/internal_frontend_testdata_neg_pk_off_edge/build.stderr')
abort 'packet edge rejection differs/published artifacts' unless status.exitstatus==1&&ByteComparison.equal?(err,want)&&!File.exist?(work+'/rejected-artifacts')
puts 'packet boundaries: schema/maps raw, structure, named SB023 and no artifacts GREEN'
