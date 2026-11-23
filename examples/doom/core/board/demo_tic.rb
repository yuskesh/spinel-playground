# examples/doom/core/board/demo_tic.rb — the demo's tic, shared by DOOM's board
# applications (decision 0027): app.rb, which also streams the frames over the
# network, and pair.rb, which runs beside the M33's companion. Each requires
# it with `require_relative "demo_tic"`; the build packs it after the
# application, so it holds definitions only.
#
# The console lines are app.rb's (its header): `F <tic> <view fnv> <full fnv>
# <cycles>`, `D <tics>` and `X <tic> <what> <status>`, every number 16
# hexadecimal digits, the first eight zero.

# 16 lowercase hex digits of a 32-bit word, most significant first: eight
# zeros, then the word's own eight (its unsigned reading, so a pattern with
# the top bit set prints as the word, not as a negative number). Shifts and
# masks, so no division; the line keeps the form board-frames.rb reads.
def put_hex(out, pos, v)
  k = 0
  while k < 8
    out[pos + k] = 48
    k += 1
  end
  # its own counter from 0: a loop that starts where another left off has no
  # bound the kernel can derive, and the application entry needs one
  j = 0
  while j < 8
    d = core_u32_shr(v, 28 - 4 * j) & 15
    if d < 10
      out[pos + 8 + j] = 48 + d
    else
      out[pos + 8 + j] = 87 + d
    end
    j += 1
  end
  pos + 16
end

# A byte of the demo lump as the signed value demo.rb makes of it.
def signed8(b)
  if b >= 128
    b - 256
  else
    b
  end
end

def stop(line, pending, phase, t, what, n_what, status)
  n = put_str(line, 0, "X ", 2)
  n = put_hex(line, n, t)
  n = put_u8(line, n, 32)
  n = put_str(line, n, what, n_what)
  n = put_u8(line, n, 32)
  n = put_hex(line, n, status)
  n = put_u8(line, n, 10)
  pending[0] = n
  phase[0] = 2
  0
end

# The demo's end: `D <tics>` as the pending line, and the loop stops.
def demo_end(line, pending, phase, t)
  n = put_str(line, 0, "D ", 2)
  n = put_hex(line, n, t)
  n = put_u8(line, n, 10)
  pending[0] = n
  phase[0] = 1
  0
end

# Tic t of the demo, what native_loop.rb does between the entries: the
# demo's command, the rebirth check, the step, the cells the renderer takes
# from the game, the mode check, the render and the frame's digests into
# `dig`. Answers 1 with the frame drawn, or 0 with an X line pending and the
# loop stopped.
def demo_frame(t, core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
               game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
               phase, pending, dig, line)
  # the demo's command (demo.rb: forward, side, angleturn << 8, buttons)
  o = Image::DEMO_OFFSET + 13 + 4 * t
  core_command[0] = signed8(renderer_wad_data[o])
  core_command[1] = signed8(renderer_wad_data[o + 1])
  a = renderer_wad_data[o + 2] * 256
  if a >= 32768
    a = a - 65536
  end
  core_command[2] = a
  core_command[3] = renderer_wad_data[o + 3]
  core_command[4] = 0
  # the step, after the rebirth check
  # PST_REBORN is 2 (native_loop.rb)
  return stop(line, pending, phase, t, "reborn", 6, 0) if core_state[Slot::GAME_PL_PLAYERSTATE] == 2
  wipe = 0
  wipe = 320 if t == 2
  st = DoomCore.step(wipe)
  return stop(line, pending, phase, t, "step", 4, st) if st != 0
  # what the renderer takes from the game between the entries
  core_state[Slot::RENDERER_PSP_STATE] = game_psp_state[0]
  core_state[Slot::RENDERER_PSP_SX] = game_psp_sx[0]
  core_state[Slot::RENDERER_PSP_SY] = game_psp_sy[0]
  core_state[Slot::RENDERER_PSP1_STATE] = game_psp_state[1]
  core_state[Slot::RENDERER_PSP1_SX] = game_psp_sx[1]
  core_state[Slot::RENDERER_PSP1_SY] = game_psp_sy[1]
  core_state[Slot::RENDERER_EXTRALIGHT] = core_state[Slot::GAME_PL_EXTRALIGHT]
  m = game_player_mo[0]
  health = core_state[Slot::GAME_PL_HEALTH]
  armor = core_state[Slot::GAME_PL_ARMORPOINTS]
  ammokind = game_weapon_ammo[core_state[Slot::GAME_PL_READYWEAPON]]
  vx = game_mobj_x[m]
  vy = game_mobj_y[m]
  vz = core_state[Slot::GAME_PL_VIEWZ]
  va = game_mobj_angle[m]
  # the render, after the mode check: the entry is classified for job mode 0
  return stop(line, pending, phase, t, "mode", 4, renderer_jobmode[0]) if renderer_jobmode[0] != 0
  first = 0
  first = 1 if t == 0
  st = DoomCore.render(first, health, armor, ammokind, vx, vy, vz, va)
  return stop(line, pending, phase, t, "render", 6, st) if st != 0
  # the view is 320 x 168 bytes, bin/doom.rb's default setblocks
  Frame.digests(renderer_screen, 53760, dig)
  1
end

# The tic's F line into `line`: the tic, the two digests and the tic's
# cycles. Answers its length.
def f_line(line, t, dig, cycles)
  n = put_str(line, 0, "F ", 2)
  n = put_hex(line, n, t)
  n = put_u8(line, n, 32)
  i = 0
  while i < 33
    line[n + i] = dig[i]
    i += 1
  end
  n = put_u8(line, n + 33, 32)
  n = put_hex(line, n, cycles)
  put_u8(line, n, 10)
end
