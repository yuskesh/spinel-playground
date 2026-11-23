# examples/doom/core/board/play.rb — DOOM played from a host keyboard, a CORE application (decision 0025).
#
# Built as examples/doom/core/board/app.rb is (spinel-core-app build --board
# frdm_imxrt1186_cm7 --session-image ... --session-objects ... --net FILE),
# with the same session image: a demo's snapshot, whose map and skill the
# game starts from (0025 point 11). The demo's commands and length are not
# used; the run lasts until it stops or the board is reset.
#
# Per tic, at most one every 1/35 s (point 10: the next tic starts at
# max(this tic's start + P, this tic's end), P = ceil(CYCLES_PER_SECOND / 35);
# a late tic is followed at once, and no step runs to catch up):
#
#   * the exit check: game_exit_requested, set by the last tic's step, stops
#     the run with `X <tic> exit 1` before another step (point 14);
#   * the keys (points 5 to 7 and 13): the time-out first -- 500 ms after the
#     last applied message every key is released, counted once -- then at
#     most `depth` messages from the `keys` channel, each bad, stale,
#     superseded or applied (dequeued = bad + stale + superseded + applied);
#     the applied mask becomes key_state_down's 18 watched keys;
#   * DoomCore.input with no script and no recording; a failure stops the
#     run with `X <tic> input <status>` before the step and the render, so no
#     storage of the failed call is used again (0007);
#   * the rebirth check, the step, the copies, the mode check and the render,
#     as app.rb does them;
#   * the frame over UDP as app.rb sends it (decision 0024, wire format 3),
#     each piece naming the frame's input (point 15): the controller's
#     session id, the sequence number the tic used and the input's state, 0
#     none (session 0, sequence 0), 1 held from an applied message, 2
#     released by the time-out.
#
# THE CONSOLE: `F <tic> <view fnv> <full fnv> <cycles>` per frame as app.rb
# writes it, `B <boot id>` once, `X ...` when it stops, and once a second
# `I <dequeued> <bad> <stale> <superseded> <applied> <tics applied>
# <time-outs>`, the counts since boot, each 16 hexadecimal digits
# (tools/doom/board-frames.rb --play reads them). There is no `D` line: the
# run has no end. The figures are measurements, not realtime claims.
#
# THIS IS NOT A REALTIME APPLICATION, for app.rb's reasons: the step and
# render entries have loops without a derived bound.
require "spinel/core"
require "spinel/net"
core_session "../entries", dtcm: ["renderer_screen"]

state :next_tic, :i32, 1
state :phase, :i32, 1   # 0 running, 2 stopped
state :pending, :i32, 1 # bytes of `line` still to send
state :dig, :u8, 33
state :line, :u8, 136
channel :console, :out, size: 136, depth: 8, uart: true
# the frames, as app.rb sends them (decision 0024, wire format 3)
channel :frames, :out, size: 1301, depth: 64, udp: true
state :pkt, :u8, 1301
state :boot, :u8, 4
# the stream's words, as app.rb's: 0 the boot id seen, 1 next_due, 2
# next_second, 3 frames sent, 4 not sent, 5 dropped, 6 messages dropped, 7
# palette drops, 8 stats drops, 9 not sent before the boot id, 10 the B line
# to write (0 or 1), 11 unused
state :net, :i32, 12
state :bline, :u8, 20
# the keys from the host (decision 0025): the 17-byte K message, from the
# M33 through the inbound OCRAM ring
channel :keys, :in, size: 17, depth: 16, udp: true
state :kmsg, :u8, 17
# the input's words: 0 bound (0 or 1), 1 the controller's session id, 2 the
# last applied sequence number (the high-water), 3 when it was applied, 4
# active (1 holding an applied mask, 0 released), 5 the mask, 6 dequeued, 7
# bad, 8 stale, 9 superseded, 10 applied, 11 tics with an applied message, 12
# time-outs, 13 a message was ever applied (0 or 1), 14 the next tic's start,
# 15 the next I line's time
state :inp, :i32, 16
state :iline, :u8, 136
state :ipend, :i32, 1   # bytes of `iline` still to send
every_ms 1, :tic

module Ring
  core_extern :boot_id, params: {out: [:buf, :u8]}, writes: [:out], isr_ok: false, bound: "iterations 1",
              provider: "ring_boot_id.c"
end

module Frame
  core_extern :digests, params: {screen: [:buf, :u8], view_bytes: :u32, out: [:buf, :u8]},
              reads: [:screen], writes: [:out], isr_ok: false, bound: "iterations 2", provider: "frame_digests.c"
end

# 16 lowercase hex digits of a 32-bit word, as app.rb writes them.
def put_hex(out, pos, v)
  k = 0
  while k < 8
    out[pos + k] = 48
    k += 1
  end
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

def put_le32(out, pos, v)
  out[pos] = v & 255
  out[pos + 1] = core_u32_shr(v, 8) & 255
  out[pos + 2] = core_u32_shr(v, 16) & 255
  out[pos + 3] = core_u32_shr(v, 24) & 255
  pos + 4
end

# A u32 from four bytes, least significant first, as the 32-bit word it is.
def get_le32(b, pos)
  core_w32_add(core_w32_mul(b[pos + 3], 16777216), b[pos + 2] * 65536 + b[pos + 1] * 256 + b[pos])
end

def net_header(pkt, kind, boot)
  pkt[0] = kind
  pkt[1] = 3
  pkt[2] = boot[0]
  pkt[3] = boot[1]
  pkt[4] = boot[2]
  pkt[5] = boot[3]
  6
end

# The key code of the mask's bit i: TiccmdBuilder::WATCHED_KEYS's order
# (decision 0025 point 5): right, left, up, down, strafe left, strafe right,
# fire, use, strafe, speed, then the digits 1 to 8.
def watched_key(i)
  return 174 if i == 0
  return 172 if i == 1
  return 173 if i == 2
  return 175 if i == 3
  return 44 if i == 4
  return 46 if i == 5
  return 157 if i == 6
  return 32 if i == 7
  return 184 if i == 8
  return 182 if i == 9
  39 + i
end

# A K message's checks (point 5), 1 when it is one for this boot: its length,
# kind `K`, version 1, a session id that is not 0, the board's own boot id,
# and the third mask byte's upper six bits 0. Before the boot id is known
# no message is one.
def k_valid(kmsg, n, boot, net)
  return 0 if n != 17 || net[0] == 0
  return 0 if kmsg[0] != 75 || kmsg[1] != 1
  return 0 if kmsg[2] == 0 && kmsg[3] == 0 && kmsg[4] == 0 && kmsg[5] == 0
  return 0 if kmsg[6] != boot[0] || kmsg[7] != boot[1] || kmsg[8] != boot[2] || kmsg[9] != boot[3]
  return 0 if (kmsg[16] & 252) != 0
  1
end

# The keys for this tic (points 6, 7 and 13), at `now` by Clock.cycles32:
# the time-out, then up to the channel's depth of messages, then the mask
# into key_state_down.
def take_keys(now, kmsg, boot, net, inp, key_state_down)
  if inp[4] == 1 && core_w32_sub(now, inp[3]) >= Clock::CYCLES_PER_SECOND / 2
    inp[4] = 0
    inp[5] = 0
    inp[12] = inp[12] + 1
  end
  hw = inp[2]
  cand = 0
  cmask = 0
  # a different session may take over only once the bound one has timed out;
  # a session bound in this tic keeps the tic
  open = 0
  open = 1 if inp[0] == 0 || inp[4] == 0
  bound_now = 0
  k = 0
  more = 1
  while k < 16
    if more == 1
      n = Keys.get(kmsg)
      if n == 0
        more = 0
      else
        inp[6] = inp[6] + 1
        if k_valid(kmsg, n, boot, net) == 0
          inp[7] = inp[7] + 1
        else
          s = get_le32(kmsg, 2)
          seq = get_le32(kmsg, 10)
          mask = kmsg[14] + kmsg[15] * 256 + (kmsg[16] & 3) * 65536
          if bound_now == 0 && open == 1 && (inp[0] == 0 || s != inp[1])
            # a first message: at boot, or a takeover after the time-out;
            # bound at once, taken without a sequence comparison
            inp[0] = 1
            inp[1] = s
            hw = seq
            cand = 1
            cmask = mask
            bound_now = 1
          elsif s != inp[1]
            inp[7] = inp[7] + 1
          elsif core_w32_sub(seq, hw) > 0
            inp[9] = inp[9] + 1 if cand == 1
            hw = seq
            cand = 1
            cmask = mask
          else
            inp[8] = inp[8] + 1
          end
        end
      end
    end
    k += 1
  end
  if cand == 1
    inp[2] = hw
    inp[3] = now
    inp[4] = 1
    inp[5] = cmask
    inp[10] = inp[10] + 1
    inp[11] = inp[11] + 1
    inp[13] = 1
  end
  i = 0
  while i < 256
    key_state_down[i] = 0
    i += 1
  end
  b = 0
  while b < 18
    key_state_down[watched_key(b)] = 1 if (core_u32_shr(inp[5], b) & 1) == 1
    b += 1
  end
  0
end

# The frame's input (point 15): 0 none, 1 held, 2 released by the time-out.
def input_state(inp)
  return 1 if inp[4] == 1
  return 2 if inp[13] == 1
  0
end

# app.rb's stream, with each piece naming the frame's input.
def stream(t, now, renderer_screen, renderer_wad_data, net, pkt, boot, inp)
  if net[0] == 0
    Ring.boot_id(boot)
    if boot[0] == 0 && boot[1] == 0 && boot[2] == 0 && boot[3] == 0
      net[4] = net[4] + 1
      net[9] = net[9] + 1
      return 0
    end
    net[0] = 1
    net[1] = now
    net[2] = now
    net[10] = 1
  end
  period = (Clock::CYCLES_PER_SECOND + 34) / 35
  second = 0
  if core_w32_sub(now, net[2]) >= 0
    n = net_header(pkt, 80, boot)
    i = 0
    while i < 768
      pkt[n + i] = renderer_wad_data[Image::PLAYPAL_OFFSET + i]
      i += 1
    end
    net[7] = net[7] + 1 if Frames.put(pkt, 774) == 0
    net[2] = core_w32_add(net[2], Clock::CYCLES_PER_SECOND)
    second = 1
  end
  ist = input_state(inp)
  session = 0
  seq = 0
  if ist != 0
    session = inp[1]
    seq = inp[2]
  end
  late = core_w32_sub(now, net[1])
  if late < 0
    net[4] = net[4] + 1
  else
    p = 0
    put = 1
    while p < 50
      if put == 1
        n = net_header(pkt, 67, boot)
        n = put_le32(pkt, n, t)
        pkt[n] = p
        pkt[n + 1] = 50
        n = put_le32(pkt, n + 2, session)
        n = put_le32(pkt, n, seq)
        pkt[n] = ist
        base = p * 1280
        i = 0
        while i < 1280
          pkt[21 + i] = renderer_screen[base + i]
          i += 1
        end
        if Frames.put(pkt, 1301) == 0
          put = 0
          net[5] = net[5] + 1
          net[6] = net[6] + 50 - p
        end
      end
      p += 1
    end
    net[3] = net[3] + 1 if put == 1
    if late >= period
      net[1] = core_w32_add(now, period)
    else
      net[1] = core_w32_add(net[1], period)
    end
  end
  if second == 1
    n = net_header(pkt, 83, boot)
    n = put_le32(pkt, n, t)
    n = put_le32(pkt, n, net[3])
    n = put_le32(pkt, n, net[4])
    n = put_le32(pkt, n, net[5])
    n = put_le32(pkt, n, net[6])
    net[8] = net[8] + 1 if Frames.put(pkt, n) == 0
  end
  0
end

# The I line, once a second from the first tic: the input's counts since boot.
def i_line(iline, inp)
  n = put_str(iline, 0, "I ", 2)
  w = 6
  while w < 13
    n = put_hex(iline, n, inp[w])
    if w < 12
      n = put_u8(iline, n, 32)
    end
    w += 1
  end
  put_u8(iline, n, 10)
end

def tic(core_state, core_command, key_state_down, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
        game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
        next_tic, phase, pending, dig, line, pkt, boot, net, bline, kmsg, inp, iline, ipend)
  # a line the channel could not take yet goes first, and nothing else runs
  if pending[0] > 0
    return 0 if Console.put(line, pending[0]) == 0
    pending[0] = 0
  end
  if ipend[0] > 0
    return 0 if Console.put(iline, ipend[0]) == 0
    ipend[0] = 0
  end
  return 0 if phase[0] != 0
  t = next_tic[0]
  c0 = Clock.cycles32
  # the pace: not before this tic's start
  return 0 if t > 0 && core_w32_sub(c0, inp[14]) < 0
  # the exit the last step requested, before another step
  return stop(line, pending, phase, t, "exit", 4, 1) if core_state[Slot::GAME_EXIT_REQUESTED] == 1
  take_keys(c0, kmsg, boot, net, inp, key_state_down)
  st = DoomCore.input(0, t, 0)
  return stop(line, pending, phase, t, "input", 5, st) if st != 0
  # the step, after the rebirth check (PST_REBORN is 2, native_loop.rb)
  return stop(line, pending, phase, t, "reborn", 6, 0) if core_state[Slot::GAME_PL_PLAYERSTATE] == 2
  wipe = 0
  wipe = 320 if t == 2
  st = DoomCore.step(wipe)
  return stop(line, pending, phase, t, "step", 4, st) if st != 0
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
  return stop(line, pending, phase, t, "mode", 4, renderer_jobmode[0]) if renderer_jobmode[0] != 0
  first = 0
  first = 1 if t == 0
  st = DoomCore.render(first, health, armor, ammokind, vx, vy, vz, va)
  return stop(line, pending, phase, t, "render", 6, st) if st != 0
  Frame.digests(renderer_screen, 53760, dig)
  stream(t, Clock.cycles32, renderer_screen, renderer_wad_data, net, pkt, boot, inp)
  c1 = Clock.cycles32
  # the next tic's start: max(this start + P, this end)
  ns = core_w32_add(c0, (Clock::CYCLES_PER_SECOND + 34) / 35)
  ns = c1 if core_w32_sub(c1, ns) > 0
  inp[14] = ns
  if net[10] == 1
    b = put_str(bline, 0, "B ", 2)
    b = put_hex(bline, b, core_w32_add(core_w32_mul(boot[3], 16777216), boot[2] * 65536 + boot[1] * 256 + boot[0]))
    b = put_u8(bline, b, 10)
    net[10] = 0 if Console.put(bline, b) == 1
  end
  if t == 0 || core_w32_sub(c1, inp[15]) >= 0
    ipend[0] = i_line(iline, inp)
    inp[15] = core_w32_add(c1, Clock::CYCLES_PER_SECOND)
  end
  n = put_str(line, 0, "F ", 2)
  n = put_hex(line, n, t)
  n = put_u8(line, n, 32)
  i = 0
  while i < 33
    line[n + i] = dig[i]
    i += 1
  end
  n = put_u8(line, n + 33, 32)
  n = put_hex(line, n, core_w32_sub(c1, c0))
  n = put_u8(line, n, 10)
  pending[0] = n
  next_tic[0] = t + 1
  0
end
