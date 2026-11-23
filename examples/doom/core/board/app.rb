# examples/doom/core/board/app.rb — DOOM's board loop, a CORE application (decision 0021).
#
# Built by tools/app's `spinel-core-app build --board frdm_imxrt1186` with
# `--session-image` (a demo's session image, tools/doom/session-image.rb
# --demo) and `--session-objects` (the three entries built for the target).
# Per tic it does what examples/doom/core/full/native_loop.rb does between the
# entries when bin/doom.rb -core plays a demo, and nothing else:
#
#   * the demo's command for the tic into core_command, decoded from the demo
#     lump in the IWAD the image holds as examples/doom/lib/doom/demo.rb
#     decodes it;
#   * the rebirth check (no pending PST_REBORN), then the step entry, with the
#     melt wipe's 320 draws before gametic 2;
#   * the weapon sprites and the extra light copied from the game's cells to
#     the renderer's, and the render entry's eight values read off the cells;
#   * the mode check (renderer_jobmode is 0), then the render entry.
#
# It loads no WAD and opens no session: the session is the image's, placed by
# the build. After each frame it writes one console line,
#
#   F <tic> <view fnv> <full fnv> <cycles>
#
# the two FNV-1a 64 digests bin/doom.rb -frames records (the board lane
# compares them with tests/doom-core/fixtures/screens) and the tic's cycles
# from before the command to after the digests. The board computes no
# SHA-256 (0021, the owner's decision of 2026-10-21). When the demo ends it
# writes `D <tics>`. A failing entry writes `X <tic> <entry>
# <status>` with the entry's 0007 status, a refused check `X <tic> <check>
# <value>`, and the loop stops. Every number is 16 hexadecimal digits, the
# first eight zero: the application computes at the target's 32 bits
# (decision 0022), and the line keeps the form tools/doom/board-frames.rb
# reads, chosen when it computed at 64 bits, where a decimal digit needed a
# runtime helper call that 0014 refuses in an application entry. The tic's
# cycles are a span of Clock.cycles32, taken with core_w32_sub.
#
# THIS IS NOT A REALTIME APPLICATION. The step and render entries have loops
# without a derived bound, so this entry is built under the realtime profile
# with loop_bound unknown through DoomCore: not a realtime claim. One tic runs
# per release; a tic longer than the period skips releases.
require "spinel/core"
require "spinel/net"
# the demo's tic, shared with pair.rb (decision 0027)
require_relative "demo_tic"
# the screen in the data TCM (0021, the owner's decision of 2026-10-21): it is
# the renderer's hottest buffer, and the data TCM is where both cores read
# and write fastest
core_session "../entries", dtcm: ["renderer_screen"]

state :next_tic, :i32, 1
state :phase, :i32, 1   # 0 running, 1 the demo ended, 2 stopped
state :pending, :i32, 1 # bytes of `line` still to send
state :dig, :u8, 33
state :line, :u8, 136
channel :console, :out, size: 136, depth: 8, uart: true
# DOOM's frames over UDP (decision 0024, wire format 3 since decision 0025):
# on this board the udp: channel's consumer is the M33's network firmware,
# through the OCRAM ring (the board table's udp_consumer); the endpoint is the
# network file's. A message is at most a frame's piece, 21 + 1280 bytes.
channel :frames, :out, size: 1301, depth: 64, udp: true
state :pkt, :u8, 1301
state :boot, :u8, 4
# the stream's words: 0 the boot id seen (0 or 1), 1 next_due, 2 next_second,
# 3 frames sent, 4 not sent, 5 dropped, 6 messages dropped, 7 palette drops,
# 8 stats drops, 9 not sent before the boot id, 10 the B line to write (0 or 1),
# 11 the N line written (0 or 1)
state :net, :i32, 12
# the B line, a console message of its own (tools/doom/board-frames.rb reads one
# line per message)
state :bline, :u8, 20
every_ms 1, :tic

# The boot id the M33 publishes once it has its address (decision 0024): one
# load of the ring's shared word, never waiting; 0 until then.
module Ring
  core_extern :boot_id, params: {out: [:buf, :u8]}, writes: [:out], isr_ok: false, bound: "iterations 1",
              provider: "ring_boot_id.c"
end

module Frame
  core_extern :digests, params: {screen: [:buf, :u8], view_bytes: :u32, out: [:buf, :u8]},
              reads: [:screen], writes: [:out], isr_ok: false, bound: "iterations 2", provider: "frame_digests.c"
end

# A u32 into four bytes, least significant first (the wire's integers).
def put_le32(out, pos, v)
  out[pos] = v & 255
  out[pos + 1] = core_u32_shr(v, 8) & 255
  out[pos + 2] = core_u32_shr(v, 16) & 255
  out[pos + 3] = core_u32_shr(v, 24) & 255
  pos + 4
end

# The wire's common header (decision 0024, version 3 since decision 0025):
# kind, 3, the boot id.
def net_header(pkt, kind, boot)
  pkt[0] = kind
  pkt[1] = 3
  pkt[2] = boot[0]
  pkt[3] = boot[1]
  pkt[4] = boot[2]
  pkt[5] = boot[3]
  6
end

# The tic's part of the stream (decision 0024's amendment, wire format 3),
# at `now` by Clock.cycles32:
#   * until the M33 has published a boot id, nothing is put and the frame is
#     not sent;
#   * at the first tic of each second, the palette (PLAYPAL's first, from the
#     WAD) before the frame and the stream's counts after it; a refused one is
#     a palette or a stats drop, counted apart from the frames;
#   * the frame is due by time, at most 35 a second, keeping the average's
#     phase: the period is ceil(Clock::CYCLES_PER_SECOND / 35); a sent frame
#     moves next_due on by a period, and a tic more than a period late moves
#     it to now plus a period, so no extra frame is sent to catch up (the
#     differences hold below 2^31 cycles);
#   * a due frame is 50 pieces of 1280 bytes; a refused piece drops the rest
#     of the frame. Each piece's header names the frame's input (decision
#     0025): a demo takes no keys, so every piece says no input -- session 0,
#     sequence 0, state 0.
def stream(t, now, renderer_screen, renderer_wad_data, net, pkt, boot)
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
        # the input: none (session 0, sequence 0, state 0)
        n = put_le32(pkt, n + 2, 0)
        n = put_le32(pkt, n, 0)
        pkt[n] = 0
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
    # the counts after this tic: sent + not sent + dropped = t + 1
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

def tic(core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
        game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
        next_tic, phase, pending, dig, line, pkt, boot, net, bline)
  # a line the channel could not take yet goes first, and nothing else runs
  if pending[0] > 0
    return 0 if Console.put(line, pending[0]) == 0
    pending[0] = 0
  end
  return 0 if phase[0] != 0
  t = next_tic[0]
  if t >= Image::DEMO_TICS
    if net[11] == 0
      # the stream's drops and the frames not sent, then at the next release
      # the end (decision 0024): each a console message of its own
      n = put_str(line, 0, "N ", 2)
      n = put_hex(line, n, net[5])
      n = put_u8(line, n, 32)
      n = put_hex(line, n, net[6])
      n = put_u8(line, n, 32)
      n = put_hex(line, n, net[4])
      n = put_u8(line, n, 10)
      pending[0] = n
      net[11] = 1
      return 0
    end
    return demo_end(line, pending, phase, t)
  end
  c0 = Clock.cycles32
  return 0 if demo_frame(t, core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
                         game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
                         phase, pending, dig, line) == 0
  # the frame over the network (decision 0024), inside the tic's cycles
  stream(t, Clock.cycles32, renderer_screen, renderer_wad_data, net, pkt, boot)
  c1 = Clock.cycles32
  if net[10] == 1
    # the boot id, once, before the F line of the first tic that saw it: its
    # own message, put now (this tic's F line goes at the next release); a
    # full channel tries again at the next tic, still before that tic's F line
    b = put_str(bline, 0, "B ", 2)
    b = put_hex(bline, b, core_w32_add(core_w32_mul(boot[3], 16777216), boot[2] * 65536 + boot[1] * 256 + boot[0]))
    b = put_u8(bline, b, 10)
    net[10] = 0 if Console.put(bline, b) == 1
  end
  pending[0] = f_line(line, t, dig, core_w32_sub(c1, c0))
  next_tic[0] = t + 1
  0
end
