# doom/lib/doom/mapmove.rb
#
# Movement and collision (`p_maputl.c` + `p_map.c`). A mixin included in `Doom::Game`.
#
# Vanilla writes this with **global variables + function pointers**:
# `tmbbox` / `tmthing` / `tmfloorz` / `spechit` live across calls, and a predicate is
# passed, as in `P_BlockLinesIterator(x, y, PIT_CheckLine)`.
#
# In Ruby:
#   - the globals are `@tm*` ivars (on the one object, like the rest of Game)
#   - **function pointers are expanded**: a dedicated iterator per predicate, like
#     `block_lines_iterator_checkline`. Passing a block would allocate, and Spinel's
#     type inference risks falling to poly. An iterator's body is 10 lines, so
#     determinism and stable types win over the cost of duplication.
#
# `validcount` is "one global counter" as in vanilla, written to
# `@level.line_validcount` / `@level.sector_validcount`.
# **Leaving it out processes the same linedef twice and changes how many random numbers
# are consumed.**

require_relative "defs"
require_relative "info"

module Doom
  module MapMove
    def init_map_state
      @tmbox_top = 0
      @tmbox_bottom = 0
      @tmbox_left = 0
      @tmbox_right = 0
      @tmthing = -1
      @tmflags = 0
      @tmx = 0
      @tmy = 0
      @floatok = false
      @tmfloorz = 0
      @tmceilingz = 0
      @tmdropoffz = 0
      @ceilingline = -1
      @spechit = Array.new(MAXSPECHIT, 0)
      @numspechit = 0
      @opentop = 0
      @openbottom = 0
      @openrange = 0
      @lowfloor = 0
      # intercepts (`P_PathTraverse`)
      @ic_frac = Array.new(MAXINTERCEPTS, 0)
      @ic_isaline = Array.new(MAXINTERCEPTS, 0)
      @ic_thing = Array.new(MAXINTERCEPTS, 0)
      @ic_n = 0
      @trace_x = 0
      @trace_y = 0
      @trace_dx = 0
      @trace_dy = 0
      @earlyout = false
      @bestslidefrac = 0
      @secondslidefrac = 0
      @bestslideline = -1
      @secondslideline = -1
      @slidemo = -1
      @tmxmove = 0
      @tmymove = 0
      @traverser = 0
      @usething = -1
      @linetarget = -1
      @shootthing = -1
      @shootz = 0
      @la_damage = 0
      @attackrange = 0
      @aimslope = 0
      @topslope = 0
      @bottomslope = 0
    end

    # ------------------------------------------------------------ p_maputl.c

    # `P_PointOnLineSide`
    def point_on_line_side(x, y, ld)
      lv = @level
      dxl = lv.line_dx[ld]
      dyl = lv.line_dy[ld]
      v1 = lv.line_v1[ld]
      if dxl == 0
        return x <= lv.vertex_x[v1] ? (dyl > 0 ? 1 : 0) : (dyl < 0 ? 1 : 0)
      end
      if dyl == 0
        return y <= lv.vertex_y[v1] ? (dxl < 0 ? 1 : 0) : (dxl > 0 ? 1 : 0)
      end
      dx = i32(x - lv.vertex_x[v1])
      dy = i32(y - lv.vertex_y[v1])
      left = fixed_mul(dyl >> 16, dx)
      right = fixed_mul(dy, dxl >> 16)
      right < left ? 0 : 1
    end

    # `P_BoxOnLineSide`: returns 0 / 1 / -1 (crossing).
    def box_on_line_side(ld)
      lv = @level
      st = lv.line_slopetype[ld]
      v1 = lv.line_v1[ld]
      if st == 0                                  # ST_HORIZONTAL
        p1 = @tmbox_top > lv.vertex_y[v1] ? 1 : 0
        p2 = @tmbox_bottom > lv.vertex_y[v1] ? 1 : 0
        if lv.line_dx[ld] < 0
          p1 ^= 1
          p2 ^= 1
        end
      elsif st == 1                               # ST_VERTICAL
        p1 = @tmbox_right < lv.vertex_x[v1] ? 1 : 0
        p2 = @tmbox_left < lv.vertex_x[v1] ? 1 : 0
        if lv.line_dy[ld] < 0
          p1 ^= 1
          p2 ^= 1
        end
      elsif st == 2                               # ST_POSITIVE
        p1 = point_on_line_side(@tmbox_left, @tmbox_top, ld)
        p2 = point_on_line_side(@tmbox_right, @tmbox_bottom, ld)
      else                                        # ST_NEGATIVE
        p1 = point_on_line_side(@tmbox_right, @tmbox_top, ld)
        p2 = point_on_line_side(@tmbox_left, @tmbox_bottom, ld)
      end
      p1 == p2 ? p1 : -1
    end

    # `P_PointOnDivlineSide` (the divline is trace).
    def point_on_divline_side_trace(x, y)
      if @trace_dx == 0
        return x <= @trace_x ? (@trace_dy > 0 ? 1 : 0) : (@trace_dy < 0 ? 1 : 0)
      end
      if @trace_dy == 0
        return y <= @trace_y ? (@trace_dx < 0 ? 1 : 0) : (@trace_dx > 0 ? 1 : 0)
      end
      dx = i32(x - @trace_x)
      dy = i32(y - @trace_y)
      if ((@trace_dy ^ @trace_dx ^ dx ^ dy) & 0x80000000) != 0
        return ((@trace_dy ^ dx) & 0x80000000) != 0 ? 1 : 0
      end
      left = fixed_mul(@trace_dy >> 8, dx >> 8)
      right = fixed_mul(dy >> 8, @trace_dx >> 8)
      right < left ? 0 : 1
    end

    # `P_InterceptVector`. v2 = trace, v1 = the segment.
    def intercept_vector(v1x, v1y, v1dx, v1dy)
      den = i32(fixed_mul(v1dy >> 8, @trace_dx) - fixed_mul(v1dx >> 8, @trace_dy))
      return 0 if den == 0
      num = i32(fixed_mul(i32(v1x - @trace_x) >> 8, v1dy) +
                fixed_mul(i32(@trace_y - v1y) >> 8, v1dx))
      fixed_div(num, den)
    end

    # `P_LineOpening`: writes `@opentop` / `@openbottom` / `@openrange` / `@lowfloor`.
    def line_opening(ld)
      lv = @level
      if lv.line_side1[ld] == -1
        @openrange = 0
        return
      end
      front = lv.line_frontsector[ld]
      back = lv.line_backsector[ld]
      fc = lv.sector_ceilingheight[front]
      bc = lv.sector_ceilingheight[back]
      @opentop = fc < bc ? fc : bc
      ff = lv.sector_floorheight[front]
      bf = lv.sector_floorheight[back]
      if ff > bf
        @openbottom = ff
        @lowfloor = bf
      else
        @openbottom = bf
        @lowfloor = ff
      end
      @openrange = i32(@opentop - @openbottom)
    end

    # ------------------------------------------------------- blockmap iterators

    # `P_BlockLinesIterator(x, y, PIT_CheckLine)`
    def block_lines_iterator_checkline(x, y)
      lv = @level
      return true if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      off = lv.blockmap_off[y * lv.bmapwidth + x]
      bm = lv.blockmap
      i = off
      loop do
        v = bm[i]
        break if v == -1
        i += 1
        next if lv.line_validcount[v] == @validcount
        lv.line_validcount[v] = @validcount
        return false unless pit_check_line(v)
      end
      true
    end

    # `P_BlockThingsIterator(x, y, PIT_CheckThing)`
    def block_things_iterator_checkthing(x, y)
      lv = @level
      return true if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      m = @blocklinks[y * lv.bmapwidth + x]
      while m >= 0
        nxt = @mobj_bnext[m]
        return false unless pit_check_thing(m)
        m = nxt
      end
      true
    end

    # `P_BlockLinesIterator(x, y, PIT_AddLineIntercepts)`
    def block_lines_iterator_addline(x, y)
      lv = @level
      return true if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      off = lv.blockmap_off[y * lv.bmapwidth + x]
      bm = lv.blockmap
      i = off
      loop do
        v = bm[i]
        break if v == -1
        i += 1
        next if lv.line_validcount[v] == @validcount
        lv.line_validcount[v] = @validcount
        return false unless pit_add_line_intercepts(v)
      end
      true
    end

    def block_things_iterator_addthing(x, y)
      lv = @level
      return true if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      m = @blocklinks[y * lv.bmapwidth + x]
      while m >= 0
        nxt = @mobj_bnext[m]
        return false unless pit_add_thing_intercepts(m)
        m = nxt
      end
      true
    end

    # ---------------------------------------------------------------- p_map.c

    # `PIT_CheckLine`
    def pit_check_line(ld)
      lv = @level
      return true if @tmbox_right <= lv.line_bbox_left[ld] ||
                     @tmbox_left >= lv.line_bbox_right[ld] ||
                     @tmbox_top <= lv.line_bbox_bottom[ld] ||
                     @tmbox_bottom >= lv.line_bbox_top[ld]
      return true if box_on_line_side(ld) != -1
      return false if lv.line_backsector[ld] < 0
      if (@mobj_flags[@tmthing] & Info::MF_MISSILE) == 0
        return false if (lv.line_flags[ld] & ML_BLOCKING) != 0
        if @mobj_player[@tmthing] < 0 && (lv.line_flags[ld] & ML_BLOCKMONSTERS) != 0
          return false
        end
      end
      line_opening(ld)
      if @opentop < @tmceilingz
        @tmceilingz = @opentop
        @ceilingline = ld
      end
      @tmfloorz = @openbottom if @openbottom > @tmfloorz
      @tmdropoffz = @lowfloor if @lowfloor < @tmdropoffz
      if lv.line_special[ld] != 0
        # Vanilla corrupts memory past 8 lines with `SpechitOverrun`.
        # This port accepts **a deliberately narrow subset** and fails loudly outside it.
        if @numspechit >= 8
          raise LevelError, "spechit overrun (#{@numspechit} lines) at line #{ld}"
        end
        @spechit[@numspechit] = ld
        @numspechit += 1
      end
      true
    end

    # `PIT_CheckThing`
    def pit_check_thing(th)
      return true if (@mobj_flags[th] &
                      (Info::MF_SOLID | Info::MF_SPECIAL | Info::MF_SHOOTABLE)) == 0
      blockdist = i32(@mobj_radius[th] + @mobj_radius[@tmthing])
      dx = i32(@mobj_x[th] - @tmx)
      dy = i32(@mobj_y[th] - @tmy)
      dx = -dx if dx < 0
      dy = -dy if dy < 0
      return true if dx >= blockdist || dy >= blockdist
      return true if th == @tmthing

      if (@mobj_flags[@tmthing] & Info::MF_SKULLFLY) != 0
        damage = ((@rnd.p_random(SITE_CHECKTHING_SKULL) % 8) + 1) *
                 @info_damage[@mobj_type[@tmthing]]
        damage_mobj(th, @tmthing, @tmthing, damage)
        @mobj_flags[@tmthing] &= ~Info::MF_SKULLFLY
        @mobj_momx[@tmthing] = 0
        @mobj_momy[@tmthing] = 0
        @mobj_momz[@tmthing] = 0
        set_mobj_state(@tmthing, @info_spawnstate[@mobj_type[@tmthing]])
        return false
      end

      if (@mobj_flags[@tmthing] & Info::MF_MISSILE) != 0
        return true if @mobj_z[@tmthing] > i32(@mobj_z[th] + @mobj_height[th])
        return true if i32(@mobj_z[@tmthing] + @mobj_height[@tmthing]) < @mobj_z[th]
        tg = @mobj_target[@tmthing]
        if tg >= 0 &&
           (@mobj_type[tg] == @mobj_type[th] ||
            (@mobj_type[tg] == MT_KNIGHT && @mobj_type[th] == MT_BRUISER) ||
            (@mobj_type[tg] == MT_BRUISER && @mobj_type[th] == MT_KNIGHT))
          return true if th == tg
          return false if @mobj_type[th] != MT_PLAYER
        end
        if (@mobj_flags[th] & Info::MF_SHOOTABLE) == 0
          return (@mobj_flags[th] & Info::MF_SOLID) == 0
        end
        damage = ((@rnd.p_random(SITE_CHECKTHING_MISSILE) % 8) + 1) *
                 @info_damage[@mobj_type[@tmthing]]
        damage_mobj(th, @tmthing, @mobj_target[@tmthing], damage)
        return false
      end

      if (@mobj_flags[th] & Info::MF_SPECIAL) != 0
        solid = (@mobj_flags[th] & Info::MF_SOLID) != 0
        touch_special_thing(th, @tmthing) if (@tmflags & Info::MF_PICKUP) != 0
        return !solid
      end
      (@mobj_flags[th] & Info::MF_SOLID) == 0
    end

    # `P_CheckPosition`
    def check_position(thing, x, y)
      lv = @level
      @tmthing = thing
      @tmflags = @mobj_flags[thing]
      @tmx = x
      @tmy = y
      r = @mobj_radius[thing]
      @tmbox_top = i32(y + r)
      @tmbox_bottom = i32(y - r)
      @tmbox_right = i32(x + r)
      @tmbox_left = i32(x - r)
      newsubsec = lv.point_in_subsector(x, y)
      @ceilingline = -1
      sec = lv.ss_sector[newsubsec]
      @tmfloorz = lv.sector_floorheight[sec]
      @tmdropoffz = @tmfloorz
      @tmceilingz = lv.sector_ceilingheight[sec]
      @validcount += 1
      @numspechit = 0
      return true if (@tmflags & Info::MF_NOCLIP) != 0

      xl = (@tmbox_left - lv.bmaporgx - MAXRADIUS) >> MAPBLOCKSHIFT
      xh = (@tmbox_right - lv.bmaporgx + MAXRADIUS) >> MAPBLOCKSHIFT
      yl = (@tmbox_bottom - lv.bmaporgy - MAXRADIUS) >> MAPBLOCKSHIFT
      yh = (@tmbox_top - lv.bmaporgy + MAXRADIUS) >> MAPBLOCKSHIFT
      bx = xl
      while bx <= xh
        by = yl
        while by <= yh
          return false unless block_things_iterator_checkthing(bx, by)
          by += 1
        end
        bx += 1
      end

      xl = (@tmbox_left - lv.bmaporgx) >> MAPBLOCKSHIFT
      xh = (@tmbox_right - lv.bmaporgx) >> MAPBLOCKSHIFT
      yl = (@tmbox_bottom - lv.bmaporgy) >> MAPBLOCKSHIFT
      yh = (@tmbox_top - lv.bmaporgy) >> MAPBLOCKSHIFT
      bx = xl
      while bx <= xh
        by = yl
        while by <= yh
          return false unless block_lines_iterator_checkline(bx, by)
          by += 1
        end
        bx += 1
      end
      true
    end

    # `P_TryMove`
    def try_move(thing, x, y)
      @floatok = false
      return false unless check_position(thing, x, y)
      if (@mobj_flags[thing] & Info::MF_NOCLIP) == 0
        return false if i32(@tmceilingz - @tmfloorz) < @mobj_height[thing]
        @floatok = true
        if (@mobj_flags[thing] & Info::MF_TELEPORT) == 0 &&
           i32(@tmceilingz - @mobj_z[thing]) < @mobj_height[thing]
          return false
        end
        if (@mobj_flags[thing] & Info::MF_TELEPORT) == 0 &&
           i32(@tmfloorz - @mobj_z[thing]) > 24 * FRACUNIT
          return false
        end
        if (@mobj_flags[thing] & (Info::MF_DROPOFF | Info::MF_FLOAT)) == 0 &&
           i32(@tmfloorz - @tmdropoffz) > 24 * FRACUNIT
          return false
        end
      end
      unset_thing_position(thing)
      oldx = @mobj_x[thing]
      oldy = @mobj_y[thing]
      @mobj_floorz[thing] = @tmfloorz
      @mobj_ceilingz[thing] = @tmceilingz
      @mobj_x[thing] = x
      @mobj_y[thing] = y
      set_thing_position(thing)

      if (@mobj_flags[thing] & (Info::MF_TELEPORT | Info::MF_NOCLIP)) == 0
        # Vanilla's `while (numspechit--)` runs **from the back**.
        while @numspechit > 0
          @numspechit -= 1
          ld = @spechit[@numspechit]
          side = point_on_line_side(@mobj_x[thing], @mobj_y[thing], ld)
          oldside = point_on_line_side(oldx, oldy, ld)
          if side != oldside && @level.line_special[ld] != 0
            cross_special_line(ld, oldside, thing)
          end
        end
      end
      true
    end

    # `P_TeleportMove` (`p_map.c`). Crushes the mobjs at the teleport destination.
    def teleport_move(thing, x, y)
      lv = @level
      @tmthing = thing
      @tmflags = @mobj_flags[thing]
      @tmx = x
      @tmy = y
      r = @mobj_radius[thing]
      @tmbox_top = i32(y + r)
      @tmbox_bottom = i32(y - r)
      @tmbox_right = i32(x + r)
      @tmbox_left = i32(x - r)
      newsubsec = lv.point_in_subsector(x, y)
      @ceilingline = -1
      sec = lv.ss_sector[newsubsec]
      @tmfloorz = lv.sector_floorheight[sec]
      @tmdropoffz = @tmfloorz
      @tmceilingz = lv.sector_ceilingheight[sec]
      @validcount += 1
      @numspechit = 0
      xl = (@tmbox_left - lv.bmaporgx - MAXRADIUS) >> MAPBLOCKSHIFT
      xh = (@tmbox_right - lv.bmaporgx + MAXRADIUS) >> MAPBLOCKSHIFT
      yl = (@tmbox_bottom - lv.bmaporgy - MAXRADIUS) >> MAPBLOCKSHIFT
      yh = (@tmbox_top - lv.bmaporgy + MAXRADIUS) >> MAPBLOCKSHIFT
      bx = xl
      while bx <= xh
        by = yl
        while by <= yh
          return false unless block_things_iterator_stomp(bx, by)
          by += 1
        end
        bx += 1
      end
      unset_thing_position(thing)
      @mobj_floorz[thing] = @tmfloorz
      @mobj_ceilingz[thing] = @tmceilingz
      @mobj_x[thing] = x
      @mobj_y[thing] = y
      set_thing_position(thing)
      true
    end

    def block_things_iterator_stomp(x, y)
      lv = @level
      return true if x < 0 || y < 0 || x >= lv.bmapwidth || y >= lv.bmapheight
      m = @blocklinks[y * lv.bmapwidth + x]
      while m >= 0
        nxt = @mobj_bnext[m]
        return false unless pit_stomp_thing(m)
        m = nxt
      end
      true
    end

    # `PIT_StompThing`
    def pit_stomp_thing(thing)
      return true if (@mobj_flags[thing] & Info::MF_SHOOTABLE) == 0
      blockdist = i32(@mobj_radius[thing] + @mobj_radius[@tmthing])
      dx = i32(@mobj_x[thing] - @tmx)
      dy = i32(@mobj_y[thing] - @tmy)
      dx = -dx if dx < 0
      dy = -dy if dy < 0
      return true if dx >= blockdist || dy >= blockdist
      return true if thing == @tmthing
      # `gamemap != 30` is always true in shareware. Monsters cannot crush.
      return false if @mobj_player[@tmthing] < 0
      damage_mobj(thing, @tmthing, @tmthing, 10000)
      true
    end

    # `P_ThingHeightClip`
    def thing_height_clip(thing)
      onfloor = @mobj_z[thing] == @mobj_floorz[thing]
      check_position(thing, @mobj_x[thing], @mobj_y[thing])
      @mobj_floorz[thing] = @tmfloorz
      @mobj_ceilingz[thing] = @tmceilingz
      if onfloor
        @mobj_z[thing] = @mobj_floorz[thing]
      else
        if i32(@mobj_z[thing] + @mobj_height[thing]) > @mobj_ceilingz[thing]
          @mobj_z[thing] = i32(@mobj_ceilingz[thing] - @mobj_height[thing])
        end
      end
      i32(@mobj_ceilingz[thing] - @mobj_floorz[thing]) >= @mobj_height[thing]
    end

    # ------------------------------------------------------------- sliding movement

    # `P_HitSlideLine`
    def hit_slide_line(ld)
      lv = @level
      st = lv.line_slopetype[ld]
      if st == 0
        @tmymove = 0
        return
      end
      if st == 1
        @tmxmove = 0
        return
      end
      side = point_on_line_side(@mobj_x[@slidemo], @mobj_y[@slidemo], ld)
      lineangle = point_to_angle2(0, 0, lv.line_dx[ld], lv.line_dy[ld])
      lineangle = bam(lineangle + ANG180) if side == 1
      moveangle = point_to_angle2(0, 0, @tmxmove, @tmymove)
      deltaangle = bam(moveangle - lineangle)
      deltaangle = bam(deltaangle + ANG180) if deltaangle > ANG180
      la = lineangle >> ANGLETOFINESHIFT
      da = deltaangle >> ANGLETOFINESHIFT
      movelen = aprox_distance(@tmxmove, @tmymove)
      newlen = fixed_mul(movelen, @finesine[da + 2048])
      @tmxmove = fixed_mul(newlen, @finesine[la + 2048])
      @tmymove = fixed_mul(newlen, @finesine[la])
    end

    # `PTR_SlideTraverse`
    def ptr_slide_traverse(idx)
      li = @ic_thing[idx]
      raise LevelError, "PTR_SlideTraverse: not a line" if @ic_isaline[idx] == 0
      blocking = false
      if (@level.line_flags[li] & ML_TWOSIDED) == 0
        return true if point_on_line_side(@mobj_x[@slidemo], @mobj_y[@slidemo], li) != 0
        blocking = true
      else
        line_opening(li)
        if @openrange < @mobj_height[@slidemo]
          blocking = true
        elsif i32(@opentop - @mobj_z[@slidemo]) < @mobj_height[@slidemo]
          blocking = true
        elsif i32(@openbottom - @mobj_z[@slidemo]) > 24 * FRACUNIT
          blocking = true
        end
      end
      return true unless blocking
      if @ic_frac[idx] < @bestslidefrac
        @secondslidefrac = @bestslidefrac
        @secondslideline = @bestslideline
        @bestslidefrac = @ic_frac[idx]
        @bestslideline = li
      end
      false
    end

    # `P_SlideMove`: copies vanilla's gotos as they are (retry / stairstep).
    def slide_move(mo)
      @slidemo = mo
      hitcount = 0
      loop do
        hitcount += 1
        if hitcount == 3
          stairstep(mo)
          return
        end
        if @mobj_momx[mo] > 0
          leadx = i32(@mobj_x[mo] + @mobj_radius[mo])
          trailx = i32(@mobj_x[mo] - @mobj_radius[mo])
        else
          leadx = i32(@mobj_x[mo] - @mobj_radius[mo])
          trailx = i32(@mobj_x[mo] + @mobj_radius[mo])
        end
        if @mobj_momy[mo] > 0
          leady = i32(@mobj_y[mo] + @mobj_radius[mo])
          traily = i32(@mobj_y[mo] - @mobj_radius[mo])
        else
          leady = i32(@mobj_y[mo] - @mobj_radius[mo])
          traily = i32(@mobj_y[mo] + @mobj_radius[mo])
        end
        @bestslidefrac = FRACUNIT + 1
        @traverser = 1
        path_traverse(leadx, leady, i32(leadx + @mobj_momx[mo]), i32(leady + @mobj_momy[mo]), 1)
        path_traverse(trailx, leady, i32(trailx + @mobj_momx[mo]), i32(leady + @mobj_momy[mo]), 1)
        path_traverse(leadx, traily, i32(leadx + @mobj_momx[mo]), i32(traily + @mobj_momy[mo]), 1)
        if @bestslidefrac == FRACUNIT + 1
          stairstep(mo)
          return
        end
        @bestslidefrac -= 0x800
        if @bestslidefrac > 0
          newx = fixed_mul(@mobj_momx[mo], @bestslidefrac)
          newy = fixed_mul(@mobj_momy[mo], @bestslidefrac)
          unless try_move(mo, i32(@mobj_x[mo] + newx), i32(@mobj_y[mo] + newy))
            stairstep(mo)
            return
          end
        end
        @bestslidefrac = i32(FRACUNIT - (@bestslidefrac + 0x800))
        @bestslidefrac = FRACUNIT if @bestslidefrac > FRACUNIT
        return if @bestslidefrac <= 0
        @tmxmove = fixed_mul(@mobj_momx[mo], @bestslidefrac)
        @tmymove = fixed_mul(@mobj_momy[mo], @bestslidefrac)
        hit_slide_line(@bestslideline)
        @mobj_momx[mo] = @tmxmove
        @mobj_momy[mo] = @tmymove
        return if try_move(mo, i32(@mobj_x[mo] + @tmxmove), i32(@mobj_y[mo] + @tmymove))
      end
    end

    def stairstep(mo)
      unless try_move(mo, @mobj_x[mo], i32(@mobj_y[mo] + @mobj_momy[mo]))
        try_move(mo, i32(@mobj_x[mo] + @mobj_momx[mo]), @mobj_y[mo])
      end
    end

    # ------------------------------------------------------------ path traverse

    # `PIT_AddLineIntercepts`
    def pit_add_line_intercepts(ld)
      lv = @level
      v1 = lv.line_v1[ld]
      v2 = lv.line_v2[ld]
      if @trace_dx > FRACUNIT * 16 || @trace_dy > FRACUNIT * 16 ||
         @trace_dx < -FRACUNIT * 16 || @trace_dy < -FRACUNIT * 16
        s1 = point_on_divline_side_trace(lv.vertex_x[v1], lv.vertex_y[v1])
        s2 = point_on_divline_side_trace(lv.vertex_x[v2], lv.vertex_y[v2])
      else
        s1 = point_on_line_side(@trace_x, @trace_y, ld)
        s2 = point_on_line_side(i32(@trace_x + @trace_dx), i32(@trace_y + @trace_dy), ld)
      end
      return true if s1 == s2
      frac = intercept_vector(lv.vertex_x[v1], lv.vertex_y[v1],
                              lv.line_dx[ld], lv.line_dy[ld])
      return true if frac < 0
      return false if @earlyout && frac < FRACUNIT && lv.line_backsector[ld] < 0
      if @ic_n >= 128
        raise LevelError, "intercepts overrun (#{@ic_n})"
      end
      @ic_frac[@ic_n] = frac
      @ic_isaline[@ic_n] = 1
      @ic_thing[@ic_n] = ld
      @ic_n += 1
      true
    end

    # `PIT_AddThingIntercepts`
    def pit_add_thing_intercepts(th)
      tracepositive = (@trace_dx ^ @trace_dy) > 0
      r = @mobj_radius[th]
      if tracepositive
        x1 = i32(@mobj_x[th] - r)
        y1 = i32(@mobj_y[th] + r)
        x2 = i32(@mobj_x[th] + r)
        y2 = i32(@mobj_y[th] - r)
      else
        x1 = i32(@mobj_x[th] - r)
        y1 = i32(@mobj_y[th] - r)
        x2 = i32(@mobj_x[th] + r)
        y2 = i32(@mobj_y[th] + r)
      end
      s1 = point_on_divline_side_trace(x1, y1)
      s2 = point_on_divline_side_trace(x2, y2)
      return true if s1 == s2
      frac = intercept_vector(x1, y1, i32(x2 - x1), i32(y2 - y1))
      return true if frac < 0
      if @ic_n >= 128
        raise LevelError, "intercepts overrun (#{@ic_n})"
      end
      @ic_frac[@ic_n] = frac
      @ic_isaline[@ic_n] = 0
      @ic_thing[@ic_n] = th
      @ic_n += 1
      true
    end

    def dispatch_traverse(idx)
      return ptr_slide_traverse(idx) if @traverser == 1
      return ptr_use_traverse(idx) if @traverser == 2
      return ptr_aim_traverse(idx) if @traverser == 3
      return ptr_shoot_traverse(idx) if @traverser == 4
      true
    end

    # `P_TraverseIntercepts`: copies vanilla's **selection sort** as it is.
    def traverse_intercepts(maxfrac)
      count = @ic_n
      inn = -1
      while count > 0
        count -= 1
        dist = 0x7fffffff
        scan = 0
        while scan < @ic_n
          if @ic_frac[scan] < dist
            dist = @ic_frac[scan]
            inn = scan
          end
          scan += 1
        end
        return true if dist > maxfrac
        return false unless dispatch_traverse(inn)
        @ic_frac[inn] = 0x7fffffff
      end
      true
    end

    # `P_PathTraverse`
    def path_traverse(x1, y1, x2, y2, flags)
      lv = @level
      @earlyout = (flags & 4) != 0
      @validcount += 1
      @ic_n = 0
      x1 = i32(x1 + FRACUNIT) if ((x1 - lv.bmaporgx) & (MAPBLOCKSIZE - 1)) == 0
      y1 = i32(y1 + FRACUNIT) if ((y1 - lv.bmaporgy) & (MAPBLOCKSIZE - 1)) == 0
      @trace_x = x1
      @trace_y = y1
      @trace_dx = i32(x2 - x1)
      @trace_dy = i32(y2 - y1)
      x1 = i32(x1 - lv.bmaporgx)
      y1 = i32(y1 - lv.bmaporgy)
      xt1 = x1 >> MAPBLOCKSHIFT
      yt1 = y1 >> MAPBLOCKSHIFT
      x2 = i32(x2 - lv.bmaporgx)
      y2 = i32(y2 - lv.bmaporgy)
      xt2 = x2 >> MAPBLOCKSHIFT
      yt2 = y2 >> MAPBLOCKSHIFT

      if xt2 > xt1
        mapxstep = 1
        partial = FRACUNIT - ((x1 >> MAPBTOFRAC) & (FRACUNIT - 1))
        ystep = fixed_div(i32(y2 - y1), abs_i(i32(x2 - x1)))
      elsif xt2 < xt1
        mapxstep = -1
        partial = (x1 >> MAPBTOFRAC) & (FRACUNIT - 1)
        ystep = fixed_div(i32(y2 - y1), abs_i(i32(x2 - x1)))
      else
        mapxstep = 0
        partial = FRACUNIT
        ystep = 256 * FRACUNIT
      end
      yintercept = i32((y1 >> MAPBTOFRAC) + fixed_mul(partial, ystep))

      if yt2 > yt1
        mapystep = 1
        partial = FRACUNIT - ((y1 >> MAPBTOFRAC) & (FRACUNIT - 1))
        xstep = fixed_div(i32(x2 - x1), abs_i(i32(y2 - y1)))
      elsif yt2 < yt1
        mapystep = -1
        partial = (y1 >> MAPBTOFRAC) & (FRACUNIT - 1)
        xstep = fixed_div(i32(x2 - x1), abs_i(i32(y2 - y1)))
      else
        mapystep = 0
        partial = FRACUNIT
        xstep = 256 * FRACUNIT
      end
      xintercept = i32((x1 >> MAPBTOFRAC) + fixed_mul(partial, xstep))

      mapx = xt1
      mapy = yt1
      count = 0
      while count < 64
        if (flags & 1) != 0
          return false unless block_lines_iterator_addline(mapx, mapy)
        end
        if (flags & 2) != 0
          return false unless block_things_iterator_addthing(mapx, mapy)
        end
        break if mapx == xt2 && mapy == yt2
        if (yintercept >> 16) == mapy
          yintercept = i32(yintercept + ystep)
          mapx += mapxstep
        elsif (xintercept >> 16) == mapx
          xintercept = i32(xintercept + xstep)
          mapy += mapystep
        end
        count += 1
      end
      traverse_intercepts(FRACUNIT)
    end
  end
end
