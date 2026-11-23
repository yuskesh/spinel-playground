# doom/bin/gpu_demo.rb
#
#   gpu_demo <doom1.wad> <DEMOLUMP> <ntics> <stride> <out.tsv> <vmfb> <entries> <device>
#            [resscale]
#
# The 9th argument is **the internal resolution's multiplier** (default 1).
#   There is no reference implementation (doomgeneric) at high resolutions, so **the Job IR
#   CPU executor is the right answer**. This harness's comparison is that oracle.
#
# **Compares a frame Ruby drew on the GPU with the frame the CPU executor drew, in the
# same process.** Headless; it goes through not one line of SDL.
#
# Every tic:
#
#   (1) `render_player_view` (`job_mode = 4`) **only queues jobs** and returns
#   (2) on a sample tic:
#        save the screen -> **the GPU draws the 3D view** -> save the view area
#        restore the screen -> **the CPU executor draws the same job list**
#        -> compare the 2 view areas **byte for byte**
#   (3) on other tics only the CPU executor draws
#
# The order in (2) is the point. The game always advances on **the screen the CPU drew**,
# so the world is the same whether or not a tic is sampled: this harness's
# frame sequence matches `sim_demo`'s. The GPU is only asked each time whether "the same
# input gives the same picture", and holds not one byte of state.
#
# The status bar and HUD are **not called** (for the same reason as `dump_jobs.rb`:
#   with no edge from this program to `StatusBar#draw` its arguments get no type, a poly
#   reaches `setbyte`'s value argument and the generated C breaks). What is compared is the 3D view.
#
# **Spinel-specific** (`ffi_func`). `sim_demo.rb` keeps the CRuby differential.

require_relative "../lib/doom/wad"
require_relative "../lib/doom/level"
require_relative "../lib/doom/texnames"
require_relative "../lib/doom/texture"
require_relative "../lib/doom/sprites"
require_relative "../lib/doom/render"
require_relative "../lib/doom/jobs"
require_relative "../lib/doom/info"
require_relative "../lib/doom/random"
require_relative "../lib/doom/demo"
require_relative "../lib/doom/game"
require_relative "../lib/doom/bytes"
require_relative "../lib/doom/render_gpu"

def main
  if ARGV.length < 8
    $stderr.puts "usage: gpu_demo <wad> <DEMOLUMP> <ntics> <stride> <out.tsv> " \
                 "<vmfb> <entries.tsv> <device> [resscale]"
    exit 1
  end
  wad = Doom::Wad.new(ARGV[0])
  demo = Doom::Demo.new(wad, ARGV[1], "")
  want = ARGV[2].to_i
  stride = ARGV[3].to_i
  outpath = ARGV[4]
  vmfb = ARGV[5]
  entries = ARGV[6]
  device = ARGV[7]
  stride = 1 if stride < 1
  rs = ARGV.length > 8 ? ARGV[8].to_i : 1
  rs = 1 if rs < 1

  lv = Doom::Level.new(wad, demo.mapname, demo.episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)
  rnd = Doom::Random.new
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
  colormap = wad.bytes_by_name("COLORMAP")
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, rs)
  sw = r.screenwidth
  sh = r.screenheight
  # Mode 4 = only queue jobs. This program does the drawing.
  r.job_mode = 4
  r.clear_screen

  fuzzoff = Doom::Bytes.buffer(50, 0)
  fi = 0
  while fi < 50
    fuzzoff.setbyte(fi, r.fuzzoffset[fi] & 255)
    fi += 1
  end

  gpu = Doom::GpuRaster.new
  ok = gpu.open(vmfb, device, entries, sw, r.viewheight, sw, sh,
                r.viewwindowx, r.viewwindowy)
  ok = gpu.resident(tx.tex_atlas, tx.flat_atlas, colormap, fuzzoff, wad.data) if ok == 0
  if ok != 0
    $stderr.puts "gpu_demo: GPU raster unavailable (#{gpu.error}); " \
                 "every frame will fall back to the CPU job executor"
  end

  vw = sw
  vh = r.viewheight
  vwx = r.viewwindowx
  vwy = r.viewwindowy
  save = Doom::Bytes.buffer(sw * sh, 0)     # the screen before the frame
  gpufb = Doom::Bytes.buffer(sw * sh, 0)    # the screen the GPU drew

  f = File.open(outpath, "w")
  f.puts("#tic\tsampled\tgpu\tdiff\tpx\tgpuhash\tcpuhash\tdispatch\tnwin\tnbatch\t" \
         "kopaque\tkspan\tkmasked")

  n = want
  n = demo.numtics if n == 0 || demo.numtics < n
  t = 0
  nsample = 0
  nbitwise = 0
  ndiffer = 0
  nfallback = 0
  while t < n
    if t == 2
      k = 0
      while k < 320
        rnd.m_random
        k += 1
      end
    end
    g.g_ticker(demo.forwardmove[t], demo.sidemove[t], demo.angleturn[t], demo.buttons[t])
    rnd.m_random
    g.take_message
    r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
    r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
    r.extralight = g.extralight
    r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)

    sampled = t % stride == 0 ? 1 : 0
    drew = 0
    diff = -1
    gh = "-"
    ch = "-"
    disp = 0
    nwin = 0
    nbat = 0
    ko = 0
    ks = 0
    km = 0
    if sampled != 0
      nsample += 1
      Doom::Bytes.copy(save, r.screen, sw * sh)
      drew = gpu.draw(r.jobs, r.screen) == 0 ? 1 : 0
      if drew != 0
        Doom::Bytes.copy(gpufb, r.screen, sw * sh)
        gh = Doom::Bytes.fnv1a64_hex_range(gpufb, 0, sw * sh)
        disp = gpu.counter(Doom::GpuRaster::C_DISPATCH)
        nwin = gpu.counter(Doom::GpuRaster::C_NWIN)
        nbat = gpu.counter(Doom::GpuRaster::C_NBATCH)
        ko = gpu.counter(Doom::GpuRaster::C_KOPAQUE)
        ks = gpu.counter(Doom::GpuRaster::C_KSPAN)
        km = gpu.counter(Doom::GpuRaster::C_KMASKED)
      else
        nfallback += 1
      end
      # Put the screen back and have the CPU executor draw **the same job list**.
      Doom::Bytes.copy(r.screen, save, sw * sh)
      r.draw_jobs_cpu
      ch = Doom::Bytes.fnv1a64_hex_range(r.screen, 0, sw * sh)
      if drew != 0
        # Count bytes only in the view rectangle (neither touched the 32 lines below).
        diff = 0
        y = 0
        while y < vh
          x = 0
          while x < vw
            o = (y + vwy) * sw + x + vwx
            diff += 1 if gpufb.getbyte(o) != r.screen.getbyte(o)
            x += 1
          end
          y += 1
        end
        if diff == 0
          nbitwise += 1
        else
          ndiffer += 1
        end
      end
    else
      r.draw_jobs_cpu
    end
    f.puts("#{t}\t#{sampled}\t#{drew}\t#{diff}\t#{vw * vh}\t#{gh}\t#{ch}\t" \
           "#{disp}\t#{nwin}\t#{nbat}\t#{ko}\t#{ks}\t#{km}")
    t += 1
  end
  f.close

  $stderr.puts "gpu_demo: #{ARGV[1]} tics=#{t} sampled=#{nsample} " \
               "gpu=#{gpu.frames} bitwise=#{nbitwise} differs=#{ndiffer} " \
               "fallback=#{nfallback} rejects=#{gpu.rejects} " \
               "alloc=#{gpu.counter(Doom::GpuRaster::C_ALLOC)} " \
               "h2d=#{gpu.counter(Doom::GpuRaster::C_H2D)} " \
               "d2h=#{gpu.counter(Doom::GpuRaster::C_D2H)} " \
               "invoke=#{gpu.counter(Doom::GpuRaster::C_INVOKE)}"
  gpu.close
  exit 1 if ndiffer != 0
end

main
