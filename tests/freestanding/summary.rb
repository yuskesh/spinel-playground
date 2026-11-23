# frozen_string_literal: true
#
# tests/freestanding/summary.rb -- counts the verdict rows of every table a lane
# wrote, so run.sh can print one line per lane with the numbers behind it.
#
#   ruby summary.rb <results-dir>   ->  "<pass> pass, <fail> fail, <np> not ported (<tables>)"
#
# The lanes kept spinel-llvm's table shapes, which differ, so each row is read
# by the columns its header has:
#   - `expected` beside `verdict` (e063 reject.tsv): pass when they are equal;
#   - `kind` (reject/control/allow/deny): fail when the verdict says
#     "(should not be)", which is how those runners spell a wrong outcome;
#   - otherwise the `verdict` or `result` column: pass on PASS or MATCH;
#   - a table with no header (the probes' trap.tsv): the first field.
# NOT-PORTED is counted apart, never as a pass. The per-symbol undef.*.tsv
# listings, shapes, sizes and raw outputs are records, not checks, and are skipped.

COUNTED = %w[undef_gate extern_check reject ran trap zephyr abi workerd determinism legs loop surface hvpsym host image platforms].freeze

dir = ARGV.fetch(0)
pass = fail = np = 0
seen = []
Dir.glob(File.join(dir, "*.tsv")).sort.each do |path|
  name = File.basename(path, ".tsv")
  next unless COUNTED.include?(name)
  lines = File.readlines(path, chomp: true).reject(&:empty?)
  next if lines.empty?
  head = lines.first.split("\t")
  headed = head.include?("verdict") || head.include?("result")
  rows = headed ? lines.drop(1) : lines
  col = head.index("verdict") || head.index("result")
  exp = head.index("expected")
  kind = head.index("kind")
  rows.each do |line|
    f = line.split("\t")
    v = headed ? f[col].to_s : f[0].to_s
    if v.include?("NOT-PORTED") || (kind && f[kind] == "not-ported")
      np += 1
    elsif exp
      v == f[exp] ? pass += 1 : fail += 1
    elsif kind
      v.include?("should not be") ? fail += 1 : pass += 1
    elsif v.start_with?("PASS", "MATCH")
      pass += 1
    else
      fail += 1
    end
  end
  seen << name
end
puts "#{pass} pass, #{fail} fail, #{np} not ported (#{seen.join(' ')})"
exit(fail.zero? && !seen.empty? ? 0 : 1)
