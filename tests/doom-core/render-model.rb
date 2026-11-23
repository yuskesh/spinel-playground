# frozen_string_literal: true
#
# tests/doom-core/render-model.rb — the renderer's BSP descent, without recursion.
#
#   ruby tests/doom-core/render-model.rb WAD [MAP]
#
# THE ORIGINAL IS `Doom::Renderer#render_bsp_node` ITSELF. Mac review of
# 33da4d9 noted that this walk was "neither implemented nor compared" -- the
# sight walk had a model and this one had nothing at all. It has one now.
#
# WHAT IS COMPARED: the visit order and the subsectors reached. `render_bsp_node`
# differs from `cross_bsp_node` in two ways, and both matter here --
#
#   * the side comes from `R_PointOnSide`, not `P_DivlineSide`. They are
#     different predicates (no on-the-line answer, no `x == ny` typo, and a
#     sign fast path), so the port calls `dc_point_on_side` and not
#     `dc_sight_side`.
#   * the far child is gated by `check_bbox`, not by comparing two sides.
#
# WHAT IS NOT COMPARED: `check_bbox` itself. It needs `point_to_angle`, the
# `viewangletox` table and the solidsegs clip list -- a rendering subsystem,
# not a helper -- so it is NOT PORTED, and both sides here call the same
# controlled gate instead. That makes this a comparison of the TRAVERSAL
# around the gate, which is what the frame shape depends on; the gate is
# recorded as outstanding in docs/core/doom-closure-gaps.md rather than
# quietly folded in.
ROOT = File.expand_path("../..", __dir__)
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
require_relative File.join(ROOT, "examples/doom/core/src/fixed")
require_relative File.join(ROOT, "examples/doom/core/src/bspwalk")
%w[wad level render].each { |f| require_relative File.join(ROOT, "examples/doom/lib/doom", f) }

# The original name, kept so a control can invert the real answer.
alias dc_point_on_side_orig dc_point_on_side

wad = Doom::Wad.new(ARGV[0])
lv = Doom::Level.new(wad, ARGV[1] || "E1M1", 1)

# The gate, deterministic and shared. Not the thing under test.
def gate?(n, child, seed)
  (((n * 2_654_435_761) ^ (child * 40_503) ^ seed) >> 5) % 4 != 0
end

# The original's own descent, with only the leaf and the gate controlled.
Original = Class.new(Doom::Renderer) do
  attr_reader :visits, :leaves
  def initialize(lv, vx, vy, seed)
    @level = lv
    @viewx = vx
    @viewy = vy
    @seed = seed
    @visits = []
    @leaves = []
  end
  def render_bsp_node(bspnum)
    @visits << bspnum
    super
  end
  def subsector(ss) = @leaves << ss
  def check_bbox(n, child) = gate?(n, child, @seed)
end

def ported(lv, root, vx, vy, seed, cap)
  visits = []
  leaves = []
  stk_node = Array.new(cap, 0)
  stk_phase = Array.new(cap, 0)
  stk_side = Array.new(cap, 0)
  sp = [0]
  return [:capacity, visits, leaves] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
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
        leaves << dc_bsp_leaf_index(node)
        next
      end
      side = dc_point_on_side(lv.node_x, lv.node_y, lv.node_dx, lv.node_dy, vx, vy, node)
      stk_phase[n] = PHASE_FAR
      stk_side[n] = side
      near = dc_bsp_near(lv.node_child0, lv.node_child1, node, side)
      return [:capacity, visits, leaves] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
                                                        near, PHASE_NEAR, 0).zero?
    else
      # The gate runs where the original runs it: after the near child is
      # finished and before the far one is considered.
      sp[0] = n
      other = side ^ 1
      next unless gate?(node, other, seed)
      far = dc_bsp_far(lv.node_child0, lv.node_child1, node, side)
      return [:capacity, visits, leaves] if dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap,
                                                        far, PHASE_NEAR, 0).zero?
    end
  end
  [:ok, visits, leaves]
end

# Is the original actually being called? The same control the other models
# carry, for the same reason.
begin
  probe = Module.new do
    def render_bsp_node(*) = raise("the original was not called")
  end
  Doom::Renderer.prepend(probe)
  Original.new(lv, 0, 0, 1).render_bsp_node(lv.num_nodes - 1)
  puts "reaches-original false"
rescue RuntimeError => e
  puts "reaches-original #{e.message == 'the original was not called'}"
ensure
  probe.send(:remove_method, :render_bsp_node)
end

root = lv.num_nodes - 1
cap = lv.num_nodes + 8
agree = 0
differ = []
srand(7)
400.times do
  vx = rand(-4096..4096) << 16
  vy = rand(-4096..4096) << 16
  seed = rand(1 << 20)
  o = Original.new(lv, vx, vy, seed)
  o.render_bsp_node(root)
  r, pv, pl = ported(lv, root, vx, vy, seed, cap)
  if r == :ok && o.visits == pv && o.leaves == pl
    agree += 1
  else
    differ << [r, o.visits.length, pv.length, o.leaves.length, pl.length]
  end
end
puts "nodes #{lv.num_nodes}"
puts "views 400"
puts "agree #{agree}"
puts "differ #{differ.length}"
differ.first(3).each { |r, ov, pv, ol, pl| puts "  #{r} visits #{ov}/#{pv} leaves #{ol}/#{pl}" }

# IS THE COMPARISON LIVE? An inverted predicate must change the walk. Without
# this the measurement below would be indistinguishable from a dead harness.
def walk_differs(lv, root, cap, n, &swap)
  m = Module.new(&swap)
  saved = []
  srand(7)
  n.times do
    vx = rand(-4096..4096) << 16
    vy = rand(-4096..4096) << 16
    seed = rand(1 << 20)
    o = Original.new(lv, vx, vy, seed)
    o.render_bsp_node(root)
    saved << [vx, vy, seed, o.visits]
  end
  self.singleton_class.prepend(m)
  saved.count { |vx, vy, seed, ov| _, pv, = ported(lv, root, vx, vy, seed, cap); ov != pv }
end

inverted = walk_differs(lv, root, cap, 40) do
  define_method(:dc_point_on_side) { |nx, ny, ndx, ndy, x, y, n| 1 - dc_point_on_side_orig(nx, ny, ndx, ndy, x, y, n) }
end
puts "inverted-predicate-differs #{inverted}"

# AND A MEASUREMENT, not a claim. `dc_sight_side` and `dc_point_on_side` are
# different functions -- no on-the-line answer here, no `x == ny` typo, a sign
# fast path -- but whether that difference is OBSERVABLE in this walk is a
# question about the map, not about the definitions. Measured on E1M1 over
# these views, folding the sight predicate in (its 2 taken as 0) gives the
# SAME walk every time. So this number is reported rather than asserted: it
# says the difference does not show here, not that there is none.
folded = walk_differs(lv, root, cap, 40) do
  define_method(:dc_point_on_side) do |nx, ny, ndx, ndy, x, y, n|
    s = dc_sight_side(x, y, nx[n], ny[n], ndx[n], ndy[n])
    s == 2 ? 0 : s
  end
end
puts "folded-sight-differs #{folded}"

tiny, = ported(lv, root, 0, 0, 0, 2)
puts "capacity #{tiny}"
