#!/usr/bin/env ruby
require 'open3'
require 'tmpdir'
require 'json'
repo = File.expand_path('..', __dir__)
require_relative '../scripts/lib/source-pipeline-union'
%w[facts_consumer inherited unknown].each do |kind|
  begin
    SourcePipelineUnion.verify({ 'facts' => nil, 'execution' => { 'kind' => kind } })
    abort 'missing facts selected source pipeline implicitly'
  rescue RuntimeError => error
    abort 'wrong explicit-kind rejection' unless error.message == 'source pipeline execution kind'
  end
end
Dir.mktmpdir('e052-pipeline-test-') do |dir|
  source = dir + '/sample.rb'
  File.write(source, "require_relative \"other\"\n")
  File.write(dir + '/producer', <<~'RUBY')
    #!/usr/bin/env ruby
    if ARGV.include?('--dump-ast') || ARGV.any? { |a| a.start_with?('--emit-mlir=') }
      warn 'spinel: sample.rb: cannot load such file -- other.rb (require_relative "other")'
      exit 1
    end
    exit 2
  RUBY
  File.chmod(0755, dir + '/producer')
  File.write(dir + '/bpf.rb', '# library fixture')
  command = ['ruby', repo + '/scripts/compile-spinel.rb', '--producer', dir + '/producer',
             '--consumer', '/usr/bin/false', '--library', dir, '--work-dir', dir + '/run', source]
  stdout, stderr, status = Open3.capture3(*command)
  expected = "sample.rb:1:1: rejected SB001 (UnsupportedConstruct): `require_relative` is not accepted in P001 (the program is one file plus `require \"bpf\"`); spinel: spinel --dump-ast failed: spinel: sample.rb: cannot load such file -- other.rb (require_relative \"other\")\n"
  abort "source pipeline loader diagnostic missing: rc=#{status.exitstatus}, stderr=#{stderr.inspect}" unless status.exitstatus == 1 && stdout.empty? && stderr.b == expected.b
  ledger = JSON.parse(File.read(dir + '/run/execution.json'))
  abort 'source pipeline stages missing' unless ledger.fetch('m3').fetch('rc') == 1 && ledger.fetch('probe').fetch('rc') == 1 && !ledger.key?('consumer')
  abort 'failed producer published facts' if File.exist?(dir + '/run/facts.mlir')
end
Dir.mktmpdir('e052-pipeline-success-') do |dir|
  File.write(dir + '/sample.rb', "require \"bpf\"\n")
  File.write(dir + '/bpf.rb', '# library fixture')
  File.write(dir + '/producer', <<~'RUBY')
    #!/usr/bin/env ruby
    abort 'unexpected diagnostic probe' if ARGV.include?('--dump-ast')
    File.write(ARGV.find { |a| a.start_with?('--emit-mlir=') }.split('=', 2)[1], 'fixture facts')
  RUBY
  File.write(dir + '/consumer', "#!/bin/sh\nexit 0\n")
  File.chmod(0755, dir + '/producer', dir + '/consumer')
  command = ['ruby', repo + '/scripts/compile-spinel.rb', '--producer', dir + '/producer',
             '--consumer', dir + '/consumer', '--library', dir, '--work-dir', dir + '/run', dir + '/sample.rb']
  stdout, stderr, status = Open3.capture3(*command)
  abort 'successful M3 pipeline failed' unless status.success? && stdout.empty? && stderr.empty?
  ledger = JSON.parse(File.read(dir + '/run/execution.json'))
  abort 'successful M3 ran probe' if ledger.key?('probe')
  abort 'successful M3 skipped consumer' unless ledger.fetch('consumer').fetch('rc') == 0
  # A failed stage must not request the loader probe just because the source
  # contains require_relative. This is an environment failure, not SB001.
  File.write(dir + '/sample.rb', "require_relative \"other\"\n")
  File.write(dir + '/producer', "#!/bin/sh\necho 'missing builtins' >&2\nexit 1\n")
  command[command.index('--work-dir') + 1] = dir + '/failed'
  stdout, stderr, status = Open3.capture3(*command)
  abort 'unrelated producer failure disguised as loader diagnostic' unless status.exitstatus == 2 && stdout.empty? && stderr.include?('outside the supported loader diagnostic route')
  ledger = JSON.parse(File.read(dir + '/failed/execution.json'))
  abort 'unrelated producer failure ran probe/consumer' if ledger.key?('probe') || ledger.key?('consumer')
  abort 'failed adapter result missing' unless ledger.fetch('adapter').fetch('rc') == 2
end
puts 'source pipeline loader wrapper fixture ok (not a real producer observation)'
