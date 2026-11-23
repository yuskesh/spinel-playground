# frozen_string_literal: true
#
# E456: numeric comparator for the gpu-metal harness. Text formats differ
# between Swift and Ruby float printing, so compare NUMBERS, not lines.
#
#   ruby gpu_compare.rb <gpu.txt> <oracle.txt> [rel_tol]
#
# Each file is "<index> <value>" per line. Exit 0 with the max relative error on
# stdout when every element is within tolerance; exit 1 naming the first
# offender otherwise. Index sets must match exactly (a missing element is a
# failure, not a skip).

abort "usage: ruby gpu_compare.rb <a.txt> <b.txt> [rel_tol]" unless ARGV.length >= 2
tol = ARGV[2] ? Float(ARGV[2]) : 1e-5

def load_vals(path)
  h = {}
  File.foreach(path) do |line|
    i, v = line.split
    next unless i && v
    h[Integer(i)] = Float(v)
  end
  h
end

a = load_vals(ARGV[0])
b = load_vals(ARGV[1])
abort "FAIL: element count differs (#{a.length} vs #{b.length})" unless a.keys.sort == b.keys.sort
abort "FAIL: empty comparison (0 elements) -- the harness produced nothing" if a.empty?

max_rel = 0.0
max_at = -1
a.keys.sort.each do |i|
  x, y = a[i], b[i]
  denom = [x.abs, y.abs, 1e-30].max
  rel = (x - y).abs / denom
  if rel > max_rel
    max_rel = rel
    max_at = i
  end
  if rel > tol
    abort format("FAIL: element %d differs beyond tol=%g: gpu=%.9g oracle=%.9g (rel=%.3g)",
                 i, tol, x, y, rel)
  end
end
where = max_at >= 0 ? " at #{max_at}" : ""
puts format("OK: %d elements, max_rel_err=%.3g%s (tol=%g)", a.length, max_rel, where, tol)
