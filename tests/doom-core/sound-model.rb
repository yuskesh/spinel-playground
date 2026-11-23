# frozen_string_literal: true
#
# tests/doom-core/sound-model.rb — sound propagation without recursion.
#
#   ruby tests/doom-core/sound-model.rb WAD [MAP]
#
# THE ORIGINAL IS `Doom::Enemy#recursive_sound` ITSELF -- the method in
# examples/doom/lib/doom/enemy.rb, called here, not transcribed.
#
# It used to be a copy, and Mac review of 33da4d9 proved what that was worth
# by injecting a `raise` into the real method and watching this file's output
# not move at all. Worse, BOTH sides called the production `dc_sound_other`,
# so corrupting that helper moved the two together and 60/60 still agreed.
# Agreement between two outputs from one generator is not an oracle
# (AGENTS.md), and that is what this had become.
#
# The PORT is the same walk driven by a stack of (sector, soundblocks, line
# index) frames -- the line index because the original recurses from inside
# the loop and continues it when the call returns -- and it reaches the other
# side of a line through `dc_sound_other`, which is CORE source. The original
# computes that inline, as vanilla does, so corrupting the CORE helper now
# moves one side only.
#
# WHAT IS NOT COMPARED: openness. `line_opening` is not ported yet, so it is
# an INPUT here, taken once from the original before the walk and read by both
# sides. Corrupting it moves both, and this file cannot see that; it is
# recorded in docs/core/doom-closure-gaps.md rather than left implicit.
#
# Compared: the visit order, and the two marked arrays afterwards. The marks
# are what the game reads; the order is what decides which sector marks first
# when two paths reach it, so comparing only the marks would miss a reordering
# that happens to end in the same place on this map.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require_relative File.join(ROOT, "examples/doom/core/src/bspwalk")
%w[wad level game].each { |f| require_relative File.join(ROOT, "examples/doom/lib/doom", f) }

ML_TWOSIDED = 4
ML_SOUNDBLOCK = 64

wad = Doom::Wad.new(ARGV[0])
lv = Doom::Level.new(wad, ARGV[1] || "E1M1", 1)

# A SUBCLASS OF THE REAL `Doom::Game`: `Doom::Enemy` is a module production
# includes there, and `recursive_sound` calls `line_opening`, which lives in
# `Doom::MapMove` on the same class. Retyping either would be the mistake this
# change exists to undo. `initialize` is overridden rather than called because
# loading a whole game is not what this measures.
Original = Class.new(Doom::Game) do
  attr_reader :visits
  def initialize(lv, st, vc, target)
    @level = lv
    @validcount = vc
    @soundtarget = target
    @sector_soundtraversed = st["trav"]
    @sector_soundtarget = st["target"]
    @visits = []
  end
  def recursive_sound(sec, soundblocks)
    before = @level.sector_validcount[sec] == @validcount &&
             @sector_soundtraversed[sec] <= soundblocks + 1
    @visits << sec unless before
    super
  end
end

def orig(lv, sec, blocks, st, vc, target, visits)
  o = Original.new(lv, st, vc, target)
  o.recursive_sound(sec, blocks)
  visits.concat(o.visits)
end

# Openness as the ORIGINAL computes it, sampled once per line before any walk.
# It is an input to both sides, not a thing under comparison -- see the header.
def openness(lv)
  probe = Original.new(lv, { "trav" => [], "target" => [] }, 0, 0)
  Array.new(lv.num_lines) do |ld|
    probe.send(:line_opening, ld)
    probe.instance_variable_get(:@openrange) > 0
  end
end

def ported(lv, sec0, st, vc, target, visits, cap)
  fs = Array.new(cap, 0); fb = Array.new(cap, 0); fi = Array.new(cap, 0)
  sp = [0]
  push = lambda do |s, b, i|
    return false if sp[0] >= cap
    fs[sp[0]] = s; fb[sp[0]] = b; fi[sp[0]] = i
    sp[0] += 1
    true
  end
  return :capacity unless push.call(sec0, 0, -1)
  until sp[0].zero?
    n = sp[0] - 1
    sec = fs[n]; blocks = fb[n]; i = fi[n]
    if i < 0
      # Entering: the skip test and the marks, in vanilla's order.
      if dc_sound_skip(lv.sector_validcount, st["trav"], sec, vc, blocks) == 1
        sp[0] = n
        next
      end
      visits << sec
      dc_sound_mark(lv.sector_validcount, st["trav"], st["target"], sec, vc, blocks, target)
      fi[n] = 0
      next
    end
    c = lv.sector_linecount[sec]
    if i >= c
      sp[0] = n
      next
    end
    check = lv.sector_lines[lv.sector_lineofs[sec] + i]
    fi[n] = i + 1
    next if (lv.line_flags[check] & ML_TWOSIDED).zero?
    next unless OPEN[check]
    other = dc_sound_other(lv.side_sector, lv.line_side0, lv.line_side1, check, sec)
    if (lv.line_flags[check] & ML_SOUNDBLOCK) != 0
      next unless blocks.zero?
      return :capacity unless push.call(other, 1, -1)
    else
      return :capacity unless push.call(other, blocks, -1)
    end
  end
  :ok
end

OPEN = openness(lv)

# IS THE ORIGINAL ACTUALLY BEING CALLED? This is the injection Mac review used
# to show that it was not: a raise in the real method, which the old copy sat
# straight past. It is a standing control now rather than something a reviewer
# has to think to do.
begin
  probe = Module.new do
    def recursive_sound(*) = raise("the original was not called")
  end
  Doom::Game.prepend(probe)
  orig(lv, 0, 0, { "trav" => Array.new(lv.num_sectors, 0),
                   "target" => Array.new(lv.num_sectors, -1) }, 1, 7, [])
  puts "reaches-original false"
rescue RuntimeError => e
  puts "reaches-original #{e.message == 'the original was not called'}"
ensure
  probe.send(:remove_method, :recursive_sound)
end

n = lv.num_sectors
agree = 0
differ = []
srand(3)
60.times do |k|
  start = rand(n)
  target = 1000 + k
  a = { "trav" => Array.new(n, 0), "target" => Array.new(n, -1) }
  lv.num_sectors.times { |s| lv.sector_validcount[s] = 0 }
  av = []
  orig(lv, start, 0, a, k + 1, target, av)
  b = { "trav" => Array.new(n, 0), "target" => Array.new(n, -1) }
  lv.num_sectors.times { |s| lv.sector_validcount[s] = 0 }
  bv = []
  r = ported(lv, start, b, k + 1, target, bv, n + 8)
  if r == :ok && av == bv && a["trav"] == b["trav"] && a["target"] == b["target"]
    agree += 1
  else
    differ << [start, r, av.length, bv.length]
  end
end
puts "sectors #{n}"
puts "alerts 60"
puts "agree #{agree}"
puts "differ #{differ.length}"
differ.first(3).each { |s, r, al, bl| puts "  from #{s} #{r} visits #{al}/#{bl}" }
tiny = ported(lv, 0, { "trav" => Array.new(n, 0), "target" => Array.new(n, -1) },
              99, 0, [], 2)
puts "capacity #{tiny}"

# THE OTHER INJECTION FROM THE SAME REVIEW: corrupt the CORE helper that finds
# the far side of a line. It used to be called by BOTH sides, so breaking it
# moved them together and 60/60 stood. The original now computes that inline,
# as vanilla does, so this must show up. It runs last because the prepend
# stays in place.
module BrokenOther
  def dc_sound_other(side_sector, line_side0, line_side1, check, sec)
    s0 = side_sector[line_side0[check]]
    s0 == sec ? side_sector[line_side1[check]] : 0
  end
end
self.singleton_class.prepend(BrokenOther)
caught = 0
60.times do |k|
  start = rand(n)
  a = { "trav" => Array.new(n, 0), "target" => Array.new(n, -1) }
  lv.num_sectors.times { |s| lv.sector_validcount[s] = 0 }
  av = []
  orig(lv, start, 0, a, k + 1, 2000 + k, av)
  b = { "trav" => Array.new(n, 0), "target" => Array.new(n, -1) }
  lv.num_sectors.times { |s| lv.sector_validcount[s] = 0 }
  bv = []
  r = ported(lv, start, b, k + 1, 2000 + k, bv, n + 8)
  caught += 1 unless r == :ok && av == bv && a["trav"] == b["trav"] && a["target"] == b["target"]
end
puts "broken-other-caught #{caught}"
