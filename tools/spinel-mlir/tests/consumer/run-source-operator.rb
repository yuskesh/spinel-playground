require 'open3'
require 'tmpdir'
tool, archive = ARGV
abort 'usage: run-source-operator TOOL SUPPLY_ARCHIVE' unless archive
Dir.mktmpdir('source-operator-') do |dir|
  raw, error, status = Open3.capture3('/usr/bin/tar','-xOzf',archive,'facts-01/cases/internal_frontend_testdata_neg_op_redef/facts.mlir')
  abort 'source operator fixture extract: '+error unless status.success? && !raw.empty?
  file = dir+'/facts.mlir'
  File.binwrite(file,raw)
  stdout,stderr,result = Open3.capture3(tool,file)
  $stdout.write(stdout);$stderr.write(stderr)
  exit(result.exitstatus || 1)
end
