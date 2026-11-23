require 'tmpdir'; require 'fileutils'; require 'open3'; require 'json'
require_relative '../scripts/lib/release-corpus'
def command(*args)
  o,e,s=Open3.capture3(*args);raise e unless s.success?;o.strip
end
def rejects(message)
  begin;yield;rescue RuntimeError,KeyError => e;raise e unless e.message.include?(message);return;end
  raise 'unexpected acceptance '+message
end
Dir.mktmpdir('release-corpus-') do |d|
  command('git','init','-q',d)
  FileUtils.mkdir_p(d+'/examples/bcc/example')
  File.binwrite(d+'/examples/bcc/example/example.rb',"require \"bpf\"\n")
  command('git','-C',d,'add','.')
  command('git','-C',d,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','fixture')
  pin=command('git','-C',d,'rev-parse','HEAD')
  j=ReleaseCorpus.inventory(d,pin,'bcc');id='examples_bcc_example_example'
  raise 'selection' unless j['cases'].size==1 && j['cases'][0]['id']==id
  profiles={'test'=>{'positive_ids'=>[id],'negative_ids'=>[]}}
  raise 'valid rejected' unless ReleaseCorpus.validate(j,d,profiles,'test')==j
  rejects('release-pin-format') { ReleaseCorpus.inventory(d,'main','bcc') }
  rejects('release-pin-mismatch') { ReleaseCorpus.inventory(d,'0'*40,'bcc') }
  rejects('release-corpus-name') { ReleaseCorpus.inventory(d,pin,'other') }
  rejects('capture-unknown-corpus') { ReleaseCorpus.validate(j,d,profiles,'other') }
  bad=Marshal.load(Marshal.dump(j));bad['cases']<<bad['cases'][0]
  rejects('release-source-set') { ReleaseCorpus.validate(bad,d,profiles,'test') }
  bad=Marshal.load(Marshal.dump(j));bad['cases'][0]['source_sha256']='0'*64
  rejects('release-source-set') { ReleaseCorpus.validate(bad,d,profiles,'test') }
  rejects('release-profile-ID-set') { ReleaseCorpus.validate(j,d,{'test'=>{'positive_ids'=>[],'negative_ids'=>[]}},'test') }
  File.binwrite(d+'/examples/bcc/example/untracked.rb','untracked')
  rejects('release-source-untracked') { ReleaseCorpus.inventory(d,pin,'bcc') }
  FileUtils.rm(d+'/examples/bcc/example/untracked.rb')
  File.binwrite(d+'/examples/bcc/example/example.rb','changed')
  rejects('release-source-dirty') { ReleaseCorpus.inventory(d,pin,'bcc') }
end
puts 'release inventory: valid + 9 refusal controls GREEN'
