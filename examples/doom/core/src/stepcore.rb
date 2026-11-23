# examples/doom/core/src/stepcore.rb — the step entry's shared vocabulary and leaves.
#
# GPL-derived, from `examples/doom/lib/doom/game.rb`, `inter.rb`, `specials.rb`,
# `enemy.rb`, `mapmove.rb`, `sight.rb`, `pspr.rb` and `random.rb` (`Doom::Game`,
# `Doom::Random`), `statusbar.rb`, `hud.rb` and `texture.rb`, which reproduce
# doomgeneric's `p_*.c`, `m_random.c`, `st_stuff.c`, `hu_stuff.c` and
# `p_spec.c`. See ../NOTICE.md and ../sources.tsv.
#
# THE STEP ENTRY'S CONVENTION. Every scalar field lives in `core_state`
# (`state`), as for render. The step code touches a hundred of them, so their
# slot indices do not travel one parameter each: they arrive once, in `gx`, an
# i64 index table Full fills from the layout, and `state[gx[G_NAME]]` is the
# field NAME. The G_ constants are positions in that table and nothing else;
# examples/doom/core/entries/step-slots.tsv names the field at each
# position. Arrays, and scalars Full prepares (which are one-element buffers in
# the layout, not cells), arrive as buffers, one parameter each, named by field.
#
# WHAT CHANGES FROM THE ORIGINAL, and only this: `self` becomes `state`, `gx`
# and the buffers; a boolean becomes 0 or 1; `raise LevelError` becomes
# `core_fail(:capacity)`, which is the ONLY failure this kernel version admits --
# so it also stands where the original raises for a path it does not implement
# (A_BossDeath, T_MoveCeiling) or for a plat it cannot find, which the
# classification records. FixedDiv is core_fixed_div (decision 0022), which
# needs no copy.
#
# WHAT THE KERNEL REFUSES, learned writing this, so the next definition does not
# pay for it again:
#   * `core_fail(:capacity)` is the only failure; `:bounds` and the rest are not
#     in this version.
#   * a local cannot hold a boolean: `x = a > b` is refused; write `a > b ? 1 : 0`
#     and test `x != 0`.
#   * a conditional that ENDS a branch of another conditional is typed as that
#     branch's value, so a no-else `if` (or an elsif chain with no else) there is
#     refused as an implicit nil: end the branch with `0`.
#   * a literal must be a signed 64-bit value (a table of bytes is packed seven to
#     a constant, below), and there is no data table at all.
#   * a callee whose buffer parameter is handed an ENTRY buffer at one call site
#     and a HELPER's buffer parameter at another is refused as conflicting type
#     evidence; tests/doom-core/stepall.rb therefore calls only root definitions.
#   * `.size` / `.length` of a buffer is not available in a helper: use the
#     capacity state.tsv declares, or take the count as a scalar.
#   * a dense chain of `==` tests can become a jump table in .rodata, which the
#     link rule (object-relocs) refuses: lay a dispatch out as a range tree.
#     WHETHER IT DOES DEPENDS ON THE CALLERS, not only on the definition:
#     give_ammo linked as a root and made three jump tables once inlined into
#     the lowered knot. A definition that is clean today can stop being clean
#     when the closure grows; the link rule runs on the final object for that.
#     IT IS NOT ONLY SWITCHES: any table of constants clang decides to
#     materialise is a data reference. clipammo's `return 10 if ...` chain,
#     inlined, became two lookup tables (the sizes and their halves). The fix is
#     the same shape: a packed constant read with a shift, or a range tree.
#   * an if/else that is the LAST statement of a branch of another if/else is
#     typed as that branch's value, so each of its own branches needs a value:
#     one that ends in an if with no else is refused as an implicit nil. End it
#     with `0`. One level of nesting is admitted; this is the second level.
#
# THE RANDOM TABLE IS CONSTANTS. The kernel admits no data table, and a literal
# must be a signed 32-bit value (decision 0022), so rndtable's 256 bytes are
# packed four to a constant, byte i at bit 8 * (i % 4) of ST_RND_(i / 4) (a word
# with bit 31 set written as its signed pattern, which the shift and the mask
# read the same way), and read through a range tree rather than an index.
#
# THE THINKER SLOTS ARE CELLS HERE. thinkers.rb takes the free-list head and the
# high-water mark as one-element buffers, which a session cannot hand over: they
# are scalar fields, cells of core_state. The same list operations are written
# again over the cells (dc_st_take_slot and the rest); the algorithm is
# thinkers.rb's, line for line.

# positions in gx; step-slots.tsv names the field at each
G_MOBJ_FREE = 0
G_MOBJ_ALLOC = 1
G_PL_MESSAGE = 2
G_PL_ARMORPOINTS = 3
G_PL_ARMORTYPE = 4
G_PL_HEALTH = 5
G_PL_BONUSCOUNT = 6
G_PL_BOB = 7
G_PL_VIEWZ = 8
G_PL_VIEWHEIGHT = 9
G_PL_DELTAVIEWHEIGHT = 10
G_PL_PLAYERSTATE = 11
G_ONGROUND = 12
G_LEVELTIME = 13
G_TRACE_X = 14
G_TRACE_Y = 15
G_TRACE_DX = 16
G_TRACE_DY = 17
G_STRACE_X = 18
G_STRACE_Y = 19
G_STRACE_DX = 20
G_STRACE_DY = 21
G_DR_N = 22
G_TH_FREE = 23
G_TH_ALLOC = 24
G_PRNDINDEX = 25
G_PCOUNT = 26
G_HUD_MESSAGE_COUNTER = 27
G_HUD_MESSAGE = 28
G_HUD_MESSAGE_ON = 29
G_SB_PAINHEALTH = 30
G_SB_PAINCALC = 31

ST_MAXMOBJS = 4096
ST_MF_SOLID = 2
ST_SFX_PODTH1 = 59
ST_SFX_BGDTH1 = 62
ST_MAXPLATS = 30
ST_MAXBUTTONS = 16
ST_TH_DOOR = 6
ST_TH_NULL = 10
ST_TH_REMOVED = 0
ST_MAXTHINKERS = 4096
ST_MAXDOORS = 64 # state.tsv: game_dr_sector fixed:64
ST_MAXHEALTH = 100
ST_BONUSADD = 6
ST_NUMAMMO = 4
ST_MAXBOB = 1048576 # 0x100000
ST_FINEMASK = 8191
ST_PST_LIVE = 0
ST_FRACUNIT = 65536
ST_VIEWHEIGHT = 2686976 # 41 * FRACUNIT
ST_ANGLETOFINESHIFT = 19
ST_FACESTRIDE = 8
ST_NUMPAINFACES = 5
ST_HU_MSGTIMEOUT = 140
ST_RND_0 = -596834304 # 0xdc6d0800
ST_RND_1 = 1804988894
ST_RND_2 = -1929447349 # 0x8cfef84b
ST_RND_3 = 357188112
ST_RND_4 = -229625901 # 0xf2502fd3
ST_RND_5 = -2134041702 # 0x80cd1b9a
ST_RND_6 = 609048993
ST_RND_7 = 810905183
ST_RND_8 = -103576364 # 0xf9d38cd4
ST_RND_9 = 851988246
ST_RND_10 = -1942701028 # 0x8c34bc1c
ST_RND_11 = -1857783606 # 0x914478ca
ST_RND_12 = -1095219650 # 0xbeb8463e
ST_RND_13 = -526858917 # 0xe098c55b
ST_RND_14 = -1306957675 # 0xb2196895
ST_RND_15 = -1228228868 # 0xb6cab6fc
ST_RND_16 = 1359267213
ST_RND_17 = 714207925
ST_RND_18 = -962796761 # 0xc69ce327
ST_RND_19 = 1574683105
ST_RND_20 = 16363386
ST_RND_21 = -280588369 # 0xef468faf
ST_RND_22 = 899937838
ST_RND_23 = -2019005021 # 0x87a86da3
ST_RND_24 = 1545202434
ST_RND_25 = 1300926740
ST_RND_26 = -1337022907 # 0xb04ea645
ST_RND_27 = 1906758829
ST_RND_28 = 841589086
ST_RND_29 = -1536216593 # 0xa46f31ef
ST_RND_30 = 620903494
ST_RND_31 = -1668789333 # 0x9c884bab
ST_RND_32 = -1842726901 # 0x922a380b
ST_RND_33 = -1840650870 # 0x9249e58a
ST_RND_34 = -1000194739 # 0xc4623d4d
ST_RND_35 = -985699705 # 0xc53f6a87
ST_RND_36 = -882878781 # 0xcb6056c3
ST_RND_37 = -139827855 # 0xf7aa6571
ST_RND_38 = -95391307 # 0xfa5071b5
ST_RND_39 = -302053524 # 0xedff076c
ST_RND_40 = 1800397441
ST_RND_41 = -244865424 # 0xf167a670
ST_RND_42 = 2028986136
ST_RND_43 = 1379678918
ST_RND_44 = 1119355776
ST_RND_45 = -527310705 # 0xe091e08f
ST_RND_46 = 765709905
ST_RND_47 = 1923635775
ST_RND_48 = 1604264251
ST_RND_49 = 1652263708
ST_RND_50 = 1175438461
ST_RND_51 = 238484930
ST_RND_52 = 289923693
ST_RND_53 = 1471831457
ST_RND_54 = 873761524
ST_RND_55 = 605748091
ST_RND_56 = -416010735 # 0xe7342e11
ST_RND_57 = -585151256 # 0xdd1f4ce8
ST_RND_58 = -1512561324 # 0xa5d82554
ST_RND_59 = -221943084 # 0xf2c56ad4
ST_RND_60 = -1356387486 # 0xaf272b62
ST_RND_61 = 1421775358
ST_RND_62 = -2000953738 # 0x88bbde76
ST_RND_63 = -101932168 # 0xf9eca378

# ---------------------------------------------------------------- arithmetic

def dc_st_abs_i(v)
  v < 0 ? -v : v
end

# `P_AproxDistance`
def dc_st_aprox_distance(dx, dy)
  dx = -dx if dx < 0
  dy = -dy if dy < 0
  return dx + dy - (dx >> 1) if dx < dy
  dx + dy - (dy >> 1)
end

# `slope_to_angle` (`SlopeDiv` into tantoangle)
def dc_st_slope_to_angle(tantoangle, num, den)
  # SlopeDiv's unsigned arguments (decision 0022), as leaves.rb's dc_slope_div:
  # den compared and shifted as a word, (num << 3) / (den >> 8) an unsigned
  # quotient, h = u >>> 1 and dd >= 2, no term past i32.
  return tantoangle[2048] if core_u32_lt(den, 512)
  u = core_w32_mul(num, 8)
  dd = core_u32_shr(den, 8)
  h = core_u32_shr(u, 1)
  ans = (h / dd) * 2 + ((h % dd) * 2 + (u & 1)) / dd
  tantoangle[ans <= 2048 ? ans : 2048]
end

# ------------------------------------------------------------------- random

# rndtable[i], read out of the packed constants
def dc_st_rnd_byte(i)
  k = i / 4
  w =
    if k <= 31
      if k <= 15
        if k <= 7
          if k <= 3
            if k <= 1
              if k <= 0
                ST_RND_0
              else
                ST_RND_1
              end
            else
              if k <= 2
                ST_RND_2
              else
                ST_RND_3
              end
            end
          else
            if k <= 5
              if k <= 4
                ST_RND_4
              else
                ST_RND_5
              end
            else
              if k <= 6
                ST_RND_6
              else
                ST_RND_7
              end
            end
          end
        else
          if k <= 11
            if k <= 9
              if k <= 8
                ST_RND_8
              else
                ST_RND_9
              end
            else
              if k <= 10
                ST_RND_10
              else
                ST_RND_11
              end
            end
          else
            if k <= 13
              if k <= 12
                ST_RND_12
              else
                ST_RND_13
              end
            else
              if k <= 14
                ST_RND_14
              else
                ST_RND_15
              end
            end
          end
        end
      else
        if k <= 23
          if k <= 19
            if k <= 17
              if k <= 16
                ST_RND_16
              else
                ST_RND_17
              end
            else
              if k <= 18
                ST_RND_18
              else
                ST_RND_19
              end
            end
          else
            if k <= 21
              if k <= 20
                ST_RND_20
              else
                ST_RND_21
              end
            else
              if k <= 22
                ST_RND_22
              else
                ST_RND_23
              end
            end
          end
        else
          if k <= 27
            if k <= 25
              if k <= 24
                ST_RND_24
              else
                ST_RND_25
              end
            else
              if k <= 26
                ST_RND_26
              else
                ST_RND_27
              end
            end
          else
            if k <= 29
              if k <= 28
                ST_RND_28
              else
                ST_RND_29
              end
            else
              if k <= 30
                ST_RND_30
              else
                ST_RND_31
              end
            end
          end
        end
      end
    else
      if k <= 47
        if k <= 39
          if k <= 35
            if k <= 33
              if k <= 32
                ST_RND_32
              else
                ST_RND_33
              end
            else
              if k <= 34
                ST_RND_34
              else
                ST_RND_35
              end
            end
          else
            if k <= 37
              if k <= 36
                ST_RND_36
              else
                ST_RND_37
              end
            else
              if k <= 38
                ST_RND_38
              else
                ST_RND_39
              end
            end
          end
        else
          if k <= 43
            if k <= 41
              if k <= 40
                ST_RND_40
              else
                ST_RND_41
              end
            else
              if k <= 42
                ST_RND_42
              else
                ST_RND_43
              end
            end
          else
            if k <= 45
              if k <= 44
                ST_RND_44
              else
                ST_RND_45
              end
            else
              if k <= 46
                ST_RND_46
              else
                ST_RND_47
              end
            end
          end
        end
      else
        if k <= 55
          if k <= 51
            if k <= 49
              if k <= 48
                ST_RND_48
              else
                ST_RND_49
              end
            else
              if k <= 50
                ST_RND_50
              else
                ST_RND_51
              end
            end
          else
            if k <= 53
              if k <= 52
                ST_RND_52
              else
                ST_RND_53
              end
            else
              if k <= 54
                ST_RND_54
              else
                ST_RND_55
              end
            end
          end
        else
          if k <= 59
            if k <= 57
              if k <= 56
                ST_RND_56
              else
                ST_RND_57
              end
            else
              if k <= 58
                ST_RND_58
              else
                ST_RND_59
              end
            end
          else
            if k <= 61
              if k <= 60
                ST_RND_60
              else
                ST_RND_61
              end
            else
              if k <= 62
                ST_RND_62
              else
                ST_RND_63
              end
            end
          end
        end
      end
    end
  (w >> (8 * (i % 4))) & 0xff
end

# `P_Random`: the index advances before the read, and the draw is counted.
# The original's `site` argument only labels a trace and is dropped.
def dc_st_p_random(state, gx)
  i = (state[gx[G_PRNDINDEX]] + 1) & 0xff
  state[gx[G_PRNDINDEX]] = i
  state[gx[G_PCOUNT]] = state[gx[G_PCOUNT]] + 1
  dc_st_rnd_byte(i)
end

# `M_Random`: random.rb's dc_m_random over the two cells, kept separate from
# P_Random as there: the menu's index is not the game's.
def dc_st_m_random(state, gx)
  i = (state[gx[G_RNDINDEX]] + 1) & 0xff
  state[gx[G_RNDINDEX]] = i
  state[gx[G_MCOUNT]] = state[gx[G_MCOUNT]] + 1
  dc_st_rnd_byte(i)
end

# ------------------------------------------------------------ thinker slots

# thinkers.rb's dc_take_slot, over the two cells
def dc_st_take_slot(state, gx, th_prev, cap)
  f = state[gx[G_TH_FREE]]
  if f >= 0
    state[gx[G_TH_FREE]] = th_prev[f]
    f
  else
    a = state[gx[G_TH_ALLOC]]
    if a >= cap
      -1
    else
      state[gx[G_TH_ALLOC]] = a + 1
      a
    end
  end
end

# `add_thinker`: take, store, link (thinkers.rb's three steps in one)
def dc_st_add_thinker(state, gx, th_next, th_prev, th_func, th_data, func, data)
  t = dc_st_take_slot(state, gx, th_prev, ST_MAXTHINKERS)
  if t < 0
    core_fail(:capacity)
  end
  th_func[t] = func
  th_data[t] = data
  p = th_prev[0]
  th_next[p] = t
  th_next[t] = 0
  th_prev[t] = p
  th_prev[0] = t
  t
end

# `remove_thinker`: mark, the sweep unlinks
def dc_st_remove_thinker(th_func, t)
  th_func[t] = ST_TH_REMOVED
  t
end

# ------------------------------------------------------------------- things

# `alloc_mobj`: the free list, then the high-water mark
def dc_st_alloc_mobj(state, gx, thing_next)
  m = state[gx[G_MOBJ_FREE]]
  if m >= 0
    state[gx[G_MOBJ_FREE]] = thing_next[m]
  else
    if state[gx[G_MOBJ_ALLOC]] >= ST_MAXMOBJS
      core_fail(:capacity)
    end
    m = state[gx[G_MOBJ_ALLOC]]
    state[gx[G_MOBJ_ALLOC]] = m + 1
  end
  m
end

def dc_st_free_mobj(state, gx, thing_next, m)
  thing_next[m] = state[gx[G_MOBJ_FREE]]
  state[gx[G_MOBJ_FREE]] = m
  m
end

# `mobj_removed?`: no thinker, or one marked for removal
def dc_st_mobj_removed(mobj_th, th_func, m)
  t = mobj_th[m]
  if t < 0
    return 1
  end
  th_func[t] == ST_TH_REMOVED ? 1 : 0
end

# `P_Thrust` on the player
def dc_st_thrust(player_mo, mobj_momx, mobj_momy, finesine, angle, move)
  a = core_u32_shr(angle, ST_ANGLETOFINESHIFT)
  m = player_mo[0]
  mobj_momx[m] = core_w32_add(mobj_momx[m], core_fixed_mul(move, finesine[a + 2048]))
  mobj_momy[m] = core_w32_add(mobj_momy[m], core_fixed_mul(move, finesine[a]))
  0
end

# `A_Fall`
def dc_st_a_fall(mobj_flags, actor)
  mobj_flags[actor] = mobj_flags[actor] & ~ST_MF_SOLID
  0
end

# `A_Scream`: the sound is not played, but the draw a death sound's pick makes is
def dc_st_a_scream(state, gx, mobj_type, info_deathsound, actor)
  ds = info_deathsound[mobj_type[actor]]
  if ds != 0
    if ds == ST_SFX_PODTH1 || ds == ST_SFX_PODTH1 + 1 || ds == ST_SFX_PODTH1 + 2
      dc_st_p_random(state, gx)
    elsif ds == ST_SFX_BGDTH1 || ds == ST_SFX_BGDTH1 + 1
      dc_st_p_random(state, gx)
    end
  end
  0
end

# `A_BossDeath`: E1M8's finale, which the original does not implement.
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17):
# the original raises LevelError "A_BossDeath reached (not implemented for this
# map)" here (enemy.rb), so the program stops at this call; CORE has no failure
# but CAPACITY, and the entry stops at the same call (through the 0007 adapter
# its mutable participants are poisoned; a direct C call is not). Reachable: an
# E1M8 baron's death (scenario baron-death).
def dc_st_a_boss_death(actor)
  core_fail(:capacity)
  actor
end

# `T_MoveCeiling`, which the original does not implement.
# AN ORIGINAL RAISE, PORTED AS CAPACITY (the owner's decision of 2026-09-17):
# the original raises LevelError "T_MoveCeiling not implemented" (specials.rb);
# CORE has no failure but CAPACITY. Unreached by construction: nothing creates
# a ceiling thinker (tests/doom-core/content-scan.rb).
def dc_st_t_move_ceiling(k)
  core_fail(:capacity)
  k
end

# ------------------------------------------------------------------- player

# `msg`: the message is set when the pickup took
def dc_st_msg(state, gx, got, text)
  if got != 0
    state[gx[G_PL_MESSAGE]] = text
  end
  got
end

def dc_st_give_armor(state, gx, armortype)
  hits = armortype * 100
  return 0 if state[gx[G_PL_ARMORPOINTS]] >= hits
  state[gx[G_PL_ARMORTYPE]] = armortype
  state[gx[G_PL_ARMORPOINTS]] = hits
  1
end

def dc_st_give_body(state, gx, player_mo, mobj_health, num)
  return 0 if state[gx[G_PL_HEALTH]] >= ST_MAXHEALTH
  h = state[gx[G_PL_HEALTH]] + num
  h = ST_MAXHEALTH if h > ST_MAXHEALTH
  state[gx[G_PL_HEALTH]] = h
  mobj_health[player_mo[0]] = h
  1
end

def dc_st_give_card(state, gx, pl_cards, card)
  return 0 if pl_cards[card] != 0
  state[gx[G_PL_BONUSCOUNT]] = ST_BONUSADD
  pl_cards[card] = 1
  1
end

# the clip sizes 10, 4, 20, 1 packed a byte each: inlined into give_ammo, the
# == chain became two lookup tables in .rodata, which the link rule refuses
ST_CLIPAMMO = 0x0114040a

def dc_st_clipammo(ammo)
  return 1 if ammo < 0 || ammo > 3
  (ST_CLIPAMMO >> (ammo * 8)) & 0xff
end

def dc_st_decrease_ammo(pl_ammo, pl_maxammo, ammonum, amount)
  if ammonum < ST_NUMAMMO
    pl_ammo[ammonum] = pl_ammo[ammonum] - amount
  else
    pl_maxammo[ammonum - ST_NUMAMMO] = pl_maxammo[ammonum - ST_NUMAMMO] - amount
  end
  0
end

# `P_CalcHeight`
def dc_st_calc_height(state, gx, player_mo, mobj_momx, mobj_momy, mobj_z, mobj_ceilingz, finesine)
  m = player_mo[0]
  bob = core_w32_add(core_fixed_mul(mobj_momx[m], mobj_momx[m]), core_fixed_mul(mobj_momy[m], mobj_momy[m]))
  bob = bob >> 2
  bob = ST_MAXBOB if bob > ST_MAXBOB
  state[gx[G_PL_BOB]] = bob
  if state[gx[G_ONGROUND]] == 0
    state[gx[G_PL_VIEWZ]] = core_w32_add(mobj_z[m], state[gx[G_PL_VIEWHEIGHT]])
    return 0
  end
  angle = (8192 / 20 * state[gx[G_LEVELTIME]]) & ST_FINEMASK
  vbob = core_fixed_mul(bob / 2, finesine[angle])
  if state[gx[G_PL_PLAYERSTATE]] == ST_PST_LIVE
    vh = core_w32_add(state[gx[G_PL_VIEWHEIGHT]], state[gx[G_PL_DELTAVIEWHEIGHT]])
    state[gx[G_PL_VIEWHEIGHT]] = vh
    if vh > ST_VIEWHEIGHT
      state[gx[G_PL_VIEWHEIGHT]] = ST_VIEWHEIGHT
      state[gx[G_PL_DELTAVIEWHEIGHT]] = 0
    end
    if state[gx[G_PL_VIEWHEIGHT]] < ST_VIEWHEIGHT / 2
      state[gx[G_PL_VIEWHEIGHT]] = ST_VIEWHEIGHT / 2
      state[gx[G_PL_DELTAVIEWHEIGHT]] = 1 if state[gx[G_PL_DELTAVIEWHEIGHT]] <= 0
    end
    if state[gx[G_PL_DELTAVIEWHEIGHT]] != 0
      d = core_w32_add(state[gx[G_PL_DELTAVIEWHEIGHT]], ST_FRACUNIT / 4)
      d = 1 if d == 0
      state[gx[G_PL_DELTAVIEWHEIGHT]] = d
    end
  end
  vz = core_w32_add(core_w32_add(mobj_z[m], state[gx[G_PL_VIEWHEIGHT]]), vbob)
  top = core_w32_sub(mobj_ceilingz[m], core_w32_mul(4, ST_FRACUNIT))
  vz = top if vz > top
  state[gx[G_PL_VIEWZ]] = vz
  0
end

# --------------------------------------------------------------- line math

# `P_InterceptVector` against the trace
def dc_st_intercept_vector(state, gx, v1x, v1y, v1dx, v1dy)
  den = core_w32_sub(core_fixed_mul(v1dy >> 8, state[gx[G_TRACE_DX]]), core_fixed_mul(v1dx >> 8, state[gx[G_TRACE_DY]]))
  return 0 if den == 0
  num = core_w32_add(core_fixed_mul(core_w32_sub(v1x, state[gx[G_TRACE_X]]) >> 8, v1dy), core_fixed_mul(core_w32_sub(state[gx[G_TRACE_Y]], v1y) >> 8, v1dx))
  core_fixed_div(num, den)
end

# `P_PointOnDivlineSide` against the trace
def dc_st_point_on_divline_side_trace(state, gx, x, y)
  tx = state[gx[G_TRACE_X]]
  ty = state[gx[G_TRACE_Y]]
  tdx = state[gx[G_TRACE_DX]]
  tdy = state[gx[G_TRACE_DY]]
  if tdx == 0
    if x <= tx
      return tdy > 0 ? 1 : 0
    end
    return tdy < 0 ? 1 : 0
  end
  if tdy == 0
    if y <= ty
      return tdx < 0 ? 1 : 0
    end
    return tdx > 0 ? 1 : 0
  end
  dx = core_w32_sub(x, tx)
  dy = core_w32_sub(y, ty)
  # bit 31, the sign of the 32-bit value (C: & 0x80000000)
  if (tdy ^ tdx ^ dx ^ dy) < 0
    return (tdy ^ dx) < 0 ? 1 : 0
  end
  left = core_fixed_mul(tdy >> 8, dx >> 8)
  right = core_fixed_mul(dy >> 8, tdx >> 8)
  right < left ? 0 : 1
end

# `P_DivlineSide` (sight), vanilla's `x == node->y` typo kept
def dc_st_sight_divline_side(x, y, nx, ny, ndx, ndy)
  if ndx == 0
    return 2 if x == nx
    if x <= nx
      return ndy > 0 ? 1 : 0
    end
    return ndy < 0 ? 1 : 0
  end
  if ndy == 0
    return 2 if x == ny
    if y <= ny
      return ndx < 0 ? 1 : 0
    end
    return ndx > 0 ? 1 : 0
  end
  dx = core_w32_sub(x, nx)
  dy = core_w32_sub(y, ny)
  left = core_w32_mul((ndy >> 16), (dx >> 16))
  right = core_w32_mul((dy >> 16), (ndx >> 16))
  return 0 if right < left
  return 2 if left == right
  1
end

# `P_InterceptVector2` against the sight trace
def dc_st_sight_intercept_vector(state, gx, dx0, dy0, ddx, ddy)
  den = core_w32_sub(core_fixed_mul(ddy >> 8, state[gx[G_STRACE_DX]]), core_fixed_mul(ddx >> 8, state[gx[G_STRACE_DY]]))
  return 0 if den == 0
  num = core_w32_add(core_fixed_mul(core_w32_sub(dx0, state[gx[G_STRACE_X]]) >> 8, ddy), core_fixed_mul(core_w32_sub(state[gx[G_STRACE_Y]], dy0) >> 8, ddx))
  core_fixed_div(num, den)
end

# ------------------------------------------------------------------ specials

def dc_st_add_active_plat(activeplats, k)
  i = 0
  while i < ST_MAXPLATS
    if activeplats[i] < 0
      activeplats[i] = k
      return 0
    end
    i += 1
  end
  core_fail(:capacity)
  0
end

def dc_st_remove_active_plat(sector_specialdata, pl_sector, pl_th, th_func, activeplats, k)
  i = 0
  while i < ST_MAXPLATS
    if activeplats[i] == k
      sector_specialdata[pl_sector[k]] = -1
      dc_st_remove_thinker(th_func, pl_th[k])
      activeplats[i] = -1
      return 0
    end
    i += 1
  end
  core_fail(:capacity)
  0
end

def dc_st_new_door(state, gx, dr_th, dr_sector, sector_specialdata, th_next, th_prev, th_func, th_data, sec)
  k = state[gx[G_DR_N]]
  state[gx[G_DR_N]] = k + 1
  if k >= ST_MAXDOORS
    core_fail(:capacity)
  end
  dr_th[k] = dc_st_add_thinker(state, gx, th_next, th_prev, th_func, th_data, ST_TH_DOOR, k)
  sector_specialdata[sec] = dr_th[k]
  dr_sector[k] = sec
  k
end

def dc_st_start_button(button_line, button_where, button_texture, button_timer, line, where, texture, time)
  i = 0
  while i < ST_MAXBUTTONS
    if button_timer[i] == 0
      button_line[i] = line
      button_where[i] = where
      button_texture[i] = texture
      button_timer[i] = time
      return 0
    end
    i += 1
  end
  core_fail(:capacity)
  0
end

# ------------------------------------------------------------ bar, hud, anims

# `StatusBar#calc_pain_offset`
def dc_st_calc_pain_offset(state, gx, health)
  h = health > 100 ? 100 : health
  if h != state[gx[G_SB_PAINHEALTH]]
    state[gx[G_SB_PAINCALC]] = ST_FACESTRIDE * (((100 - h) * ST_NUMPAINFACES) / 101)
    state[gx[G_SB_PAINHEALTH]] = h
  end
  state[gx[G_SB_PAINCALC]]
end

# `Hud#ticker`
def dc_st_hud_ticker(state, gx, msg)
  if state[gx[G_HUD_MESSAGE_COUNTER]] != 0
    state[gx[G_HUD_MESSAGE_COUNTER]] = state[gx[G_HUD_MESSAGE_COUNTER]] - 1
    if state[gx[G_HUD_MESSAGE_COUNTER]] == 0
      state[gx[G_HUD_MESSAGE_ON]] = 0
    end
  end
  if msg != 0
    state[gx[G_HUD_MESSAGE]] = msg
    state[gx[G_HUD_MESSAGE_ON]] = 1
    state[gx[G_HUD_MESSAGE_COUNTER]] = ST_HU_MSGTIMEOUT
  end
  0
end

# `Textures#animate`
def dc_st_animate(num_anims, anim_basepic, anim_numpics, anim_speed, anim_istexture,
                  texturetranslation, flattranslation, leveltime)
  a = 0
  while a < num_anims[0]
    base = anim_basepic[a]
    n = anim_numpics[a]
    sp = anim_speed[a]
    i = base
    while i < base + n
      pic = base + ((leveltime / sp + i) % n)
      if anim_istexture[a] == 1
        texturetranslation[i] = pic
      else
        flattranslation[i] = pic
      end
      i += 1
    end
    a += 1
  end
  0
end
