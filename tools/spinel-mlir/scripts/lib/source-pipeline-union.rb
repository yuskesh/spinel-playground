require 'json'
require 'digest'
require 'fileutils'
require 'open3'

# Optional plan arm, selected only by execution.kind. Missing facts is never a
# request to retry a failed facts consumer through the source pipeline.
module SourcePipelineUnion
  module_function
  def verify(input)
    execution = input.fetch('execution')
    raise 'source pipeline execution kind' unless execution.fetch('kind') == 'source_pipeline'
    raise 'source pipeline facts must be null' unless input.key?('facts') && input['facts'].nil?
    %w[source producer].each do |name|
      raise 'source pipeline ' + name + ' hash' unless Digest::SHA256.file(execution.fetch(name)).hexdigest == execution.fetch(name + '_sha256')
    end
    %w[library builtins].each do |name|
      root = execution.fetch(name)
      expected = execution.fetch(name + '_sha256')
      actual = Dir[root + '/**/*'].select { |p| File.file?(p) }.sort.to_h { |p| [p.delete_prefix(root + '/'), Digest::SHA256.file(p).hexdigest] }
      raise 'source pipeline ' + name + ' closure' unless actual == expected
    end
    raise 'source pipeline roots' unless execution.fetch('roots').is_a?(Array) && execution['roots'].all? { |r| r.is_a?(String) }
  end

  def capture(input, out, dir, run, inspection = false)
    verify(input)
    execution = input.fetch('execution')
    command = ['/usr/bin/ruby', out + '/tools/compile-spinel.rb', '--producer', execution.fetch('producer'),
               '--consumer', out + '/tools/consumer', '--library', execution.fetch('library'), '--work-dir', run + '/pipeline',
               *execution.fetch('roots').flat_map { |r| ['--analysis-root', r] }, execution.fetch('source')]
    if inspection
      metadata=execution.fetch('producer_metadata')
      raise 'source pipeline metadata hash' unless Digest::SHA256.file(metadata).hexdigest==execution.fetch('producer_metadata_sha256')
      command.insert(-2,'--inspect-dir',run+'/inspection','--producer-metadata',metadata)
    end
    stdout, stderr, status = Open3.capture3(*command)
    File.binwrite(dir + '/build.stdout', stdout)
    File.binwrite(dir + '/build.stderr', stderr)
    row = input.merge('argv' => command, 'rc' => status.exitstatus, 'signal' => status.termsig)
    # Real producer/probe rc and raw hashes live separately from adapter rc.
    execution_path = run + '/pipeline/execution.json'
    row['source_pipeline'] = JSON.parse(File.read(execution_path)) if File.file?(execution_path)
    row['artifacts'] = Dir[run + '/pipeline/artifacts/*'].to_h { |p| [File.basename(p), { bytes: File.size(p), sha256: Digest::SHA256.file(p).hexdigest }] }
    row
  end
end
