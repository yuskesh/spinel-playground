require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'
tool,fixture=ARGV
raise 'usage: cli.rb TOOL HANDWRITTEN_FIXTURE' unless fixture
Dir.mktmpdir('e075-cli-') do |root|
  # This is an explicitly handwritten test assumption, not a producer run.
  text=File.binread(fixture).sub('spinel_facts.producer_revision = "E001"',
    'spinel_facts.producer_revision = "0000000000000000000000000000000000000000+fixture"')
  path=root+'/arbitrary-facts-name.mlir';File.binwrite(path,text)
  run=->(*args){Open3.capture3(tool,*args)}
  raise 'legacy fails' unless run.call('--emit-dir',root+'/legacy',path)[2].success?
  o,e,s=run.call('--emit-dir',root+'/emit','--inspect-dir',root+'/inspect',path)
  raise 'seam fails: '+e unless s.success? && o.empty?
  actual=Dir[root+'/emit/*'].map{|p|File.basename(p)}.sort
  want=%w[mlir schema.json maps.json records.txt uprobe_targets.json].map{|x|'xdpcount.'+x}.sort
  raise 'seam file set' unless actual==want
  %w[mlir schema.json maps.json].each{|x|raise 'legacy byte changed '+x unless File.binread(root+'/legacy/xdpcount.'+x)==File.binread(root+'/emit/xdpcount.'+x)}
  raise 'records empty file missing' unless File.file?(root+'/emit/xdpcount.records.txt') && File.zero?(root+'/emit/xdpcount.records.txt')
  raise 'targets shape' unless JSON.parse(File.binread(root+'/emit/xdpcount.uprobe_targets.json'))=={'version'=>1,'programs'=>[]}
  manifest=JSON.parse(File.binread(root+'/inspect/xdpcount.inspect-manifest.json'))
  raise 'manifest source hash' unless manifest.dig('facts','sha256')==Digest::SHA256.file(path).hexdigest
  raise 'manifest outputs: '+manifest.fetch('outputs').keys.inspect unless manifest.fetch('outputs').keys.sort==%w[mlir schema maps records uprobe_targets domain].sort
  manifest.fetch('outputs').each{|k,v|raise 'manifest hash '+k unless Digest::SHA256.file(v.fetch('path')).hexdigest==v.fetch('sha256')}
  raise 'source provenance' unless manifest.dig('pins','spinel','producer_source')=='facts'
  domain=JSON.parse(File.binread(root+'/inspect/xdpcount.domain.json'))
  raise 'domain source' unless domain.fetch('source')=='xdpcount.rb'
  raise 'domain roots' unless domain.fetch('roots').map{|r|r.fetch('name')}==['count_pkts']
  _,err,status=run.call('--inspect-dir',root+'/inspect',path)
  raise 'existing inspect not named rc3' unless status.exitstatus==3 && err.include?('already exists')
  _,_,status=run.call('--emit-dir',root+'/overlap','--inspect-dir',root+'/overlap/child',path)
  raise 'nested outputs not usage2' unless status.exitstatus==2 && !File.exist?(root+'/overlap')
  _,_,status=run.call('--inspect-dir',root+'/x','--inspect-dir',root+'/y',path)
  raise 'duplicate inspect not usage2' unless status.exitstatus==2
  _,_,status=run.call('--inspect-dir',root+'/parse','/nonexistent/e075.mlir')
  raise 'read failure publishes inspection' unless status.exitstatus==1 && !File.exist?(root+'/parse')
  # A valid fact fixture whose body really violates the existing arg-count rule.
  # Reuse the existing finalized body shape control by deleting the analyzed
  # policy's integer width: this is a policy failure before a domain exists.
  bad=text.sub('spinel_facts.integer_bits = 64','spinel_facts.integer_bits = 32')
  File.binwrite(root+'/policy.mlir',bad)
  _,_,status=run.call('--inspect-dir',root+'/policy-report',root+'/policy.mlir')
  raise 'policy rejection publishes false report' unless status.exitstatus==1 && !File.exist?(root+'/policy-report')
end
puts 'inspection CLI contracts GREEN'
