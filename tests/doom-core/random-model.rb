# frozen_string_literal: true
#
# tests/doom-core/random-model.rb — the ported generator against the original.
#
# Every demo comparison rests on the random stream, so what is checked is the
# STREAM and the counters, draw for draw, over a sequence that interleaves the
# two generators the way a tic does -- the melt wipe's 320 menu draws at tic 2
# among the game's own.
#
# The original is `Doom::Random` itself, not a transcription of it.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require_relative File.join(ROOT, "examples/doom/core/src/random")
require_relative File.join(ROOT, "examples/doom/lib/doom/random")

orig = Doom::Random.new
orig.clear
table = Doom::Random::RNDTABLE.bytes
prnd = [0]; rnd = [0]; pc = [0]; mc = [0]
dc_clear_random(prnd, rnd)

ops = []
2000.times { |i| ops << (i % 97 == 2 ? :m : :p) }
320.times { ops << :m }          # the melt wipe
2000.times { |i| ops << (i.even? ? :p : :m) }

mismatch = []
ops.each_with_index do |op, k|
  if op == :p
    a = orig.p_random(0)
    b = dc_p_random(table, table.length, prnd, pc)
  else
    a = orig.m_random
    b = dc_m_random(table, table.length, rnd, mc)
  end
  mismatch << [k, op, a, b] unless a == b
end
puts "draws #{ops.length}"
puts "mismatch #{mismatch.length}"
mismatch.first(3).each { |k, op, a, b| puts "  #{k} #{op} #{a}/#{b}" }
puts "prndindex #{orig.prndindex} #{prnd[0]}"
puts "rndindex #{orig.rndindex} #{rnd[0]}"
puts "pcount #{orig.pcount} #{pc[0]}"
puts "mcount #{orig.mcount} #{mc[0]}"
# Clearing the indices must not clear the counters.
dc_clear_random(prnd, rnd)
puts "cleared #{prnd[0]} #{rnd[0]} #{pc[0]} #{mc[0]}"

# --- the injections 0008 task 6 asks for ------------------------------------
# "Inject omitted/reordered random calls and swapped state fields; require the
# corresponding comparator diagnostic." A stream comparison that did not
# notice these would not be evidence of anything.
# THE VALUE STREAM IS NOT ENOUGH, and that is measured below. Both indices
# start at zero and walk the same table, so using the wrong generator
# throughout produces the SAME values -- the counters are what tell the two
# apart, which is why `pcount` and `mcount` are state in the schema rather
# than instrumentation a release build might not have.
def stream(ops, table)
  prnd = [0]; rnd = [0]; pc = [0]; mc = [0]
  vals = ops.map do |op|
    op == :p ? dc_p_random(table, table.length, prnd, pc)
             : dc_m_random(table, table.length, rnd, mc)
  end
  [vals, [pc[0], mc[0]]]
end
base_ops = Array.new(600) { |i| i % 5 == 0 ? :m : :p }
base, base_counts = stream(base_ops, table)

omitted = base_ops.dup
omitted.delete_at(300)                       # one draw that never happens
reordered = base_ops.dup
reordered[100], reordered[101] = reordered[101], reordered[100]
swapped = base_ops.map { |o| o == :p ? :m : :p }   # the wrong index entirely

[["omitted", omitted], ["reordered", reordered], ["swapped", swapped]].each do |name, ops|
  s, counts = stream(ops, table)
  n = [base.length, s.length].min
  at = (0...n).find { |i| base[i] != s[i] }
  by_value = at.nil? ? "values-agree" : "values-diverge-at-#{at}"
  by_count = counts == base_counts ? "counts-agree" : "counts-differ"
  puts "#{name} #{by_value} #{by_count} lengths #{base.length}/#{s.length}"
end

# --- the trace is reference-only ---------------------------------------------
# Random@@log_*, @log_n, @trace and @tic are eliminated from the schema as a
# reference-only trace (tools/doom/core-fields.tsv): the port has no trace, and
# only bin/sim_demo.rb turns the original's on. That is only right while the
# trace changes nothing the game sees. So the ORIGINAL is run with the trace off
# and on -- `trace!(0)` (a bank that is full at once), `trace!(1)` (full after
# one draw) and `trace!(64)` -- over the same interleaved draws, after `clear`,
# and the value stream and all four state fields must be identical. `log_n` is
# the one thing allowed to differ, and it is printed.
trace_ops = base_ops.first(200)
run_original = lambda do |cap|
  r = Doom::Random.new
  r.clear
  r.trace!(cap) if cap
  vals = trace_ops.each_with_index.map { |op, k| r.tic = k; op == :p ? r.p_random(k % 7) : r.m_random }
  [vals, [r.prndindex, r.rndindex, r.pcount, r.mcount], r.log_n]
end
off_vals, off_state, off_n = run_original.call(nil)
port_vals, port_counts = stream(trace_ops, table)
puts "trace off log_n #{off_n} port-values #{port_vals == off_vals ? 'agree' : 'differ'} " \
     "port-counts #{port_counts == off_state[2, 2] ? 'agree' : 'differ'}"
[0, 1, 64].each do |cap|
  vals, state, n = run_original.call(cap)
  puts "trace cap #{cap} values #{vals == off_vals ? 'agree' : 'differ'} " \
       "state #{state == off_state ? 'agree' : 'differ'} log_n #{n}"
end
puts "trace first values #{off_vals.first(3).join(',')} state #{off_state.join(',')}"
