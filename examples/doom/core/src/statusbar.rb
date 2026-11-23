# examples/doom/core/src/statusbar.rb — the status bar's pixels.
#
# GPL-derived, from `examples/doom/lib/doom/statusbar.rb` (`Doom::StatusBar`),
# which reproduces doomgeneric's `st_stuff.c`, `st_lib.c` and `v_video.c`
# (`ST_refreshBackground`, `STlib_updateNum`, `V_DrawPatch`, `V_CopyRect`).
# See ../NOTICE.md and ../sources.tsv.
#
# THIS IS THE REGION NOTHING HAS EVER COMPARED. The frame oracle reports one
# screen of 64000 bytes per frame, and the 10240 bytes below the view -- 16.0%
# of it -- were measured to be ZERO ON BOTH SIDES: the original does not draw
# the status bar in that route and the port had nothing to draw it with. Those
# bytes matched because neither side wrote them. These definitions are what the
# port draws them with, so the comparison there starts meaning something.
#
# THE PATCH FORMAT, since both writers walk it. A patch lump is
#
#   i16 width, i16 height, i16 leftoffset, i16 topoffset,
#   i32 columnofs[width]           -- each relative to the lump's start
#
# and a column is a run of POSTS terminated by 0xff:
#
#   u8 topdelta, u8 length, u8 pad, u8 pixels[length], u8 pad
#
# so a post advances by `length + 4`. The pixels of one post go DOWN a column,
# which is why the destination index steps by the destination's width.
#
# A REFUSAL IS A BARE `core_fail(:capacity)` STATEMENT, not a returned value.
# The lowering treats core_fail as a contract-only intrinsic that never returns,
# and it is recognised in statement position; `return core_fail(...)` reads as a
# call to a method outside the selected closure and is refused as
# unsupported-node. checks.rb calls it the same way.
#
# A REFUSAL IS `capacity` BECAUSE THAT IS THE ONLY ONE THIS VERSION HAS. The
# checker refuses `core_fail(:capacity)` -- "the only application-requested failure
# is core_fail(:capacity)" -- so a patch that would fall outside its destination
# is refused as CAPACITY. The kernel's own BOUNDS status stays what it is: an
# access that actually went out of range, which is a different event from this
# code declining to make one.
#
# A REFUSAL IS A BARE `core_fail(:capacity)` STATEMENT, not a returned value.
# The lowering treats core_fail as a contract-only intrinsic that never returns,
# and it is recognised in statement position; `return core_fail(...)` reads as a
# call to a method outside the selected closure and is refused as
# unsupported-node. checks.rb calls it the same way.
#
# A REFUSAL IS `capacity` BECAUSE THAT IS THE ONLY ONE THIS VERSION HAS. The
# eligibility checker refuses `core_fail(:bounds)` -- "the only
# application-requested failure is core_fail(:capacity)" -- so a patch that would
# fall outside its destination is refused as CAPACITY. The kernel's own BOUNDS
# status stays what it is: an access that actually went out of range, which is a
# different event from this code declining to make one.
#
# EVERY BUFFER IS BORROWED AND EVERY BOUND IS CHECKED. `wad` is the IWAD's
# bytes, a resource CORE only reads; `lump_pos` is the lump directory's offsets,
# also a resource; `dest` is the framebuffer or the status bar's backing store,
# which CORE writes. 0008's roles put the patches and the directory under
# `resource` -- "prepared before play; CORE reads only" -- and the backing store
# under `persistent`, since the record names HUD/status-bar state there.

ST_SCREENWIDTH = 320
ST_SCREENHEIGHT = 200
ST_BAR_HEIGHT = 32
ST_BAR_Y = 168
ST_POST_END = 0xff

# A signed 16-bit little-endian read, and a signed 32-bit one. The original's
# `Doom::Bytes.i16` and `.i32`, which every patch header goes through.
def dc_i16(buf, o)
  v = buf[o] | (buf[o + 1] << 8)
  v >= 0x8000 ? v - 0x10000 : v
end

def dc_i32(buf, o)
  # the top byte placed by a word multiply: the i32 is its signed pattern at once
  buf[o] | (buf[o + 1] << 8) | (buf[o + 2] << 16) | core_w32_mul(buf[o + 3], 16777216)
end

# `V_DrawPatch`: the patch at `lumpnum` into `dest`, whose shape is `dw` by
# `dh`, with its top-left placed at (`x`, `y`) MINUS the patch's own offsets.
# Answers 0. The original raises when the patch would fall outside the
# destination; CORE refuses with BOUNDS, which is the same refusal at the
# boundary rather than an exception.
def dc_draw_patch(dest, wad, lump_pos, dw, dh, x, y, lumpnum)
  p = lump_pos[lumpnum]
  w = dc_i16(wad, p)
  h = dc_i16(wad, p + 2)
  dx = x - dc_i16(wad, p + 4)
  dy = y - dc_i16(wad, p + 6)
  if dx < 0 || dx + w > dw || dy < 0 || dy + h > dh
    core_fail(:capacity)
  end
  col = 0
  while col < w
    c = p + dc_i32(wad, p + 8 + col * 4)
    while true
      td = wad[c]
      break if td == ST_POST_END
      len = wad[c + 1]
      src = c + 3
      o = (dy + td) * dw + dx + col
      k = 0
      while k < len
        dest[o] = wad[src + k]
        o += dw
        k += 1
      end
      c += len + 4
    end
    col += 1
  end
  0
end

# `V_CopyRect(x, y - ST_Y, backing, w, h, x, y)`: `w` by `h` from the status
# bar's backing store into the screen at (`x`, `y`). The backing store is 320
# wide and 32 tall, and the copy's stride is the SCREEN's width on both sides --
# they are equal, which is why one width serves. Answers 0, or refuses with
# BOUNDS for a rectangle outside the bar, as the original raises.
def dc_copy_rect(screen, backing, x, y, w, h)
  if x < 0 || x + w > ST_SCREENWIDTH || y < ST_BAR_Y || y + h > ST_SCREENHEIGHT
    core_fail(:capacity)
  end
  row = 0
  while row < h
    src = (y - ST_BAR_Y + row) * ST_SCREENWIDTH + x
    dst = (y + row) * ST_SCREENWIDTH + x
    k = 0
    while k < w
      screen[dst + k] = backing[src + k]
      k += 1
    end
    row += 1
  end
  0
end

# `ST_refreshBackground`'s restore half: the rectangle a patch occupies, put
# back from the backing store. The patch's own size and offsets decide the
# rectangle, so this reads the header and hands the rest to `dc_copy_rect`.
def dc_copy_rect_from_backing(screen, backing, wad, lump_pos, lumpnum, x, y)
  p = lump_pos[lumpnum]
  w = dc_i16(wad, p)
  h = dc_i16(wad, p + 2)
  cx = x - dc_i16(wad, p + 4)
  cy = y - dc_i16(wad, p + 6)
  dc_copy_rect(screen, backing, cx, cy, w, h)
end

# `ST_refreshBackground`: clear the backing store, draw STBAR into it, and
# transfer the whole of it to the screen at the bar's row. It runs ONCE per
# demo and every later `dc_copy_rect` reads what it leaves, so a wrong one is
# thin in call count and wide in effect.
def dc_refresh_background(screen, backing, wad, lump_pos, sbar)
  n = ST_SCREENWIDTH * ST_BAR_HEIGHT
  i = 0
  while i < n
    backing[i] = 0
    i += 1
  end
  st = dc_draw_patch(backing, wad, lump_pos, ST_SCREENWIDTH, ST_BAR_HEIGHT, 0, 0, sbar)
  return st unless st == 0
  i = 0
  while i < n
    screen[ST_BAR_Y * ST_SCREENWIDTH + i] = backing[i]
    i += 1
  end
  0
end

# `STlib_drawNum`: erase the widget's rectangle from the backing store, then
# draw `num` right-aligned in at most `numdigits` digits of width `w`. 1994 is
# the original's "n/a" -- the erase happens and no digit is drawn. A negative
# value other than that is refused; the original raises on it.
#
# `nums` is the table of digit lump numbers, 0 to 9 at its first ten entries.
SB_NA_GUARD = 1994

def dc_update_num(screen, backing, wad, lump_pos, nums, nx, ny, numdigits, num, w)
  # The original raises on a negative value other than the "n/a" sentinel. CORE
  # refuses with CAPACITY because that is the only application-requested failure
  # this version has -- the same narrowing as the bounds checks above, and the
  # same note: what the refusal MEANS is in this comment, because the status
  # cannot carry it.
  if num < 0 && num != SB_NA_GUARD
    core_fail(:capacity)
  end
  h = dc_i16(wad, lump_pos[nums[0]] + 2)
  st = dc_copy_rect(screen, backing, nx - numdigits * w, ny, w * numdigits, h)
  return st unless st == 0
  return 0 if num == SB_NA_GUARD
  x = nx
  if num == 0
    st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, x - w, ny, nums[0])
    return st unless st == 0
  end
  d = numdigits
  v = num
  while v != 0 && d > 0
    d -= 1
    x -= w
    st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, x, ny, nums[v % 10])
    return st unless st == 0
    v /= 10
  end
  0
end

# `w_arms[i]`'s lump: the yellow digit when the weapon is owned, the grey one
# when it is not. A selector over two prepared tables.
#
# BOTH BRANCHES ARE TAKEN BY ALL THREE DEMOS, measured rather than assumed:
# owned three times and not-owned seven in DEMO1, two and six in DEMO2 and in
# DEMO3. That matters because it is a property of the INPUT and not of this
# definition -- against a demo where the player owned nothing, only one branch
# would ever run, a swapped selector would draw correctly on every frame, and
# this would be a definition that could not be caught being wrong. Nobody
# should assume the coverage transfers to another demo.
def dc_arms_lump(shortnum, armsgray, i, owned)
  owned == 1 ? shortnum[i + 2] : armsgray[i]
end

# ------------------------------------------------------------------ the widget
#
# `ST_Drawer`'s per-frame body, over the fields examples/doom/core/state.tsv
# already declares. THE MANIFEST IS THE CONTRACT: it names old_arms, old_face,
# old_keybox, old_armsbg and firsttime as separate fields, so they arrive as
# separate storage -- the persistent scalars as cells of core_state, the arrays
# as their own buffers, the prepared scalars as one-element buffers. An earlier
# version packed the widget memory into one twelve-cell buffer of its own, which
# 0008 permits in prose but which no manifest declared; this conforms to the
# choice the manifest had already made.
#
# WHAT IS THE PORT'S AND WHAT IS THE GAME'S. old_* and firsttime are the port's
# own memory of what it last drew, so they are written here. faceindex, the key
# boxes and notdeathmatch are the GAME's, computed by the ticker, and are only
# read. health, armor, the ammo and the weapons arrive as the caller's
# arguments, the way render_player_view receives the view.
SB_AMMOX = 44
SB_AMMOY = 171
SB_AMMOWIDTH = 3
SB_HEALTHX = 90
SB_HEALTHY = 171
SB_ARMORX = 221
SB_ARMORY = 171
SB_ARMSX = 111
SB_ARMSY = 172
SB_ARMSXSPACE = 12
SB_ARMSYSPACE = 10
SB_FACESX = 143
SB_FACESY = 168
SB_AMMO0X = 288
SB_AMMO0Y = 173
SB_AMMO1Y = 179
SB_AMMO2Y = 191
SB_AMMO3Y = 185
SB_MAXAMMO0X = 314
SB_ARMSBGX = 104
SB_ARMSBGY = 168
SB_KEY0X = 239
SB_KEY0Y = 171
SB_KEY1Y = 181
SB_KEY2Y = 191
SB_NA = 1994

# One ammo row: the count and the maximum, short digits, at row `y`.
def dc_ammo_pair(screen, backing, wad, lump_pos, shortnum, shortw, y, count, max)
  st = dc_update_num(screen, backing, wad, lump_pos, shortnum, SB_AMMO0X, y, 3, count, shortw)
  return st unless st == 0
  dc_update_num(screen, backing, wad, lump_pos, shortnum, SB_MAXAMMO0X, y, 3, max, shortw)
end

def dc_draw_statusbar(screen, backing, wad, lump_pos, state,
                      old_arms, old_keybox, keyboxes,
                      tallnum, shortnum, armsgray, faces, keys,
                      tallw_b, shortw_b, sbar_b, tallpercent_b, armsbg_b,
                      ammo, maxammo, weaponowned,
                      i_firsttime, i_old_armsbg, i_old_face, i_faceindex, i_notdeathmatch,
                      health, armorpoints, ammokind)
  tallw = tallw_b[0]
  shortw = shortw_b[0]
  tallpercent = tallpercent_b[0]
  armsbg = armsbg_b[0]
  notdeathmatch = state[i_notdeathmatch]
  faceindex = state[i_faceindex]
  refresh = state[i_firsttime]
  if refresh == 1
    state[i_firsttime] = 0
    st = dc_refresh_background(screen, backing, wad, lump_pos, sbar_b[0])
    return st unless st == 0
  end

  # The ready weapon's ammo, tall digits. A weapon with no ammo kind shows the
  # original's "n/a", which erases the widget and draws nothing.
  ready = ammokind < 0 || ammokind >= 4 ? SB_NA : ammo[ammokind]
  st = dc_update_num(screen, backing, wad, lump_pos, tallnum, SB_AMMOX, SB_AMMOY, SB_AMMOWIDTH, ready, tallw)
  return st unless st == 0

  # The four rows one call each, as the original writes them. A loop choosing the
  # row's y from the index compiled to a lookup table in .rodata, and a CORE
  # object that references data is one tick.sh's link rule refuses.
  st = dc_ammo_pair(screen, backing, wad, lump_pos, shortnum, shortw, SB_AMMO0Y, ammo[0], maxammo[0])
  return st unless st == 0
  st = dc_ammo_pair(screen, backing, wad, lump_pos, shortnum, shortw, SB_AMMO1Y, ammo[1], maxammo[1])
  return st unless st == 0
  st = dc_ammo_pair(screen, backing, wad, lump_pos, shortnum, shortw, SB_AMMO2Y, ammo[2], maxammo[2])
  return st unless st == 0
  st = dc_ammo_pair(screen, backing, wad, lump_pos, shortnum, shortw, SB_AMMO3Y, ammo[3], maxammo[3])
  return st unless st == 0

  # health and armor are percent widgets: the `%` is drawn on a refresh only.
  if refresh == 1
    st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, SB_HEALTHX, SB_HEALTHY, tallpercent)
    return st unless st == 0
  end
  st = dc_update_num(screen, backing, wad, lump_pos, tallnum, SB_HEALTHX, SB_HEALTHY, 3, health, tallw)
  return st unless st == 0
  if refresh == 1
    st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, SB_ARMORX, SB_ARMORY, tallpercent)
    return st unless st == 0
  end
  st = dc_update_num(screen, backing, wad, lump_pos, tallnum, SB_ARMORX, SB_ARMORY, 3, armorpoints, tallw)
  return st unless st == 0

  # The arms background is a binary icon: drawn when true, and when false the
  # background is put back in its place.
  if state[i_old_armsbg] != notdeathmatch || refresh == 1
    if notdeathmatch == 1
      st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, SB_ARMSBGX, SB_ARMSBGY, armsbg)
    else
      st = dc_copy_rect_from_backing(screen, backing, wad, lump_pos, armsbg, SB_ARMSBGX, SB_ARMSBGY)
    end
    return st unless st == 0
    state[i_old_armsbg] = notdeathmatch
  end

  i = 0
  while i < 6
    v = weaponowned[i + 1] != 0 ? 1 : 0
    if old_arms[i] != v || refresh == 1
      x = SB_ARMSX + (i % 3) * SB_ARMSXSPACE
      y = SB_ARMSY + (i / 3) * SB_ARMSYSPACE
      if old_arms[i] != -1
        st = dc_copy_rect_from_backing(screen, backing, wad, lump_pos,
                                       dc_arms_lump(shortnum, armsgray, i, old_arms[i]), x, y)
        return st unless st == 0
      end
      st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, x, y,
                         dc_arms_lump(shortnum, armsgray, i, v))
      return st unless st == 0
      old_arms[i] = v
    end
    i += 1
  end

  if (state[i_old_face] != faceindex || refresh == 1) && faceindex != -1
    if state[i_old_face] != -1
      st = dc_copy_rect_from_backing(screen, backing, wad, lump_pos, faces[state[i_old_face]], SB_FACESX, SB_FACESY)
      return st unless st == 0
    end
    st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, SB_FACESX, SB_FACESY, faces[faceindex])
    return st unless st == 0
    state[i_old_face] = faceindex
  end

  i = 0
  while i < 3
    v = keyboxes[i]
    if (old_keybox[i] != v || refresh == 1) && v != -1
      y = i == 0 ? SB_KEY0Y : (i == 1 ? SB_KEY1Y : SB_KEY2Y)
      if old_keybox[i] != -1
        st = dc_copy_rect_from_backing(screen, backing, wad, lump_pos, keys[old_keybox[i]], SB_KEY0X, y)
        return st unless st == 0
      end
      st = dc_draw_patch(screen, wad, lump_pos, ST_SCREENWIDTH, ST_SCREENHEIGHT, SB_KEY0X, y, keys[v])
      return st unless st == 0
      old_keybox[i] = v
    end
    i += 1
  end
  0
end
