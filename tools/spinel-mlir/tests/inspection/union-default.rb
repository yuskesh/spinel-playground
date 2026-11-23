require 'tmpdir';require 'fileutils';require 'json';require 'digest';require 'open3'
repo=File.expand_path(ARGV.fetch(0))
Dir.mktmpdir('spinel-union-default-') do |d|
  root=d+'/repo';FileUtils.mkdir_p(root+'/build/bin');FileUtils.mkdir_p(root+'/build/bpf-mlir/bin');FileUtils.mkdir_p(root+'/docs/experiments/results/E003/capture')
  source_sha=Digest::SHA256.hexdigest("fixture source\n");id='fixture-positive'
  facts=d+'/facts.mlir';File.binwrite(facts,"fixture is passed only to a mock tool\n")
  File.write(d+'/plan.json',JSON.pretty_generate([{id:id,facts:facts,sha256:Digest::SHA256.file(facts).hexdigest}])+"\n")
  File.write(root+'/docs/experiments/results/E003/capture/manifest.json',JSON.pretty_generate({cases:[{id:id,kind:'positive',source:'example.rb',source_sha256:source_sha}]})+"\n")
  mock=<<'MOCK'
#!/usr/bin/ruby
require 'fileutils';require 'json';require 'digest'
emit=ARGV[ARGV.index('--emit-dir')+1];inspect=ARGV.include?('--inspect-dir') ? ARGV[ARGV.index('--inspect-dir')+1] : nil
stem=inspect ? 'example' : 'xdpcount';FileUtils.mkdir_p(emit)
{'mlir'=>"module {}\n",'schema.json'=>"{}\n",'maps.json'=>"{}\n"}.each{|name,bytes|File.binwrite(emit+'/'+stem+'.'+name,bytes)}
if inspect
 FileUtils.mkdir_p(inspect);File.binwrite(emit+'/'+stem+'.records.txt','');File.write(emit+'/'+stem+'.uprobe_targets.json',"{\"version\":1,\"programs\":[]}\n");File.write(inspect+'/'+stem+'.domain.json',"{}\n")
 names={'mlir'=>'mlir','schema'=>'schema.json','maps'=>'maps.json','records'=>'records.txt','uprobe_targets'=>'uprobe_targets.json','domain'=>'domain.json'}
 files=names.to_h{|key,suffix|p=(key=='domain' ? inspect : emit)+'/'+stem+'.'+suffix;[key,{path:p,sha256:Digest::SHA256.file(p).hexdigest}]}
 m={version:1,source:{path:'example.rb',sha256:'SOURCE_SHA'},facts:{path:ARGV.last,sha256:Digest::SHA256.file(ARGV.last).hexdigest},execution:'consumer',pins:{spinel:{producer_source:'facts'}},result:{rc:0,domain_produced:true},outputs:files}
 File.write(inspect+'/'+stem+'.inspect-manifest.json',JSON.pretty_generate(m)+"\n")
end
MOCK
  mock=mock.sub('SOURCE_SHA'){source_sha};File.write(root+'/build/bin/spinel-mlir',mock);File.chmod(0755,root+'/build/bin/spinel-mlir')
  compiler=root+'/build/bpf-mlir/bin/ebpf-compile';File.write(compiler,"#!/usr/bin/ruby\nFile.binwrite(ARGV[ARGV.index('-o')+1],\"mock-elf\\n\")\n");File.chmod(0755,compiler)
  normal=root+'/build/bin/spinel-ir-normalize';File.write(normal,"#!/bin/sh\nexit 0\n");File.chmod(0755,normal)
  destination=d+'/same-output';base=[root,d+'/plan.json',repo+'/scripts/lib/compile-warnings.rb',destination]
  capture=->(script,args){o,e,s=Open3.capture3('/usr/bin/ruby',script,*args);raise 'mock union failed: '+e unless s.success?&&e.empty?;o}
  before=capture.call(repo+'/tests/inspection/Inputs/measure-union-before-e077.rb',base);FileUtils.mv(destination,d+'/before')
  after=capture.call(repo+'/scripts/measure-union.rb',base);raise 'default stdout bytes changed' unless before==after
  %w[candidate.json ledger.json].each{|name|raise 'default metadata bytes changed '+name unless File.binread(d+'/before/'+name)==File.binread(destination+'/'+name)}
  %w[build.stdout build.stderr example.mlir example.schema.json example.maps.json example.bpf.o].each{|name|p='/cases/'+id+'/'+name;raise 'default product bytes changed '+name unless File.binread(d+'/before'+p)==File.binread(destination+p)}
  a=JSON.parse(File.read(d+'/before/tools.json'));b=JSON.parse(File.read(destination+'/tools.json'));a.delete('runner_sha256');b.delete('runner_sha256');raise 'default tool pins changed' unless a==b
  raise 'default inspection was invoked' if Dir[destination+'/runs/*/inspection'].any?
  inspect=d+'/with-inspection';capture.call(repo+'/scripts/measure-union.rb',base[0..2]+[inspect,'--inspection'])
  raise 'new mode emits wrong canonical candidate set' unless Dir[inspect+'/cases/'+id+'/*'].map{|p|File.basename(p)}.sort==%w[build.stdout build.stderr example.mlir example.schema.json example.maps.json example.bpf.o].sort
  row=JSON.parse(File.read(inspect+'/ledger.json')).first;raise 'inspection receipt missing' unless row.fetch('inspection').fetch('files').size==2
  %w[example.mlir example.schema.json example.maps.json example.bpf.o build.stdout build.stderr].each{|name|raise 'inspection changes product byte '+name unless File.binread(inspect+'/cases/'+id+'/'+name)==File.binread(destination+'/cases/'+id+'/'+name)}
  o,e,s=Open3.capture3('/usr/bin/ruby',repo+'/scripts/measure-union.rb',*base[0..2],d+'/duplicate','--inspection','--inspection');raise 'duplicate flag not loud' unless s.exitstatus==1&&e.include?('duplicate inspection option')&&!File.exist?(d+'/duplicate')
end
puts 'union default raw/candidate/argv unchanged; inspection opt-in and duplicate gate GREEN (mock tools only)'
