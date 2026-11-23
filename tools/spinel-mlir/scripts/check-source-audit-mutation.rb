#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
abort 'usage: check-source-audit-mutation FACTS BASELINE_CASE MUTANT FRESH_OUT' unless ARGV.size == 4
facts, baseline, mutant, out = ARGV.map { |p| File.expand_path(p) }
abort 'fresh output required' if File.exist?(out)
FileUtils.mkdir_p(out)
want = File.binread(baseline + '/build.stderr')
abort 'baseline is not the intended diagnostic' unless want.include?(': rejected SB007 (ReservedName):'.b) && want.include?('uses the reserved prefix spinelbpf_'.b)
abort 'baseline stdout is nonempty' unless File.zero?(baseline + '/build.stdout')
argv = [mutant, '--emit-dir', out + '/artifacts', facts]
stdout, stderr, status = Open3.capture3(*argv)
File.binwrite(out + '/mutation.stdout', stdout); File.binwrite(out + '/mutation.stderr', stderr)
diff = want.bytes.zip(stderr.bytes).each_index.select { |i| want.getbyte(i) != stderr.getbyte(i) }
result = { argv: argv, rc: status.exitstatus, signal: status.termsig, facts_sha256: Digest::SHA256.file(facts).hexdigest,
           mutant_sha256: Digest::SHA256.file(mutant).hexdigest, baseline_sha256: Digest::SHA256.hexdigest(want),
           baseline_bytes: want.bytesize, mutation_bytes: stderr.bytesize, byte_offsets: diff,
           artifacts: Dir[out + '/artifacts/*'] }
File.write(out + '/result.json', JSON.pretty_generate(result) + "\n")
abort 'STOP diagnostic mutation' unless status.exitstatus == 1 && !status.termsig && stdout.empty? && result[:artifacts].empty? &&
  want.bytesize == stderr.bytesize && diff.size == 1 && want.getbyte(diff[0]) == '_'.ord && stderr.getbyte(diff[0]) == '!'.ord &&
  stderr.include?(': rejected SB007 (ReservedName):'.b)
puts JSON.generate(result)
