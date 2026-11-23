# The ported slot operations against the ORIGINAL implementation, on the same
# sequence of operations. The original is `Doom::Game`'s own list; this drives
# both and compares the live order and the reuse order after every step.
# frozen_string_literal: true
#
# tests/doom-core/slot-model.rb — the ported slot list against the original.
#
# The plan asks for the ORIGINAL implementation as the check, not a second copy
# of the pointer assignments. IT USED TO BE A COPY: `orig_add` was game.rb's
# code with `self` replaced by a hash, and the header claimed that made it
# independent. It did not -- Mac review of 33da4d9 made the same point about
# the BSP and sound models, and it applies here. The original is now
# `Doom::Game#add_thinker`, `#remove_thinker` and `#free_thinker` themselves,
# called on a real instance.
#
# What is checked is that moving the state out of `self` and into borrowed
# buffers did not move the ANSWER: the live order and the reuse order after
# every step, and the overflow behaviour at the real MAXTHINKERS boundary.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require_relative File.join(ROOT, "examples/doom/core/src/thinkers")
%w[wad level game].each { |f| require_relative File.join(ROOT, "examples/doom/lib/doom", f) }

# The real arena size. The port is given the same one, so the exhaustion edge
# is the edge the game actually has and not a small number chosen to be quick.
CAP = Doom::MAXTHINKERS

# The function code stored in every slot. `run_thinkers` is driven below to
# get the original's own unlink-and-free, and TH_NULL is a code it dispatches
# nothing for -- any of TH_MOBJ..TH_CEILING would run game logic, which is not
# what a slot-list comparison is about.
FUNC = Doom::TH_NULL
def fresh
  { "next" => Array.new(CAP, 0), "prev" => Array.new(CAP, 0),
    "func" => Array.new(CAP, TH_NULL), "data" => Array.new(CAP, -1),
    "free" => [-1], "alloc" => [1] }   # slot 0 is the head
end

# `Doom::Game` itself, with only the constructor skipped: loading a whole game
# is not what this measures, and the six arrays are what the slot list is.
Original = Class.new(Doom::Game) do
  attr_reader :th_next, :th_prev, :th_func, :th_data
  def initialize
    @th_next = Array.new(Doom::MAXTHINKERS, 0)
    @th_prev = Array.new(Doom::MAXTHINKERS, 0)
    @th_func = Array.new(Doom::MAXTHINKERS, Doom::TH_NULL)
    @th_data = Array.new(Doom::MAXTHINKERS, -1)
    @th_free = -1
    @th_alloc = 1              # slot 0 is the head
  end
end

# Overflow: the original RAISES, and the port answers CAPACITY. Both are the
# same event and neither is a slot number, so the comparison is on that rather
# than on a shared sentinel.
def orig_add(o, func, data)
  o.add_thinker(func, data)
rescue Doom::LevelError
  :capacity
end

def orig_live(o)
  a = []
  t = o.th_next[0]
  while t != 0
    a << t
    t = o.th_next[t]
  end
  a
end
def live(s)
  a = []; t = s["next"][0]
  while t != 0; a << t; t = s["next"][t]; end
  a
end

def port_add(s, func, data)
  t = dc_take_slot(s["free"], s["prev"], s["alloc"], CAP)
  return :capacity if t < 0
  # The store is CORE source now. It used to be two lines of this file, which
  # meant the model supplied a step of the algorithm it was checking.
  dc_store_thinker(s["func"], s["data"], t, func, data)
  dc_link_slot(s["next"], s["prev"], t)
  t
end

# IS THE ORIGINAL ACTUALLY BEING CALLED? The same control the BSP and sound
# models carry, for the same reason: this file used to hold a transcription
# and claim in its own header that the transcription was independent.
begin
  probe = Module.new do
    def add_thinker(*) = raise("the original was not called")
  end
  Doom::Game.prepend(probe)
  orig_add(Original.new, FUNC, 0)
  puts "reaches-original false"
rescue RuntimeError => e
  puts "reaches-original #{e.message == 'the original was not called'}"
ensure
  probe.send(:remove_method, :add_thinker)
end

o = Original.new
b = fresh
log = []
ops = []
7.times { ops << [:add] }
ops << [:remove, 3] << [:remove, 1] << [:add] << [:add] << [:add]
ops << [:remove, 5] << [:add]
k = 0
ops.each do |op, arg|
  case op
  when :add
    k += 1
    ra = orig_add(o, FUNC, 100 + k)
    rb = port_add(b, FUNC, 100 + k)
    log << ["add", ra, rb, orig_live(o).join(","), live(b).join(",")]
  when :remove
    # THE ORIGINAL'S OWN REMOVAL PATH, end to end. `remove_thinker` only
    # MARKS; the unlink and the free live inside `run_thinkers`, so that is
    # what is called -- there is no transcription of the two pointer writes
    # here any more.
    o.remove_thinker(arg)
    o.run_thinkers
    dc_mark_removed(b["func"], arg)
    dc_unlink_slot(b["next"], b["prev"], arg)
    dc_free_slot(b["func"], b["data"], b["prev"], b["free"], arg)
    log << ["rm#{arg}", 0, 0, orig_live(o).join(","), live(b).join(",")]
  end
end
bad = log.reject { |r| r[1] == r[2] && r[3] == r[4] }
puts "steps #{log.length}"
puts "disagree #{bad.length}"
log.each { |r| puts "  #{r[0]}\tslot #{r[1]}/#{r[2]}\tlive #{r[3]} | #{r[4]}" }

# THE STORE, which is the thing the migration row was missing. `th_func` and
# `th_data` must carry what was passed, in the slot that was taken -- and
# comparing the live ORDER alone would not have noticed if they did not.
store_bad = 0
(1...[o.th_func.length, CAP].min).each do |s|
  store_bad += 1 unless o.th_func[s] == b["func"][s] && o.th_data[s] == b["data"][s]
end
puts "store-disagree #{store_bad}"

# EXHAUSTION AT THE REAL BOUNDARY. The original raises LevelError; the port
# answers :capacity. CAP-1 slots are usable because slot 0 is the head.
oe = Original.new
be = fresh
first_orig = nil
first_port = nil
(CAP + 2).times do |i|
  ra = orig_add(oe, FUNC, i)
  rb = port_add(be, FUNC, i)
  first_orig ||= i if ra == :capacity
  first_port ||= i if rb == :capacity
  break if first_orig && first_port
end
puts "exhausts-at #{first_orig} #{first_port}"
puts "exhaustion-agrees #{first_orig == first_port && first_orig == CAP - 1}"

# --- the trace the native lane compares against -------------------------------
# `ruby slot-model.rb --trace` prints the ORIGINAL's slot arrays after a fixed
# sequence. tests/doom-core/state.sh runs the same sequence through a CORE
# object driven from the REAL schema -- buffer sizes and scalar slot indices
# taken from the generated registry.h -- and compares this, byte for byte.
#
# The oracle is `Doom::Game` either way. What the native lane adds is that the
# layout the C side uses is the schema's, not one invented for a fixture.
if ARGV.include?("--trace")
  tr = Original.new
  20.times { |i| tr.add_thinker(FUNC, 200 + i) }
  [3, 1, 9].each { |s| tr.remove_thinker(s); tr.run_thinkers }
  5.times { |i| tr.add_thinker(FUNC, 300 + i) }
  puts "trace-next #{(0...24).map { |i| tr.th_next[i] }.join(",")}"
  puts "trace-prev #{(0...24).map { |i| tr.th_prev[i] }.join(",")}"
  puts "trace-func #{(0...24).map { |i| tr.th_func[i] }.join(",")}"
  puts "trace-data #{(0...24).map { |i| tr.th_data[i] }.join(",")}"
  puts "trace-free #{tr.instance_variable_get(:@th_free)}"
  puts "trace-alloc #{tr.instance_variable_get(:@th_alloc)}"
end
