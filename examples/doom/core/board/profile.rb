# examples/doom/core/board/profile.rb — DOOM's board loop, timed by stage.
#
# A measuring variant of examples/doom/core/board/app.rb, built and written
# like it (tools/doom/board-profile.rb reads its console). The loop is
# app.rb's, line for line, with Clock.cycles32 read between the stages (each
# span taken with core_w32_sub), and the digests taken by its own provider
# (Frame.fnv, the same 33 bytes as app.rb's Frame.digests, counted for the
# PC sampler). It writes app.rb's F, D and X lines unchanged, so its frames
# are checked against the recording as the acceptance run's are, and after
# every tenth tic's F line (tics 0, 10, 20, ...) one more line,
#
#   T <tic> <input> <step> <cells> <render> <fnv> <total> <format> <put>
#     <wall> <stalls>
#
# the tic in 16 hex digits and the rest as the low 32 bits of a cycle count,
# 8 hex digits each (32 bits are 17.8 s at 240 MHz):
#
#   input   decoding the demo's command into core_command (this loop never
#           calls DoomCore.input; native_loop.rb does not either);
#   step    the rebirth check and DoomCore.step;
#   cells   the copies and reads between the entries, and the mode check;
#   render  DoomCore.render;
#   fnv     the two FNV-1a 64 digests (view and full), as hex (the board
#           computes no SHA-256: 0021, the owner's decision of 2026-10-21);
#   total   from before the command to after the digests: the span the F
#           line's cycles cover, as in app.rb;
#   format  building the F line after that span;
#   put     Console.put of the previous tic's F line, which happens at the
#           start of this tic's release (copying it into the channel's ring);
#   wall    from the previous tic's start to this tic's start: its release,
#           its tic, the time the scheduler thread slept, and every release
#           whose put found the ring full;
#   stalls  how many of those releases found the ring full.
#
# A put only hands the line to the ring. The transport thread, at the lowest
# application priority, writes it to the UART while this thread sleeps, so
# the time a line takes on the wire is not in any column here.
#
# THIS IS NOT A REALTIME APPLICATION, and the T line is not part of the
# acceptance run: app.rb is the acceptance image.
require "spinel/core"
require "spinel/net"
# the screen in the data TCM (0021, the owner's decision of 2026-10-21): it is
# the renderer's hottest buffer, and the data TCM is where both cores read
# and write fastest
core_session "../entries", dtcm: ["renderer_screen"]

state :next_tic, :i32, 1
state :phase, :i32, 1   # 0 running, 1 the demo ended, 2 stopped
state :pending, :i32, 1 # bytes of `line` still to send
state :fdig, :u8, 33
state :line, :u8, 136
state :mline, :u8, 136
state :mpending, :i32, 1
state :sample, :i32, 1  # tics until the next T line
state :prof, :i32, 3    # the previous tic's start, the last put, stalls since
channel :console, :out, size: 136, depth: 8, uart: true
every_ms 1, :tic

module Frame
  core_extern :fnv, params: {screen: [:buf, :u8], view_bytes: :u32, out: [:buf, :u8]},
              reads: [:screen], writes: [:out], isr_ok: false, bound: "iterations 2", provider: "profile_digests.c"
end

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

# a space, then 8 hex digits of the low 32 bits
def put_field(out, pos, v)
  out[pos] = 32
  k = 0
  while k < 8
    d = (v >> (28 - 4 * k)) & 15
    if d < 10
      out[pos + 1 + k] = 48 + d
    else
      out[pos + 1 + k] = 87 + d
    end
    k += 1
  end
  pos + 9
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

def tic(core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
        game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
        next_tic, phase, pending, fdig, line, mline, mpending, sample, prof)
  # a line the channel could not take yet goes first, and nothing else runs
  if pending[0] > 0
    p0 = Clock.cycles32
    if Console.put(line, pending[0]) == 0
      prof[2] = prof[2] + 1
      return 0
    end
    prof[1] = core_w32_sub(Clock.cycles32, p0)
    pending[0] = 0
  end
  if mpending[0] > 0
    return 0 if Console.put(mline, mpending[0]) == 0
    mpending[0] = 0
  end
  return 0 if phase[0] != 0
  t = next_tic[0]
  if t >= Image::DEMO_TICS
    n = put_str(line, 0, "D ", 2)
    n = put_hex(line, n, t)
    n = put_u8(line, n, 10)
    pending[0] = n
    phase[0] = 1
    return 0
  end
  c0 = Clock.cycles32
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
  c_in = Clock.cycles32
  # the step, after the rebirth check
  # PST_REBORN is 2 (native_loop.rb)
  return stop(line, pending, phase, t, "reborn", 6, 0) if core_state[Slot::GAME_PL_PLAYERSTATE] == 2
  wipe = 0
  wipe = 320 if t == 2
  st = DoomCore.step(wipe)
  return stop(line, pending, phase, t, "step", 4, st) if st != 0
  c_st = Clock.cycles32
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
  c_ce = Clock.cycles32
  st = DoomCore.render(first, health, armor, ammokind, vx, vy, vz, va)
  return stop(line, pending, phase, t, "render", 6, st) if st != 0
  c_rn = Clock.cycles32
  # the view is 320 x 168 bytes, bin/doom.rb's default setblocks
  Frame.fnv(renderer_screen, 53760, fdig)
  c1 = Clock.cycles32
  n = put_str(line, 0, "F ", 2)
  n = put_hex(line, n, t)
  n = put_u8(line, n, 32)
  i = 0
  while i < 33
    line[n + i] = fdig[i]
    i += 1
  end
  n = put_u8(line, n + 33, 32)
  n = put_hex(line, n, core_w32_sub(c1, c0))
  n = put_u8(line, n, 10)
  pending[0] = n
  c_fm = Clock.cycles32
  if sample[0] == 0
    k = put_str(mline, 0, "T ", 2)
    k = put_hex(mline, k, t)
    k = put_field(mline, k, core_w32_sub(c_in, c0))
    k = put_field(mline, k, core_w32_sub(c_st, c_in))
    k = put_field(mline, k, core_w32_sub(c_ce, c_st))
    k = put_field(mline, k, core_w32_sub(c_rn, c_ce))
    k = put_field(mline, k, core_w32_sub(c1, c_rn))
    k = put_field(mline, k, core_w32_sub(c1, c0))
    k = put_field(mline, k, core_w32_sub(c_fm, c1))
    k = put_field(mline, k, prof[1])
    w = 0
    w = core_w32_sub(c0, prof[0]) if t > 0
    k = put_field(mline, k, w)
    k = put_field(mline, k, prof[2])
    k = put_u8(mline, k, 10)
    mpending[0] = k
    sample[0] = 9
  else
    sample[0] = sample[0] - 1
  end
  prof[0] = c0
  prof[2] = 0
  next_tic[0] = t + 1
  0
end
