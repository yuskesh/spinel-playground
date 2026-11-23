# doom/lib/doom/jobs.rb
#
# **Job IR**: drawing calls lowered into a POD list of "what to draw"
# (POD = plain old data). `Doom::Renderer` queues jobs here while it walks the BSP,
# and `Doom::JobExecutor` writes pixels looking **only** at the job list.
#
# The design's 3 pillars:
#
# 1. **A 2-layer ABI.** Layer 1 = the logical field definitions (names, order, types, ranges)
#    is fixed here. Layer 2 = the physical layout (AoS / planar SoA) is **not fixed**:
#    measured, planar SoA was 2.45 times faster on Metal, and on the CPU, on the contrary,
#    AoS was faster. **The layout is something a device chooses.**
#    The CPU executor reads AoS (one flat Array, `i * NF + f`), and
#    the planar SoA for the GPU (`f * n + i`) is packed by `pack` when asked for.
#
# 2. **Rings allocated ahead.** Zero allocation in the frame loop.
#    `Array.new` appears only in this file's `initialize`, and `reset` in the frame loop
#    only puts the indexes back to 0. Overflow **raises rather than dropping quietly**.
#
# 3. **One schedule list holds the order.** Even split into 3 banks (wall / span / masked),
#    the order of writes to the screen must be kept (in phase 1, sky
#    columns and spans alternate per visplane). `sc_kind` / `sc_idx` are
#    the issue order itself, and the executor walks it. Phase boundaries (check #6)
#    are kept as index boundaries inside the banks.
#
# The checker is in `check`. **#4 (exclusive y-intervals per x) runs every
# frame**: the correctness of the gather formulation depends on **a property of the data**
# that cannot be known at compile time, and observing one frame is not a proof.

require_relative "errors"
require_relative "bytes"

module Doom
  # A Job IR invariant was broken. **Never truncate quietly / never drop quietly.**
  class JobError < Error
  end

  class Jobs
    # ================= layer 1: logical field definitions (ABI) =====================
    #
    # Type spellings: 'i' = i32 / 'u' = u32 (16.16 fixed point; arithmetic always wraps) /
    #                 'x' = screen column / 'o' = offset in a resource / 'r' = resource number
    #
    # Declaring `iscale` and `texmid` u32 means something:
    #   `iscale = 0xffffffff / rw_scale` is **an unsigned 32-bit division**, and
    #   `frac >> 16` must be **an unsigned right shift**
    #   (`texmid` was measured to range over -3 866 624..11 468 800).

    KIND_WALL = 0        # opaque wall columns + sky columns (phase 0 / 1)
    KIND_SPAN = 1        # plane spans (phase 1)
    KIND_MASKED = 2      # masked columns (phase 2 / 3)
    NKIND = 3

    # ---- wall column (7 fields) ----
    WC_NF = 7
    WC_X = 0
    WC_YL = 1
    WC_YH = 2
    WC_ISCALE = 3
    WC_TEXMID = 4
    WC_SRCOFS = 5        # window start in the texture column atlas. **Always a multiple of 128**
    WC_CMAP = 6
    WC_FIELDS = "x,yl,yh,iscale,texmid,srcofs,cmap"
    WC_TYPES = "xiiuuoi"

    # ---- plane span (7 fields) ----
    #
    # The x/y fractions are **not** held **separately**. The reference (doomgeneric)'s `R_DrawSpan`
    # packs x and y into one 32-bit `position` and keeps adding `step`.
    # The Job IR holds them in that form: the meaning closes on one u32 addition, and
    # `spot` becomes a function of position alone (a precondition for the span gather).
    SP_NF = 7
    SP_Y = 0
    SP_X1 = 1
    SP_X2 = 2
    SP_POS = 3           # u32: the top 16 bits are x (6 integer + 10 fraction), the bottom y
    SP_STEP = 4          # u32
    SP_SRCOFS = 5        # plane start in the flat atlas. **Always a multiple of 4096**
    SP_CMAP = 6
    SP_FIELDS = "y,x1,x2,position,step,srcofs,cmap"
    SP_TYPES = "iiiuuoi"

    # ---- masked column (9 fields) ----
    #
    # Only 2 differences from wall: it **holds a resource number** (masked reads the posts of
    # a patch lump directly, so they are not in an atlas), and it holds **fuzz** (spectre)
    # as a precomputed `fuzzpos`.
    # `fuzz < 0` is an ordinary column; `0 <= fuzz < 50` is a fuzz column's starting phase.
    # "`fuzzpos` is a sequence that can be computed in advance, not an order dependence".
    MC_NF = 9
    MC_X = 0
    MC_YL = 1
    MC_YH = 2
    MC_ISCALE = 3
    MC_TEXMID = 4
    MC_SRCRES = 5
    MC_SRCOFS = 6
    MC_CMAP = 7
    MC_FUZZ = 8
    MC_FIELDS = "x,yl,yh,iscale,texmid,srcres,srcofs,cmap,fuzz"
    MC_TYPES = "xiiuurioi"

    # ---- resource numbers ----
    #
    # Masked columns are not in an atlas because their source is
    # "the 128 bytes following a post in a patch lump".
    # They can be cut into 128-byte windows, but **which windows are needed changes every frame**,
    # so they do not fit a static atlas. RES_WAD points straight into the WAD, and
    # RES_ZONE makes, in a per-frame ring, only the windows that run past a lump's end.
    RES_ATLAS = 0        # the texture column atlas (static, a row of 128B windows)
    RES_WAD = 1          # the WAD's raw bytes (masked posts; not 128-aligned)
    RES_ZONE = 2         # the zone window ring (per frame; 128B-aligned)
    RES_FLAT = 3         # the flat atlas (static, a row of 4096B planes)

    # ---- limits: **all decided from measurement** ----
    #
    # DEMO1 (E1M5, 5 026) + DEMO2 (E1M3, 3 836) + DEMO3 (E1M7, 2 134) =
    # the per-frame maximum over **all 10 996 frames**:
    #
    #   | bank   | DEMO1 | DEMO2 | DEMO3 | max  | limit (ratio) |
    #   | wall   |  1648 |  1614 |  1730 | 1730 | 4096 (2.4x) |
    #   | span   |   556 |  1023 |   612 | 1023 | 3072 (3.0x) |
    #   | masked |  1188 |  1029 |  2525 | 2525 | 8192 (3.2x) |
    #   | sched  |  2190 |  2149 |  3060 | 3060 |12288 (4.0x) |
    #   | zone   |   388 |   734 |  1006 | 1006 | 3072 (3.1x) |
    #
    # About 1.6 MB in all, allocated once in `initialize`. Overflow raises.
    CAP_WALL = 4096
    CAP_SPAN = 3072
    CAP_MASKED = 8192
    CAP_SCHED = 12288
    # The zone window ring. An earlier record says "20 columns over all 5 026 frames of DEMO1",
    # but that was about masked midtextures; with **sprites** included the
    # order of magnitude differs (up to 1 006 columns in one frame). In a small patch lump a post's
    # 128-byte window running past the lump's end is normal.
    ZONE_SLOTS = 3072
    # The ring's base width (the measurements above were taken at this width).
    SCREENWIDTH_BASE = 320
    ZONE_STRIDE = 128

    # Slots per x in the gather formulation.
    # **The earlier "K=4 is enough" came from observing one frame, and is not enough over all demos**:
    # the measured maximum over 10 996 frames is **13** (E1M5), and 25.1% of frames have K>4.
    # The declared value is 16. The wall gather is proportional to HxWxK, so
    # this pushes the 1920x1008 estimate of 0.707 ms up **about 3.3 times**.
    K_MAX = 16
    # The capacity the checker records with. To **count** going past K_MAX **before** failing,
    # the recording side is wide.
    K_CAP = 64

    # Slots per y in the span gather formulation.
    # Where the walls' K is "columns per x", the spans' K is
    # **"spans per y"** (the gather's iteration space is (y,x,k), and
    # the slots are cut by y).
    # **2 are declared** because of a carried-over note: the cost is **proportional to the declared K**,
    # not the effective max_k, so frames where a small K is enough should run on a small kernel.
    # K is part of the ABI the table holds, so "changing K per frame" needs both
    # the table and the kernel; hence **2 rows in the table, chosen by max_k**.
    SPAN_K_SMALL = 4
    SPAN_K_MAX = 16
    # The recording side (counts going past K before failing). y is at most viewheight rows, and
    # the spans on one row are bounded above by the number of visplanes (MAXVISPLANES=128).
    SPAN_K_CAP = 256

    # Slots in the masked gather formulation.
    #
    # Cut on **the same axis** as walls (y-intervals per x: a masked column also paints a
    # vertical closed interval on one x), but **exclusivity is not required**: masked columns
    # overlap by design (`seq_front_wins`), and the gather resolves it with "among the covering
    # slots, **the last in schedule order** wins". So K is an upper bound on "masked jobs per x",
    # not a forecast of exclusivity.
    #
    # Fuzz columns become **a separate stage** (their source is the frame buffer of the earlier
    # stages, so they cannot go in the same dispatch). So K is held separately too.
    #
    # The values come from measuring all 10 996 frames. The measured maximum of masked jobs per x
    # is **37**, and the distribution covers 84.0% at 8 / 98.1% at 16. So,
    # in the same manner as `plane_spans`, there is **one row per K**, but with
    # **3 rows** rather than 2 (8 / 16 / 40). The "9-16" band is 14.2%, and making it
    # pay for K=40 is expensive.
    MASKED_K_SMALL = 8
    MASKED_K_MID = 16
    MASKED_K_MAX = 40
    MASKED_K_CAP = 256
    # Fuzz's K **is 1**. The measured fuzz jobs per x are at most 5, but
    # fuzz jobs in the same column **create read-after-write** (54 pairs over all demos).
    # One dispatch "reads the input FB and writes the output FB", so with 2 in the same
    # column the later one cannot read the earlier one's result. Fuzz across columns never
    # touch each other, so **splitting the batches by slot index is structurally correct**:
    # it can be "built that way" rather than "measured and it was fine".
    FUZZ_K = 1
    # The upper bound on the number of fuzz batches in one frame (measured maximum 5).
    FUZZ_SPLIT_MAX = 8
    FUZZ_K_CAP = 64

    M32 = 0xffffffff

    attr_reader :nwall, :nspan, :nmasked, :nsched
    # The effective ring limits (scaled with the resolution). Read by dump_jobs and the checker.
    attr_reader :resscale, :cap_wall, :cap_span, :cap_masked, :cap_sched, :zone_slots
    attr_reader :wall_phase0_n, :masked_phase2_n
    attr_reader :zonebuf, :nzone

    # Read the live ring in its owner; exporting its String can snapshot it.
    def zone_byte(index)
      @zonebuf.getbyte(index)
    end
    attr_reader :max_k, :overlaps, :hi_wall, :hi_span, :hi_masked, :hi_sched, :hi_zone
    # Observations on the span side (#10 = exclusive x-intervals per y / the closed-form identity).
    attr_reader :span_max_kx, :span_overlaps
    attr_reader :span_closed_bad, :span_closed_px, :span_ycarry
    # Observations on masked / fuzz / "the opaque pass as a whole".
    # The per-frame `check` takes only K (cheap). The rest runs only when `check_masked_dist` /
    # `check_opaque_cover` are called explicitly (the same position as the spans' #11).
    attr_reader :masked_max_kx, :fuzz_max_kx, :fuzz_n
    attr_reader :masked_ovpairs, :masked_ovpx, :masked_cover_px
    attr_reader :fuzz_conflicts, :fuzz_raw, :fuzz_badrange, :fuzz_suffix
    attr_reader :wall_all_max_k, :wall_all_overlaps
    attr_reader :cover_dbl, :cover_bad, :cover_oob, :cover_px
    attr_reader :masked_runs, :masked_run_maxk, :fuzz_run_raw, :max_masked_runs
    attr_reader :masked_dispatches, :max_masked_dispatches, :tot_masked_dispatches
    attr_reader :fuzz_chain_max, :tot_fuzz_chain_max, :tot_fuzz_selfref_px
    # Running totals (accumulated across frames).
    attr_reader :tot_masked_ovpx, :tot_masked_cover_px, :tot_fuzz_conflicts,
                :tot_fuzz_raw, :tot_fuzz_badrange, :tot_cover_dbl, :tot_cover_px,
                :tot_masked_ovpairs, :tot_nonsuffix_frames, :tot_fuzz_frames,
                :tot_cover_bad, :tot_masked_runs, :tot_fuzz_run_raw

    def initialize(width, height)
      @width = width
      @height = height

      # **The ring limits are proportional to the resolution.**
      # Walls / masked columns are a family of "one per screen column", spans of "one per
      # scan line", so both grow in proportion to s = width/320 (the BSP's shape does not
      # change, so only **the counts** grow, not the numbers of visplanes / drawsegs /
      # vissprites; so MAXVISPLANES and the like are not touched here).
      #
      # The limits themselves are multiplied by s, keeping their ratio to the measured
      # maxima over 10 996 frames. **At s = 1 not one byte changes.**
      # The values really needed were measured again at all 4 resolutions.
      s = width / SCREENWIDTH_BASE
      s = 1 if s < 1
      @resscale = s
      @cap_wall = CAP_WALL * s
      @cap_span = CAP_SPAN * s
      @cap_masked = CAP_MASKED * s
      @cap_sched = CAP_SCHED * s
      @zone_slots = ZONE_SLOTS * s

      # ---- layer 2: the physical layout = AoS (one flat Array, `i * NF + f`).
      # Planar SoA is needed only when packing for the GPU, and `pack` does that.
      @wall = Array.new(@cap_wall * WC_NF, 0)
      @span = Array.new(@cap_span * SP_NF, 0)
      @masked = Array.new(@cap_masked * MC_NF, 0)
      @sc_kind = Array.new(@cap_sched, 0)
      @sc_idx = Array.new(@cap_sched, 0)
      @zonebuf = Bytes.buffer(@zone_slots * ZONE_STRIDE, 0)

      @nwall = 0
      @nspan = 0
      @nmasked = 0
      @nsched = 0
      @nzone = 0
      @wall_phase0_n = 0
      @masked_phase2_n = 0

      # The checker's work areas (allocated ahead).
      @xcount = Array.new(width, 0)
      @xyl = Array.new(width * K_CAP, 0)
      @xyh = Array.new(width * K_CAP, 0)
      @max_k = 0
      @overlaps = 0

      # The work areas of span check #10 (**allocated ahead**).
      # Walls are cut by x; spans by y.
      @ycount = Array.new(height, 0)
      @yx1 = Array.new(height * SPAN_K_CAP, 0)
      @yx2 = Array.new(height * SPAN_K_CAP, 0)
      @span_max_kx = 0
      @span_overlaps = 0
      @span_closed_bad = 0
      @span_closed_px = 0
      @span_ycarry = 0

      # The work areas of the masked checks (**allocated ahead**). The same "cut by x"
      # shape as walls, but **exclusivity is not required**, so besides lo/hi they hold
      # **the index in schedule order** (= the masked bank's index) and the fuzz phase: since
      # the gather's winner is "the last slot covering", the order itself is what is observed.
      @mcount = Array.new(width, 0)
      @mlo = Array.new(width * MASKED_K_CAP, 0)
      @mhi = Array.new(width * MASKED_K_CAP, 0)
      @mseq = Array.new(width * MASKED_K_CAP, 0)
      @mfz = Array.new(width * MASKED_K_CAP, 0)
      @masked_max_kx = 0
      @fuzz_max_kx = 0
      @fuzz_n = 0
      @masked_ovpairs = 0
      @masked_ovpx = 0
      @masked_cover_px = 0
      @fuzz_conflicts = 0
      @fuzz_raw = 0
      @fuzz_badrange = 0
      @fuzz_suffix = 1
      @wall_all_max_k = 0
      @wall_all_overlaps = 0
      @cover_dbl = 0
      @cover_bad = 0
      @cover_oob = 0
      @cover_px = 0
      @masked_runs = 0
      @masked_run_maxk = 0
      @fuzz_run_raw = 0
      @max_masked_runs = 0
      @masked_dispatches = 0
      @max_masked_dispatches = 0
      @fuzz_chain_max = 0
      @tot_fuzz_chain_max = 0
      @tot_fuzz_selfref_px = 0

      # A stamp scheme for counting per-pixel coverage (invalidated by a generation number
      # **to avoid a memset every frame**, without breaking the allocation ahead).
      @cov_stamp = Array.new(width * height, 0)
      @cov_cnt = Array.new(width * height, 0)
      @cov_last = Array.new(width * height, 0)
      @cov_gen = 0

      @tot_masked_ovpx = 0
      @tot_masked_cover_px = 0
      @tot_masked_ovpairs = 0
      @tot_fuzz_conflicts = 0
      @tot_fuzz_raw = 0
      @tot_fuzz_badrange = 0
      @tot_cover_dbl = 0
      @tot_cover_bad = 0
      @tot_cover_px = 0
      @tot_masked_runs = 0
      @tot_masked_dispatches = 0
      @tot_fuzz_run_raw = 0
      @tot_nonsuffix_frames = 0
      @tot_fuzz_frames = 0

      # High-water marks (to get the ground for the ring sizes from measurement).
      @hi_wall = 0
      @hi_span = 0
      @hi_masked = 0
      @hi_sched = 0
      @hi_zone = 0
    end

    # The start of a frame. **It only puts the indexes back**: not one byte is allocated.
    def reset
      @nwall = 0
      @nspan = 0
      @nmasked = 0
      @nsched = 0
      @nzone = 0
      @wall_phase0_n = 0
      @masked_phase2_n = 0
      @max_k = 0
      @overlaps = 0
      # Span observations are per frame too (the same position as the walls' max_k / overlaps).
      # `span_closed_*` and `span_ycarry` are **running** totals, so they are not reset.
      @span_max_kx = 0
      @span_overlaps = 0
      # The masked / fuzz / opaque pass observations are per frame too.
      # `tot_*` are running totals, so they are not reset.
      @masked_max_kx = 0
      @fuzz_max_kx = 0
      @fuzz_n = 0
      @masked_ovpairs = 0
      @masked_ovpx = 0
      @masked_cover_px = 0
      @fuzz_conflicts = 0
      @fuzz_raw = 0
      @fuzz_badrange = 0
      @fuzz_suffix = 1
      @wall_all_max_k = 0
      @wall_all_overlaps = 0
      @cover_dbl = 0
      @cover_bad = 0
      @cover_oob = 0
      @cover_px = 0
      @masked_runs = 0
      @masked_run_maxk = 0
      @fuzz_run_raw = 0
      @masked_dispatches = 0
      @fuzz_chain_max = 0
    end

    # Records the phase boundary (check #6). Phases only advance, so
    # "the index boundary inside a bank" is itself the phase boundary.
    def mark_phase1
      @wall_phase0_n = @nwall
    end

    def mark_phase3
      @masked_phase2_n = @nmasked
    end

    def push_wall(x, yl, yh, iscale, texmid, srcofs, cmap)
      i = @nwall
      raise JobError, "wall column ring overflow: #{i} jobs, CAP_WALL=#{@cap_wall}" if i >= @cap_wall
      b = i * WC_NF
      @wall[b + WC_X] = x
      @wall[b + WC_YL] = yl
      @wall[b + WC_YH] = yh
      @wall[b + WC_ISCALE] = iscale
      @wall[b + WC_TEXMID] = texmid
      @wall[b + WC_SRCOFS] = srcofs
      @wall[b + WC_CMAP] = cmap
      @nwall = i + 1
      s = @nsched
      raise JobError, "schedule ring overflow: #{s} entries, CAP_SCHED=#{@cap_sched}" if s >= @cap_sched
      @sc_kind[s] = KIND_WALL
      @sc_idx[s] = i
      @nsched = s + 1
    end

    def push_span(y, x1, x2, position, step, srcofs, cmap)
      i = @nspan
      raise JobError, "plane span ring overflow: #{i} jobs, CAP_SPAN=#{@cap_span}" if i >= @cap_span
      b = i * SP_NF
      @span[b + SP_Y] = y
      @span[b + SP_X1] = x1
      @span[b + SP_X2] = x2
      @span[b + SP_POS] = position
      @span[b + SP_STEP] = step
      @span[b + SP_SRCOFS] = srcofs
      @span[b + SP_CMAP] = cmap
      @nspan = i + 1
      s = @nsched
      raise JobError, "schedule ring overflow: #{s} entries, CAP_SCHED=#{@cap_sched}" if s >= @cap_sched
      @sc_kind[s] = KIND_SPAN
      @sc_idx[s] = i
      @nsched = s + 1
    end

    def push_masked(x, yl, yh, iscale, texmid, srcres, srcofs, cmap, fuzz)
      i = @nmasked
      raise JobError, "masked column ring overflow: #{i} jobs, CAP_MASKED=#{@cap_masked}" if i >= @cap_masked
      b = i * MC_NF
      @masked[b + MC_X] = x
      @masked[b + MC_YL] = yl
      @masked[b + MC_YH] = yh
      @masked[b + MC_ISCALE] = iscale
      @masked[b + MC_TEXMID] = texmid
      @masked[b + MC_SRCRES] = srcres
      @masked[b + MC_SRCOFS] = srcofs
      @masked[b + MC_CMAP] = cmap
      @masked[b + MC_FUZZ] = fuzz
      @nmasked = i + 1
      s = @nsched
      raise JobError, "schedule ring overflow: #{s} entries, CAP_SCHED=#{@cap_sched}" if s >= @cap_sched
      @sc_kind[s] = KIND_MASKED
      @sc_idx[s] = i
      @nsched = s + 1
    end

    # Borrows one zone window. Returns an offset inside `zonebuf` (a multiple of 128).
    def alloc_zone_window
      i = @nzone
      raise JobError, "zone window ring overflow: #{i} windows, ZONE_SLOTS=#{@zone_slots}" if i >= @zone_slots
      @nzone = i + 1
      i * ZONE_STRIDE
    end

    # ---- reading ----
    #
    # The executor is given **the banks themselves** (it writes `i * NF + f` on its side).
    # Fetching 7-9 fields per job through accessors would add an order of magnitude of calls,
    # and could also create a cycle in the value flow. The banks' Arrays are made
    # only once in `initialize` and **never replaced** afterwards, so
    # the executor can hold them from construction.
    def wall_bank
      @wall
    end

    def span_bank
      @span
    end

    def masked_bank
      @masked
    end

    def sched_kind_bank
      @sc_kind
    end

    def sched_idx_bank
      @sc_idx
    end

    # ================= the checker ==============================================
    #
    # Runs every frame. **#1-#3 (invariants) always raise**: when broken they touch
    # outside the frame buffer or the atlas, so not even statistics mode lets them through.
    # `strict` applies **only to #5 (past K_MAX) and #4 (overlaps)**;
    # those forecast "whether the wall gather holds" and are not conditions of this executor's
    # correctness, so statistics mode can just count them
    # (that is how every frame of DEMO1/2/3 was run).
    #
    # The checks and their numbers:
    #   #1 coordinates inside the screen   - every job
    #   #2 srcofs alignment and range      - wall (128) / span (4096)
    #   #3 cmap is 0..33
    #   #4 **exclusive y-intervals per x** - phase 0 wall columns. The gather's precondition
    #   #5 jobs per x <= K_MAX             - likewise
    #   #6 phase number matches dispatch order - holds structurally at the banks' index boundaries
    def check(strict, atlas_size, flat_size, cmap_rows)
      i = 0
      n = @nwall
      while i < n
        b = i * WC_NF
        x = @wall[b + WC_X]
        yl = @wall[b + WC_YL]
        yh = @wall[b + WC_YH]
        o = @wall[b + WC_SRCOFS]
        cm = @wall[b + WC_CMAP]
        if x < 0 || x >= @width || yl < -1 || yh >= @height
          raise JobError, "wall job #{i}: x=#{x} yl=#{yl} yh=#{yh} out of 0..#{@width - 1} / #{@height}"
        end
        if (o & 127) != 0 || o < 0 || o + 127 >= atlas_size
          raise JobError, "wall job #{i}: srcofs=#{o} not a 128-aligned window inside the atlas (#{atlas_size} B)"
        end
        if cm < 0 || cm >= cmap_rows
          raise JobError, "wall job #{i}: cmap=#{cm} out of 0..#{cmap_rows - 1}"
        end
        i += 1
      end

      i = 0
      n = @nspan
      while i < n
        b = i * SP_NF
        y = @span[b + SP_Y]
        x1 = @span[b + SP_X1]
        x2 = @span[b + SP_X2]
        o = @span[b + SP_SRCOFS]
        cm = @span[b + SP_CMAP]
        if y < 0 || y >= @height || x1 < 0 || x2 >= @width || x1 > x2
          raise JobError, "span job #{i}: y=#{y} x1=#{x1} x2=#{x2} out of the view rectangle"
        end
        if (o & 4095) != 0 || o < 0 || o + 4095 >= flat_size
          raise JobError, "span job #{i}: srcofs=#{o} not a 4096-aligned flat inside the atlas (#{flat_size} B)"
        end
        if cm < 0 || cm >= cmap_rows
          raise JobError, "span job #{i}: cmap=#{cm} out of 0..#{cmap_rows - 1}"
        end
        i += 1
      end

      i = 0
      n = @nmasked
      while i < n
        b = i * MC_NF
        x = @masked[b + MC_X]
        cm = @masked[b + MC_CMAP]
        fz = @masked[b + MC_FUZZ]
        if x < 0 || x >= @width
          raise JobError, "masked job #{i}: x=#{x} out of 0..#{@width - 1}"
        end
        if fz < 0 && (cm < 0 || cm >= cmap_rows)
          raise JobError, "masked job #{i}: cmap=#{cm} out of 0..#{cmap_rows - 1}"
        end
        if fz >= 50
          raise JobError, "masked job #{i}: fuzzpos=#{fz} out of 0..49"
        end
        i += 1
      end

      check_disjoint(0, @wall_phase0_n, strict)
      # Check #10: spans exclusive per y. The same position as the walls' #4 (every frame,
      # raising only when `strict`), and **the very precondition of the gather formulation**.
      check_span_disjoint(strict)
      # Check #12: slots per x for masked / fuzz, and
      # **exclusivity per x of the opaque pass as a whole (walls phase 0 + sky phase 1)**.
      # Both are the cheap O(K^2 * W) form and run every frame (the same position as #4 / #10).
      check_masked_k(strict)
      check_wall_all(strict)

      @hi_wall = @nwall if @nwall > @hi_wall
      @hi_span = @nspan if @nspan > @hi_span
      @hi_masked = @nmasked if @nmasked > @hi_masked
      @hi_sched = @nsched if @nsched > @hi_sched
      @hi_zone = @nzone if @nzone > @hi_zone
    end

    # Checks #4 / #5: **y-intervals are exclusive per x**.
    #
    # The correctness of the gather formulation (the decided route) depends on **a property of
    # the data**: "no two jobs on the same x cover the same y". It cannot be known at
    # compile time, so the CPU executor checks it every frame in O(K^2 * W)
    # (W=320, K<=4: at most 1 920 comparisons).
    def check_disjoint(lo, hi, strict)
      x = 0
      w = @width
      while x < w
        @xcount[x] = 0
        x += 1
      end
      i = lo
      while i < hi
        b = i * WC_NF
        yl = @wall[b + WC_YL]
        yh = @wall[b + WC_YH]
        if yl <= yh                       # an empty job covers nothing, so it is not counted
          x = @wall[b + WC_X]
          k = @xcount[x]
          if k >= K_CAP
            raise JobError, "wall column x=#{x} has more than #{K_CAP} jobs (K_CAP)"
          end
          @xyl[x * K_CAP + k] = yl
          @xyh[x * K_CAP + k] = yh
          @xcount[x] = k + 1
        end
        i += 1
      end
      x = 0
      while x < w
        k = @xcount[x]
        @max_k = k if k > @max_k
        if strict && k > K_MAX
          raise JobError, "check #5: x=#{x} has #{k} wall jobs, K_MAX=#{K_MAX}"
        end
        a = 0
        while a < k
          bb = a + 1
          while bb < k
            al = @xyl[x * K_CAP + a]
            ah = @xyh[x * K_CAP + a]
            bl = @xyl[x * K_CAP + bb]
            bh = @xyh[x * K_CAP + bb]
            if al <= bh && bl <= ah
              @overlaps += 1
              if strict
                raise JobError,
                      "check #4: x=#{x} wall jobs overlap in y: [#{al},#{ah}] and [#{bl},#{bh}]"
              end
            end
            bb += 1
          end
          a += 1
        end
        x += 1
      end
    end

    # Check #10: **x-intervals are exclusive per y**.
    #
    # The span gather formulation rests on the property **dual** to the walls' "y-intervals
    # exclusive per x" (check #4): "no two spans on the same y cover the same x".
    # Why it holds looks visually obvious (visplanes partition the screen), but
    # **that is not a proof**: in the same way the walls were measured over 10 996 frames,
    # the spans are measured every frame too.
    #
    # The cost is O(K^2 * H). H=168 and the measured K is small, so it is the same order as the walls' #4.
    def check_span_disjoint(strict)
      y = 0
      h = @height
      while y < h
        @ycount[y] = 0
        y += 1
      end
      i = 0
      n = @nspan
      while i < n
        b = i * SP_NF
        x1 = @span[b + SP_X1]
        x2 = @span[b + SP_X2]
        if x1 <= x2                       # an empty span paints not one pixel
          yy = @span[b + SP_Y]
          k = @ycount[yy]
          if k >= SPAN_K_CAP
            raise JobError, "span row y=#{yy} has more than #{SPAN_K_CAP} spans (SPAN_K_CAP)"
          end
          @yx1[yy * SPAN_K_CAP + k] = x1
          @yx2[yy * SPAN_K_CAP + k] = x2
          @ycount[yy] = k + 1
        end
        i += 1
      end
      y = 0
      while y < h
        k = @ycount[y]
        @span_max_kx = k if k > @span_max_kx
        if strict && k > SPAN_K_MAX
          raise JobError, "check #10: y=#{y} has #{k} spans, SPAN_K_MAX=#{SPAN_K_MAX}"
        end
        a = 0
        while a < k
          bb = a + 1
          while bb < k
            al = @yx1[y * SPAN_K_CAP + a]
            ah = @yx2[y * SPAN_K_CAP + a]
            bl = @yx1[y * SPAN_K_CAP + bb]
            bh = @yx2[y * SPAN_K_CAP + bb]
            if al <= bh && bl <= ah
              @span_overlaps += 1
              if strict
                raise JobError,
                      "check #10: y=#{y} spans overlap in x: [#{al},#{ah}] and [#{bl},#{bh}]"
              end
            end
            bb += 1
          end
          a += 1
        end
        y += 1
      end
    end

    # Checks the closed-form identity.
    #
    # `JobExecutor#exec_span` adds `position += step` **sequentially**, but
    # the gather kernel must draw pixel x independently of other pixels, so it
    #
    #     position(x) = position0 + (x - x1) * step        (mod 2^32)
    #
    # uses the **closed form** above. There is only addition, so under 32-bit wrapping they are
    # exactly equal, "in theory". As with the walls, **check on real data first**,
    # then write the kernel. What is compared is **both** `position` itself and
    # the `spot` taken from it (spot is nonlinear, so even with position right,
    # a wrong spelling picks a different texel).
    #
    # The cost is proportional to one frame's span pixels (at most W*H), so it is **not
    # part of** the per-frame `check`. It is called explicitly only when measuring.
    def check_span_closed
      i = 0
      n = @nspan
      while i < n
        b = i * SP_NF
        x1 = @span[b + SP_X1]
        count = @span[b + SP_X2] - x1
        pos0 = @span[b + SP_POS] & M32
        step = @span[b + SP_STEP] & M32
        seq = pos0
        j = 0
        while j <= count
          closed = (pos0 + j * step) & M32
          @span_closed_px += 1
          # Carries from the y field (bottom 16 bits) leak into the x field
          # (the semantics of the packed position). Counts how many pixels it happens on.
          @span_ycarry += 1 if (seq & 0xffff) + (step & 0xffff) > 0xffff
          if closed != seq
            @span_closed_bad += 1
          elsif ((closed >> 26) | ((closed >> 4) & 0x0fc0)) !=
                ((seq >> 26) | ((seq >> 4) & 0x0fc0))
            @span_closed_bad += 1
          end
          seq = (seq + step) & M32
          j += 1
        end
        i += 1
      end
    end

    # Check #12: **slots per x** for masked / fuzz.
    #
    # Unlike walls (#5) or spans (#10), **exclusivity is not required**. Masked is
    # `seq_front_wins`: overlapping is by design. What the gather formulation requires is
    #
    #   (1) the jobs per x are at most the declared K (this method)
    #   (2) "among the covering slots, the last in schedule order wins"
    #       matches sequential execution (holds structurally: a masked job is a post
    #       already resolved into an opaque contiguous interval, so it paints every pixel
    #       of `[yl,yh]` **unconditionally**; transparency was decided when it was made)
    #
    # and only these 2. Fuzz columns are a separate stage (a separate dispatch), so they are counted separately.
    def check_masked_k(strict)
      x = 0
      w = @width
      while x < w
        @mcount[x] = 0
        x += 1
      end
      nf = 0
      i = 0
      n = @nmasked
      while i < n
        b = i * MC_NF
        yl = @masked[b + MC_YL]
        yh = @masked[b + MC_YH]
        if yl <= yh
          x = @masked[b + MC_X]
          k = @mcount[x]
          if k >= MASKED_K_CAP
            raise JobError, "masked column x=#{x} has more than #{MASKED_K_CAP} jobs (MASKED_K_CAP)"
          end
          @mlo[x * MASKED_K_CAP + k] = yl
          @mhi[x * MASKED_K_CAP + k] = yh
          @mseq[x * MASKED_K_CAP + k] = i
          @mfz[x * MASKED_K_CAP + k] = @masked[b + MC_FUZZ]
          @mcount[x] = k + 1
          nf += 1 if @masked[b + MC_FUZZ] >= 0
        end
        i += 1
      end
      @fuzz_n = nf
      x = 0
      while x < w
        k = @mcount[x]
        kf = 0
        km = 0
        a = 0
        while a < k
          if @mfz[x * MASKED_K_CAP + a] >= 0
            kf += 1
          else
            km += 1
          end
          a += 1
        end
        @masked_max_kx = km if km > @masked_max_kx
        @fuzz_max_kx = kf if kf > @fuzz_max_kx
        if strict && km > MASKED_K_MAX
          raise JobError, "check #12: x=#{x} has #{km} masked jobs, MASKED_K_MAX=#{MASKED_K_MAX}"
        end
        if strict && kf > FUZZ_SPLIT_MAX
          raise JobError, "check #12: x=#{x} has #{kf} fuzz jobs, FUZZ_SPLIT_MAX=#{FUZZ_SPLIT_MAX}"
        end
        x += 1
      end
    end

    # Check #13: exclusivity per x looking at **the whole wall bank** (phase 0 opaque walls +
    # phase 1 sky columns).
    #
    # The earlier GPU route drew only phase 0, because exclusivity had been proven only
    # there. **A screen missing the sky is not "the ordinary game screen"**,
    # so to meet the completion condition the GPU must draw the sky columns too.
    # Sky columns read from the same `RES_ATLAS` and follow the same closed form, so **as long as
    # exclusivity holds they can simply be mixed into the wall stage** (`@max_k` / `@overlaps`
    # stay the phase 0 observations, unchanged, for continuity).
    def check_wall_all(strict)
      x = 0
      w = @width
      while x < w
        @xcount[x] = 0
        x += 1
      end
      i = 0
      n = @nwall
      while i < n
        b = i * WC_NF
        yl = @wall[b + WC_YL]
        yh = @wall[b + WC_YH]
        if yl <= yh
          x = @wall[b + WC_X]
          k = @xcount[x]
          if k >= K_CAP
            raise JobError, "wall column x=#{x} has more than #{K_CAP} jobs (K_CAP)"
          end
          @xyl[x * K_CAP + k] = yl
          @xyh[x * K_CAP + k] = yh
          @xcount[x] = k + 1
        end
        i += 1
      end
      x = 0
      while x < w
        k = @xcount[x]
        @wall_all_max_k = k if k > @wall_all_max_k
        if strict && k > K_MAX
          raise JobError, "check #13: x=#{x} has #{k} wall jobs (incl. sky), K_MAX=#{K_MAX}"
        end
        a = 0
        while a < k
          bb = a + 1
          while bb < k
            al = @xyl[x * K_CAP + a]
            ah = @xyh[x * K_CAP + a]
            bl = @xyl[x * K_CAP + bb]
            bh = @xyh[x * K_CAP + bb]
            if al <= bh && bl <= ah
              @wall_all_overlaps += 1
              if strict
                raise JobError,
                      "check #13: x=#{x} wall jobs (incl. sky) overlap in y: " \
                      "[#{al},#{ah}] and [#{bl},#{bh}]"
              end
            end
            bb += 1
          end
          a += 1
        end
        x += 1
      end
    end

    # The masked distribution. **A measurement for deciding the design**,
    # not part of the per-frame `check` (the cost is proportional to the masked pixels).
    #
    # What it counts:
    #
    #   masked_ovpairs   the number of (masked, masked) pairs whose intervals overlap per x
    #   masked_ovpx      the number of **pixels covered by 2 or more** (pixels, not pairs)
    #   masked_cover_px  the total pixels masked covered (the denominator of ratios)
    #   fuzz_conflicts   the number of combinations where **moving fuzz to a later stage changes the answer**.
    #                    If a non-fuzz job M issued **after** a fuzz job F touches the range
    #                    F reads ([yl-1, yh+1]) on the same x, the reordering
    #                    "all non-fuzz -> all fuzz" is invalid
    #   fuzz_raw         read-after-write between fuzz jobs. If a later F2 reads a pixel
    #                    F1 wrote, it **cannot be expressed in one dispatch**
    #   fuzz_badrange    fuzz jobs with `yl < 1` or `yh > viewheight-2`
    #                    (checks the screen-edge clamp is in effect)
    #   fuzz_suffix      whether that screen's fuzz jobs are a **suffix** of the masked list
    #
    # `fuzzoffset` is taken as an argument because the line read is `y + fuzzoffset[fp]`
    # (decided by **the lines actually read**, not the conservative [yl-1, yh+1]).
    def check_masked_dist(fuzzoffset)
      check_masked_k(false)
      @cov_gen += 1
      g = @cov_gen
      w = @width
      h = @height
      ovpx = 0
      cover = 0
      i = 0
      n = @nmasked
      while i < n
        b = i * MC_NF
        yl = @masked[b + MC_YL]
        yh = @masked[b + MC_YH]
        if yl <= yh
          x = @masked[b + MC_X]
          y = yl
          while y <= yh
            if y >= 0 && y < h
              o = y * w + x
              if @cov_stamp[o] == g
                c = @cov_cnt[o] + 1
                @cov_cnt[o] = c
                ovpx += 1 if c == 1
              else
                @cov_stamp[o] = g
                @cov_cnt[o] = 0
              end
              cover += 1
            end
            y += 1
          end
        end
        i += 1
      end
      @masked_ovpx = ovpx
      @masked_cover_px = cover
      @tot_masked_ovpx += ovpx
      @tot_masked_cover_px += cover

      # The number of pairs and fuzz staging safety are looked at per x (`check_masked_k`
      # has already packed the per-x bundles).
      pairs = 0
      conf = 0
      raw = 0
      x = 0
      while x < w
        k = @mcount[x]
        a = 0
        while a < k
          al = @mlo[x * MASKED_K_CAP + a]
          ah = @mhi[x * MASKED_K_CAP + a]
          afz = @mfz[x * MASKED_K_CAP + a]
          bb = a + 1
          while bb < k
            bl = @mlo[x * MASKED_K_CAP + bb]
            bh = @mhi[x * MASKED_K_CAP + bb]
            bfz = @mfz[x * MASKED_K_CAP + bb]
            pairs += 1 if al <= bh && bl <= ah
            # `a` is always earlier in schedule order (`mseq` is packed monotonically).
            if afz >= 0 && bfz < 0
              # A non-fuzz M=b **after** a fuzz F=a. Reordered, M runs first, so
              # if M touches the interval F writes or the lines it reads, the answer changes.
              conf += 1 if bl <= ah + 1 && al - 1 <= bh
            elsif afz >= 0 && bfz >= 0
              # Fuzz with fuzz. If a line F2=b reads has a pixel F1=a wrote,
              # it cannot be expressed in one stage where "every fuzz reads the same input FB".
              raw += 1 if fuzz_reads_into(fuzzoffset, bl, bh, bfz, al, ah)
            end
            bb += 1
          end
          a += 1
        end
        x += 1
      end
      @masked_ovpairs = pairs
      @fuzz_conflicts = conf
      @fuzz_raw = raw
      @tot_masked_ovpairs += pairs
      @tot_fuzz_conflicts += conf
      @tot_fuzz_raw += raw

      # The fuzz y clipping, and whether fuzz is a suffix of the masked list.
      bad = 0
      seen_fuzz = 0
      suffix = 1
      i = 0
      while i < n
        b = i * MC_NF
        fz = @masked[b + MC_FUZZ]
        yl = @masked[b + MC_YL]
        yh = @masked[b + MC_YH]
        if fz >= 0
          seen_fuzz = 1
          bad += 1 if yl <= yh && (yl < 1 || yh > h - 2)
        elsif seen_fuzz == 1 && yl <= yh
          suffix = 0
        end
        i += 1
      end
      @fuzz_badrange = bad
      @fuzz_suffix = suffix

      # The depth of a fuzz column's **self-reference**.
      # When `off(y) = -1` and `y > yl`, the pixel `R_DrawFuzzColumn` reads is
      # **one the same job wrote just before**. The gather kernel closes that
      # sequential dependence as `f(y) = C^(j+1)[fb0[...]]`, so **the upper bound on j**
      # decides the number of unrolled steps. Here j is measured on real data
      # (the static bound is the longest run of -1 in `fuzzoffset` = 4).
      cmax = 0
      selfpx = 0
      i = 0
      while i < n
        b = i * MC_NF
        fz = @masked[b + MC_FUZZ]
        if fz >= 0
          yl = @masked[b + MC_YL]
          yh = @masked[b + MC_YH]
          y = yl
          while y <= yh
            j = 0
            t = y
            while t > yl
              fp = fz + (t - yl)
              fp -= 50 while fp >= 50
              break if fuzzoffset[fp] >= 0
              j += 1
              t -= 1
            end
            selfpx += 1 if j > 0
            cmax = j if j > cmax
            y += 1
          end
        end
        i += 1
      end
      @fuzz_chain_max = cmax
      @tot_fuzz_selfref_px += selfpx
      @tot_fuzz_chain_max = cmax if cmax > @tot_fuzz_chain_max
      @tot_fuzz_badrange += bad
      @tot_fuzz_frames += 1 if @fuzz_n > 0
      @tot_nonsuffix_frames += 1 if @fuzz_n > 0 && suffix == 0
    end

    # Whether any line the fuzz job (`lo..hi`, starting phase `fz`) actually reads falls
    # in `[wlo,whi]`. At pixel y `R_DrawFuzzColumn` reads
    # `y + fuzzoffset[(fz + y - lo) mod 50]`.
    def fuzz_reads_into(fuzzoffset, lo, hi, fz, wlo, whi)
      y = lo
      fp = fz
      while y <= hi
        r = y + fuzzoffset[fp]
        return true if r >= wlo && r <= whi
        fp += 1
        fp = 0 if fp == 50
        y += 1
      end
      false
    end

    # Coverage of the opaque pass. Counts per pixel **walls (phase 0 + sky) and spans
    # together**.
    #
    # It is needed because the GPU route **reorders** the stages: the sequential schedule list
    # is "walls phase 0 -> (sky phase 1 and spans alternating per visplane)", but the GPU
    # draws with 2 dispatches, "all walls -> all spans". The reordering changes the answer
    # only when **"a span also writes a pixel that a wall wrote last sequentially"**
    # (on the GPU the span comes later, so the span's value would remain).
    # So it counts 2 things:
    #
    #   cover_dbl  pixels written twice or more (wall x span; wall with wall is #13, span with span #10)
    #   cover_bad  **those whose last sequential writer is a wall** = the pixels the reordering
    #              breaks. If this is 0, swapping the stages does not change the answer
    #
    # **It walks the schedule list**, so the order is exactly what the Job IR holds.
    def check_opaque_cover
      @cov_gen += 1
      g = @cov_gen
      w = @width
      h = @height
      dbl = 0
      oob = 0
      px = 0
      s = 0
      ns = @nsched
      while s < ns
        k = @sc_kind[s]
        j = @sc_idx[s]
        if k == KIND_WALL
          b = j * WC_NF
          yl = @wall[b + WC_YL]
          yh = @wall[b + WC_YH]
          if yl <= yh
            x = @wall[b + WC_X]
            y = yl
            while y <= yh
              if y < 0 || y >= h
                oob += 1
              else
                o = y * w + x
                if @cov_stamp[o] == g
                  dbl += 1
                  @cov_cnt[o] = @cov_cnt[o] | 1
                else
                  @cov_stamp[o] = g
                  @cov_cnt[o] = 1
                end
                @cov_last[o] = 0
                px += 1
              end
              y += 1
            end
          end
        elsif k == KIND_SPAN
          b = j * SP_NF
          x1 = @span[b + SP_X1]
          x2 = @span[b + SP_X2]
          if x1 <= x2
            y = @span[b + SP_Y]
            x = x1
            while x <= x2
              if y < 0 || y >= h || x < 0 || x >= w
                oob += 1
              else
                o = y * w + x
                if @cov_stamp[o] == g
                  dbl += 1
                  @cov_cnt[o] = @cov_cnt[o] | 2
                else
                  @cov_stamp[o] = g
                  @cov_cnt[o] = 2
                end
                @cov_last[o] = 1
                px += 1
              end
              x += 1
            end
          end
        end
        s += 1
      end
      # Pixels the reordering breaks: both a wall and a span wrote them, and **the last writer is a wall**.
      bad = 0
      o = 0
      nn = w * h
      while o < nn
        bad += 1 if @cov_stamp[o] == g && @cov_cnt[o] == 3 && @cov_last[o] == 0
        o += 1
      end
      @cover_dbl = dbl
      @cover_bad = bad
      @cover_oob = oob
      @cover_px = px
      @tot_cover_dbl += dbl
      @tot_cover_bad += bad
      @tot_cover_px += px
    end

    # The masked batch split.
    #
    # Fuzz reads "the screen already drawn", so the reordering **draw all non-fuzz and then
    # all fuzz** is invalid in general (measured: `fuzz_conflicts`).
    # Taking the staged strategy "a conservative order-keeping version -> extract non-overlapping batches"
    # plainly gives a split of the masked list into **contiguous batches cut where the kind
    # (non-fuzz / fuzz) changes**: order is kept inside a batch, and batch boundaries
    # become dispatch boundaries. What it counts:
    #
    #   masked_runs      the number of batches (= the number of dispatches)
    #   masked_run_maxk  the maximum jobs per x inside a batch (= the lower bound on the declared K)
    #   fuzz_run_raw     read-after-write **inside the same fuzz batch**.
    #                    If this is not 0, the batch must be split further
    def check_masked_runs(fuzzoffset)
      n = @nmasked
      runs = 0
      runmax = 0
      raw = 0
      disp = 0
      i = 0
      w = @width
      while i < n
        # Skip empty jobs and decide the next batch's kind.
        while i < n && @masked[i * MC_NF + MC_YL] > @masked[i * MC_NF + MC_YH]
          i += 1
        end
        break if i >= n
        kind = @masked[i * MC_NF + MC_FUZZ] >= 0 ? 1 : 0
        lo = i
        while i < n
          b = i * MC_NF
          if @masked[b + MC_YL] <= @masked[b + MC_YH]
            kk = @masked[b + MC_FUZZ] >= 0 ? 1 : 0
            break if kk != kind
          end
          i += 1
        end
        runs += 1
        # This batch's maximum jobs per x, and RAW if it is fuzz.
        x = 0
        while x < w
          @mcount[x] = 0
          x += 1
        end
        j = lo
        while j < i
          b = j * MC_NF
          yl = @masked[b + MC_YL]
          yh = @masked[b + MC_YH]
          if yl <= yh
            x = @masked[b + MC_X]
            k = @mcount[x]
            if k < MASKED_K_CAP
              @mlo[x * MASKED_K_CAP + k] = yl
              @mhi[x * MASKED_K_CAP + k] = yh
              @mfz[x * MASKED_K_CAP + k] = @masked[b + MC_FUZZ]
              @mcount[x] = k + 1
            end
          end
          j += 1
        end
        x = 0
        rk = 0
        while x < w
          k = @mcount[x]
          runmax = k if k > runmax
          rk = k if k > rk
          if kind == 1
            a = 0
            while a < k
              bb = a + 1
              while bb < k
                if fuzz_reads_into(fuzzoffset,
                                   @mlo[x * MASKED_K_CAP + bb], @mhi[x * MASKED_K_CAP + bb],
                                   @mfz[x * MASKED_K_CAP + bb],
                                   @mlo[x * MASKED_K_CAP + a], @mhi[x * MASKED_K_CAP + a])
                  raw += 1
                end
                bb += 1
              end
              a += 1
            end
          end
          x += 1
        end
        # The number of dispatches. A non-fuzz batch is 1 (max-by-key absorbs the order), but
        # **a fuzz batch is split into "at most 1 per column"**: fuzz can read pixels an
        # earlier fuzz in the same column wrote (`fuzz_run_raw`), so
        # 2 in the same dispatch would change the answer. Fuzz across columns
        # never touch each other, so **splitting by slot index is structurally correct**.
        disp += kind == 1 ? rk : 1
      end
      @masked_dispatches = disp
      @tot_masked_dispatches += disp
      @max_masked_dispatches = disp if disp > @max_masked_dispatches
      @masked_runs = runs
      @masked_run_maxk = runmax
      @fuzz_run_raw = raw
      @tot_fuzz_run_raw += raw
      @tot_masked_runs += runs
      @max_masked_runs = runs if runs > @max_masked_runs
    end

    # ================= layer 2: packing for the GPU ===================================
    #
    # Measured: at 1920x1008 on Metal, planar SoA 0.707 ms /
    # AoS 1.73 ms (**2.45 times**); on the CPU (`local-sync`), on the contrary, AoS 7.30 / SoA 9.14.
    # So **the layout is not part of the ABI but something a device chooses**.
    # This takes the logical fields and returns **the bytes in the layout asked for**.
    #
    #   layout 0 = AoS         `(i * nf + f) * 4`
    #   layout 1 = planar SoA  `(f * n + i) * 4`
    #
    # Values are u32 little-endian (negative values in two's complement).
    LAYOUT_AOS = 0
    LAYOUT_PLANAR_SOA = 1

    def pack(kind, layout, out)
      if kind == KIND_WALL
        pack_bank(@wall, @nwall, WC_NF, layout, out)
      elsif kind == KIND_SPAN
        pack_bank(@span, @nspan, SP_NF, layout, out)
      else
        pack_bank(@masked, @nmasked, MC_NF, layout, out)
      end
    end

    def pack_bank(bank, n, nf, layout, out)
      i = 0
      while i < n
        f = 0
        while f < nf
          v = bank[i * nf + f] & 0xffffffff
          o = layout == LAYOUT_AOS ? (i * nf + f) * 4 : (f * n + i) * 4
          out.setbyte(o, v & 255)
          out.setbyte(o + 1, (v >> 8) & 255)
          out.setbyte(o + 2, (v >> 16) & 255)
          out.setbyte(o + 3, (v >> 24) & 255)
          f += 1
        end
        i += 1
      end
      n * nf * 4
    end

    # The number of table rows (3 -> 4). **There are still 3 job kinds** (`NKIND`);
    # rows grew because `plane_spans` became **one row per K**:
    # K is part of the kernel's ABI, so K=4 and K=16 are different contracts with
    # their own `sig` / `ksig` / `.vmfb`. Chosen at run time by `max_k`.
    # The number of table rows (3 -> 4, **then 4 -> 8**). **There are still 3 job kinds**
    # (`NKIND`); what grew is rows. The discipline established for spans,
    # "K is part of the kernel's ABI, so one row per K", was applied as it is.
    #
    #   wall_columns        as before (phase 0 opaque walls only). **Not one bit is touched**
    #   opaque_columns_k16  new. Phase 0 walls **+ phase 1 sky columns**.
    #                       Measured over 10 996 frames, 0 breaks of per-x exclusivity / max_k=14,
    #                       so they can be put into one dispatch.
    #                       `wall_columns` was not rewritten, because rewriting it would
    #                       break continuity with the earlier sig/ksig/.vmfb
    #   plane_spans_k4/k16  as before
    #   masked_columns_k8/k16/k40  new. **gather**. K is masked jobs
    #                       per x (measured maximum 37 / 84.0% at 8 / 98.1% at 16)
    #   fuzz_columns_k1     new. **K=1 is a structural contract**
    NTABLE = 8

    # One table row (the first version of `sp_job_entry_t`).
    # It is the input when lowered into a C header. `sig` is the FNV-1a 64 of the declaration.
    #
    # **The argument is the table's row number** (earlier it matched the job kind).
    def self.table_row(i)
      if i == 0
        "wall_columns\t0\tgather\t#{WC_NF}\t#{WC_FIELDS}\t#{WC_TYPES}\t#{K_MAX}\t" \
        "atlas:128,cmap:256x34\tfb:WxH\tdisjoint_per_x\t" \
        "x:0..W;y:0..H;cmap:0..34;srcofs%128==0"
      elsif i == 1
        opaque_table_row(K_MAX)
      elsif i == 2
        span_table_row(SPAN_K_SMALL)
      elsif i == 3
        span_table_row(SPAN_K_MAX)
      elsif i == 4
        masked_table_row(MASKED_K_SMALL)
      elsif i == 5
        masked_table_row(MASKED_K_MID)
      elsif i == 6
        masked_table_row(MASKED_K_MAX)
      else
        fuzz_table_row(FUZZ_K)
      end
    end

    # The plane span rows. As a carried-over note said, "only the row is rewritten",
    # but 3 places change:
    #   form   scatter -> **gather** (per pixel; possible because it is closed-form in x)
    #   k_max  0 -> K   (slots per y. **The cost is proportional to the declared K**)
    #   order  seq -> **disjoint_per_y** (the property of the data the gather rests on)
    # K goes into the name, so K=4 and K=16 are different things in the table too.
    def self.span_table_row(k)
      "plane_spans_k#{k}\t1\tgather\t#{SP_NF}\t#{SP_FIELDS}\t#{SP_TYPES}\t#{k}\t" \
      "flat:4096,cmap:256x34\tfb:WxH\tdisjoint_per_y\t" \
      "y:0..H;x1<=x2<W;cmap:0..34;srcofs%4096==0"
    end

    # The opaque column row. Fields and meaning are the same as `wall_columns`;
    # **only the set of jobs differs**: phase 0 walls plus phase 1 sky columns,
    # "every column read from the texture column atlas".
    # It is a separate row because moving even one character of `wall_columns`'s declaration moves `sig`,
    # breaking continuity with the earlier 22 runs / `sp_job_table.h` / `.vmfb`.
    # **It looks like the same contract but is a different one** (the range of exclusivity the
    # `gather` column claims differs), so it is a different thing in the table too.
    def self.opaque_table_row(k)
      "opaque_columns_k#{k}\t0\tgather\t#{WC_NF}\t#{WC_FIELDS}\t#{WC_TYPES}\t#{k}\t" \
      "atlas:128,cmap:256x34\tfb:WxH\tdisjoint_per_x\t" \
      "x:0..W;y:0..H;cmap:0..34;srcofs%128==0"
    end

    # The masked column rows. The same 3 places as `plane_spans` change:
    #   form   scatter -> **gather**
    #   k_max  0 -> K
    #   order  seq -> **seq_front_wins** (the spelling did not change; **the meaning did**:
    #          how the gather resolves "overlapping by design" goes into the `gather` column)
    # `reads` stays in the Job IR's words (`wad` / `zone`): the per-frame
    # 128B window atlas is **a physical layout (layer 2)**, not part of the ABI, so
    # it is written in the `layout` column.
    def self.masked_table_row(k)
      "masked_columns_k#{k}\t2\tgather\t#{MC_NF}\t#{MC_FIELDS}\t#{MC_TYPES}\t#{k}\t" \
      "wad,zone:128,cmap:256x34\tfb:WxH\tseq_front_wins\t" \
      "x:0..W;cmap:0..34;fuzz==-1"
    end

    # The fuzz column row. The fields are the same 9 as masked, but
    # **what it reads differs**: it reads not one byte of texture, but the frame buffer of
    # the earlier stages and the `fuzzoffset` table (`R_DrawFuzzColumn`).
    # The `seq_one_per_column` in `order` is **a structural contract**:
    # one dispatch may hold at most 1 per column.
    def self.fuzz_table_row(k)
      "fuzz_columns_k#{k}\t2\tgather\t#{MC_NF}\t#{MC_FIELDS}\t#{MC_TYPES}\t#{k}\t" \
      "fb:WxH,fuzzoff:50,cmap:256x34\tfb:WxH\tseq_one_per_column\t" \
      "x:0..W;y:1..H-2;fuzz:0..49"
    end
  end
end
