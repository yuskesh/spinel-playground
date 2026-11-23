# doom/bin/doom.rb — **playable DOOM**
#
#   doom -iwad <doom1.wad> [options]
#
#     -warp <E> <M>     episode and map (default 1 1)
#     -skill <N>        1..5 (default 2)
#     -playdemo <NAME>  plays a demo lump in the WAD (DEMO1 / DEMO2 / DEMO3)
#     -playdemo @<path> plays a recorded `.lmp`
#     -record <path>    records the input in a `.lmp` (interactive or synthetic)
#     -script <path>    a synthetic input script (instead of a person; `lib/doom/input.rb`)
#     -scale <N>        the window's multiplier (default 3 -> 960x600)
#     -res <W>x<H>      **the internal drawing resolution** (default 320x200). Where `-scale`
#                       is the window's multiplier, this is **the number of pixels really drawn**.
#                       W is 1..8 times 320, H is W*5/8 (8:5 = vanilla's aspect ratio).
#                       Anything but 320x200 has no bit-exact match with the doomgeneric reference
#                       (the oracle is the Job IR CPU executor at the same resolution)
#     -tics <N>         ends after this many tics (default 0 = no limit)
#     -nopace           drops the 35 Hz pacing and runs flat out (for measuring)
#     -shot <path>      writes a BMP at the -shottic tics
#     -shottic <N,N,...> the tics at which to take screenshots
#     -stats <path>     a TSV of times, one line per tic (the frame pacing's instrument)
#     -frames <path>    a TSV of frame hashes, one line per tic (the same form as sim_demo)
#     -jobs             the Job IR route
#     -core             decision 0008's route: before the first tic the objects
#                       below are built as always and Full's preparation copies
#                       them into the session; every tic then runs ONLY through
#                       the three CORE entries (job mode 1). Needs the build
#                       with the entries (examples/doom/build.sh CORE_DIR=...).
#                       Refused with -gpu and with -res other than 320x200.
#     -gpu              **draws the 3D view on the GPU**.
#                       If it cannot open, or a frame is refused, it **falls back to the CPU
#                       executor automatically** (one loud log line, then it carries on).
#                       The status bar and HUD are always CPU (the mixed form)
#     -gpuvmfb <path>   the GPU kernels (.vmfb). The default is the environment variable SPINEL_RASTER_VMFB
#     -gpuentries <p>   the entry table (spinel-rastergen --entries-out). The default is
#                       the environment variable SPINEL_RASTER_ENTRIES
#     -gpudev <name>    the IREE device URI (default metal)
#
# **Only this program goes through `lib/doom/video.rb` (SDL2)**, so it is
#    **Spinel-specific** (CRuby has no `ffi_func`). Game logic and drawing know
#    not one line of SDL: `bin/sim_demo.rb` and `bin/record_demo.rb` keep the CRuby
#    differential.
#
# **This is the only place that reads a clock.** Nothing inside `lib/doom/`
#    reads the time, so the simulation's determinism holds structurally.
#    It is read here only **for pacing and measuring**, never in the game's branches.

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
require_relative "../lib/doom/input"
require_relative "../lib/doom/record"
require_relative "../lib/doom/video"
require_relative "../lib/doom/render_gpu"
require_relative "../lib/doom/hires"
require_relative "../lib/doom/specials"
require_relative "../lib/doom/tables"
# decision 0008's entries (examples/doom/core/full). Their C operations are
# linked by examples/doom/build.sh: the adapter and the kernel's objects with
# CORE_DIR, examples/doom/native/sp_core_stub.c without.
require_relative "../core/full/nativeprep"
require_relative "../core/full/native_session"
require_relative "../core/full/native_catalog"
require_relative "../core/full/native_loop"

TICRATE = 35

def main
  iwad = ""
  episode = 1
  map = 1
  skill = 2
  demoname = ""
  recpath = ""
  scriptpath = ""
  scale = 3
  resscale = 1
  maxtics = 0
  pace = true
  shotpath = ""
  shottics = []
  statspath = ""
  framespath = ""
  jobmode = 0
  gpumode = 0
  gpuvmfb = ""
  gpuentries = ""
  gpudev = ""
  coremode = 0

  i = 0
  while i < ARGV.length
    a = ARGV[i]
    if a == "-iwad"
      iwad = ARGV[i + 1]; i += 2
    elsif a == "-warp"
      episode = ARGV[i + 1].to_i; map = ARGV[i + 2].to_i; i += 3
    elsif a == "-skill"
      skill = ARGV[i + 1].to_i; i += 2
    elsif a == "-playdemo"
      demoname = ARGV[i + 1]; i += 2
    elsif a == "-record"
      recpath = ARGV[i + 1]; i += 2
    elsif a == "-script"
      scriptpath = ARGV[i + 1]; i += 2
    elsif a == "-scale"
      scale = ARGV[i + 1].to_i; i += 2
    elsif a == "-res"
      # The internal resolution. **Not quietly corrected**: a width that is not an integer
      # multiple of 320 or a height that is not 8:5 is refused loudly. There is only one
      # multiplier so that one s runs through all the tables of `R_ExecuteSetViewSize`.
      spec = ARGV[i + 1]
      # `String#index` returns an Integer or nil (to avoid that poly), so
      # it is scanned by hand. The separator is one character, 'x' (0x78).
      xi = -1
      xj = 0
      while xj < spec.bytesize
        xi = xj if spec.getbyte(xj) == 120
        xj += 1
      end
      if xi < 0
        $stderr.puts "doom: -res wants <W>x<H> (got #{spec})"
        exit 1
      end
      rw = spec.byteslice(0, xi).to_i
      rh = spec.byteslice(xi + 1, spec.bytesize - xi - 1).to_i
      if rw % 320 != 0 || rw / 320 < 1 || rw / 320 > 8
        $stderr.puts "doom: -res width #{rw} must be 320*s with s in 1..8"
        exit 1
      end
      resscale = rw / 320
      if rh != 200 * resscale
        $stderr.puts "doom: -res #{rw}x#{rh} is not 8:5; DOOM's aspect wants " \
                     "#{rw}x#{200 * resscale}"
        exit 1
      end
      i += 2
    elsif a == "-tics"
      maxtics = ARGV[i + 1].to_i; i += 2
    elsif a == "-nopace"
      pace = false; i += 1
    elsif a == "-shot"
      shotpath = ARGV[i + 1]; i += 2
    elsif a == "-shottic"
      shottics = ARGV[i + 1].split(",").map { |v| v.to_i }; i += 2
    elsif a == "-stats"
      statspath = ARGV[i + 1]; i += 2
    elsif a == "-frames"
      framespath = ARGV[i + 1]; i += 2
    elsif a == "-jobs"
      # Draws through the Job IR route (the old route is the default).
      jobmode = 1; i += 1
    elsif a == "-core"
      coremode = 1; i += 1
    elsif a == "-gpu"
      # Draws the 3D view on the GPU. It stands on the Job IR route,
      # so it implies `-jobs` (`job_mode = 4` = only queue jobs).
      gpumode = 1; i += 1
    elsif a == "-gpuvmfb"
      gpuvmfb = ARGV[i + 1]; i += 2
    elsif a == "-gpuentries"
      gpuentries = ARGV[i + 1]; i += 2
    elsif a == "-gpudev"
      gpudev = ARGV[i + 1]; i += 2
    else
      $stderr.puts "doom: unknown option #{a}"
      exit 1
    end
  end
  if iwad == ""
    $stderr.puts "usage: doom -iwad <doom1.wad> [-warp E M] [-skill N] " \
                 "[-playdemo NAME|@path] [-record out.lmp] [-script s.txt] " \
                 "[-scale N] [-tics N] [-nopace] [-shot p.bmp -shottic N,..] " \
                 "[-stats t.tsv] [-frames f.tsv] [-jobs] " \
                 "[-gpu [-gpuvmfb k.vmfb] [-gpuentries e.tsv] [-gpudev metal]]"
    exit 1
  end

  wad = Doom::Wad.new(iwad)

  # ---- demo playback mode, or interactive (or synthetic input) mode --------------
  playing = demoname != ""
  demo = nil
  if playing
    if demoname[0] == "@"
      p = demoname.byteslice(1, demoname.bytesize - 1)
      demo = Doom::Demo.new(wad, p, p)
    else
      demo = Doom::Demo.new(wad, demoname, "")
    end
    episode = demo.episode
    map = demo.map
    skill = demo.skill
  end

  mapname = "E#{episode}M#{map}"
  lv = Doom::Level.new(wad, mapname, episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)

  rnd = Doom::Random.new
  rnd.clear                                     # `G_InitNew` -> `M_ClearRandom`
  g = Doom::Game.new(wad, lv, skill, rnd, tx)

  colormap = wad.bytes_by_name("COLORMAP")
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  sb = Doom::StatusBar.new(wad)
  sb.start(g.pl_weaponowned)
  weapon_ammo = Doom::Info.weapon_ammo
  r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, resscale)
  sw = r.screenwidth
  sh = r.screenheight
  hud = Doom::Hud.new(wad, sw, sh, resscale)
  # The status bar is drawn as before into a 320x200 **shadow buffer**, and only the
  # bottom 32 lines are copied to the real screen at an integer multiple (the reasons are in `lib/doom/hires.rb`).
  # At s = 1 no shadow is used and it draws straight to the real screen: the route does not change by one byte.
  sbshadow = Doom::Bytes.buffer(resscale == 1 ? 1 : 320 * 200, 0)
  # `-gpu` stands on the Job IR route. Mode 4 = **only queue jobs**, drawing
  # not one pixel (the GPU route below draws, or `draw_jobs_cpu` if refused).
  r.job_mode = gpumode != 0 ? 4 : jobmode

  # The GPU route. **Always constructed**: if the variable's type wavered with and
  # without `-gpu`, Spinel's inference would widen to poly. `initialize` calls no FFI.
  gpu = Doom::GpuRaster.new
  if gpumode != 0
    fuzzoff = Doom::Bytes.buffer(50, 0)
    fi = 0
    while fi < 50
      fuzzoff.setbyte(fi, r.fuzzoffset[fi] & 255)
      fi += 1
    end
    ok = gpu.open(gpuvmfb, gpudev, gpuentries, sw, r.viewheight, sw, sh,
                  r.viewwindowx, r.viewwindowy)
    ok = gpu.resident(tx.tex_atlas, tx.flat_atlas, colormap, fuzzoff, wad.data) if ok == 0
    if ok != 0
      # **Say it loudly in one line and carry on.** The CPU executor is the permanent
      # right answer, so the GPU not opening does not mean "cannot play".
      $stderr.puts "doom: GPU raster unavailable (#{gpu.error}); " \
                   "falling back to the CPU job executor for every frame"
      gpu.close
    else
      $stderr.puts "doom: GPU raster ready (#{sw}x#{r.viewheight} view)"
    end
  end
  # Only PLAYPAL's plane 0 (768 bytes) is passed to SDL.
  # **Not through `Doom::Palette`**: that is the RGB lookup for PPM, with a hook for
  # applying `colormap`. The right display puts out the 8-bit indices as they are
  # (`dc_colormap` has already been applied on the drawing side).
  playpal = wad.bytes_by_name("PLAYPAL")
  if playpal.bytesize < 768
    raise Doom::PaletteError, "PLAYPAL is #{playpal.bytesize} bytes (need >= 768)"
  end

  video = Doom::Video.new("Spinel DOOM (#{mapname})", sw, sh, scale)
  video.palette = playpal.byteslice(0, 768)

  ks = Doom::KeyState.new
  tc = Doom::TiccmdBuilder.new
  script = scriptpath == "" ? nil : Doom::KeyScript.new(scriptpath)
  rec = recpath == "" ? nil : Doom::DemoWriter.new(skill, episode, map,
                                                   maxtics > 0 ? maxtics : 40000)

  if coremode != 0
    if gpumode != 0 || resscale != 1
      $stderr.puts "doom: -core draws the CPU job path at 320x200 only (no -gpu, no -res)"
      exit 1
    end
    if recpath != "" && maxtics > 40000
      $stderr.puts "doom: -core records at most 40000 tics (the catalog's demotics)"
      exit 1
    end
    core_play(wad, lv, tx, rnd, g, sp, sb, r, hud, video, playing, demo, scriptpath, recpath,
              framespath, statspath, maxtics, pace, skill, episode, map, mapname)
    return
  end

  ff = framespath == "" ? nil : File.open(framespath, "w")
  ff.puts("#gametic\tviewhash\tfullhash") if ff
  sf = statspath == "" ? nil : File.open(statspath, "w")
  sf.puts("#tic\twork_us\tsleep_us\tframe_us\tlate_us") if sf

  n = maxtics
  n = demo.numtics if playing && (n == 0 || demo.numtics < n)
  n = script.last_tic + 1 if script && (n == 0 || script.last_tic + 1 < n)

  t = 0
  quit = false
  prev_end = video.elapsed_us
  t0_us = prev_end
  while !quit && (n == 0 || t < n)
    work0 = video.elapsed_us
    rnd.tic = t
    # The same 320 `M_Random` draws of the melt wipe as the reference harness (as in sim_demo).
    # With it in, a `.lmp` recorded here makes **the same world** when fed to the reference
    # implementation's `-timedemo`.
    if t == 2
      k = 0
      while k < 320
        rnd.m_random
        k += 1
      end
    end

    quit = video.pump

    if playing
      fwd = demo.forwardmove[t]
      side = demo.sidemove[t]
      aturn = demo.angleturn[t]
      btn = demo.buttons[t]
    else
      if script
        script.apply(ks, t)
      else
        read_keys(video, ks)
      end
      tc.build(ks.down)
      if rec
        # `G_WriteDemoTiccmd` reads back what it has just written (the angle is quantized
        # to 8 bits, so **the game being recorded also runs on the quantized value**).
        ab = tc.quantize_angle!
        rec.write_tic(tc.forwardmove, tc.sidemove, ab, tc.buttons)
      end
      fwd = tc.forwardmove
      side = tc.sidemove
      aturn = tc.angleturn
      btn = tc.buttons
    end

    g.g_ticker(fwd, side, aturn, btn)
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
    # The GPU draws the 3D view. **If refused, the CPU executor draws the same frame**:
    # the GPU refuses without touching the screen by one byte, so this is
    # not a repair but that frame's right answer.
    # The status bar and HUD are always overlaid by the CPU below (the mixed form).
    if gpumode != 0
      r.draw_jobs_cpu if gpu.draw(r.jobs, r.screen) != 0
    end
    ak = weapon_ammo[g.pl_readyweapon]
    if resscale == 1
      sb.draw(r.screen, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
              g.pl_weaponowned, g.pl_readyweapon, ak)
    else
      # Draw into the shadow and copy the bottom 32 lines s times. `StatusBar` still
      # believes it draws on a 320x200 plane, and has not changed by one line.
      sb.draw(sbshadow, g.pl_health, g.pl_armorpoints, g.pl_ammo, g.pl_maxammo,
              g.pl_weaponowned, g.pl_readyweapon, ak)
      Doom::Hires.blit_scale(r.screen, sw, sbshadow, 320, 0, 168, 320, 32, resscale)
    end
    hud.draw(r.screen)

    video.present(r.screen)
    video.save_bmp(shotpath + "_#{t}.bmp") if shotpath != "" && shottics.include?(t)
    if ff
      ff.puts("#{t}\t#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, sw * r.viewheight)}\t" \
              "#{Doom::Bytes.fnv1a64_hex_range(r.screen, 0, sw * sh)}")
    end

    work1 = video.elapsed_us
    # ---- frame pacing ------------------------------------------------------------
    # Sleep until **a target time from a fixed epoch** (not relative to the previous frame).
    # Relative, the rounding-up error below 1 ms piles up every tic, and after
    # thousands of tics it becomes visibly slow.
    late = 0
    if pace
      target = t0_us + ((t + 1) * 1_000_000) / TICRATE
      if work1 < target
        video.delay_ms(((target - work1) + 999) / 1000)
      else
        late = work1 - target
      end
    end
    tend = video.elapsed_us
    if sf
      sf.puts("#{t}\t#{work1 - work0}\t#{tend - work1}\t#{tend - prev_end}\t#{late}")
    end
    prev_end = tend
    t += 1
  end

  video.close
  if gpumode != 0
    # Counting "Ruby drew it on the GPU". If even one was refused,
    # the CPU drew that frame, and **the picture is the same either way**.
    $stderr.puts "doom: gpu frames=#{gpu.frames} rejects=#{gpu.rejects} " \
                 "h2d=#{gpu.counter(Doom::GpuRaster::C_H2D)} " \
                 "d2h=#{gpu.counter(Doom::GpuRaster::C_D2H)} " \
                 "invoke=#{gpu.counter(Doom::GpuRaster::C_INVOKE)} " \
                 "alloc=#{gpu.counter(Doom::GpuRaster::C_ALLOC)}"
    gpu.close
  end
  ff.close if ff
  sf.close if sf
  rec.save(recpath) if rec
  $stderr.puts "doom: #{t} tics on #{mapname} (skill #{skill})" \
               "#{playing ? ", playing #{demoname}" : ""}" \
               "#{rec ? ", recorded #{rec.numtics} tics to #{recpath}" : ""}"
end

# -core: Full's preparation, then every tic through the entries only.
def core_play(wad, lv, tx, rnd, g, sp, sb, r, hud, video, playing, demo, scriptpath, recpath,
              framespath, statspath, maxtics, pace, skill, episode, map, mapname)
  r.job_mode = Doom::Core::NativeLoop::JOB_MODE
  script_code = Array.new(0, 0)
  script_from = Array.new(0, 0)
  script_to = Array.new(0, 0)
  last_tic = -1
  if scriptpath != ""
    ks = Doom::KeyScript.new(scriptpath)
    script_code = ks.instance_variable_get(:@code)
    script_from = ks.instance_variable_get(:@from)
    script_to = ks.instance_variable_get(:@to)
    last_tic = ks.last_tic
  end
  # 40000, as the catalog's demotics: bin/doom.rb stops the game at -tics anyway
  dw = Doom::DemoWriter.new(skill, episode, map, 40000)
  p0 = video.elapsed_us
  cat = Doom::Core::NativeCatalog.measure(wad, lv, tx, sp, r.screenwidth, r.screenheight, script_from.length)
  s = Doom::Core::NativeSession.new(cat)
  Doom::Core::NativePrep.prepare(s, wad, tx, lv, rnd, g, sp, r, sb, hud, script_code, script_from, script_to,
                                 Doom::KeyState.new, Doom::TiccmdBuilder.new, dw,
                                 r.instance_variable_get(:@jobs), r.instance_variable_get(:@exec))
  p1 = video.elapsed_us
  $stderr.puts "doom: -core session open on #{mapname}: #{(p1 - p0) / 1000} ms to measure and prepare"
  sealed = Doom::Core::SealedOriginals.new(g, r)
  sealed.seal
  core_loop(s, sealed, video, playing, demo, scriptpath != "", last_tic, recpath, framespath, statspath,
            maxtics, pace, r.screenwidth, r.screenheight, r.viewheight)
end

# The tic, through the entries. It is handed the session and the seal only.
def core_loop(s, sealed, video, playing, demo, scripted, last_tic, recpath, framespath, statspath,
              maxtics, pace, sw, sh, vh)
  ff = framespath == "" ? nil : File.open(framespath, "w")
  ff.puts("#gametic\tviewhash\tfullhash") if ff
  sf = statspath == "" ? nil : File.open(statspath, "w")
  sf.puts("#tic\twork_us\tsleep_us\tframe_us\tlate_us") if sf
  recording = recpath != "" ? 1 : 0
  screen = Doom::Bytes.buffer(sw * sh, 0)
  n = maxtics
  n = demo.numtics if playing && (n == 0 || demo.numtics < n)
  n = last_tic + 1 if scripted && (n == 0 || last_tic + 1 < n)
  t = 0
  quit = false
  prev_end = video.elapsed_us
  t0_us = prev_end
  while !quit && (n == 0 || t < n)
    work0 = video.elapsed_us
    quit = video.pump
    if playing
      Doom::Core::NativeLoop.demo_command(s, demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t],
                                          demo.buttons[t])
    else
      Doom::Core::NativeLoop.keys(s, video) unless scripted
      Doom::Core::NativeLoop.input(s, scripted ? 1 : 0, t, recording)
    end
    Doom::Core::NativeLoop.step(s, t)
    Doom::Core::NativeLoop.render(s, t, t + 1)
    Doom::Core::NativeLoop.screen(s, screen, sw * sh)
    video.present(screen)
    if ff
      ff.puts("#{t}\t#{Doom::Bytes.fnv1a64_hex_range(screen, 0, sw * vh)}\t" \
              "#{Doom::Bytes.fnv1a64_hex_range(screen, 0, sw * sh)}")
    end
    work1 = video.elapsed_us
    late = 0
    if pace
      target = t0_us + ((t + 1) * 1_000_000) / TICRATE
      if work1 < target
        video.delay_ms(((target - work1) + 999) / 1000)
      else
        late = work1 - target
      end
    end
    tend = video.elapsed_us
    sf.puts("#{t}\t#{work1 - work0}\t#{tend - work1}\t#{tend - prev_end}\t#{late}") if sf
    prev_end = tend
    t += 1
  end
  video.close
  ff.close if ff
  sf.close if sf
  saved = recording != 0 ? Doom::Core::NativeLoop.save_recording(s, recpath) : 0
  $stderr.puts "doom: -core #{t} tics through the entries" \
               "#{recording != 0 ? ", recorded #{saved} tics to #{recpath}" : ""}"
end

# Copies SDL's key state into `gamekeydown[]`. **Only the keys listed here are read**:
# there is no menu and no automap, so the others are ignored (keys that "do not work"
# are not quietly made to half work).
def read_keys(video, ks)
  ks.clear
  codes = Doom::TiccmdBuilder::WATCHED_KEYS
  i = 0
  while i < codes.length
    c = codes[i]
    ks.press(c) if video.key(c) != 0
    i += 1
  end
end

main
