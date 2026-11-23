#!/usr/bin/env ruby
# E052 supply only. Diagnostic comparison remains in batch-compare.rb.
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: capture-source-audits TOOLS VERIFIER FRESH_OUT [--plan-only]' unless (3..4).cover?(ARGV.size) && (ARGV.size == 3 || ARGV.last == '--plan-only')
tools, verifier, out = ARGV.take(3).map { |p| File.expand_path(p) }
repo = File.expand_path('..', __dir__)
abort 'fresh output required' if File.exist?(out)
sha = ->(p) { Digest::SHA256.file(p).hexdigest }
producer = tools + '/bin/spinel'
abort 'M3 producer hash' unless sha.call(producer) == 'b1165232e3ce6c6f74d60703aee28b46a7730e98aa2bf251328e6ceda72fd223'
builtins = JSON.parse(File.read(repo + '/docs/experiments/results/E040/builtins-sha256.json'))
abort 'builtins set' unless Dir[tools + '/builtins/*'].map { |p| File.basename(p) }.sort == builtins.keys.sort
builtins.each { |p, h| abort 'builtins hash' unless sha.call(tools + '/builtins/' + p) == h }
base = repo + '/docs/experiments/results/E003/'
library = JSON.parse(File.read(base + 'inputs-and-library.json')).fetch('ruby_lib')
library.each { |p, h| abort 'library hash' unless sha.call(base + 'ruby-lib/' + p.delete_prefix('ruby/lib/')) == h }
ids = %w[lpm_class reopen_lib dyn_send method_missing op_redef reopen_integer reserved rn_ebpf_other_def rn_ebpf_present_def rn_ebpf_program kret_in_expr no_def no_program early_return_in_arm early_return_in_loop early_return_mixed early_return_no_value mid_return]
rootless = %w[kret_in_expr no_def no_program]
oracle = JSON.parse(File.read(base + 'capture/manifest.json')).fetch('cases').to_h { |r| [r.fetch('id'), r] }
plan = ids.map do |name|
  row = oracle.fetch('internal_frontend_testdata_neg_' + name)
  dir = base + 'capture/' + row.fetch('raw_dir')
  source = dir + '/' + File.basename(row.fetch('source'))
  abort 'source hash' unless sha.call(source) == row.fetch('source_sha256')
  roots = if rootless.include?(name)
    [] # Invalid declaration selection is checked on pristine AST, no inferred target.
  else
    File.read(source).lines.filter_map { |line| m = line.match(/^BPF\.xdp\s+:([A-Za-z_]\w*)/); m && m[1] + ':obj_BPF::XdpMd' }
  end
  abort 'explicit root profile missing' if !rootless.include?(name) && roots.size != 1
  row.merge('original' => source, 'roots' => roots, 'profile' => rootless.include?(name) ? 'pristine-rootless' : 'typed-explicit-xdp',
            'oracle_stderr_sha256' => sha.call(dir + '/build.stderr'), 'reuse' => false)
end
FileUtils.mkdir_p(out)
File.write(out + '/plan.json', JSON.pretty_generate({ producer_sha256: sha.call(producer), builtins: builtins,
  verifier_sha256: sha.call(verifier), library: library, cases: plan }) + "\n")
if ARGV.last == '--plan-only'
  puts JSON.generate({ planned: plan.size, executed: 0 })
  exit
end
library.each do |path, _|
  target = out + '/source/' + path
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.copy_file(base + 'ruby-lib/' + path.delete_prefix('ruby/lib/'), target)
end
ledger = []
plan.each do |row|
  dir = out + '/cases/' + row.fetch('id')
  FileUtils.mkdir_p(dir + '/tmp')
  source = dir + '/' + File.basename(row.fetch('source'))
  FileUtils.copy_file(row.fetch('original'), source)
  facts = dir + '/facts.mlir'
  argv = ['/usr/bin/timeout', '--kill-after=5s', '60s', producer, '-I', out + '/source/ruby/lib', '--emit-mlir=' + facts,
          *row.fetch('roots').map { |r| '--analysis-root=' + r }, File.basename(source)]
  so, se, status = Open3.capture3({ 'TMPDIR' => dir + '/tmp' }, *argv, chdir: dir)
  File.binwrite(dir + '/producer.stdout', so)
  File.binwrite(dir + '/producer.stderr', se)
  result = row.merge('argv' => argv, 'cwd' => dir, 'rc' => status.exitstatus, 'signal' => status.termsig,
                     'facts' => facts, 'bytes' => File.size?(facts).to_i)
  ledger << result
  File.write(out + '/ledger.json', JSON.pretty_generate(ledger) + "\n")
  abort 'STOP source audit producer: ' + row.fetch('id') unless status.success? && so.empty? && result['bytes'] > 0
  vo, ve, vs = Open3.capture3(verifier, '--verify-only', facts)
  File.binwrite(dir + '/verify.stdout', vo)
  File.binwrite(dir + '/verify.stderr', ve)
  result.merge!('verify_rc' => vs.exitstatus, 'verify_signal' => vs.termsig, 'sha256' => sha.call(facts))
  File.write(out + '/ledger.json', JSON.pretty_generate(ledger) + "\n")
  abort 'STOP source audit verify: ' + row.fetch('id') unless vs.success?
end
puts JSON.generate({ captured: ledger.size, producer_rc: ledger.map { |r| r.fetch('rc') }.tally })
