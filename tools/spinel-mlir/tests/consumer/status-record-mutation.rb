# E045 H6 (A): the record value of a hash status with its first two members
# swapped (test build only). Named observations: the base IR equals Go's after
# the normalizer, the mutant's IR differs from Go's, and both write the same
# schema and maps.json (rc 1 from either arm is not counted as detection).
require 'zlib'
require 'fileutils'
require 'open3'
base, mutant, normalizer, fixture, oracle, work = ARGV
abort 'usage: status-record-mutation BASE MUTANT NORMALIZER FACTS_GZ GO_MLIR WORK' unless work
FileUtils.mkdir_p(work)
facts = File.join(work, 'facts.mlir')
File.binwrite(facts, Zlib::GzipReader.open(fixture, &:read))
run = lambda do |tool, arm|
  out = File.join(work, arm)
  FileUtils.rm_rf(out)
  _, err, st = Open3.capture3(tool, '--emit-dir', out, facts)
  abort "#{arm} failed: #{err}" unless st.success?
  %w[mlir schema.json maps.json].each { |x| abort "#{arm} empty #{x}" unless File.size?("#{out}/xdpcount.#{x}") }
  out
end
normalize = lambda do |path|
  out, err, st = Open3.capture3(normalizer, path)
  abort "normalizer failed on #{path}: #{err}" unless st.success? && !out.empty?
  out
end
b = run.(base, 'base')
m = run.(mutant, 'mutant')
go = normalize.(oracle)
abort 'base IR differs from Go' unless normalize.("#{b}/xdpcount.mlir") == go
puts 'ok base IR equals Go (normalized)'
%w[schema.json maps.json].each do |x|
  abort "mutant #{x} differs from base" unless File.binread("#{b}/xdpcount.#{x}") == File.binread("#{m}/xdpcount.#{x}")
  puts "ok mutant #{x} equals base"
end
abort 'mutant IR equals Go — not detected' if normalize.("#{m}/xdpcount.mlir") == go
puts 'detected: mutant IR differs from Go (normalized)'
