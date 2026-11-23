# spinel: int64
# examples/doom/core/src/bspwalk.rb — the BSP traversal, without recursion.
#
# GPL-derived, from `examples/doom/lib/doom/sight.rb` (`Doom::Sight`), itself
# derived from doomgeneric's `p_sight.c`. See ../NOTICE.md and ../sources.tsv.
#
# CORE refuses recursion, so the two BSP walks become an explicit stack. 0008:
# "A traversal frame contains its node, continuation and required local
# values", and "Preserve front/back visitation and the point at which
# post-child tests execute; reversing a push order can change the image even
# when all nodes are visited."
#
# THE FRAME IS (node, phase, side). The original is not a plain walk -- it is
# a SHORT-CIRCUITING one with work after the first child:
#
#     return false unless cross_bsp_node(near)
#     return true if side == other_side
#     cross_bsp_node(far)
#
# so a frame has to remember, when its near child answers, which node it was
# and which side it took. `phase` is that continuation: 0 means "descend to
# the near child", 1 means "the near child answered true; now decide the far
# one". Collapsing the two into one visit per node would drop the test between
# them, which is exactly the post-child test 0008 says to preserve.
#
# THE BOUND IS THE TREE'S DEPTH, not a step quota. The BSP tree is finite and
# acyclic -- every child index is a strictly smaller subtree or a leaf, and
# the node count comes from the map lump -- so the descent terminates.
#
# THE NODE COUNT ALONE IS NOT A SUFFICIENT STACK SIZE, and an earlier version
# of this comment said it was. LEAVES ARE PUSHED TOO: measured on a valid
# one-node tree (children 32768 and 32769), a stack of 1 answers CAPACITY on
# the second push. The bound is the deepest root-to-leaf path, which is at
# most one frame per node plus one for the leaf -- `num_nodes + 1`. The tests
# pass `num_nodes + 8`, which is slack around that bound and not a derivation
# of it; the one-node case is what made the difference visible, because on
# E1M1's 236 nodes the slack hid it.
#
# Exhaustion is CAPACITY and is reported, not truncated: a truncated traversal
# answers a sight question nobody asked.

SUBSECTOR_BIT = 0x8000
PHASE_NEAR = 0
PHASE_FAR = 1

# Push a frame. Answers 1 on success and 0 when the stack is full, so the
# caller reports CAPACITY rather than this deciding what a full stack means.
def dc_bsp_push(stk_node, stk_phase, stk_side, sp, cap, node, phase, side)
  n = sp[0]
  if n >= cap
    0
  else
    stk_node[n] = node
    stk_phase[n] = phase
    stk_side[n] = side
    sp[0] = n + 1
    1
  end
end

# The near child of a node, given the side the trace start falls on.
def dc_bsp_near(node_child0, node_child1, bspnum, side)
  side == 0 ? node_child0[bspnum] : node_child1[bspnum]
end

# The far child: the other one.
def dc_bsp_far(node_child0, node_child1, bspnum, side)
  side == 0 ? node_child1[bspnum] : node_child0[bspnum]
end

# Whether a child index names a subsector rather than a node.
def dc_bsp_is_leaf(child)
  (child & SUBSECTOR_BIT) != 0 ? 1 : 0
end

# The subsector a leaf index names. -1 is the whole-map leaf, which vanilla
# spells as subsector 0.
def dc_bsp_leaf_index(child)
  child == -1 ? 0 : (child & 0x7fff)
end

# `P_DivlineSide` as `p_sight.c` spells it. THIS BELONGS IN THE CORE SOURCE,
# not in a test: the traversal's answer is this predicate's answer, and a
# comparison whose two sides share one hand-written copy of it compares
# nothing. Mac review of 33da4d9 found exactly that -- both sides of
# tests/doom-core/bsp-model.rb called a transcription that had dropped three
# things this has:
#
#   * ON THE LINE IS 2, not 0 or 1. `x == nx` on a vertical divider (and the
#     horizontal case below) answers "on the line", and the caller folds 2
#     into 0 for the near child but compares the UNFOLDED value for the far
#     one -- so dropping it changes which children are visited, not just a
#     tie-break. Measured on a one-node level (node 0,0,0,65536, children
#     32768/32769, start -65536,0, end 0,0): the original answers false over
#     visits [0, 32769, 32768]; without the 2 it answers true over [0, 32769].
#
#   * THE HORIZONTAL CASE COMPARES `x` AGAINST `ny`. That is vanilla's typo at
#     `p_sight.c:63` and it is transcribed, not corrected: correcting it makes
#     this disagree with the reference implementation.
#
#   * EVERY INTERMEDIATE IS AN i32. `fixed_t` is 32 bits and the subtraction
#     and the products wrap; computing them in Ruby's unbounded integers gives
#     a different sign on the far side of the wrap.
def dc_sight_side(x, y, nx, ny, ndx, ndy)
  if ndx == 0
    return 2 if x == nx
    return ndy > 0 ? 1 : 0 if x <= nx
    return ndy < 0 ? 1 : 0
  end
  if ndy == 0
    # vanilla's typo, transcribed: `x` against the node's `y`.
    return 2 if x == ny
    return ndx < 0 ? 1 : 0 if y <= ny
    return ndx > 0 ? 1 : 0
  end
  dx = fixed_to_i32(x - nx)
  dy = fixed_to_i32(y - ny)
  left = fixed_to_i32((ndy >> 16) * (dx >> 16))
  right = fixed_to_i32((dy >> 16) * (ndx >> 16))
  return 0 if right < left
  return 2 if left == right
  1
end

# `R_PointOnSide` as `r_main.c` spells it, from
# `examples/doom/lib/doom/level.rb` (`Doom::Level#point_on_side`).
#
# THIS IS NOT `dc_sight_side`, and the two must not be folded together even
# though both answer "which side of node n". They differ in ways that change
# the answer:
#
#   * NO ON-THE-LINE ANSWER. This returns 0 or 1 and never 2. The renderer's
#     descent has no use for "on the line" -- it takes a side and goes.
#   * NO `x == ny` TYPO. The horizontal case here compares `y` against the
#     node's `y`, which is what `r_main.c` does; `p_sight.c` compares `x`, and
#     that difference is transcribed in `dc_sight_side` deliberately.
#   * A SIGN FAST PATH. When an odd number of the four values is negative the
#     answer follows from the signs alone, before any multiply. Vanilla has it
#     and it is kept, because on the wrap boundary the product path and this
#     path do not always agree.
#
# The two live side by side, named for the file each came from.
def dc_point_on_side(node_x, node_y, node_dx, node_dy, x, y, n)
  ndx = node_dx[n]
  ndy = node_dy[n]
  if ndx == 0
    return ndy > 0 ? 1 : 0 if x <= node_x[n]
    return ndy < 0 ? 1 : 0
  end
  if ndy == 0
    return ndx < 0 ? 1 : 0 if y <= node_y[n]
    return ndx > 0 ? 1 : 0
  end
  dx = fixed_to_i32(x - node_x[n])
  dy = fixed_to_i32(y - node_y[n])
  neg = 0
  neg = neg + 1 if ndy < 0
  neg = neg + 1 if ndx < 0
  neg = neg + 1 if dx < 0
  neg = neg + 1 if dy < 0
  if (neg & 1) == 1
    return (ndy < 0) != (dx < 0) ? 1 : 0
  end
  left = fixed_to_i32(((ndy >> 16) * dx) >> 16)
  right = fixed_to_i32((dy * (ndx >> 16)) >> 16)
  right < left ? 0 : 1
end

# ---------------------------------------------------------------------------
# Sound propagation, also without recursion.
#
# GPL-derived, from `examples/doom/lib/doom/enemy.rb` (`Doom::Enemy`), from
# doomgeneric's `P_RecursiveSound`.
#
# THE FRAME IS (sector, soundblocks, line index). The original recurses from
# INSIDE a loop over the sector's lines and continues that loop when the call
# returns, so a frame has to remember where the loop was. A stack of sectors
# alone would restart each loop from zero and visit lines twice.
#
# THE BOUND IS THE VISITED RULE, not a step quota. A sector is entered only
# when its validcount is not the current one OR the sound reaches it through
# fewer blocks than before, and each entry sets both -- so the walk terminates
# for the same reason vanilla's does, and the stack is sized from the sector
# count.
SOUND_PHASE_ENTER = 0
SOUND_PHASE_LINES = 1

# Whether this sector should be entered at all, given how the sound arrived.
# The two halves of vanilla's early return, kept together so the rule is in
# one place: already seen this alert AND not reached more cheaply.
def dc_sound_skip(sector_validcount, sector_soundtraversed, sec, validcount, soundblocks)
  if sector_validcount[sec] == validcount && sector_soundtraversed[sec] <= soundblocks + 1
    1
  else
    0
  end
end

# Mark a sector as reached. Both marks are set together, because the skip test
# reads both and setting one without the other would let a sector be entered
# again at the same cost.
def dc_sound_mark(sector_validcount, sector_soundtraversed, sector_soundtarget,
                  sec, validcount, soundblocks, target)
  sector_validcount[sec] = validcount
  sector_soundtraversed[sec] = soundblocks + 1
  sector_soundtarget[sec] = target
  sec
end

# The sector on the other side of a two-sided line.
def dc_sound_other(side_sector, line_side0, line_side1, check, sec)
  s0 = side_sector[line_side0[check]]
  s0 == sec ? side_sector[line_side1[check]] : s0
end
