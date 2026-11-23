# doom/bin/sim_demo.rb
#
#   sim_demo <doom1.wad> <DEMOLUMP> <ntics> <outdir> [what] [mobj_every]
#            [dump_tics] [resscale]
#
# The 8th argument is **the internal resolution's multiplier** (default 1).
#   Comparison with the reference implementation means something only at 1 (= 320x200),
#   but it is needed to **measure again at high resolution** the distribution of
#   `jobstat` (K / the ring's high-water mark): "high resolution is not a copy".
#
# The tic simulation. It **writes the same things under the same key (gametic)** as the
# reference implementation's harness (`doomgeneric_e052.c`) and compares them.
#
#   rand.tsv     the call sequence of P_Random / M_Random (the staged oracle's L5)
#                : **the strongest intermediate oracle, standing before frame matching**
#   player.tsv   the player's state, one line per tic
#   mobjs.tsv    snapshots of the thinker list (the same period as `DG_E052_MOBJ_EVERY`)
#   frames.tsv   fnv1a64 of the 8-bit frame buffer (L6)
#
# `what` is a subset of "rand,player,mobj,frame" (the default is the 3 without frame;
# frame runs the renderer and is an order of magnitude slower).
#
# It runs **like `-timedemo`**: 1 tic = 1 frame. The reference harness sticks at gametic 2
# for 41 frames with the melt wipe from GS_DEMOSCREEN, so the comparison is keyed by
# **gametic**, not the frame number.

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
require_relative "../lib/doom/bytes"
require_relative "../lib/doom/hires"

def main
  if ARGV.length < 4
    $stderr.puts "usage: sim_demo <wad> <DEMOLUMP> <ntics> <outdir> [what]"
    exit 1
  end
  wad = Doom::Wad.new(ARGV[0])
  demoname = ARGV[1]
  ntics = ARGV[2].to_i
  dir = ARGV[3]
  what = ARGV.length > 4 ? ARGV[4] : "rand,player,mobj"
  @mobj_every = ARGV.length > 5 ? ARGV[5].to_i : 1
  @dump_tics = ARGV.length > 6 ? ARGV[6].split(",").map { |v| v.to_i } : []
  rs = ARGV.length > 7 ? ARGV[7].to_i : 1
  rs = 1 if rs < 1
  want_rand = what.include?("rand")
  want_player = what.include?("player")
  want_mobj = what.include?("mobj")
  want_frame = what.include?("frame")
  # Choosing the drawing route. **The old route is not removed**:
  # `jobs` gives the Job IR route (the checker strict), and `jobstat` a statistics
  # mode that only counts with the checker. The old route is the default.
  jobmode = what.include?("jobstat") ? 2 : (what.include?("jobs") ? 1 : 0)
  # Adding `spanid` checks **the closed-form identity of spans** on every span pixel
  # every frame (`Jobs#check_span_closed`).
  # It slows down in proportion to a frame's span pixels, so it does not run by default.
  want_spanid = what.include?("spanid") ? 1 : 0
  # Adding `maskid` measures every frame **the overlap distribution of masked jobs**,
  # **the safety of the reordering that moves fuzz to a later pass**, and **the pixel
  # coverage of the opaque pass (walls + sky + spans)**. Both slow down in proportion to
  # masked/drawn pixels, so they do not run by default (the same position as spans' `spanid`).
  want_maskid = what.include?("maskid") ? 1 : 0

  # If `<DEMOLUMP>` starts with `@`, the rest is read as **the path of a `.lmp`
  # file** (to play what `bin/record_demo.rb` recorded).
  # The reference implementation takes the same file with `-timedemo <path>`.
  if demoname[0] == "@"
    demopath = demoname.byteslice(1, demoname.bytesize - 1)
    demo = Doom::Demo.new(wad, demopath, demopath)
  else
    demo = Doom::Demo.new(wad, demoname, "")
  end
  mapname = demo.mapname
  lv = Doom::Level.new(wad, mapname, demo.episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)

  rnd = Doom::Random.new
  rnd.trace!(4_000_000) if want_rand
  # `G_InitNew` -> `M_ClearRandom` -> `P_SetupLevel`
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)

  if want_frame
    colormap = wad.bytes_by_name("COLORMAP")
    sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
    sb = Doom::StatusBar.new(wad)
    sb.start(g.pl_weaponowned)          # `ST_Start` -> `ST_initData`
    weapon_ammo = Doom::Info.weapon_ammo
    # setblocks 10 = a 320x168 view + the status bar (the reference implementation's default).
    r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, rs)
    sw = r.screenwidth
    sh = r.screenheight
    vh = r.viewheight
    hud = Doom::Hud.new(wad, sw, sh, rs)
    # With s > 1 the status bar is drawn into a 320x200 shadow and copied s times
    # (`lib/doom/hires.rb`). At s = 1 there is no shadow; it draws straight to the real screen.
    sbshadow = Doom::Bytes.buffer(rs == 1 ? 1 : 320 * 200, 0)
    r.job_mode = jobmode
    fr = File.open("#{dir}/frames.tsv", "w")
    # Writes **both the top 168 lines (the 3D view) and all 200 lines (with the status
    # bar)**. They correspond to the `viewhash` and `fnv1a64` columns of the reference side's
    # `frames.tsv`. The central milestone of the tic simulation is the latter.
    fr.puts("#gametic\tviewhash\tfullhash")
  end
  jf = nil
  if want_frame && jobmode != 0
    jf = File.open("#{dir}/jobs.tsv", "w")
    # 5 columns were added (additive). `span_max_kx` / `span_ov` are check #10, and
    # `sp_bad` / `sp_px` / `sp_carry` the running totals of the closed-form identity.
    # 15 more columns were added (additive). `m_max_kx` / `fz_max_kx` / `wall_all_*` are
    # checks #12 / #13 every frame; the rest are measurements that run only with `maskid`.
    jf.puts("#gametic\twall\tspan\tmasked\tsched\tzone\tmax_k\toverlaps\t" \
            "span_max_kx\tspan_ov\tsp_bad\tsp_px\tsp_carry\t" \
            "m_max_kx\tfz_max_kx\tfz_n\twall_all_max_k\twall_all_ov\t" \
            "m_ovpairs\tm_ovpx\tm_coverpx\tfz_conf\tfz_raw\tfz_badrange\t" \
            "fz_suffix\tcov_dbl\tcov_bad\tcov_oob\tcov_px\t" \
            "m_runs\tm_run_maxk\tfz_run_raw\tm_disp\tfz_chain")
  end

  pf = nil
  if want_player
    pf = File.open("#{dir}/player.tsv", "w")
    pf.puts("#gametic\tleveltime\tprndindex\trndindex\trandcalls\t" \
            "fwd\tside\taturn\tbuttons\t" \
            "x\ty\tz\tangle\tmomx\tmomy\tmomz\t" \
            "floorz\tceilingz\tsubsector\tstate\ttics\tsprite\tframe\thealth\t" \
            "viewz\tviewheight\tdeltaviewheight\tbob\t" \
            "armorpoints\tplayerstate\treadyweapon\tpendingweapon\t" \
            "attackdown\tusedown\trefire\tkillcount\titemcount\tsecretcount\t" \
            "extralight\tfixedcolormap\tdamagecount\tbonuscount\t" \
            "psp0state\tpsp0sx\tpsp0sy\tpsp1state\tnthinkers")
  end
  mf = nil
  if want_mobj
    mf = File.open("#{dir}/mobjs.tsv", "w")
    mf.puts("#gametic\tslot\tkind\ttype\tx\ty\tz\tangle\tmomx\tmomy\tmomz\t" \
            "state\ttics\tsprite\tframe\tflags\thealth\tmovedir\tmovecount\t" \
            "reactiontime\tthreshold\ttarget\tfloorz\tceilingz")
  end

  n = ntics < demo.numtics ? ntics : demo.numtics
  t = 0
  prev_pcount = 0
  while t < n
    rnd.tic = t
    # The reference harness's melt wipe (`f_wipe.c:wipe_initMelt`) draws
    # **`M_Random` 320 times**. It happens once, at the GS_DEMOSCREEN -> GS_LEVEL transition
    # (between drawing gametic 1 and gametic 2's G_Ticker).
    # The game logic uses only `P_Random`, so **it does not affect play**, but
    # `ST_Ticker`'s `st_randomnumber` shifts and the status bar's face changes
    # -> **the frame hash splits**. This is what "sticks for 41 frames" consists of.
    if t == 2
      k = 0
      while k < 320
        rnd.m_random
        k += 1
      end
    end
    g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
    # `ST_Ticker` draws `M_Random` once every tic (`st_randomnumber`).
    # `G_Ticker`'s order is P_Ticker -> **ST_Ticker** -> AM_Ticker -> HU_Ticker.
    st_randomnumber = rnd.m_random
    if want_frame
      m = g.player_mo
      atk = g.pl_attacker
      kind = atk < 0 ? Doom::StatusBar::ATTACKER_NONE :
             (atk == m ? Doom::StatusBar::ATTACKER_SELF : Doom::StatusBar::ATTACKER_OTHER)
      bga = atk >= 0 ? g.point_to_angle2(g.mobj_x[m], g.mobj_y[m],
                                         g.mobj_x[atk], g.mobj_y[atk]) : 0
      sb.ticker(st_randomnumber, g.pl_health, g.pl_weaponowned, g.pl_cards,
                g.pl_damagecount, g.pl_bonuscount, g.pl_attackdown,
                g.pl_powers[0], kind, bga, g.mobj_angle[m])
    end
    # `G_Ticker`'s order: P_Ticker -> ST_Ticker -> AM_Ticker -> HU_Ticker
    hud.ticker(g.take_message) if want_frame
    dump_player(pf, g, rnd, t, rnd.pcount - prev_pcount) if pf
    prev_pcount = rnd.pcount
    dump_mobjs(mf, g, t) if mf && (g.leveltime % @mobj_every) == 0
    if want_frame
      # **The frame buffer is not cleared.** Vanilla's `R_RenderPlayerView` does not clear
      # the view area, and pixels not drawn **keep the previous frame's contents**
      # (with screenblocks 10 the border is not drawn either). Where no visplane stands
      # this becomes a visible artifact: the famous Hall of Mirrors.
      # At tic 60 of E1M5 a 785-pixel HOM really appeared, and this port, which cleared to 0
      # every frame, split. Clear only the first time.
      r.clear_screen if t == 0
      r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
      r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
      r.extralight = g.extralight
      r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
      # `D_Display`'s order: R_RenderPlayerView -> **ST_Drawer** -> HU_Drawer.
      ak = weapon_ammo[g.pl_readyweapon]
      if rs == 1
        sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
                g.pl_weaponowned, g.pl_readyweapon, ak)
      else
        sb.draw(sbshadow, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
                g.pl_weaponowned, g.pl_readyweapon, ak)
        Doom::Hires.blit_scale(r.screen, sw, sbshadow, 320, 0, 168, 320, 32, rs)
      end
      hud.draw(r.screen)
      fr.puts("#{t}\t#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, sw * vh)}\t" \
              "#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, sw * sh)}")
      if jf
        r.job_check_span_closed if want_spanid != 0
        if want_maskid != 0
          r.job_check_masked_dist
          r.job_check_masked_runs
          r.job_check_opaque_cover
        end
        jf.puts("#{t}\t#{r.job_nwall}\t#{r.job_nspan}\t#{r.job_nmasked}\t" \
                "#{r.job_nsched}\t#{r.job_nzone}\t#{r.job_max_k}\t#{r.job_overlaps}\t" \
                "#{r.job_span_max_kx}\t#{r.job_span_overlaps}\t" \
                "#{r.job_span_closed_bad}\t#{r.job_span_closed_px}\t#{r.job_span_ycarry}\t" \
                "#{r.job_masked_max_kx}\t#{r.job_fuzz_max_kx}\t#{r.job_fuzz_n}\t" \
                "#{r.job_wall_all_max_k}\t#{r.job_wall_all_overlaps}\t" \
                "#{r.job_masked_stats}")
      end
      if @dump_tics.include?(t)
        File.open("#{dir}/frame_#{t}.bin", "wb") { |q| q.write(r.screen) }
      end
    end
    t += 1
  end

  if want_rand
    File.open("#{dir}/rand.tsv", "w") do |f|
      f.puts("#seq\tgametic\tidx_before\tidx_after\tvalue\tsite")
      i = 0
      while i < rnd.log_n
        f.puts("#{i}\t#{rnd.log_tic(i)}\t#{rnd.log_before(i)}\t#{rnd.log_after(i)}\t" \
               "#{rnd.log_value(i)}\t#{rnd.log_site(i)}")
        i += 1
      end
    end
  end
  pf.close if pf
  mf.close if mf
  fr.close if want_frame
  if jf
    jf.close
    $stderr.puts "sim_demo: jobmode=#{jobmode} highwater(wall/span/masked/sched/zone)=#{r.job_hi}"
    # Running totals (accumulated across frames). Each demo runs separately, so with
    # them printed here `run_scan.sh` only has to add the 3 for the whole count.
    $stderr.puts "sim_demo: e071_totals\t#{r.job_totals}" if want_maskid != 0
  end
  $stderr.puts "sim_demo: #{n} tics, prndindex=#{rnd.prndindex}, " \
               "P_Random calls=#{rnd.pcount}, mobjs=#{g.num_mobjs}"
end

def dump_player(f, g, rnd, t, calls)
  m = g.player_mo
  f.puts([t, g.leveltime, rnd.prndindex, rnd.rndindex, calls,
          g.cmd_forwardmove, g.cmd_sidemove, g.cmd_angleturn, g.cmd_buttons,
          g.mobj_x[m], g.mobj_y[m], g.mobj_z[m], g.mobj_angle[m],
          g.mobj_momx[m], g.mobj_momy[m], g.mobj_momz[m],
          g.mobj_floorz[m], g.mobj_ceilingz[m], g.mobj_subsector[m],
          g.mobj_state[m], g.mobj_tics[m], g.mobj_sprite[m], g.mobj_frame[m],
          g.mobj_health[m],
          g.pl_viewz, g.pl_viewheight, g.pl_deltaviewheight, g.pl_bob,
          g.pl_armorpoints, g.pl_playerstate, g.pl_readyweapon, g.pl_pendingweapon,
          g.pl_attackdown, g.pl_usedown, g.pl_refire,
          g.pl_killcount, g.pl_itemcount, g.pl_secretcount,
          g.extralight, g.pl_fixedcolormap, g.pl_damagecount, g.pl_bonuscount,
          # A psprite's "no state" is `psp->state == NULL` in vanilla, so
          # the reference side's dump writes -1. Not told apart from S_NULL (0).
          g.psp_state[0] == 0 ? -1 : g.psp_state[0], g.psp_sx[0], g.psp_sy[0],
          g.psp_state[1] == 0 ? -1 : g.psp_state[1],
          g.thinker_slots.length].join("\t"))
end

def dump_mobjs(f, g, t)
  slots = g.thinker_slots
  i = 0
  while i < slots.length
    th = slots[i]
    fn = g.th_func(th)
    if fn == 1
      m = g.th_data(th)
      f.puts([t, i, "mobj", g.mobj_type[m], g.mobj_x[m], g.mobj_y[m], g.mobj_z[m],
              g.mobj_angle[m], g.mobj_momx[m], g.mobj_momy[m], g.mobj_momz[m],
              g.mobj_state[m], g.mobj_tics[m], g.mobj_sprite[m], g.mobj_frame[m],
              g.mobj_flags[m], g.mobj_health[m], g.mobj_movedir[m],
              g.mobj_movecount[m], g.mobj_reactiontime[m], g.mobj_threshold[m],
              g.mobj_target[m] < 0 ? -1 : slot_of(slots, g, g.mobj_target[m]),
              g.mobj_floorz[m], g.mobj_ceilingz[m]].join("\t"))
    else
      kind = fn == 0 ? "removed" : (fn == 10 ? "null" : "other")
      f.puts([t, i, kind, -1, 0, 0, 0, 0, 0, 0, 0,
              -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0, 0].join("\t"))
    end
    i += 1
  end
end

def slot_of(slots, g, mobj)
  i = 0
  while i < slots.length
    return i if g.th_func(slots[i]) == 1 && g.th_data(slots[i]) == mobj
    i += 1
  end
  -1
end

main
