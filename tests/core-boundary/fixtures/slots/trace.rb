# frozen_string_literal: true
#
# The original Full slot and link state, answering for itself -- beside an
# INDEPENDENT MODEL, which is what decision 0007 asks for at this bullet.
#
# Three worlds run the same operations:
#
#   1. the ORIGINAL. `Doom::Game`'s own add_thinker, remove_thinker,
#      run_thinkers, free_thinker, alloc_mobj and free_mobj, UNMODIFIED.
#      #initialize wants a level and a wad, so the object is `allocate`d and
#      the six thinker ivars (or the three mobj ones) are set directly; those
#      methods read nothing else. What runs is the code in the Full tree.
#
#      run_thinkers dispatches on the thinker kind, and that dispatch is not
#      part of this capability. Every live slot is given TH_NULL, which is 10
#      and which none of the original's ten branches match, so its sweep runs
#      with no thinker function called at all. The sweep is what is extracted;
#      the dispatch stays in Full.
#
#   2. the EXTRACTION, under CRuby, given `core_fail`'s CRuby meaning.
#
#   3. the MODEL in model.rb, which keeps an ordered Array and a stack and
#      DERIVES the link fields rather than assigning one from another.
#
# After EVERY operation all three must agree on the status, the result, and
# every cell of every array -- not a summary of them. The trace and those
# expectations are then written out for the C harness, which calls the CORE
# kernels and compares the same way.
#
# usage: trace.rb <repo-root> <fixtures-dir> <out-file>

root = ARGV[0] or abort("trace: the repository root is required")
fixtures = ARGV[1] or abort("trace: the fixture directory is required")
out = ARGV[2] or abort("trace: an output path is required")

$LOAD_PATH.unshift(File.join(root, "examples", "doom", "lib"))
require "doom/game"
require File.join(fixtures, "model")

# Each extracted source names its own constants, because a CORE root is its own
# closure; loading them together re-initialises the shared ones. Silenced only
# across the loads, and checked afterwards, so silencing cannot hide two
# sources disagreeing.
verbose = $VERBOSE
$VERBOSE = nil
Dir[File.join(fixtures, "src", "*.rb")].sort.each { |f| load f }
$VERBOSE = verbose
abort("trace: the extracted sources disagree about TH_REMOVED") if TH_REMOVED != 0
abort("trace: the extracted sources disagree about TH_NULL") if TH_NULL != 10

def core_fail(category)
  raise CoreFail, category
end

STATUS = { nil => 0, capacity: 4 }.freeze   # decision 0007's numbers

# ---- the trace ------------------------------------------------------------

WIDTHS = { "cap" => 2, "exhaust" => 2, "op" => 4, "check" => 10 }.freeze
cap = nil
exhaust = nil
ops = []
checks = []
lineno = 0
File.readlines(File.join(fixtures, "trace.tsv"), chomp: true).each do |line|
  lineno += 1
  next if line.start_with?("#") || line.strip.empty?
  f = line.split("\t", -1)
  where = "trace.tsv line #{lineno}"
  want = WIDTHS[f[0]] or abort("trace: #{where} has an unknown record #{f[0].inspect}")
  abort("trace: #{where} is a #{f[0]} record with #{f.length} columns, not #{want}") if f.length != want
  case f[0]
  when "cap"
    abort("trace: #{where} declares the capacity a second time") if cap
    cap = Integer(f[1], 10)
  when "exhaust"
    abort("trace: #{where} declares the exhaustion capacity a second time") if exhaust
    exhaust = Integer(f[1], 10)
  when "op"
    ops << [f[1], f[2] == "-" ? 0 : Integer(f[2], 10), f[3] == "-" ? 0 : Integer(f[3], 10)]
  when "check"
    checks << f[1, 9]
  end
end
abort("trace: trace.tsv declares no capacity") unless cap
abort("trace: trace.tsv declares no exhaustion capacity") unless exhaust
abort("trace: trace.tsv declares no operations") if ops.empty?
abort("trace: trace.tsv declares no ABI checks") if checks.empty?

KINDS = %w[tadd tremove tcollect malloc mfree].freeze
ops.each { |k, _, _| abort("trace: trace.tsv has an unknown operation #{k.inspect}") unless KINDS.include?(k) }

# ---- the three worlds -----------------------------------------------------

def fresh_original_thinkers(cap)
  g = Doom::Game.allocate
  { :@th_next => Array.new(cap, 0), :@th_prev => Array.new(cap, 0),
    :@th_func => Array.new(cap, TH_NULL), :@th_data => Array.new(cap, -1),
    :@th_alloc => 1, :@th_free => -1 }.each { |k, v| g.instance_variable_set(k, v) }
  g
end

def fresh_original_mobjs(cap)
  g = Doom::Game.allocate
  { :@thing_next => Array.new(cap, -1), :@mobj_alloc => 0,
    :@mobj_free => -1 }.each { |k, v| g.instance_variable_set(k, v) }
  g
end

def original_thinker_state(g)
  { func: g.instance_variable_get(:@th_func).dup,
    data: g.instance_variable_get(:@th_data).dup,
    next: g.instance_variable_get(:@th_next).dup,
    prev: g.instance_variable_get(:@th_prev).dup,
    state: [g.instance_variable_get(:@th_free), g.instance_variable_get(:@th_alloc)] }
end

def original_mobj_state(g)
  { thing_next: g.instance_variable_get(:@thing_next).dup,
    state: [g.instance_variable_get(:@mobj_free), g.instance_variable_get(:@mobj_alloc)] }
end

def extracted_thinkers(cap)
  { func: Array.new(cap, TH_NULL), data: Array.new(cap, -1),
    next: Array.new(cap, 0), prev: Array.new(cap, 0), state: [-1, 1] }
end

def extracted_mobjs(cap)
  { thing_next: Array.new(cap, -1), state: [-1, 0] }
end

# ---- running one operation in each world ----------------------------------

# The original does not return the number of slots its sweep freed, so that
# answer is taken from its own public accessor: the drop in the length of the
# live list. Derived from the original's state, not transcribed from its code.
def run_original(g, mg, kind, a, b)
  case kind
  when "tadd"      then [0, g.send(:add_thinker, a, b)]
  when "tremove"   then g.send(:remove_thinker, a); [0, 0]
  when "tcollect"
    before = g.send(:thinker_slots).length
    g.send(:run_thinkers)
    [0, before - g.send(:thinker_slots).length]
  when "malloc"    then [0, mg.send(:alloc_mobj)]
  when "mfree"     then mg.send(:free_mobj, a); [0, 0]
  end
rescue Doom::LevelError
  [STATUS[:capacity], nil]
end

def run_extracted(t, m, kind, a, b)
  case kind
  when "tadd"
    [0, thinker_add(a, b, t[:func], t[:func].length, t[:data], t[:data].length,
                    t[:next], t[:next].length, t[:prev], t[:prev].length,
                    t[:state], t[:state].length)]
  when "tremove"   then [0, thinker_remove(a, t[:func], t[:func].length)]
  when "tcollect"
    [0, thinker_collect(t[:func], t[:func].length, t[:data], t[:data].length,
                        t[:next], t[:next].length, t[:prev], t[:prev].length,
                        t[:state], t[:state].length)]
  when "malloc"    then [0, mobj_alloc(m[:thing_next], m[:thing_next].length, m[:state], m[:state].length)]
  when "mfree"     then [0, mobj_free(a, m[:thing_next], m[:thing_next].length, m[:state], m[:state].length)]
  end
rescue CoreFail => e
  [STATUS.fetch(e.category), nil]
end

def run_model(tm, mm, kind, a, b)
  case kind
  when "tadd"      then [0, tm.add(a, b)]
  when "tremove"   then tm.remove(a); [0, 0]
  when "tcollect"  then [0, tm.collect]
  when "malloc"    then [0, mm.alloc]
  when "mfree"     then mm.free(a); [0, 0]
  end
rescue CoreFail => e
  [STATUS.fetch(e.category), nil]
end

THINKER_KINDS = %w[tadd tremove tcollect].freeze

def compare(where, want, got, whose)
  return if want == got
  bad = nil
  want.each_key do |k|
    next if want[k] == got[k]
    i = (0...want[k].length).find { |j| want[k][j] != got[k][j] }
    bad = "#{k}[#{i}]: the original says #{want[k][i]}, #{whose} says #{got[k][i]}"
    break
  end
  abort("trace: #{where}: #{bad || 'the states differ'}")
end

# ---- the trace, three ways ------------------------------------------------

og = fresh_original_thinkers(cap)
omg = fresh_original_mobjs(cap)
xt = extracted_thinkers(cap)
xm = extracted_mobjs(cap)
tm = ThinkerModel.new(cap)
mm = MobjModel.new(cap)

records = []
swept = 0
freed_mobjs = 0
reused = 0
handed_out = { "tadd" => [], "malloc" => [] }
ops.each_with_index do |(kind, a, b), i|
  thinker = THINKER_KINDS.include?(kind)
  o_status, o_result = run_original(og, omg, kind, a, b)
  x_status, x_result = run_extracted(xt, xm, kind, a, b)
  m_status, m_result = run_model(tm, mm, kind, a, b)

  where = "operation #{i} (#{kind} #{a} #{b})"
  abort("trace: #{where}: statuses #{o_status}/#{x_status}/#{m_status} differ") \
    unless o_status == x_status && x_status == m_status
  abort("trace: #{where}: results #{o_result.inspect}/#{x_result.inspect}/#{m_result.inspect} differ") \
    unless o_result == x_result && x_result == m_result

  ostate = thinker ? original_thinker_state(og) : original_mobj_state(omg)
  xstate = thinker ? xt : xm
  mstate = thinker ? tm.arrays : mm.arrays
  compare(where, ostate, xstate, "the extraction")
  compare(where, ostate, mstate, "the model")
  swept += o_result if kind == "tcollect" && o_status.zero?
  freed_mobjs += 1 if kind == "mfree"
  if o_status.zero? && handed_out.key?(kind)
    reused += 1 if handed_out[kind].include?(o_result)
    handed_out[kind] << o_result
  end
  records << [i, kind, a, b, o_status, o_result, thinker, Marshal.load(Marshal.dump(ostate))]
end

# The whole point is that something happened. A trace that left the state as it
# found it would make every comparison above and below true for nothing.
final_t = original_thinker_state(og)
final_m = original_mobj_state(omg)
abort("trace: the trace allocated no thinker") if final_t[:state][1] == 1
abort("trace: the trace allocated no mobj") if final_m[:state][1].zero?
# Watched while the trace ran, not read off the end of it: a trace that frees
# slots and then allocates them all back leaves both free lists empty, and
# asking the final state would call that "nothing was ever freed".
abort("trace: the trace swept no thinker") if swept.zero?
abort("trace: the trace freed no mobj") if freed_mobjs.zero?
abort("trace: the trace reused no slot") if reused.zero?

# ---- exhaustion, at the original's own capacity ---------------------------
#
# Everything above runs at a small capacity, which the original is happy with:
# MAXTHINKERS appears in it only in the overflow guard, and the trace never
# reaches it. Exhaustion is the one place the capacities have to be the same
# number, so it gets its own run at MAXTHINKERS and MAXMOBJS.

def exhaust_thinkers(n)
  g = fresh_original_thinkers(n)
  xt = extracted_thinkers(n)
  tm = ThinkerModel.new(n)
  i = 0
  loop do
    o = run_original(g, nil, "tadd", 7, i)
    x = run_extracted(xt, nil, "tadd", 7, i)
    m = run_model(tm, nil, "tadd", 7, i)
    abort("trace: exhaustion add #{i}: #{o.inspect}/#{x.inspect}/#{m.inspect} differ") unless o == x && x == m
    break if o[0] != 0
    i += 1
  end
  [i, original_thinker_state(g), xt, tm.arrays]
end

def exhaust_mobjs(n)
  g = fresh_original_mobjs(n)
  xm = extracted_mobjs(n)
  mm = MobjModel.new(n)
  i = 0
  loop do
    o = run_original(nil, g, "malloc", 0, 0)
    x = run_extracted(nil, xm, "malloc", 0, 0)
    m = run_model(nil, mm, "malloc", 0, 0)
    abort("trace: exhaustion alloc #{i}: #{o.inspect}/#{x.inspect}/#{m.inspect} differ") unless o == x && x == m
    break if o[0] != 0
    i += 1
  end
  [i, original_mobj_state(g), xm, mm.arrays]
end

t_adds, t_final, t_x, t_m = exhaust_thinkers(exhaust)
compare("thinker exhaustion", t_final, t_x, "the extraction")
compare("thinker exhaustion", t_final, t_m, "the model")
abort("trace: thinkers exhausted after #{t_adds}, not #{exhaust - 1}") if t_adds != exhaust - 1

m_allocs, m_final, m_x, m_m = exhaust_mobjs(exhaust)
compare("mobj exhaustion", m_final, m_x, "the extraction")
compare("mobj exhaustion", m_final, m_m, "the model")
abort("trace: mobjs exhausted after #{m_allocs}, not #{exhaust}") if m_allocs != exhaust

# ---- out, for the C harness ----------------------------------------------

ints = ->(a) { a.join(" ") }
File.open(out, "w") do |io|
  io.puts("# generated by trace.rb from trace.tsv -- do not edit")
  io.puts("cap #{cap}")
  io.puts("exhaust #{exhaust} #{t_adds} #{m_allocs}")
  records.each do |i, kind, a, b, status, result, thinker, st|
    io.puts("op #{i} #{kind} #{a} #{b} #{status} #{result.nil? ? 0 : result}")
    if thinker
      io.puts("after #{i} T #{ints.call(st[:state])} #{ints.call(st[:func])} " \
              "#{ints.call(st[:data])} #{ints.call(st[:next])} #{ints.call(st[:prev])}")
    else
      io.puts("after #{i} M #{ints.call(st[:state])} #{ints.call(st[:thing_next])}")
    end
  end
  # The row's prose stays in trace.tsv. Here the status is the last field, so
  # a control that has to reach it does not have to count past anything.
  checks.each { |c| io.puts("check #{c[0, 8].join(' ')}") }
end
warn("trace: #{ops.length} operation(s) agree across the original, the extraction and the model; " \
     "#{checks.length} ABI check(s) passed through; exhaustion at #{t_adds} thinkers and #{m_allocs} mobjs")
