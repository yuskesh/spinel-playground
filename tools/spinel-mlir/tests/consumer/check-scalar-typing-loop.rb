require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative '../../scripts/lib/byte-comparison'
tool, repo, inputs, archive, work = ARGV
abort 'usage: TOOL REPO INPUTS ARCHIVE WORK' unless work
FileUtils.rm_rf(work) if File.directory?(work)
FileUtils.mkdir_p(work)
abort 'fixture extract failed' unless system('/usr/bin/tar','-xzf',archive,'-C',work,'capture-01/cases')
failures = []
JSON.parse(File.read(inputs)).fetch('cases').each do |row|
  id = row.fetch('id')
  dir = work+'/capture-01/cases/'+id
  expected = File.binread(repo+'/'+row.fetch('stderr'))
  abort 'oracle changed: '+id unless Digest::SHA256.hexdigest(expected) == row.fetch('stderr_sha256')
  stdout, stderr, status = Open3.capture3('/usr/bin/timeout','--kill-after=2s','20s',tool,'--emit-dir',dir+'/artifacts',dir+'/facts.mlir')
  File.binwrite(dir+'/consumer.stdout',stdout)
  File.binwrite(dir+'/consumer.stderr',stderr)
  File.write(dir+'/consumer.rc',"#{status.exitstatus}\n")
  okay = status.exitstatus == 1 && !status.termsig && stdout.empty? &&
         Dir[dir+'/artifacts/*'].empty? && ByteComparison.equal?(stderr,expected)
  failures << id unless okay
end
abort 'diagnostic mismatch: '+failures.join(', ') unless failures.empty?
puts 'scalar/typing/loop: 20 canonical diagnostics, failure and artifact boundaries passed'
