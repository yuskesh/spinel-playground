# doom/bin/dump_jobs.rb
#
#   dump_jobs <doom1.wad> <DEMOLUMP> <tic> <outdir> [gpu_fb.bin|-] [resscale]
#
# The 6th argument is **the internal resolution's multiplier** (default 1 = 320x200).
#   The high-resolution Job IR is **not** a copy of the 320 jobs:
#   it is the real thing, with the BSP run at that resolution.
#
# **Writes out the whole Job IR of one frame** at the given tic.
# It is the input of the table, the checker and MLIR generation, and also the primary
# data for checking by eye that "the job list alone decides the picture".
#
#   table.tsv      **the table** of the 3 kinds of job (the first version of `sp_job_entry_t`)
#   resources.tsv  the resource table (atlas dimensions / colormap / zone ring)
#   sched.tsv      the schedule list in issue order (kind, idx)
#   wall.tsv / span.tsv / masked.tsv   the logical fields of the 3 banks
#   wall_aos.bin / wall_soa.bin        **2 physical layouts of the same logical contents**
#                                      (the layout is something a device chooses)
#
# 4 were added for the GPU route. They are its input and oracles:
#
#   meta.tsv        frame constants (the 5 the executor may look at + dimensions). Input of the generator and the checker
#   wall0_soa.bin   planar SoA of **phase 0 (opaque walls) only**. The very bytes the GPU
#                   uploads every frame (`wall_soa.bin` includes sky columns too)
#   wallfb_all.bin  **oracle**: the screen after putting every phase 0 wall job through the
#                   Job IR interpreting CPU executor (320x200, background 0). The GPU's gather matches it bit for bit
#   wallfb_one.bin  **oracle**: the screen after putting **only the first** phase 0 job through
#                   (the completion condition "a single column bit-exact")
#
# Both oracles are drawn by **`Doom::JobExecutor` itself**, not by formulas rewritten
# independently of the old route or the reference implementation. "executor = old route =
# reference implementation" was shown on all 10 996 frames, so these 2 connect to the existing 131 gates.
#
# **All output matching byte for byte under Spinel and CRuby** is a gate.

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

def main
  if ARGV.length < 4
    $stderr.puts "usage: dump_jobs <wad> <DEMOLUMP> <tic> <outdir> [gpu_fb.bin|-] [resscale]"
    exit 1
  end
  wad = Doom::Wad.new(ARGV[0])
  demo = Doom::Demo.new(wad, ARGV[1], "")
  want = ARGV[2].to_i
  dir = ARGV[3]
  rs = ARGV.length > 5 ? ARGV[5].to_i : 1
  rs = 1 if rs < 1

  lv = Doom::Level.new(wad, demo.mapname, demo.episode)
  texnames = Doom::TextureNames.new(wad)
  tx = Doom::Textures.new(wad, texnames)
  rnd = Doom::Random.new
  rnd.clear
  g = Doom::Game.new(wad, lv, demo.skill, rnd, tx)
  colormap = wad.bytes_by_name("COLORMAP")
  sp = Doom::Sprites.new(wad, Doom::Info.sprnames)
  # The status bar and HUD are **not called**. With no edge from this program to
  # `StatusBar#draw` its arguments get no type, a poly reaches `setbyte`'s
  # value argument and **the generated C breaks**. The Job IR does not depend on the
  # screen's contents, so drawing the view is enough to write out the job list.
  r = Doom::Renderer.new(lv, wad, colormap, tx, sp, g, 10, false, rs)
  sw = r.screenwidth
  sh = r.screenheight
  # Statistics mode (the checker only counts). **So that any tic can be written out**,
  # it does not fail even past K_MAX.
  r.job_mode = 2
  r.clear_screen

  n = want + 1
  n = demo.numtics if n > demo.numtics
  t = 0
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
    t += 1
  end

  jobs = r.jobs
  File.open("#{dir}/table.tsv", "w") do |f|
    f.puts("#name\tphase\tform\tnfield\tfields\tftypes\tk_max\treads\twrites\torder\tranges\tsig")
    # 3 -> **4 rows**. `plane_spans` became one row per K
    # (K is part of the kernel's ABI, so K=4 and K=16 are different contracts).
    k = 0
    while k < Doom::Jobs::NTABLE
      row = Doom::Jobs.table_row(k)
      f.puts("#{row}\t#{Doom::Bytes.fnv1a64_hex(row)}")
      k += 1
    end
  end

  File.open("#{dir}/resources.tsv", "w") do |f|
    f.puts("#resource\tid\tbytes\tstride\tnote")
    f.puts("atlas\t#{Doom::Jobs::RES_ATLAS}\t#{tx.tex_atlas_size}\t128\ttexture columns, TEXCOL_STRIDE windows")
    f.puts("wad\t#{Doom::Jobs::RES_WAD}\t#{wad.data.bytesize}\t1\traw WAD bytes (masked posts)")
    f.puts("zone\t#{Doom::Jobs::RES_ZONE}\t#{jobs.zone_slots * Doom::Jobs::ZONE_STRIDE}\t128\tper-frame zone windows")
    f.puts("flat\t#{Doom::Jobs::RES_FLAT}\t#{tx.flat_atlas_size}\t4096\tflats")
    f.puts("cmap\t-1\t#{colormap.bytesize}\t256\tcolormap rows")
    # Gate: the atlas is only a reordering of `texdata` / `flatdata`.
    f.puts("atlas_mismatch\t-1\t#{tx.atlas_check}\t0\tbytes where atlas != texdata/flatdata")
  end

  File.open("#{dir}/sched.tsv", "w") do |f|
    f.puts("#seq\tkind\tidx")
    kb = jobs.sched_kind_bank
    ib = jobs.sched_idx_bank
    i = 0
    while i < jobs.nsched
      f.puts("#{i}\t#{kb[i]}\t#{ib[i]}")
      i += 1
    end
  end

  File.open("#{dir}/wall.tsv", "w") do |f|
    f.puts("#i\t#{Doom::Jobs::WC_FIELDS.split(",").join("\t")}")
    b = jobs.wall_bank
    i = 0
    while i < jobs.nwall
      o = i * Doom::Jobs::WC_NF
      f.puts("#{i}\t#{b[o]}\t#{b[o + 1]}\t#{b[o + 2]}\t#{b[o + 3]}\t#{b[o + 4]}\t#{b[o + 5]}\t#{b[o + 6]}")
      i += 1
    end
  end

  File.open("#{dir}/span.tsv", "w") do |f|
    f.puts("#i\t#{Doom::Jobs::SP_FIELDS.split(",").join("\t")}")
    b = jobs.span_bank
    i = 0
    while i < jobs.nspan
      o = i * Doom::Jobs::SP_NF
      f.puts("#{i}\t#{b[o]}\t#{b[o + 1]}\t#{b[o + 2]}\t#{b[o + 3]}\t#{b[o + 4]}\t#{b[o + 5]}\t#{b[o + 6]}")
      i += 1
    end
  end

  File.open("#{dir}/masked.tsv", "w") do |f|
    f.puts("#i\t#{Doom::Jobs::MC_FIELDS.split(",").join("\t")}")
    b = jobs.masked_bank
    i = 0
    while i < jobs.nmasked
      o = i * Doom::Jobs::MC_NF
      f.puts("#{i}\t#{b[o]}\t#{b[o + 1]}\t#{b[o + 2]}\t#{b[o + 3]}\t#{b[o + 4]}\t" \
             "#{b[o + 5]}\t#{b[o + 6]}\t#{b[o + 7]}\t#{b[o + 8]}")
      i += 1
    end
  end

  # Layer 2: pack the same logical contents in 2 physical layouts.
  # AoS is the form the CPU executor reads; planar SoA is the GPU's form (2.45 times faster on Metal).
  nb = jobs.nwall * Doom::Jobs::WC_NF * 4
  aos = Doom::Bytes.buffer(nb, 0)
  soa = Doom::Bytes.buffer(nb, 0)
  jobs.pack(Doom::Jobs::KIND_WALL, Doom::Jobs::LAYOUT_AOS, aos)
  jobs.pack(Doom::Jobs::KIND_WALL, Doom::Jobs::LAYOUT_PLANAR_SOA, soa)
  File.open("#{dir}/wall_aos.bin", "wb") { |f| f.write(aos) }
  File.open("#{dir}/wall_soa.bin", "wb") { |f| f.write(soa) }

  # ================= the GPU route's input and oracles ===========================
  #
  # **Build one more Jobs holding only phase 0 (opaque walls).**
  # The gather formulation rests on the property "opaque walls have exclusive y-intervals
  # per x", and that is proven only for the phase 0 set
  # (sky columns go into the same wall bank but are phase 1). The GPU's first version draws this set.
  #
  # The extraction uses **only `Jobs`'s public API** (replaying `push_wall` in issue order).
  # That way `pack`, `check` and the executor work as they are, and
  # "the phase 0 Job IR" stays structurally a subset of the Job IR.
  n0 = jobs.wall_phase0_n
  jobs0 = Doom::Jobs.new(sw, r.viewheight)
  wb = jobs.wall_bank
  i = 0
  while i < n0
    o = i * Doom::Jobs::WC_NF
    jobs0.push_wall(wb[o], wb[o + 1], wb[o + 2], wb[o + 3], wb[o + 4], wb[o + 5], wb[o + 6])
    i += 1
  end
  jobs0.mark_phase1                     # all are phase 0 -> checks #4/#5 apply to every one

  # A Job IR of only the first job (the completion condition "a single column").
  jobs1 = Doom::Jobs.new(sw, r.viewheight)
  if n0 > 0
    jobs1.push_wall(wb[0], wb[1], wb[2], wb[3], wb[4], wb[5], wb[6])
    jobs1.mark_phase1
  end

  # The executor that draws the oracles. **Frame constants and resources come from the Renderer**:
  # the 3 things the top of executor.rb lists as "what the executor may look at"
  # (job list / resources / frame constants) are exactly the arguments.
  ex0 = Doom::JobExecutor.new(jobs0, colormap, tx.tex_atlas, tx.flat_atlas,
                              wad.data, r.fuzzoffset, sw,
                              r.viewwindowx, r.viewwindowy, r.viewheight)
  fb0 = Doom::Bytes.buffer(sw * sh, 0)
  ex0.run(jobs0, false, fb0)
  File.open("#{dir}/wallfb_all.bin", "wb") { |f| f.write(fb0) }

  ex1 = Doom::JobExecutor.new(jobs1, colormap, tx.tex_atlas, tx.flat_atlas,
                              wad.data, r.fuzzoffset, sw,
                              r.viewwindowx, r.viewwindowy, r.viewheight)
  fb1 = Doom::Bytes.buffer(sw * sh, 0)
  ex1.run(jobs1, false, fb1)
  File.open("#{dir}/wallfb_one.bin", "wb") { |f| f.write(fb1) }

  # The phase 0 planar SoA. **The bytes the GPU uploads every frame.**
  nb0 = n0 * Doom::Jobs::WC_NF * 4
  soa0 = Doom::Bytes.buffer(nb0 > 0 ? nb0 : 1, 0)
  jobs0.pack(Doom::Jobs::KIND_WALL, Doom::Jobs::LAYOUT_PLANAR_SOA, soa0)
  File.open("#{dir}/wall0_soa.bin", "wb") { |f| f.write(soa0) }

  # ================= plane spans' input and oracles ===============================
  #
  # Writes out the span side **in the same form** as the walls. The differences: it is cut by y,
  # not x, and the source is a 4096B flat, not a 128B texture column window.
  #
  #   span1_soa.bin  planar SoA of every phase 1 span job
  #                  (the bytes the GPU uploads every frame)
  #   spanfb_all.bin oracle: the screen after putting every span job through the executor
  #   spanfb_one.bin oracle: **only the first** (the completion condition "a single span")
  #   compfb.bin     oracle: **phase 0 walls + spans** = the screen the GPU's 2 stages draw
  #   compfb_wsm.bin oracle: that with masked overlaid (the final mixed form)
  #   flat.bin       a resident resource (the flat atlas)
  #
  # The executor is `Doom::JobExecutor` itself, as for walls, and
  # only the choice of stages is made with `run_sel` (neither the job list nor the formulas changed by one character).
  ex = Doom::JobExecutor.new(jobs, colormap, tx.tex_atlas, tx.flat_atlas,
                             wad.data, r.fuzzoffset, sw,
                             r.viewwindowx, r.viewwindowy, r.viewheight)

  fbs = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_sel(jobs, fbs, 0, 1, 0)
  File.open("#{dir}/spanfb_all.bin", "wb") { |f| f.write(fbs) }

  fbc = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_sel(jobs, fbc, 1, 1, 0)
  File.open("#{dir}/compfb.bin", "wb") { |f| f.write(fbc) }

  fbm = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_sel(jobs, fbm, 1, 1, 1)
  File.open("#{dir}/compfb_wsm.bin", "wb") { |f| f.write(fbm) }

  # A span of only the first job (the completion condition "a single span").
  # Spans use no zone window, so taking it into a separate `Jobs` is fine.
  jobsS = Doom::Jobs.new(sw, r.viewheight)
  sb0 = jobs.span_bank
  if jobs.nspan > 0
    jobsS.push_span(sb0[0], sb0[1], sb0[2], sb0[3], sb0[4], sb0[5], sb0[6])
  end
  exS = Doom::JobExecutor.new(jobsS, colormap, tx.tex_atlas, tx.flat_atlas,
                              wad.data, r.fuzzoffset, sw,
                              r.viewwindowx, r.viewwindowy, r.viewheight)
  fb1s = Doom::Bytes.buffer(sw * sh, 0)
  exS.run(jobsS, false, fb1s)
  File.open("#{dir}/spanfb_one.bin", "wb") { |f| f.write(fb1s) }

  nbs = jobs.nspan * Doom::Jobs::SP_NF * 4
  soas = Doom::Bytes.buffer(nbs > 0 ? nbs : 1, 0)
  jobs.pack(Doom::Jobs::KIND_SPAN, Doom::Jobs::LAYOUT_PLANAR_SOA, soas)
  File.open("#{dir}/span1_soa.bin", "wb") { |f| f.write(soas) }
  File.open("#{dir}/flat.bin", "wb") { |f| f.write(tx.flat_atlas) }

  # Checks the closed-form identity (for this one frame). Every frame of every demo is `sim_demo ... spanid`.
  jobs.check_span_closed
  # The masked distribution and batch split (for this one frame).
  jobs.check_masked_dist(r.fuzzoffset)
  jobs.check_masked_runs(r.fuzzoffset)
  jobs.check_opaque_cover

  # ================= masked / fuzz / full-screen input and oracles ================
  #
  #   masked_soa.bin  planar SoA of every masked job (9 planes). The raw form of the bytes the
  #                   GPU uploads every frame (repacking into the window atlas is on the host side)
  #   wallall_soa.bin planar SoA of **all** walls (phase 0 + phase 1's sky)
  #   mres_1.bin      the body of RES_WAD (the WAD's raw bytes)
  #   mres_2.bin      the body of RES_ZONE (this frame's zone window ring)
  #   fuzzoff.bin     the `fuzzoffset` table, 50 bytes (signed i8, +-1 line)
  #   opaquefb.bin    oracle: the screen with only all the walls drawn (stage (1)'s output)
  #   mfb_one.bin     oracle: **only the first non-fuzz masked job** (the completion condition)
  #   mfb_all.bin     oracle: every non-fuzz masked job (background 0)
  #   stagedfb.bin    oracle: the 3D view drawn **in the order of the GPU's stage configuration**
  #   fullfb.bin      oracle: the 3D view drawn **in the sequential schedule order**
  #                   (= `run`). Matching `stagedfb` is the evidence for reordering the stages
  nbm = jobs.nmasked * Doom::Jobs::MC_NF * 4
  soam = Doom::Bytes.buffer(nbm > 0 ? nbm : 1, 0)
  jobs.pack(Doom::Jobs::KIND_MASKED, Doom::Jobs::LAYOUT_PLANAR_SOA, soam)
  File.open("#{dir}/masked_soa.bin", "wb") { |f| f.write(soam) }

  # Take all the walls (phase 0 + sky) into a separate Jobs and make the planar SoA.
  # **Only `Jobs`'s public API** is used, for the same reason as jobs0 above.
  jobsA = Doom::Jobs.new(sw, r.viewheight)
  i = 0
  while i < jobs.nwall
    o = i * Doom::Jobs::WC_NF
    jobsA.push_wall(wb[o], wb[o + 1], wb[o + 2], wb[o + 3], wb[o + 4], wb[o + 5], wb[o + 6])
    i += 1
  end
  nba = jobs.nwall * Doom::Jobs::WC_NF * 4
  soaa = Doom::Bytes.buffer(nba > 0 ? nba : 1, 0)
  jobsA.pack(Doom::Jobs::KIND_WALL, Doom::Jobs::LAYOUT_PLANAR_SOA, soaa)
  File.open("#{dir}/wallall_soa.bin", "wb") { |f| f.write(soaa) }

  File.open("#{dir}/mres_1.bin", "wb") { |f| f.write(wad.data) }
  nz = jobs.nzone * Doom::Jobs::ZONE_STRIDE
  zb = Doom::Bytes.buffer(nz > 0 ? nz : 1, 0)
  Doom::Bytes.copy(zb, jobs.zonebuf, nz)
  File.open("#{dir}/mres_2.bin", "wb") { |f| f.write(zb) }

  fo = Doom::Bytes.buffer(50, 0)
  i = 0
  while i < 50
    fo.setbyte(i, r.fuzzoffset[i] & 255)
    i += 1
  end
  File.open("#{dir}/fuzzoff.bin", "wb") { |f| f.write(fo) }

  fbo = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_stage(jobs, fbo, 1)
  File.open("#{dir}/opaquefb.bin", "wb") { |f| f.write(fbo) }

  fbm1 = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_masked_n(jobs, fbm1, 1)
  File.open("#{dir}/mfb_one.bin", "wb") { |f| f.write(fbm1) }

  fbma = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_stage(jobs, fbma, 4)
  File.open("#{dir}/mfb_all.bin", "wb") { |f| f.write(fbma) }

  fbst = Doom::Bytes.buffer(sw * sh, 0)
  ex.run_staged(jobs, fbst)
  File.open("#{dir}/stagedfb.bin", "wb") { |f| f.write(fbst) }

  # Sequential (the schedule list itself). `run` runs the checker, but this is
  # statistics mode, so it does not fail past K_MAX.
  fbfu = Doom::Bytes.buffer(sw * sh, 0)
  ex.run(jobs, false, fbfu)
  File.open("#{dir}/fullfb.bin", "wb") { |f| f.write(fbfu) }

  # Checks byte for byte, for this one frame, **that reordering the stages did not change the
  # answer** (the ground for every frame is `cover_bad` being 0).
  staged_eq = Doom::Bytes.fnv1a64_hex_range(fbst, 0, sw * sh) ==
              Doom::Bytes.fnv1a64_hex_range(fbfu, 0, sw * sh) ? 1 : 0

  # Mixed (the GPU does walls and planes, the CPU masked). Given the 320x200 frame buffer the
  # GPU returned as the 5th argument, it **overlays only masked on the CPU** and
  # writes `hybridfb.bin`. If it matches `compfb_wsm.bin`, the mixed form holds.
  if ARGV.length > 4 && ARGV[4] != "-"
    gp = File.binread(ARGV[4])
    hyb = Doom::Bytes.buffer(sw * sh, 0)
    ngp = gp.bytesize < sw * sh ? gp.bytesize : sw * sh
    Doom::Bytes.copy(hyb, gp, ngp)
    ex.run_sel(jobs, hyb, 0, 0, 1)
    File.open("#{dir}/hybridfb.bin", "wb") { |f| f.write(hyb) }
  end

  # The bodies of the resident resources. The GPU side uploads them **only once, outside the
  # frame loop**. The atlas is only a reordering of `texdata`
  # (0 bytes disagree), so sending it is the same as
  # "sending the WAD's textures".
  File.open("#{dir}/atlas.bin", "wb") { |f| f.write(tx.tex_atlas) }
  File.open("#{dir}/cmap.bin", "wb") { |f| f.write(colormap) }

  # Frame constants and dimensions. Input of the generator (MLIR) and the checker (#1-#9).
  File.open("#{dir}/meta.tsv", "w") do |f|
    f.puts("#key\tvalue")
    f.puts("tic\t#{want}")
    f.puts("resscale\t#{rs}")
    f.puts("screen_w\t#{sw}")
    f.puts("screen_h\t#{sh}")
    f.puts("view_w\t#{sw}")
    f.puts("view_h\t#{r.viewheight}")
    f.puts("viewwindowx\t#{r.viewwindowx}")
    f.puts("viewwindowy\t#{r.viewwindowy}")
    f.puts("centery\t#{r.viewheight / 2}")
    f.puts("nwall\t#{jobs.nwall}")
    f.puts("wall_phase0_n\t#{n0}")
    f.puts("nspan\t#{jobs.nspan}")
    f.puts("nmasked\t#{jobs.nmasked}")
    f.puts("atlas_size\t#{tx.tex_atlas_size}")
    f.puts("flat_size\t#{tx.flat_atlas_size}")
    f.puts("cmap_bytes\t#{colormap.bytesize}")
    f.puts("cmap_rows\t34")
    f.puts("k_max\t#{Doom::Jobs::K_MAX}")
    f.puts("max_k_phase0\t#{jobs0.max_k}")
    f.puts("overlaps_phase0\t#{jobs0.overlaps}")
    f.puts("texcol_stride\t128")
    # ---- the span side ----
    f.puts("flat_stride\t4096")
    f.puts("span_k_small\t#{Doom::Jobs::SPAN_K_SMALL}")
    f.puts("span_k_max\t#{Doom::Jobs::SPAN_K_MAX}")
    f.puts("span_max_kx\t#{jobs.span_max_kx}")
    f.puts("span_overlaps\t#{jobs.span_overlaps}")
    f.puts("span_closed_bad\t#{jobs.span_closed_bad}")
    f.puts("span_closed_px\t#{jobs.span_closed_px}")
    f.puts("span_ycarry\t#{jobs.span_ycarry}")
    # ---- masked / fuzz / full screen ----
    f.puts("masked_k_small\t#{Doom::Jobs::MASKED_K_SMALL}")
    f.puts("masked_k_mid\t#{Doom::Jobs::MASKED_K_MID}")
    f.puts("masked_k_max\t#{Doom::Jobs::MASKED_K_MAX}")
    f.puts("fuzz_k\t#{Doom::Jobs::FUZZ_K}")
    f.puts("masked_max_kx\t#{jobs.masked_max_kx}")
    f.puts("fuzz_max_kx\t#{jobs.fuzz_max_kx}")
    f.puts("fuzz_n\t#{jobs.fuzz_n}")
    f.puts("masked_ovpairs\t#{jobs.masked_ovpairs}")
    f.puts("masked_ovpx\t#{jobs.masked_ovpx}")
    f.puts("masked_cover_px\t#{jobs.masked_cover_px}")
    f.puts("fuzz_conflicts\t#{jobs.fuzz_conflicts}")
    f.puts("fuzz_raw\t#{jobs.fuzz_raw}")
    f.puts("fuzz_run_raw\t#{jobs.fuzz_run_raw}")
    f.puts("fuzz_badrange\t#{jobs.fuzz_badrange}")
    f.puts("masked_runs\t#{jobs.masked_runs}")
    f.puts("masked_run_maxk\t#{jobs.masked_run_maxk}")
    f.puts("masked_dispatches\t#{jobs.masked_dispatches}")
    f.puts("fuzz_chain_max\t#{jobs.fuzz_chain_max}")
    f.puts("fuzz_chain_cap\t5")
    f.puts("wall_all_max_k\t#{jobs.wall_all_max_k}")
    f.puts("wall_all_overlaps\t#{jobs.wall_all_overlaps}")
    f.puts("cover_dbl\t#{jobs.cover_dbl}")
    f.puts("cover_bad\t#{jobs.cover_bad}")
    f.puts("cover_px\t#{jobs.cover_px}")
    f.puts("nzone\t#{jobs.nzone}")
    f.puts("zone_stride\t#{Doom::Jobs::ZONE_STRIDE}")
    f.puts("wad_size\t#{wad.data.bytesize}")
    f.puts("fuzz_cmap_row\t6")
    f.puts("staged_eq_full\t#{staged_eq}")
  end

  $stderr.puts "dump_jobs: tic=#{want} wall=#{jobs.nwall} span=#{jobs.nspan} " \
               "masked=#{jobs.nmasked} sched=#{jobs.nsched} zone=#{jobs.nzone} " \
               "max_k=#{jobs.max_k} overlaps=#{jobs.overlaps} packed=#{nb} " \
               "phase0=#{n0} max_k0=#{jobs0.max_k} ov0=#{jobs0.overlaps} soa0=#{nb0} " \
               "span_max_kx=#{jobs.span_max_kx} span_ov=#{jobs.span_overlaps} " \
               "span_bad=#{jobs.span_closed_bad}/#{jobs.span_closed_px} " \
               "span_carry=#{jobs.span_ycarry} soaS=#{nbs} " \
               "m_max_kx=#{jobs.masked_max_kx} fz_max_kx=#{jobs.fuzz_max_kx} " \
               "m_runs=#{jobs.masked_runs} m_disp=#{jobs.masked_dispatches} " \
               "wall_all_max_k=#{jobs.wall_all_max_k} wall_all_ov=#{jobs.wall_all_overlaps} " \
               "cov_bad=#{jobs.cover_bad} staged_eq=#{staged_eq}"
end

main
