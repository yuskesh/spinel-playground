# doom/bin/bench_tic.rb
#
#   bench_tic <doom1.wad> <DEMOLUMP> <ntics> [mode]
#
# `mode` (default 0):
#   0  tic simulation only (`G_Ticker` / `P_Ticker`): **the cost of the game logic**
#   1  tic + drawing the 3D view (`R_RenderPlayerView` + **ST_Drawer** + HUD)
#      : one frame of the real game, including the status bar (all of 320x200)
#   2  **the same work as mode 1, through the Job IR route**.
#      The difference between 1 and 2 is exactly the overhead of making and interpreting jobs
#
# **It writes no output at all.** `bin/sim_demo.rb`, for the differential oracle, writes
# TSV every tic, so timing that one is dominated by I/O.
#
# **The clock is never read inside the process.** hyperfine measures from outside, and
# the fixed cost of start-up + reading the WAD + building the level + composing textures
# is cancelled by the difference between 2 values of `ntics`.
#
# Allocation can be measured with the same binary:
#   SPINEL_ALLOC_REPORT=1 bench_tic ...
#   DYLD_INSERT_LIBRARIES=malloc_count.dylib …  (R007 §2.1)

require_relative "../lib/doom/wad"
require_relative "../lib/doom/level"
require_relative "../lib/doom/texnames"
require_relative "../lib/doom/texture"
require_relative "../lib/doom/sprites"
require_relative "../lib/doom/statusbar"
require_relative "../lib/doom/hud"
require_relative "../lib/doom/render"
require_relative "../lib/doom/info"
require_relative "../lib/doom/random"
require_relative "../lib/doom/demo"
require_relative "../lib/doom/game"

def main
  if ARGV.length < 3
    $stderr.puts "usage: bench_tic <wad> <DEMOLUMP> <ntics> [mode]"
    exit 1
  end
  wad = Doom::Wad.new(ARGV[0])
  demo = Doom::Demo.new(wad, ARGV[1], "")
  ntics = ARGV[2].to_i
  mode = ARGV.length > 3 ? ARGV[3].to_i : 0

  lv = Doom::Level.new(wad, demo.mapname, demo.episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)
  rnd = Doom::Random.new
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)

  if mode >= 1
    colormap = wad.bytes_by_name("COLORMAP")
    sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
    hud = Doom::Hud.new(wad, 320, 200, 1)
    sb = Doom::StatusBar.new(wad)
    sb.start(g.pl_weaponowned)
    weapon_ammo = Doom::Info.weapon_ammo
    r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, 1)
    r.job_mode = mode == 2 ? 1 : 0
    r.clear_screen
  end

  n = ntics < demo.numtics ? ntics : demo.numtics
  t = 0
  acc = 0
  while t < n
    if t == 2
      k = 0
      while k < 320
        rnd.m_random
        k += 1
      end
    end
    g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
    st_randomnumber = rnd.m_random
    if mode >= 1
      m = g.player_mo
      atk = g.pl_attacker
      kind = atk < 0 ? Doom::StatusBar::ATTACKER_NONE :
             (atk == m ? Doom::StatusBar::ATTACKER_SELF : Doom::StatusBar::ATTACKER_OTHER)
      bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m],
                                         g.mobj_x[atk], g.mobj_y[atk]) : 0
      sb.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards,
                g.pl_damagecount, g.pl_bonuscount, g.pl_attackdown,
                g.pl_powers[0], kind, bga, g.mobj_angle[m])
      hud.ticker(g.take_message)
      r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
      r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
      r.extralight = g.extralight
      r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
      sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
              g.pl_weaponowned, g.pl_readyweapon, weapon_ammo[g.pl_readyweapon])
      hud.draw(r.screen)
      acc += r.screen.getbyte(32000)
    else
      acc += g.mobj_x[g.player_mo] & 255
    end
    t += 1
  end
  $stderr.puts "bench_tic: mode=#{mode} tics=#{n} acc=#{acc} prnd=#{rnd.prndindex}"
end

main
