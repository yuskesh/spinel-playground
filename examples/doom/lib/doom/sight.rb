# doom/lib/doom/sight.rb
#
# Line of sight (`p_sight.c`). A mixin included in `Doom::Game`.
#
# **It has nothing to do with drawing**: it uses REJECT and the BSP, but only the AI uses it.
# It is still required for demos to match, for one reason: whether `P_CheckSight` is true
# changes `A_Look` / `A_Chase`'s branches and so **changes how many `P_Random` values are
# consumed** (see REJECT).
#
# `p_sight.c` has its **own** `P_DivlineSide` / `P_InterceptVector2`, different from
# `p_maputl.c`'s (they return 3 values 0/1/2, and drop the multiplication's digits differently).
# The names are alike and easy to copy wrongly, so here they carry a `sight_*` prefix.

require_relative "defs"
require_relative "info"

module Doom
  module Sight
    # `P_DivlineSide`: **3 values, 0 / 1 / 2 (on)**.
    # node is (nx, ny, ndx, ndy).
    def sight_divline_side(x, y, nx, ny, ndx, ndy)
      if ndx == 0
        return 2 if x == nx
        return x <= nx ? (ndy > 0 ? 1 : 0) : (ndy < 0 ? 1 : 0)
      end
      if ndy == 0
        # Copies vanilla's typo as it is: this is `x == node->y`
        # (not `y`), `p_sight.c:63`. Fixing it changes the answer from the reference implementation.
        return 2 if x == ny
        return y <= ny ? (ndx < 0 ? 1 : 0) : (ndx > 0 ? 1 : 0)
      end
      dx = i32(x - nx)
      dy = i32(y - ny)
      left = i32((ndy >> 16) * (dx >> 16))
      right = i32((dy >> 16) * (ndx >> 16))
      return 0 if right < left
      return 2 if left == right
      1
    end

    # `P_InterceptVector2` (strace and divl).
    def sight_intercept_vector(dx0, dy0, ddx, ddy)
      den = i32(fixed_mul(ddy >> 8, @strace_dx) - fixed_mul(ddx >> 8, @strace_dy))
      return 0 if den == 0
      num = i32(fixed_mul(i32(dx0 - @strace_x) >> 8, ddy) +
                fixed_mul(i32(@strace_y - dy0) >> 8, ddx))
      fixed_div(num, den)
    end

    # `P_CrossSubsector`
    def cross_subsector(num)
      lv = @level
      count = lv.ss_numlines[num]
      seg = lv.ss_firstline[num]
      k = 0
      while k < count
        s = seg + k
        k += 1
        line = lv.seg_linedef[s]
        next if lv.line_validcount[line] == @validcount
        lv.line_validcount[line] = @validcount
        v1 = lv.line_v1[line]
        v2 = lv.line_v2[line]
        v1x = lv.vertex_x[v1]
        v1y = lv.vertex_y[v1]
        v2x = lv.vertex_x[v2]
        v2y = lv.vertex_y[v2]
        s1 = sight_divline_side(v1x, v1y, @strace_x, @strace_y, @strace_dx, @strace_dy)
        s2 = sight_divline_side(v2x, v2y, @strace_x, @strace_y, @strace_dx, @strace_dy)
        next if s1 == s2
        dlx = v1x
        dly = v1y
        dldx = i32(v2x - v1x)
        dldy = i32(v2y - v1y)
        s1 = sight_divline_side(@strace_x, @strace_y, dlx, dly, dldx, dldy)
        s2 = sight_divline_side(@t2x, @t2y, dlx, dly, dldx, dldy)
        next if s1 == s2
        return false if lv.line_backsector[line] < 0
        return false if (lv.line_flags[line] & ML_TWOSIDED) == 0
        front = lv.seg_frontsector[s]
        back = lv.seg_backsector[s]
        ff = lv.sector_floorheight[front]
        bf = lv.sector_floorheight[back]
        fc = lv.sector_ceilingheight[front]
        bc = lv.sector_ceilingheight[back]
        next if ff == bf && fc == bc
        opentop = fc < bc ? fc : bc
        openbottom = ff > bf ? ff : bf
        return false if openbottom >= opentop
        frac = sight_intercept_vector(dlx, dly, dldx, dldy)
        if ff != bf
          slope = fixed_div(i32(openbottom - @sightzstart), frac)
          @bottomslope = slope if slope > @bottomslope
        end
        if fc != bc
          slope = fixed_div(i32(opentop - @sightzstart), frac)
          @topslope = slope if slope < @topslope
        end
        return false if @topslope <= @bottomslope
      end
      true
    end

    # `P_CrossBSPNode`: recursive.
    def cross_bsp_node(bspnum)
      lv = @level
      if (bspnum & 0x8000) != 0
        return cross_subsector(0) if bspnum == -1
        return cross_subsector(bspnum & 0x7fff)
      end
      side = sight_divline_side(@strace_x, @strace_y,
                                lv.node_x[bspnum], lv.node_y[bspnum],
                                lv.node_dx[bspnum], lv.node_dy[bspnum])
      side = 0 if side == 2
      child = side == 0 ? lv.node_child0[bspnum] : lv.node_child1[bspnum]
      return false unless cross_bsp_node(child)
      other = sight_divline_side(@t2x, @t2y,
                                 lv.node_x[bspnum], lv.node_y[bspnum],
                                 lv.node_dx[bspnum], lv.node_dy[bspnum])
      return true if side == other
      other_child = side == 0 ? lv.node_child1[bspnum] : lv.node_child0[bspnum]
      cross_bsp_node(other_child)
    end

    # `P_CheckSight`: trivial rejection by REJECT before the rest.
    def check_sight(t1, t2)
      lv = @level
      s1 = @mobj_sector[t1]
      s2 = @mobj_sector[t2]
      pnum = s1 * lv.num_sectors + s2
      return false if (lv.reject.getbyte(pnum >> 3) & (1 << (pnum & 7))) != 0

      @validcount += 1
      @sightzstart = i32(@mobj_z[t1] + @mobj_height[t1] - (@mobj_height[t1] >> 2))
      @topslope = i32(@mobj_z[t2] + @mobj_height[t2] - @sightzstart)
      @bottomslope = i32(@mobj_z[t2] - @sightzstart)
      @strace_x = @mobj_x[t1]
      @strace_y = @mobj_y[t1]
      @t2x = @mobj_x[t2]
      @t2y = @mobj_y[t2]
      @strace_dx = i32(@mobj_x[t2] - @mobj_x[t1])
      @strace_dy = i32(@mobj_y[t2] - @mobj_y[t1])
      cross_bsp_node(lv.num_nodes - 1)
    end
  end
end
