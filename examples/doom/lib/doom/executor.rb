# doom/lib/doom/executor.rb
#
# **The Job IR interpreting CPU executor.**
#
# This is "the outpost of the MLIR boundary". What the executor may look at is
#
#   * the job list (the 3 banks of `Doom::Jobs` + the schedule)
#   * resources (the texture column atlas / the flat atlas / the WAD's bytes /
#     the zone window ring / colormap / the fuzzoffset table)
#   * frame constants (screen width, the view window's origin, `centery`, `viewheight`)
#
# those 3 only, and it **never touches game state (level / mobj / drawseg / visplane /
# viewpoint)**. It reads not one ivar of `Doom::Renderer`.
# So even if this executor were swapped wholesale for another implementation (MLIR -> GPU),
# the boundary of the swap would stay "job list + resources + constants".
#
# The drawing formulas are `render.rb`'s `draw_column` / `draw_span` / `draw_fuzz_column`
# copied **without changing one character**, and the bit-exact match with the old route comes from that.
# Only how the source is reached differs (job fields rather than ivars, and offsets
# into atlases rather than separate buffers).

require_relative "errors"
require_relative "jobs"

module Doom
  class JobExecutor
    M32 = 0xffffffff
    CMAP_ROWS = 34
    # The darkness of `R_DrawFuzzColumn` (`colormaps + 6*256`).
    FUZZ_CMAP = 6

    # **The frame buffer is not kept in an ivar.** Put in an ivar and written as
    # `scr = @screen; scr.setbyte(...)`, Spinel lowers that String to a handle
    # representation (`sp_String*`) and emits a COW loop that copies 64 000 bytes twice
    # per `setbyte`. **Taken as an argument, it stays a `const char*` with a plain
    # `setbyte`**: the form `Doom::StatusBar#draw` already takes.
    # Read-only resources (atlases / colormap)
    # may be ivars.
    #
    # **The atlas sizes are not taken as arguments.** `Textures#flat_atlas_size` derives from
    # `@numflats` (poly) and has widened to untyped; passing just one of them makes
    # **every argument of `initialize` a boxed poly** ("once one widens, every value through
    # it becomes boxed"). Then `@centery` / `@width` become poly, and even `frac` in
    # `exec_wall`'s inner loop becomes boxed, going through sp_poly_* at every pixel.
    # The sizes are **asked of the buffers themselves**.
    def initialize(jobs, colormap, atlas, flatatlas,
                   waddata, fuzzoffset, width, viewwindowx, viewwindowy,
                   viewheight)
      @wall = jobs.wall_bank
      @span = jobs.span_bank
      @masked = jobs.masked_bank
      @sc_kind = jobs.sched_kind_bank
      @sc_idx = jobs.sched_idx_bank
      @jobs = jobs
      @colormap = colormap
      @atlas = atlas
      @atlas_size = atlas.bytesize
      @flatatlas = flatatlas
      @flat_size = flatatlas.bytesize
      @waddata = waddata
      @fuzzoffset = fuzzoffset
      @width = width
      @viewwindowx = viewwindowx
      @viewwindowy = viewwindowy
      # `centery` is not taken as an argument either (it would become poly for the same reason).
      # Made with the same formula as `R_ExecuteSetViewSize`, it stays an `mrb_int`.
      @centery = viewheight / 2
      @viewheight = viewheight
      @checked = 0
    end

    attr_reader :checked

    # Runs the job list in the order issued.
    #
    # **The order is preserved.** The 3 phases (walls -> planes -> masked) have separate banks,
    # but in phase 1 sky columns (the wall bank) and spans alternate per visplane, and
    # masked expresses "the nearer wins" by drawing order.
    # The schedule list is exactly that issue order, so the executor only has to walk it.
    def run(jobs, strict, scr)
      # All checks. Coordinates, alignment and cmap range (#1-#3) raise whatever `strict` is.
      # `strict` affects #4 (y-interval exclusion per x) and #5 (K_MAX): they forecast the
      # gather and are not conditions of this executor's correctness, so in the statistics
      # mode (measuring a hypothesis across every demo) they are only counted.
      jobs.check(strict, @atlas_size, @flat_size, CMAP_ROWS)
      @checked += 1
      n = jobs.nsched
      i = 0
      while i < n
        k = @sc_kind[i]
        j = @sc_idx[i]
        if k == Jobs::KIND_WALL
          exec_wall(j, scr)
        elsif k == Jobs::KIND_SPAN
          exec_span(j, scr)
        else
          exec_masked(j, scr)
        end
        i += 1
      end
    end

    # Walks the schedule list but runs **only the chosen stages**.
    #
    # It is needed to make the oracle for the mixed configuration "walls and planes on the
    # GPU, masked on the CPU". The screen the GPU's 2 stages (wall gather -> span gather)
    # draw is exactly `run_sel(jobs, scr, 1, 1, 0)`, and the result of the CPU
    # overlaying masked on top must match
    # `run_sel(..., 1, 1, 1)`.
    #
    # **Walls are phase 0 only.** Sky columns (phase 1) go into the same wall bank, but
    # the gather's precondition (exclusion per x) is proven only for the phase 0 set,
    # and the GPU kernel draws only that.
    #
    # Unlike `run`, **it does not run the checker**: it is a tool for redrawing, from another
    # angle, the same job list the caller has already put through `run`.
    def run_sel(jobs, scr, want_wall0, want_span, want_masked)
      n = jobs.nsched
      n0 = jobs.wall_phase0_n
      i = 0
      while i < n
        k = @sc_kind[i]
        j = @sc_idx[i]
        if k == Jobs::KIND_WALL
          exec_wall(j, scr) if want_wall0 != 0 && j < n0
        elsif k == Jobs::KIND_SPAN
          exec_span(j, scr) if want_span != 0
        else
          exec_masked(j, scr) if want_masked != 0
        end
        i += 1
      end
    end

    # Draws **in the order of the GPU's stage configuration itself**.
    #
    # The GPU dispatches one frame in this order:
    #
    #   (1) walls (phase 0's opaque walls **+ phase 1's sky columns**) in one dispatch
    #   (2) plane spans in one dispatch
    #   (3) masked as **a sequence of batches** (non-fuzz batches and fuzz batches alternate;
    #      fuzz batches are split further into "one per column")
    #
    # The only difference from the sequential schedule list (`run`) is **between (1) and (2)**:
    # sequentially, sky columns and spans alternate per visplane. That this does not change
    # the answer is shown by `Jobs#check_opaque_cover`'s `cover_bad` being 0
    # (0 on all 10 996 frames).
    # The masked side can be **the bank's order itself**: the GPU's "the last covering slot
    # wins" in a non-fuzz batch gives the same answer as sequential, and a fuzz batch is
    # one per column, so only reordering across columns happens, and fuzz in different
    # columns never touches each other's pixels.
    #
    # So `run_staged` == `run` is the CPU side's evidence that
    # **the GPU's stage configuration draws the same picture as sequential**.
    def run_staged(jobs, scr)
      run_stage(jobs, scr, 15)
    end

    # Draws the chosen stages (the mask's bits: 1 all walls / 2 spans / 4 masked non-fuzz / 8 fuzz).
    # **The order inside a stage is the bank's order** = the issue order.
    def run_stage(jobs, scr, mask)
      if mask & 1 != 0
        i = 0
        n = jobs.nwall
        while i < n
          exec_wall(i, scr)
          i += 1
        end
      end
      if mask & 2 != 0
        i = 0
        n = jobs.nspan
        while i < n
          exec_span(i, scr)
          i += 1
        end
      end
      if mask & 12 != 0
        i = 0
        n = jobs.nmasked
        while i < n
          fz = @masked[i * Jobs::MC_NF + Jobs::MC_FUZZ]
          if fz >= 0
            exec_masked(i, scr) if mask & 8 != 0
          elsif mask & 4 != 0
            exec_masked(i, scr)
          end
          i += 1
        end
      end
    end

    # Draws **only the first n** non-fuzz masked jobs, in issue order
    # (the partner of the completion condition "a single masked column bit-exact").
    def run_masked_n(jobs, scr, want)
      i = 0
      n = jobs.nmasked
      done = 0
      while i < n && done < want
        b = i * Jobs::MC_NF
        if @masked[b + Jobs::MC_FUZZ] < 0 &&
           @masked[b + Jobs::MC_YL] <= @masked[b + Jobs::MC_YH]
          exec_masked(i, scr)
          done += 1
        end
        i += 1
      end
    end

    private

    # A wall column (opaque wall + sky). The source is always the texture column atlas.
    # `R_DrawColumn` itself.
    def exec_wall(i, scr)
      b = i * Jobs::WC_NF
      yl = @wall[b + Jobs::WC_YL]
      yh = @wall[b + Jobs::WC_YH]
      count = yh - yl
      return if count < 0
      buf = @atlas
      ofs = @wall[b + Jobs::WC_SRCOFS]
      cmp = @colormap
      cm = @wall[b + Jobs::WC_CMAP] * 256
      fracstep = @wall[b + Jobs::WC_ISCALE] & M32
      frac = (@wall[b + Jobs::WC_TEXMID] + (yl - @centery) * fracstep) & M32
      o = (yl + @viewwindowy) * @width + @wall[b + Jobs::WC_X] + @viewwindowx
      i2 = 0
      while i2 <= count
        scr.setbyte(o, cmp.getbyte(cm + buf.getbyte(ofs + ((frac >> 16) & 127))))
        o += @width
        frac = (frac + fracstep) & M32
        i2 += 1
      end
    end

    # A plane span. The source is the flat atlas. `R_DrawSpan` (doomgeneric's packed version).
    def exec_span(i, scr)
      b = i * Jobs::SP_NF
      x1 = @span[b + Jobs::SP_X1]
      count = @span[b + Jobs::SP_X2] - x1
      return if count < 0
      src = @flatatlas
      ofs = @span[b + Jobs::SP_SRCOFS]
      cmp = @colormap
      cm = @span[b + Jobs::SP_CMAP] * 256
      o = (@span[b + Jobs::SP_Y] + @viewwindowy) * @width + x1 + @viewwindowx
      position = @span[b + Jobs::SP_POS]
      step = @span[b + Jobs::SP_STEP]
      i2 = 0
      while i2 <= count
        spot = (position >> 26) | ((position >> 4) & 0x0fc0)
        scr.setbyte(o, cmp.getbyte(cm + src.getbyte(ofs + spot)))
        o += 1
        position = (position + step) & M32
        i2 += 1
      end
    end

    # A masked column. The source is a WAD post (RES_WAD) or the zone window ring (RES_ZONE).
    # If `fuzz >= 0`, it is `R_DrawFuzzColumn`: it **reads the screen already drawn**, so
    # the job list's order being preserved is a precondition of correctness
    # (the starting phase of `fuzzpos` is baked in when the job is made).
    def exec_masked(i, scr)
      b = i * Jobs::MC_NF
      yl = @masked[b + Jobs::MC_YL]
      yh = @masked[b + Jobs::MC_YH]
      count = yh - yl
      return if count < 0
      cmp = @colormap
      x = @masked[b + Jobs::MC_X]
      o = (yl + @viewwindowy) * @width + x + @viewwindowx
      fz = @masked[b + Jobs::MC_FUZZ]
      if fz >= 0
        fp = fz
        i2 = 0
        while i2 <= count
          scr.setbyte(o, cmp.getbyte(FUZZ_CMAP * 256 + scr.getbyte(o + @fuzzoffset[fp] * @width)))
          fp += 1
          fp = 0 if fp == 50
          o += @width
          i2 += 1
        end
        return
      end
      use_zone_ring = @masked[b + Jobs::MC_SRCRES] == Jobs::RES_ZONE
      buf = @waddata
      ofs = @masked[b + Jobs::MC_SRCOFS]
      cm = @masked[b + Jobs::MC_CMAP] * 256
      fracstep = @masked[b + Jobs::MC_ISCALE] & M32
      frac = (@masked[b + Jobs::MC_TEXMID] + (yl - @centery) * fracstep) & M32
      i2 = 0
      while i2 <= count
        source_index = ofs + ((frac >> 16) & 127)
        source_byte = use_zone_ring ? @jobs.zone_byte(source_index) : buf.getbyte(source_index)
        scr.setbyte(o, cmp.getbyte(cm + source_byte))
        o += @width
        frac = (frac + fracstep) & M32
        i2 += 1
      end
    end
  end
end
