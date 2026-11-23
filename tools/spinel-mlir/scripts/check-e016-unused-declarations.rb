#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require_relative 'lib/byte-comparison'
repo, oracle, supply, producer, consumer, output = ARGV
abort 'usage: check-e016-unused-declarations REPO E035_CAPTURE E030_SUPPLY PRODUCER CONSUMER FRESH_OUT' unless output
abort 'output exists' if File.exist?(output)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
abort 'producer pin mismatch' unless sha.call(producer) == 'b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
abort 'consumer missing' unless File.executable?(consumer)
plan = JSON.parse(File.read(File.join(supply, 'plan.json')))
input_dir = File.join(repo, 'docs/experiments/results/E016/additional-negative/inputs')
inputs = Dir[File.join(input_dir, '*.rb')].sort
abort 'five input set required' unless inputs.length == 5
prepared = inputs.map do |path|
  id = File.basename(path, '.rb')
  original = File.join(oracle, 'synthetic', id)
  execution = JSON.parse(File.read(File.join(original, 'execution.json')))
  abort "source differs from E035 #{id}" unless execution.fetch('source_sha256') == sha.call(path)
  {id: id, path: path, source_sha256: sha.call(path), oracle: original}
end
plan.fetch('library').each do |path, hash|
  abort "library mismatch #{path}" unless sha.call(File.join(supply, 'source', path)) == hash
end
FileUtils.mkdir_p(output)
source = File.join(output, 'source')
plan.fetch('library').each_key do |path|
  target = File.join(source, path)
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.cp(File.join(supply, 'source', path), target)
end
File.write(File.join(output, 'plan.json'), JSON.pretty_generate({
  producer_sha256: sha.call(producer), consumer_sha256: sha.call(consumer),
  library: plan.fetch('library'), cases: prepared
}) + "\n")
rows = []
prepared.each do |item|
  id = item.fetch(:id)
  dir = File.join(output, 'cases', id)
  FileUtils.mkdir_p(dir)
  input = File.join(source, File.basename(item.fetch(:path)))
  FileUtils.cp(item.fetch(:path), input)
  facts = File.join(dir, 'facts.mlir')
  command = ['/usr/bin/timeout', '--kill-after=5s', '60s', producer,
    '-I', File.join(source, 'ruby/lib'), "--emit-mlir=#{facts}",
    '--analysis-root=prog:obj_BPF::XdpMd', input]
  out, err, ps = Open3.capture3(*command, chdir: source)
  File.binwrite(File.join(dir, 'producer.stdout'), out)
  File.binwrite(File.join(dir, 'producer.stderr'), err)
  row = {id: id, source_sha256: item.fetch(:source_sha256), producer_rc: ps.exitstatus,
    producer_signal: ps.termsig, command: command}
  stop = ->(message) do
    row[:stop] = message
    rows << row
    File.write(File.join(output, 'ledger.json'), JSON.pretty_generate(rows) + "\n")
    abort "STOP #{id}: #{message}"
  end
  stop.call('producer contract') unless ps.exitstatus == 0 && out.empty? && File.file?(facts) && File.size(facts) > 0
  row[:facts_sha256] = sha.call(facts)
  vo, ve, vs = Open3.capture3(consumer, '--verify-only', facts)
  File.binwrite(File.join(dir, 'verify.stdout'), vo)
  File.binwrite(File.join(dir, 'verify.stderr'), ve)
  row[:verify_rc] = vs.exitstatus
  stop.call('facts verification') unless vs.exitstatus == 0
  artifacts = File.join(dir, 'artifacts')
  co, ce, cs = Open3.capture3(consumer, '--emit-dir', artifacts, facts)
  File.binwrite(File.join(dir, 'build.stdout'), co)
  File.binwrite(File.join(dir, 'build.stderr'), ce)
  expected = File.binread(File.join(item.fetch(:oracle), 'build.stderr'))
  File.binwrite(File.join(dir, 'oracle.stderr'), expected)
  row.merge!(consumer_rc: cs.exitstatus, consumer_signal: cs.termsig,
    artifact_files: Dir[File.join(artifacts, '**', '*')].count { |p| File.file?(p) },
    stdout_bytes: co.bytesize, stderr_sha256: Digest::SHA256.hexdigest(ce),
    oracle_stderr_sha256: Digest::SHA256.hexdigest(expected), stderr_equal: ByteComparison.equal?(ce, expected))
  stop.call('negative rejection differs') unless cs.exitstatus == 1 && co.empty? &&
    row[:artifact_files] == 0 && row[:stderr_equal]
  rows << row
  File.write(File.join(output, 'ledger.json'), JSON.pretty_generate(rows) + "\n")
  puts "#{id}: producer0 verify0 consumer1 SB013 exact artifact0"
end
File.write(File.join(output, 'summary.json'), JSON.pretty_generate({
  cases: rows.size, producer_rc: rows.group_by { |r| r[:producer_rc] }.transform_values(&:size),
  verify_rc: rows.group_by { |r| r[:verify_rc] }.transform_values(&:size),
  consumer_rc: rows.group_by { |r| r[:consumer_rc] }.transform_values(&:size),
  exact: rows.count { |r| r[:stderr_equal] }, artifact_files: rows.sum { |r| r[:artifact_files] }
}) + "\n")
