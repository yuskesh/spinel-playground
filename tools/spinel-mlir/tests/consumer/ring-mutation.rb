# E029 H6: a ring mutation build changes only the named IR of a saved facts
# input; rc 1 alone never counts as detection. SSA names are not compared —
# MLIR names constants after their values and numbers the rest by order.
#   ring-mutation.rb TOOL MUTANT swap|polarity FACTS_GZ WORK [CHECKER]
require 'zlib'
require 'fileutils'
require 'open3'
tool, mutant, kind, fixture, work, checker = ARGV
abort 'usage: ring-mutation TOOL MUTANT swap|polarity FACTS_GZ WORK' unless work
abort "unknown mutation #{kind}" unless %w[swap polarity].include?(kind)
FileUtils.rm_rf(work)
FileUtils.mkdir_p(work)
facts = File.join(work, 'facts.mlir')
File.binwrite(facts, Zlib::GzipReader.open(fixture, &:read))
arms = {}
{ 'base' => tool, 'mutant' => mutant }.each do |arm, bin|
  out = File.join(work, arm)
  _o, err, st = Open3.capture3(bin, '--emit-dir', out, facts)
  files = Dir[File.join(out, '*')].sort
  abort "#{arm}: rc #{st.exitstatus}: #{err}" unless st.success?
  abort "#{arm}: expected 3 non-empty artifacts, got #{files.map { |f| [File.basename(f), File.size(f)] }}" unless files.size == 3 && files.all? { |f| File.size(f) > 0 }
  # Keyed by suffix: ".mlir", ".schema.json", ".maps.json".
  arms[arm] = files.to_h { |f| [File.basename(f).sub(/\A[^.]*/, ''), File.read(f)] }
end
base, mut = arms['base'], arms['mutant']
abort "artifact names differ: #{base.keys} / #{mut.keys}" unless base.keys == mut.keys
abort "no .mlir artifact: #{base.keys}" unless base.key?('.mlir')
base.each_key { |k| next if k == '.mlir'; abort "#{k} differs (only the IR may change)" unless base[k] == mut[k] }

REF = /%[\w.$-]+/
# The IR body lines without locations (the #loc table differs by order only).
def body(ir) = ir.lines.map { |l| l.sub(/\s*loc\([^)]*\)\s*$/, '').rstrip }.reject { |l| l.empty? || l.start_with?('#loc') }
a, b = body(base['.mlir']), body(mut['.mlir'])
abort "IR line count differs: #{a.size} / #{b.size}" unless a.size == b.size

case kind
when 'polarity'
  na, nb = a.map { |l| l.gsub(REF, '%_') }, b.map { |l| l.gsub(REF, '%_') }
  diffs = na.each_index.reject { |i| na[i] == nb[i] }
  abort 'mutation not observed: the IR is identical' if diffs.empty?
  diffs.each do |i|
    flipped = na[i].sub(/arith\.constant (true|false)\z/) { "arith.constant #{$1 == 'true' ? 'false' : 'true'}" }
    abort "unexpected IR difference at line #{i + 1}:\n- #{a[i]}\n+ #{b[i]}" unless na[i] =~ /arith\.constant (true|false)\z/ && nb[i] == flipped
  end
  abort "polarity: expected exactly 2 flipped constants per output, got #{diffs.size}" unless diffs.size.even? && diffs.size >= 2
  puts "ok polarity: #{diffs.size} yield constant(s) flipped, all else equal up to SSA names; schema and maps unchanged"
  diffs.each { |i| puts "  line #{i + 1}: #{a[i].strip}  =>  #{b[i].strip}" }
when 'swap'
  # SSA names are reused across sibling regions, so the swap is compared on
  # the parsed SSA graph (spinel-ring-test --swap).
  abort 'swap needs the checker (spinel-ring-test)' unless checker
  out, st = Open3.capture2e(checker, '--swap', Dir[File.join(work, 'base', '*.mlir')].first,
                            Dir[File.join(work, 'mutant', '*.mlir')].first)
  puts out
  abort 'swap: the structural check failed' unless st.success?
  puts 'ok swap: schema and maps unchanged'
end
