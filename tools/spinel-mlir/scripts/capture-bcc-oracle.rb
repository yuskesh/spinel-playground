#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'lib/capture-selection'
clone,reference,out,*options=ARGV
settings={}
abort 'capture options require pairs' unless out && options.size.even?
options.each_slice(2) do |key,value|
  abort 'capture unknown/duplicate option' unless %w[--corpus --input-manifest --case-ids --observe-derived].include?(key) && value && !settings.key?(key)
  settings[key]=value
end
abort 'input manifest requires named corpus' if settings['--input-manifest'] && !settings['--corpus']
clone,reference,out=[clone,reference,out].map { |p|File.expand_path(p) }
corpus=settings.fetch('--corpus','bcc-wave1')
profiles=JSON.parse(File.binread(File.join(__dir__,'lib/corpus-contracts.json')))
abort 'capture-unknown-corpus' unless profiles.key?(corpus)
abort 'fresh output required' if File.exist?(out)
sha=->(p){Digest::SHA256.file(p).hexdigest}
pin=corpus=='bcc-wave1' ? 'aefab7ea9dd104b1af4ad13ecce2e8d756e96cd3' : '8e49a446ed4319a5000f4b726c322198cc392211'
release=nil
if settings['--input-manifest']
  require_relative 'lib/release-corpus'
  release=ReleaseCorpus.validate(JSON.parse(File.binread(settings.fetch('--input-manifest'))),clone,profiles,corpus)
  pin=release.fetch('oracle_commit')
end
head,status=Open3.capture2('git','-C',clone,'rev-parse','HEAD');abort 'oracle pin' unless status.success?&&head.strip==pin
if release
inputs=release.fetch('cases').map { |r| [r.fetch('kind'),r.fetch('source'),r.fetch('id'),File.basename(r.fetch('source'),'.rb')] }
expected={};artefacts={}
elsif corpus=='bcc-wave1'
names=%w[runqlat cpudist hardirqs softirqs slabratetop funclatency fileslower runqslower killsnoop setuids syncsnoop exitsnoop mountsnoop syscount vfsstat funccount argdist cachestat tcplife tcpstates memleak]
paths=Dir[clone+'/examples/bcc/*/*.rb'].map{|p|p.delete_prefix(clone+'/')}.sort
abort '21 source set' unless paths==names.map{|n|'examples/bcc/'+n+'/'+n+'.rb'}.sort
expected=File.readlines(reference+'/docs/experiments/results/E140/bcc_outputs.sha256').to_h{|l|h,p=l.strip.split(/\s+/,2);[p,h]}
abort '189 expected files' unless expected.size==189
artefacts=File.readlines(clone+'/examples/bcc/artefacts.sha256').to_h{|l|h,p=l.strip.split(/\s+/,2);[p,h]}
inputs=names.map{|name|['positive','examples/bcc/'+name+'/'+name+'.rb','examples_bcc_'+name+'_'+name,name]}
else
profile=profiles.fetch(corpus)
files,fs=Open3.capture2('git','-C',clone,'ls-files','*.rb');abort 'capture-source-index' unless fs.success?
inputs=%w[positive negative].flat_map do |kind|
  profile.fetch(kind+'_ids').map do |id|
    matches=files.lines.map(&:strip).select{|p|p.delete_suffix('.rb').tr('/','_')==id}
    abort 'capture-source-ID: '+id unless matches.size==1
    [kind,matches[0],id,File.basename(matches[0],'.rb')]
  end
end
abort 'capture-duplicate-ID' unless inputs.map{|r|r[2]}.uniq.size==inputs.size
expected={};artefacts={}
end
inputs=CaptureSelection.select(inputs,settings['--case-ids'])
observe=settings['--observe-derived']
abort 'capture-observe-derived-value' if observe && observe!='true'
abort 'capture-observe-needs-subset' if observe && !settings['--case-ids']
if observe
  abort 'capture-observe-derived-only' unless release && inputs.all?{|r|release.fetch('cases').any?{|c|c['id']==r[2]&&c.key?('derived_content')}}
end
sb=clone+'/build/bin/spinelbpf';ec=clone+'/build/bpf-mlir/bin/ebpf-compile';spinel=clone+'/third_party/spinel/bin/spinel'
env={'SPINELBPF_ROOT'=>clone,'SPINEL'=>spinel,'EBPF_COMPILE'=>ec,'LLVM_PREFIX'=>'/opt/llvm-23.1.1','GOPROXY'=>'off','GOSUMDB'=>'off','LC_ALL'=>'C','TMPDIR'=>clone+'/build/tmp'}
FileUtils.mkdir_p(out+'/compile-all')
meta={version:1,corpus:corpus,commit:pin,tools:{'ebpf-compile'=>{sha256:sha.call(ec)},'spinelbpf'=>{sha256:sha.call(sb)},'spinel'=>{sha256:sha.call(spinel)}},versions:{},cases:[]}
{'spinelbpf'=>[sb,'--version'],'spinel'=>[spinel,'--version'],'ebpf-compile'=>[ec,'--version'],'clang'=>['/opt/llvm-23.1.1/bin/clang','--version'],'go'=>['/usr/local/go/bin/go','version']}.each do |name,argv|
  o,e,s=Open3.capture3(env,*argv);abort 'tool version '+name unless s.success?
  meta[:versions][name]={argv:argv,rc:s.exitstatus,stdout:o,stderr:e}
end
if corpus=='bcc-wave1' && !release
FileUtils.cp(reference+'/docs/experiments/results/E140/bcc_outputs.sha256',out+'/E140-bcc_outputs.sha256')
FileUtils.cp(clone+'/examples/bcc/artefacts.sha256',out+'/artefacts.sha256')
FileUtils.cp(clone+'/examples/bcc/PROVENANCE.md',out+'/PROVENANCE.md')
end
ledger=[];tracked=[]
inputs.each do |kind,rel,id,name|
  dir=out+'/'+kind+'/'+id;FileUtils.mkdir_p(dir)
  record=release && release.fetch('cases').find { |r| r.fetch('id')==id }
  if record && record.key?('derived_content')
    File.binwrite(dir+'/'+name+'.rb',record.fetch('derived_content'))
  else
    FileUtils.cp(clone+'/'+rel,dir+'/'+name+'.rb')
    target=File.dirname(clone+'/'+rel)+'/target'
    FileUtils.cp_r(target,dir+'/target') if File.directory?(target)
  end
  argv=[sb,'build',dir+'/'+name+'.rb']
  o,e,s=Open3.capture3(env,*argv,chdir:dir)
  File.binwrite(dir+'/build.stdout',o);File.binwrite(dir+'/build.stderr',e);File.write(dir+'/build.rc',s.exitstatus.to_s+"\n")
if observe
  actual_kind=CaptureSelection.outcome(kind,record,s.exitstatus,true)
  if actual_kind!=kind
    actual_dir=out+'/'+actual_kind+'/'+id
    FileUtils.mkdir_p(File.dirname(actual_dir));FileUtils.mv(dir,actual_dir)
    dir=actual_dir;kind=actual_kind
  end
end
  row={id:id,kind:kind,source:rel,source_sha256:sha.call(dir+'/'+name+'.rb'),raw_dir:kind+'/'+id,argv:argv,rc:s.exitstatus,signal:s.termsig}
  meta[:cases]<<row;ledger<<row;File.write(out+'/manifest.json',JSON.pretty_generate(meta)+"\n")
  abort 'STOP Go build '+name unless s.exitstatus==(kind=='positive' ? 0 : 1)&&!s.termsig&&o.empty?
  if kind=='negative'
    if observe
      abort 'STOP observed refusal without diagnostics '+name unless !e.empty?
    elsif record && record.key?('derived_refusal_code')
      code=record.fetch('derived_refusal_code')
      abort 'STOP invalid derived expectation '+name unless record.key?('derived_content') && code.is_a?(String) && code.match?(/\ASB\d{3}\z/)
      actual=e.scan(/(?:rejected|unknown) (SB\d{3})/).flatten
      abort 'STOP wrong-derived-refusal '+name unless !actual.empty? && actual.all? { |seen| seen==code }
    else
    wants=File.binread(dir+'/'+name+'.rb').scan(/^# want: (SB\d{3}) (\d+):(\d+)$/)
    wants=[['SB014','0','0']] if record && record.key?('derived_content')
    abort 'STOP missing negative expectations' if wants.empty?
    wants.each do |code,line,col|
      loc=record && record.key?('derived_content') ? /(?:rejected|unknown) SB014\b/ : line=='0' ? /#{Regexp.escape(name)}\.rb: (?:rejected|unknown) #{code}\b/ : /#{Regexp.escape(name)}\.rb:#{line}:#{col}: (?:rejected|unknown) #{code}\b/
      abort 'STOP wrong-refusal '+name unless e.match?(loc)
    end
    abort 'STOP extra/missing-refusal '+name unless e.scan(/(?:rejected|unknown) (SB\d{3})/).flatten.sort==wants.map(&:first).sort
    end
    abort 'STOP negative artifact '+name unless Dir[dir+'/*.{mlir,schema.json,maps.json,bpf.o}'].empty?
    next
  end
  %w[mlir schema.json maps.json bpf.o domain.json].each{|ext|abort 'empty Go artifact '+name+'.'+ext unless File.size?(dir+'/'+name+'.'+ext)}
  # E139 compile_all's sole normalization is this case's directory prefix.
  File.binwrite(out+'/compile-all/'+name+'_'+name+'.build.txt',e.gsub(dir,'<dir>'))
  %w[mlir schema.json].each{|ext|FileUtils.cp(dir+'/'+name+'.'+ext,out+'/compile-all/'+name+'_'+name+'.'+ext)}
  %w[auto off].each do |mode|
    args=[ec,name+'.mlir','--schema',name+'.schema.json','--line-info='+mode,'-o',dir+'/'+name+'.'+mode+'.bpf.o']
    so,se,st=Open3.capture3(env,*args,chdir:dir)
    File.binwrite(dir+'/'+mode+'.stdout',so);File.binwrite(dir+'/'+mode+'.stderr',se);File.write(dir+'/'+mode+'.rc',st.exitstatus.to_s+"\n")
    row[mode]={argv:args,rc:st.exitstatus,signal:st.termsig}
    File.write(out+'/manifest.json',JSON.pretty_generate(meta)+"\n")
    abort 'STOP compile '+name+' '+mode unless st.success?&&File.size?(dir+'/'+name+'.'+mode+'.bpf.o')
    %w[bpf.o stdout stderr].each do |ext|
      from=ext=='bpf.o' ? dir+'/'+name+'.'+mode+'.bpf.o' : dir+'/'+mode+'.'+ext
      FileUtils.cp(from,out+'/compile-all/'+name+'_'+name+'.'+mode+'.'+ext)
    end
  end
  artefacts.select{|p,_|p.start_with?(name+'/')}.each do |path,hash|
    p=dir+'/'+File.basename(path)
    tracked<<{path:path,expected:hash,actual:sha.call(p),same:sha.call(p)==hash}
  end
end
File.write(out+'/execution.json',JSON.pretty_generate(ledger)+"\n")
checks=expected.map{|path,hash|actual=sha.call(out+'/compile-all/'+path);{path:path,expected:hash,actual:actual,same:actual==hash}}
actual_set=Dir[out+'/compile-all/*'].map{|p|File.basename(p)}.sort
File.write(out+'/E140-check.json',JSON.pretty_generate({files:checks,missing:expected.keys-actual_set,extra:actual_set-expected.keys})+"\n")
File.write(out+'/artefacts-check.json',JSON.pretty_generate(tracked)+"\n")
abort 'STOP E140/artefacts byte mismatch' unless release || corpus!='bcc-wave1'||(actual_set==expected.keys.sort&&checks.all?{|r|r[:same]}&&tracked.all?{|r|r[:same]})
require_relative 'lib/capture-inventory'
CaptureInventory.write(out)
puts JSON.generate({cases:inputs.size,E140_files:checks.size,tracked_files:tracked.size,different:0})
