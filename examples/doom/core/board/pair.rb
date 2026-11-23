# examples/doom/core/board/pair.rb — DOOM's board loop beside the M33's Spinel
# companion (decision 0027): app.rb's demo, without its network stream.
#
# Built with `spinel-core-app build --board frdm_imxrt1186_cm7 --companion
# companion.rb`, the session image and the entries as app.rb is. The M33 runs
# companion.rb, not the network firmware: a build of the pair with a udp:
# channel is refused (owner, 2026-10-26), so this application has none, and
# no boot id, B line or N line.
#
# Per tic it does what app.rb does, through the shared demo_tic.rb: the demo's
# command, the step, the cells, the render and the digests, then one console
# line, `F <tic> <view fnv> <full fnv> <cycles>`; `D <tics>` at the demo's end
# and `X ...` on a failure, as app.rb's header says.
#
# Its console is the M33's (decision 0027 stage 2): each line goes into the
# `console` channel of channels/console.channel, its tic, its length and its
# text, and companion.rb writes it to LPUART1. A line the channel refuses is
# tried again at the next release, and nothing else runs until it is taken;
# every try is counted (the channel's P line).
#
# THIS IS NOT A REALTIME APPLICATION, for app.rb's reason.
require "spinel/core"
require "spinel/net"
# the demo's tic, shared with app.rb
require_relative "demo_tic"
# the screen in the data TCM, as app.rb
core_session "../entries", dtcm: ["renderer_screen"]

state :next_tic, :i32, 1
state :phase, :i32, 1   # 0 running, 1 the demo ended, 2 stopped
state :pending, :i32, 1 # bytes of `line` still to send
state :line_tic, :i32, 1 # the tic of the pending line
state :dig, :u8, 33
state :line, :u8, 119 # the F line is 70 bytes; the channel's text is 119
channel :console, contract: "channels/console.channel"
every_ms 1, :tic

module Frame
  core_extern :digests, params: {screen: [:buf, :u8], view_bytes: :u32, out: [:buf, :u8]},
              reads: [:screen], writes: [:out], isr_ok: false, bound: "iterations 2", provider: "frame_digests.c"
end

def tic(core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
        game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
        next_tic, phase, pending, line_tic, dig, line)
  # a line the channel could not take yet goes first, and nothing else runs
  if pending[0] > 0
    return 0 if Console.put(line_tic[0], pending[0], line) == 0
    pending[0] = 0
  end
  return 0 if phase[0] != 0
  t = next_tic[0]
  line_tic[0] = t
  return demo_end(line, pending, phase, t) if t >= Image::DEMO_TICS
  c0 = Clock.cycles32
  return 0 if demo_frame(t, core_state, core_command, renderer_wad_data, renderer_jobmode, game_player_mo, game_weapon_ammo,
                         game_psp_state, game_psp_sx, game_psp_sy, game_mobj_x, game_mobj_y, game_mobj_angle, renderer_screen,
                         phase, pending, dig, line) == 0
  c1 = Clock.cycles32
  pending[0] = f_line(line, t, dig, core_w32_sub(c1, c0))
  next_tic[0] = t + 1
  0
end
