# frozen_string_literal: true
#
# tests/doom-core/bsp-model.rb — the explicit BSP walk against the recursion.
#
#   ruby tests/doom-core/bsp-model.rb WAD
#
# THE ORIGINAL IS `Doom::Sight#cross_bsp_node` ITSELF -- the method in
# examples/doom/lib/doom/sight.rb, called here, not transcribed.
#
# It used to be a transcription, and Mac review of 33da4d9 showed what that
# was worth: both sides called ONE hand-written `side_of` that had dropped the
# on-the-line answer, vanilla's `x == ny` typo, and every i32 wrap. "400/400
# agree" was two routines sharing one wrong predicate. Agreement between two
# outputs from one generator is not an oracle (AGENTS.md), and that is what it
# had become.
#
# Only the LEAF is controlled. `cross_subsector` does the real line-clipping
# work, which is not what this compares, so it is overridden on both sides
# with the same deterministic predicate -- the short circuit then fires on a
# known schedule. Everything above the leaf is the original's own code.
#
# The PORT drives the same traversal from an explicit stack and calls
# `dc_sight_side`, which is CORE SOURCE in examples/doom/core/src/bspwalk.rb.
# Two predicates, two traversals, one comparison.
#
# What is compared is not only the ANSWER but the VISIT ORDER: 0008 says
# reversing a push order can change the image even when all nodes are visited,
# so an answer that agrees while the order does not would be agreeing by
# accident on this map and not on the next one.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require_relative File.join(ROOT, "examples/doom/core/src/fixed")
require_relative File.join(ROOT, "examples/doom/core/src/bspwalk")
%w[wad level game].each { |f| require_relative File.join(ROOT, "examples/doom/lib/doom", f) }

wad = Doom::Wad.new(ARGV[0])
lv = Doom::Level.new(wad, ARGV[1] || "E1M1", 1)

# Which subsectors answer false. Chosen from the trace so both sides see the
# same rule and the short circuit actually fires.
def blocked?(ss, seed)
  ((ss * 2_654_435_761) ^ seed) % 7 == 0
end

# The original's own `cross_bsp_node`, with the leaf controlled and the visit
# order recorded. Nothing of the traversal is rewritten here.
# A SUBCLASS OF THE REAL `Doom::Game`, because `Doom::Sight` is a module that
# production includes into that class and leans on its helpers -- `i32` above
# all. Retyping `i32` here would be the same mistake one level down: the
# transcription that started this. `initialize` is overridden rather than
# called because loading a whole game is not what this measures; the four
# ivars `cross_bsp_node` reads are set directly.
Original = Class.new(Doom::Game) do
  def initialize(lv, sx, sy, tx, ty, seed, visits)
    @level = lv
    @strace_x = sx
    @strace_y = sy
    @t2x = tx
    @t2y = ty
    @seed = seed
    @visits = visits
  end
  def cross_bsp_node(bspnum)
    @visits << bspnum
    super
  end
  def cross_subsector(ss)
    !blocked?(ss, @seed)
  end
end

def orig(lv, bspnum, sx, sy, tx, ty, seed, visits)
  Original.new(lv, sx, sy, tx, ty, seed, visits).cross_bsp_node(bspnum)
end

def ported(lv, root, sx, sy, tx, ty, seed, visits, cap)
  stk_node = Array.new(cap, 0)
  stk_phase = Array.new(cap, 0)
  stk_side = Array.new(cap, 0)
  sp = [0]
  answer = true
  return [:capacity, visits] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
                                            root, PHASE_NEAR, 0).zero?
  until sp[0].zero?
    n = sp[0] - 1
    node = stk_node[n]
    phase = stk_phase[n]
    side = stk_side[n]
    if phase == PHASE_NEAR
      visits << node
      if dc_bsp_is_leaf(node) == 1
        sp[0] = n
        unless (answer = !blocked?(dc_bsp_leaf_index(node), seed))
          # The short circuit: a false leaf ends the whole traversal, which is
          # what `return false unless ...` does in the original.
          return [false, visits]
        end
        next
      end
      side = dc_sight_side(sx, sy, lv.node_x[node], lv.node_y[node],
                     lv.node_dx[node], lv.node_dy[node])
      side = 0 if side == 2
      stk_phase[n] = PHASE_FAR
      stk_side[n] = side
      near = dc_bsp_near(lv.node_child0, lv.node_child1, node, side)
      return [:capacity, visits] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
                                                near, PHASE_NEAR, 0).zero?
    else
      # The post-child test, at the point the original runs it: after the near
      # child answered true and before the far one is considered.
      sp[0] = n
      other = dc_sight_side(tx, ty, lv.node_x[node], lv.node_y[node],
                      lv.node_dx[node], lv.node_dy[node])
      next if side == other
      far = dc_bsp_far(lv.node_child0, lv.node_child1, node, side)
      return [:capacity, visits] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
                                                far, PHASE_NEAR, 0).zero?
    end
  end
  [answer, visits]
end

# IS THE ORIGINAL ACTUALLY BEING CALLED? Mac review of 33da4d9 found the sound
# model's "original" was a copy, and proved it by injecting a raise into the
# real method and watching the output not move. That injection is the control,
# so it lives here rather than being something a reviewer has to think to do.
begin
  probe = Module.new do
    def sight_divline_side(*) = raise("the original was not called")
  end
  Doom::Game.prepend(probe)
  orig(lv, lv.num_nodes - 1, 0, 0, 1 << 16, 1 << 16, 0, [])
  puts "reaches-original false"
rescue RuntimeError => e
  puts "reaches-original #{e.message == 'the original was not called'}"
ensure
  probe.send(:remove_method, :sight_divline_side)
end

root = lv.num_nodes - 1
cap = lv.num_nodes + 8
agree = 0
differ = []
pairs = 0
srand(1)
400.times do
  sx = rand(-4096..4096) << 16
  sy = rand(-4096..4096) << 16
  tx = rand(-4096..4096) << 16
  ty = rand(-4096..4096) << 16
  seed = rand(1 << 20)
  pairs += 1
  ov = []
  oa = orig(lv, root, sx, sy, tx, ty, seed, ov)
  pv = []
  pa, = ported(lv, root, sx, sy, tx, ty, seed, pv, cap)
  if oa == pa && ov == pv
    agree += 1
  else
    differ << [oa, pa, ov.length, pv.length]
  end
end
puts "nodes #{lv.num_nodes}"
puts "pairs #{pairs}"
puts "agree #{agree}"
puts "differ #{differ.length}"
differ.first(3).each { |o, p, ol, pl| puts "  answer #{o}/#{p} visits #{ol}/#{pl}" }
# ---------------------------------------------------------------------------
# THE ON-THE-LINE CASE, which 400 random pairs never reach: it needs an exact
# coordinate equality. This is the one-node level from the Mac review of
# 33da4d9, and it is the case the old hand-written predicate got wrong.
#
# node 0 is (0,0) with direction (0, 65536) -- vertical -- and its children are
# the leaves 32768 and 32769. The start is left of it, so `side` is 1. The END
# point sits exactly ON it, so `other` is 2, which is not 1, so the far child
# is visited too. A predicate without the on-the-line answer says `other` is 1,
# finds side == other, and stops early with the opposite answer.
One = Struct.new(:node_x, :node_y, :node_dx, :node_dy,
                 :node_child0, :node_child1, :num_nodes)
one = One.new([0], [0], [0], [65536], [32768], [32769], 1)
ov = []
oa = orig(one, 0, -65536, 0, 0, 0, 0, ov)
pv = []
pa, = ported(one, 0, -65536, 0, 0, 0, 0, pv, 8)
puts "online-original #{oa} #{ov.inspect}"
puts "online-ported #{pa} #{pv.inspect}"
puts "online-agree #{oa == pa && ov == pv}"
puts "online-side #{dc_sight_side(-65536, 0, 0, 0, 0, 65536)} " \
     "#{dc_sight_side(0, 0, 0, 0, 0, 65536)}"

# Exhaustion is CAPACITY and is reported, not truncated.
tiny, = ported(lv, root, 0, 0, 1 << 16, 1 << 16, 0, [], 2)
puts "capacity #{tiny}"

# THE CONTROL. Fold the on-the-line answer away -- what the transcription did
# -- and the same case must disagree. Without this, "online-agree true" would
# only mean the two happen to match, not that the 2 is doing anything.
module Folded
  def dc_sight_side(x, y, nx, ny, ndx, ndy)
    s = super
    s == 2 ? (x <= nx ? 1 : 0) : s
  end
end
self.singleton_class.prepend(Folded)
fv = []
fa, = ported(one, 0, -65536, 0, 0, 0, 0, fv, 8)
puts "folded-ported #{fa} #{fv.inspect}"
puts "folded-differs #{!(oa == fa && ov == fv)}"
# The prepend stays in place; nothing below it reads the predicate.

