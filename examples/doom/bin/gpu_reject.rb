# doom/bin/gpu_reject.rb
#
#   gpu_reject <doom1.wad> <vmfb> <entries.tsv> <device> <stale_entries.tsv> <out.tsv>
#
# **Counts the ways the Ruby interface can be broken.** The earlier reject scripts
# (`run_reject.sh`) broke the Job IR itself (files / tables / `.vmfb`) and had
# `spinel-jobcheck` and `raster_run` refuse it. What is broken here is
# **the arguments that pass from Ruby to C**: the only new surface at this stage, and if
# something passes there quietly, the meaning of "the GPU drew it" breaks.
#
# Each case is one TSV line: `case  verdict  detail`.
#   REJECT     ... refused (as expected)
#   ESCAPED    ... **it got through** (the gate fails)
# A **positive control** (a correct call gets through) comes last. Without it,
# "an implementation that refuses everything" would also get full marks.

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

# Writes one case and returns whether it was missed (0/1). **No global variables**:
# there is no reason to bring them into Spinel's inference, and doom/ has not one anywhere.
def row(f, name, rc, want_reject)
  rejected = rc != 0 ? 1 : 0
  ok = rejected == want_reject ? 1 : 0
  v = want_reject != 0 ? (ok != 0 ? "REJECT" : "ESCAPED") : (ok != 0 ? "OK" : "REFUSED")
  msg = rejected != 0 ? Doom::Raster.sp_rg_error : "-"
  f.puts("#{name}\t#{v}\t#{msg}")
  ok != 0 ? 0 : 1
end

def main
  if ARGV.length < 6
    $stderr.puts "usage: gpu_reject <wad> <vmfb> <entries> <device> <stale_entries> <out.tsv>"
    exit 1
  end
  wadpath = ARGV[0]
  vmfb = ARGV[1]
  entries = ARGV[2]
  device = ARGV[3]
  stale = ARGV[4]
  out = ARGV[5]

  wad = Doom::Wad.new(wadpath)
  demo = Doom::Demo.new(wad, "DEMO1", "")
  lv = Doom::Level.new(wad, demo.mapname, demo.episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)
  rnd = Doom::Random.new
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
  colormap = wad.bytes_by_name("COLORMAP")
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, 1)
  r.job_mode = 4
  r.clear_screen
  g.g_ticker(demo.forwardmove[0], demo.sidemove[0], demo.angleturn[0], demo.buttons[0])
  rnd.m_random
  g.take_message
  r.set_psprite(g.psp_state[0], g.psp_sx[0], g.psp_sy[0])
  r.set_psprite_flash(g.psp_state[1], g.psp_sx[1], g.psp_sy[1])
  r.extralight = g.extralight
  r.render_player_view(g.viewx, g.viewy, g.viewz, g.viewangle)
  jobs = r.jobs

  fuzzoff = Doom::Bytes.buffer(50, 0)
  fi = 0
  while fi < 50
    fuzzoff.setbyte(fi, r.fuzzoffset[fi] & 255)
    fi += 1
  end
  short = Doom::Bytes.buffer(8, 0)
  small = Doom::Bytes.buffer(1024, 0)
  screen = Doom::Bytes.buffer(320 * 200, 0)
  # An empty bank one past the ring's limit (`Doom::Jobs::CAP_MASKED` = 8192).
  big = Array.new((Doom::Jobs::CAP_MASKED + 1) * Doom::Jobs::MC_NF, 0)
  empty = Array.new(Doom::Jobs::MC_NF, 0)
  vh = r.viewheight
  nscr = 320 * 200
  nzone = jobs.nzone * Doom::Jobs::ZONE_STRIDE

  f = File.open(out, "w")
  f.puts("#case\tverdict\tdetail")
  esc = 0
  nc = 0

  # ---- before opening ------------------------------------------------------
  nc += 1
  esc += row(f, "frame_before_open",
      Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                               jobs.masked_bank, jobs.nmasked, jobs.zonebuf, nzone,
                               wad.data, wad.data.bytesize, screen, nscr), 1)
  nc += 1
  esc += row(f, "geometry_before_open",
      Doom::Raster.sp_rg_geometry(320, vh, 320, 200, 0, 0), 1)
  nc += 1
  esc += row(f, "resident_before_open",
      Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                                  tx.flat_atlas, tx.flat_atlas.bytesize,
                                  colormap, colormap.bytesize, fuzzoff, 50), 1)

  # ---- broken ways of opening ------------------------------------------------
  nc += 1
  esc += row(f, "open_missing_vmfb",
      Doom::Raster.sp_rg_open("/nonexistent/no.vmfb", device, entries), 1)
  Doom::Raster.sp_rg_close
  nc += 1
  esc += row(f, "open_no_entry_table", Doom::Raster.sp_rg_open(vmfb, device, "/nonexistent/e.tsv"), 1)
  Doom::Raster.sp_rg_close
  nc += 1
  esc += row(f, "open_bad_device", Doom::Raster.sp_rg_open(vmfb, "no-such-driver", entries), 1)
  Doom::Raster.sp_rg_close

  # ---- broken after opening ----------------------------------------------------
  base = Doom::Raster.sp_rg_open(vmfb, device, entries)
  if base != 0
    f.puts("open_for_the_rest\tSKIP\t#{Doom::Raster.sp_rg_error}")
    f.close
    $stderr.puts "gpu_reject: cannot open the device; #{nc} cases, #{esc} escaped"
    exit 1 if esc != 0
    return
  end
  nc += 1
  esc += row(f, "geometry_view_outside_screen",
      Doom::Raster.sp_rg_geometry(320, vh, 320, 200, 8, 40), 1)
  nc += 1
  esc += row(f, "geometry_zero_view", Doom::Raster.sp_rg_geometry(0, vh, 320, 200, 0, 0), 1)
  nc += 1
  esc += row(f, "resident_before_geometry",
      Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                                  tx.flat_atlas, tx.flat_atlas.bytesize,
                                  colormap, colormap.bytesize, fuzzoff, 50), 1)
  # From here on, breakage is on top of a correct geometry.
  Doom::Raster.sp_rg_geometry(320, vh, 320, 200, r.viewwindowx, r.viewwindowy)
  # The geometry is set only once per device scope (it is the device buffers' dimensions,
  # and the resolution is folded into the kernels' ksig). The same values are a no-op; different ones are refused.
  nc += 1
  esc += row(f, "geometry_same_values_again",
      Doom::Raster.sp_rg_geometry(320, vh, 320, 200, r.viewwindowx, r.viewwindowy), 0)
  nc += 1
  esc += row(f, "geometry_changed_in_scope",
      Doom::Raster.sp_rg_geometry(320, vh - 8, 320, 200, r.viewwindowx, r.viewwindowy), 1)
  nc += 1
  esc += row(f, "resident_short_fuzzoff",
      Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                                  tx.flat_atlas, tx.flat_atlas.bytesize,
                                  colormap, colormap.bytesize, short, 8), 1)
  nc += 1
  esc += row(f, "resident_zero_atlas",
      Doom::Raster.sp_rg_resident(tx.tex_atlas, 0,
                                  tx.flat_atlas, tx.flat_atlas.bytesize,
                                  colormap, colormap.bytesize, fuzzoff, 50), 1)
  nc += 1
  esc += row(f, "frame_before_resident",
      Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                               jobs.masked_bank, jobs.nmasked, jobs.zonebuf, nzone,
                               wad.data, wad.data.bytesize, screen, nscr), 1)
  Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                              tx.flat_atlas, tx.flat_atlas.bytesize,
                              colormap, colormap.bytesize, fuzzoff, 50)
  nc += 1
  esc += row(f, "frame_framebuffer_too_small",
      Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                               jobs.masked_bank, jobs.nmasked, jobs.zonebuf, nzone,
                               wad.data, wad.data.bytesize, small, 1024), 1)
  nc += 1
  esc += row(f, "frame_bank_over_ring",
      Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                               big, Doom::Jobs::CAP_MASKED + 1, jobs.zonebuf, nzone,
                               wad.data, wad.data.bytesize, screen, nscr), 1)
  # ---- positive control: a correct call gets through --------------------------
  nc += 1
  esc += row(f, "positive_control_frame",
      Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                               jobs.masked_bank, jobs.nmasked, jobs.zonebuf, nzone,
                               wad.data, wad.data.bytesize, screen, nscr), 0)
  Doom::Raster.sp_rg_close

  # ---- the table and the kernels disagree (entries.tsv with ksig moved by one character) ---
  if Doom::Raster.sp_rg_open(vmfb, device, stale) == 0
    Doom::Raster.sp_rg_geometry(320, vh, 320, 200, r.viewwindowx, r.viewwindowy)
    Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                                tx.flat_atlas, tx.flat_atlas.bytesize,
                                colormap, colormap.bytesize, fuzzoff, 50)
    nc += 1
    esc += row(f, "frame_stale_entry_table",
        Doom::Raster.sp_rg_frame(jobs.wall_bank, jobs.nwall, jobs.span_bank, jobs.nspan,
                                 jobs.masked_bank, jobs.nmasked, jobs.zonebuf, nzone,
                                 wad.data, wad.data.bytesize, screen, nscr), 1)
    Doom::Raster.sp_rg_close
  else
    f.puts("frame_stale_entry_table\tSKIP\t#{Doom::Raster.sp_rg_error}")
  end

  # ---- passing empty banks (the right answer is **drawing nothing**, not refusing) ---
  # The table can choose a row even when all 3 banks are empty (the smallest row covering K=0), so
  # the right answer here is OK, not ESCAPED.
  if Doom::Raster.sp_rg_open(vmfb, device, entries) == 0
    Doom::Raster.sp_rg_geometry(320, vh, 320, 200, r.viewwindowx, r.viewwindowy)
    Doom::Raster.sp_rg_resident(tx.tex_atlas, tx.tex_atlas.bytesize,
                                tx.flat_atlas, tx.flat_atlas.bytesize,
                                colormap, colormap.bytesize, fuzzoff, 50)
    nc += 1
    esc += row(f, "positive_control_empty_banks",
        Doom::Raster.sp_rg_frame(empty, 0, empty, 0, empty, 0, jobs.zonebuf, nzone,
                                 wad.data, wad.data.bytesize, screen, nscr), 0)
    Doom::Raster.sp_rg_close
  end

  f.close
  $stderr.puts "gpu_reject: #{nc} cases, #{esc} escaped"
  exit 1 if esc != 0
end

main
