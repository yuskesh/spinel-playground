# doom/bin/record_demo.rb
#
#   record_demo <doom1.wad> <script> <skill> <episode> <map> <outdir> <ntics>
#
# **Runs synthetic input (`KeyScript` in `lib/doom/input.rb`) through `G_BuildTiccmd`
# to advance the game, and records that input sequence in a `.lmp`.**
#
# An agent cannot give human input, so the correctness of interactive play is shown not by
# "a person could play" but by **"the recorded demo makes the same picture in the reference implementation"**:
#
#   record_demo ...          -> out/demo.lmp + out/frames.tsv   (the live picture while recording)
#   sim_demo ... @out/demo.lmp -> this port's playback            (frames.tsv)
#   doomgeneric -timedemo out/demo.lmp -> the reference playback (frames.tsv)
#
# If all 3 hash sequences match, the round trip
# **`G_BuildTiccmd` -> `.lmp` -> playback** makes the same world as the reference implementation.
#
# **It does not touch SDL** (it does not require `lib/doom/video.rb`), so
# this program **runs under both Spinel and CRuby**: the conventions' CRuby differential
# applies as it is. Interactive play (`bin/doom.rb`) only drives the same `TiccmdBuilder`
# with SDL's key state.

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
require_relative "../lib/doom/game"
require_relative "../lib/doom/bytes"
require_relative "../lib/doom/input"
require_relative "../lib/doom/record"

def main
  if ARGV.length < 7
    $stderr.puts "usage: record_demo <wad> <script> <skill> <episode> <map> <outdir> <ntics>"
    exit 1
  end
  wad = Doom::Wad.new(ARGV[0])
  script = Doom::KeyScript.new(ARGV[1])
  skill = ARGV[2].to_i
  episode = ARGV[3].to_i
  map = ARGV[4].to_i
  dir = ARGV[5]
  ntics = ARGV[6].to_i

  mapname = "E#{episode}M#{map}"
  lv = Doom::Level.new(wad, mapname, episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)

  rnd = Doom::Random.new
  rnd.clear                                   # `G_InitNew` -> `M_ClearRandom`
  g = Doom::Game.new(wad, lv, skill, rnd, tx)

  colormap = wad.bytes_by_name("COLORMAP")
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  sb = Doom::StatusBar.new(wad)
  sb.start(g.pl_weaponowned)
  weapon_ammo = Doom::Info.weapon_ammo
  hud = Doom::Hud.new(wad, 320, 200, 1)
  r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, 1)
  # Adding "jobs" at the end draws through the Job IR route.
  # **The old route stays the default** (the CPU version is the permanent right answer).
  r.job_mode = ARGV.length > 7 && ARGV[7] == "jobs" ? 1 : 0

  ks = Doom::KeyState.new
  tc = Doom::TiccmdBuilder.new
  rec = Doom::DemoWriter.new(skill, episode, map, ntics)

  fr = File.open("#{dir}/frames.tsv", "w")
  fr.puts("#gametic\tviewhash\tfullhash")
  cf = File.open("#{dir}/cmds.tsv", "w")
  cf.puts("#gametic\tforwardmove\tsidemove\tangleturn\tbuttons")

  t = 0
  while t < ntics
    rnd.tic = t
    # The reference harness's melt wipe draws `M_Random` 320 times (as in sim_demo).
    # To make the picture while recording **the same as the picture on playback**, draw as many here too.
    if t == 2
      k = 0
      while k < 320
        rnd.m_random
        k += 1
      end
    end

    script.apply(ks, t)
    tc.build(ks.down)
    # `G_WriteDemoTiccmd` reads back what it has just written. The angle is quantized to 8 bits,
    # and **the live game being recorded also runs on the quantized value**.
    ab = tc.quantize_angle!
    rec.write_tic(tc.forwardmove, tc.sidemove, ab, tc.buttons)
    cf.puts("#{t}\t#{tc.forwardmove}\t#{tc.sidemove}\t#{tc.angleturn}\t#{tc.buttons}")

    g.g_ticker(tc.forwardmove, tc.sidemove, tc.angleturn, tc.buttons)
    st_randomnumber = rnd.m_random
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

    r.clear_screen if t == 0
    r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
    r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
    r.extralight = g.extralight
    r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
    ak = weapon_ammo[g.pl_readyweapon]
    sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
            g.pl_weaponowned, g.pl_readyweapon, ak)
    hud.draw(r.screen)
    fr.puts("#{t}\t#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, 320 * 168)}\t" \
            "#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, 320 * 200)}")
    t += 1
  end

  fr.close
  cf.close
  rec.save("#{dir}/demo.lmp")
  $stderr.puts "record_demo: #{rec.numtics} tics -> #{dir}/demo.lmp " \
               "(#{mapname} skill #{skill}), P_Random calls=#{rnd.pcount}"
end

main
