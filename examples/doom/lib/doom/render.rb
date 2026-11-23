# doom/lib/doom/render.rb
#
# BSP traversal and frame drawing (`r_main.c` / `r_bsp.c` / `r_segs.c` / `r_plane.c` /
# `r_things.c`).
#
# The level stage reproduced **only the structure of the walls** here: the set of pixels
# painted matched the reference, and only the values differed. The drawing stage fills in those values:
#
#   - textured column drawing (`R_GetColumn` + walking `dc_iscale`)
#   - visplane (`R_FindPlane` / `R_CheckPlane` / `R_DrawPlanes` / `R_MapPlane`)
#     and span drawing (`R_DrawSpan`)
#   - the sky (a `skyflatnum` visplane becomes column drawing)
#   - sprites (`R_AddSprites` / `R_ProjectSprite` / selection sort / `R_DrawSprite`)
#   - the player's weapon (`R_DrawPlayerSprites`)
#
# **Vanilla's shape is copied as it is**: C's file-scope variables are ivars of one
# instance, and what passes between functions stays in ivars rather than becoming arguments.
# All pointers become indexes:
#
#   `visplane_t*`        -> a visplane number (none is -1)
#   `lighttable_t*`      -> a colormap **row number** 0..33
#   `short* sprtopclip`  -> 2 values (kind, base into openings)
#   `byte* dc_source`    -> 2 values (buffer String, offset inside it)
#
# The allocation discipline: inside the frame loop `Array.new` / array literals /
# string interpolation / `map` are **never called**. visplanes, openings,
# drawsegs and vissprites are all allocated once at initialization and reused.
#
# 32-bit / 16-bit truncation is **written inline everywhere in this file**.
# Calling `Doom::Fixed.to_i32` / `.mul` / `.cdiv` closes a cycle in the value flow across
# call sites, type inference widens to untyped, and **the generated C breaks**.
# At the drawing stage `Doom::Fixed.div` joined the cycle too, so it was taken into this
# class as `fixed_div`. `require "fixed"` stays only for the constants.

require_relative "errors"
require_relative "bytes"
require_relative "fixed"
require_relative "tables"
require_relative "level"
require_relative "texture"
require_relative "sprites"
require_relative "things"
require_relative "info"
require_relative "jobs"
require_relative "executor"

module Doom
  class Renderer
    # **This is "the base resolution", not the screen's size.**
    #
    # The real screen is `@sw` / `@sh` (= `SCREENWIDTH * s` / `SCREENHEIGHT * s`), with
    # `s` the `resscale` argument of `initialize` (default 1). Buffer sizes, strides and
    # the lengths of resolution-dependent tables **all use `@sw` / `@sh`**.
    #
    # On the other hand **3 formulas keep using `SCREENWIDTH` (320) as it is**: not
    # leftovers, but because vanilla calibrated those formulas on "a 320-wide world"
    # (normalizing terms that keep the look unchanged in a view s times as large):
    #
    #   `@pspritescale  = FRACUNIT * @viewwidth / SCREENWIDTH`  → s·FRACUNIT
    #   `@pspriteiscale = FRACUNIT * SCREENWIDTH / @viewwidth`  → FRACUNIT/s
    #   `scalelight`: `j * SCREENWIDTH / @viewwidth / DISTMAP`  → (j/s)/DISTMAP
    #   `zlight`:     `SCREENWIDTH / 2 * FRACUNIT`              -> resolution-independent
    #
    # When `@viewwidth` is multiplied by s, `spryscale` is too, so the light index j is
    # also multiplied by s. `j * 320 / @viewwidth` is the term that divides that s back out,
    # and making it `@sw` **blows out the lighting at high resolution**.
    SCREENWIDTH = 320
    SCREENHEIGHT = 200

    # The supported multipliers of the internal resolution (`resscale`). To keep 8:5 (as vanilla),
    # **width and height are multiplied by the same integer**. 1 = 320x200 (bit-exact with the doomgeneric reference).
    RESSCALE_MAX = 8

    ANG45 = 0x20000000
    ANG90 = 0x40000000
    ANG180 = 0x80000000
    ANG270 = 0xc0000000
    ANGLETOFINESHIFT = 19
    ANGLETOSKYSHIFT = 22
    FINEANGLES = 8192
    FIELDOFVIEW = 2048

    FRACUNIT = 65536
    HEIGHTBITS = 12
    HEIGHTUNIT = 4096

    MAXSEGS = 32
    MAXDRAWSEGS = 256
    MAXVISPLANES = 128
    # openings are **proportional to the screen width** (the sum of columns one drawseg can
    # cover at most), so `@maxopenings = @sw * 64` is used. This constant is the value at s=1.
    MAXOPENINGS = SCREENWIDTH * 64
    MAXVISSPRITES = 128

    LIGHTLEVELS = 16
    LIGHTSEGSHIFT = 4
    MAXLIGHTSCALE = 48
    LIGHTSCALESHIFT = 12
    MAXLIGHTZ = 128
    LIGHTZSHIFT = 20
    NUMCOLORMAPS = 32
    DISTMAP = 2

    ML_MAPPED = 256
    ML_DONTPEGTOP = 8
    ML_DONTPEGBOTTOM = 16

    SIL_NONE = 0
    SIL_BOTTOM = 1
    SIL_TOP = 2
    SIL_BOTH = 3

    MINZ = FRACUNIT * 4
    BASEYCENTER = 100

    # The width per element of a visplane's top/bottom (+2 for the pads before and after).
    # Writes to `pl->top[minx-1]` / `pl->top[maxx+1]` are deliberately allowed by vanilla
    # (pad1..pad4 in `r_defs.h`). Here a +1 bias expresses it.
    # The real stride is `@plw = @sw + 2`.
    PLW = SCREENWIDTH + 2

    # Constants used in the inline formulas for 32/16-bit truncation.
    M32 = 0xffffffff
    SGN = 0x80000000
    M16 = 0xffff
    SGN16 = 0x8000

    # The kind of a drawseg's clip array (C's 3 kinds of pointer, as a tag).
    CLIP_NONE = 0        # NULL
    CLIP_SCREENHEIGHT = 1
    CLIP_NEGONE = 2
    CLIP_OPENINGS = 3

    # Where `mfloorclip` / `mceilingclip` point
    MCLIP_SPRITE = 0     # R_DrawSprite's local clipbot / cliptop
    MCLIP_DRAWSEG = 1    # ds->sprbottomclip / ds->sprtopclip

    CHECKCOORD = [3, 0, 2, 1,
                  3, 0, 2, 0,
                  3, 1, 2, 0,
                  0, 0, 0, 0,
                  2, 0, 2, 1,
                  0, 0, 0, 0,
                  3, 1, 3, 0,
                  0, 0, 0, 0,
                  2, 0, 3, 1,
                  2, 1, 3, 1,
                  2, 1, 3, 0,
                  0, 0, 0, 0].freeze

    attr_reader :screen, :viewwidth, :viewheight, :centerx, :centery,
                :centerxfrac, :centeryfrac, :projection, :clipangle,
                :viewangletox, :xtoviewangle, :ceilingclip, :floorclip,
                :yslope, :distscale
    # The view window's origin and the fuzzoffset table.
    # `bin/dump_jobs.rb` needs them **to assemble the Job IR interpreting CPU executor from outside**
    # (exactly the "frame constants" and "resources" the executor may look at, 1:1 with the
    # list at the top of executor.rb). Read-only accessors; the drawing route does not change by one byte.
    attr_reader :viewwindowx, :viewwindowy, :fuzzoffset
    # The real screen's size and the multiplier. Callers (`bin/doom.rb` /
    # `bin/gpu_demo.rb`) take the SDL window, the frame hash's range and the GPU's geometry
    # from here, **so that lines with 320 written in them vanish from the callers too**.
    attr_reader :screenwidth, :screenheight, :resscale
    attr_reader :visit_ss, :visit_n, :wall_n, :column_n, :span_n, :vis_n
    attr_reader :wall_seg, :wall_x1, :wall_x2, :wall_distance, :wall_scale,
                :wall_scalestep, :wall_worldtop, :wall_worldbottom,
                :wall_mid, :wall_top, :wall_bottom, :wall_markfloor,
                :wall_markceiling, :wall_segtextured, :wall_topfrac,
                :wall_topstep, :wall_bottomfrac, :wall_bottomstep,
                :wall_offset, :wall_centerangle, :wall_midmid, :wall_topmid,
                :wall_botmid, :wall_sil, :wall_bsil, :wall_tsil, :wall_masked
    attr_reader :column_tier, :column_x, :column_yl, :column_yh,
                :column_phase, :column_texnum, :column_texcol,
                :column_iscale, :column_texmid, :column_cmap
    attr_reader :span_y, :span_x1, :span_x2, :span_xfrac, :span_yfrac,
                :span_xstep, :span_ystep, :span_cmap, :span_picnum
    attr_reader :lastvisplane, :pl_height, :pl_picnum, :pl_lightlevel,
                :pl_minx, :pl_maxx, :pl_top, :pl_bottom
    attr_reader :vs_x1, :vs_x2, :vs_scale, :vs_patch, :vs_texturemid,
                :vs_xiscale, :vs_startfrac, :vs_cmap, :vs_mobjflags,
                :vs_gx, :vs_gy, :vs_gz, :vs_gzt, :vs_sorted

    # `resscale` (s) is the 9th argument. **It has no default**:
    # Spinel's inference can make types waver at call sites with default arguments, so
    # all 12 callers pass 1 explicitly.
    def initialize(level, wad, colormap, textures, sprites, things, setblocks, trace,
                   resscale)
      if resscale < 1 || resscale > RESSCALE_MAX
        raise LevelError, "resscale #{resscale} is outside 1..#{RESSCALE_MAX}"
      end
      @resscale = resscale
      @sw = SCREENWIDTH * resscale
      @sh = SCREENHEIGHT * resscale
      @screenwidth = @sw
      @screenheight = @sh
      @plw = @sw + 2
      @maxopenings = @sw * 64
      @level = level
      @wad = wad
      @wad_data = wad.data
      # The receiver for `Wad#zone_window` (reused; filled only when a masked column reads
      # past the end of its lump).
      @zonewin = Bytes.buffer(128, 0)
      @colormap = colormap
      @textures = textures
      # Equivalent to `R_PrecacheLevel`. Every texture / every flat is materialized
      # **here**. The drawing side calls only `texdata` / `flatdata` (accessors without a
      # generation branch), so lazy generation vanishes structurally from the frame loop's
      # call graph. "Happens not to run" is not a proof.
      textures.precache_all
      @sprites = sprites
      @things = things
      @trace = trace

      @finetangent = Tables.finetangent
      @finesine = Tables.finesine
      @tantoangle = Tables.tantoangle

      # Solves `R_ExecuteSetViewSize` **in a space multiplied by s**.
      # `setblocks = 10` / `s = 6` gives `1920 x 1008`, exactly the resolution measured
      # all along as "the high-resolution reference value" (not by chance:
      # 168*6 = 1008). At s = 1 not one bit changes.
      if setblocks == 11
        @scaledviewwidth = @sw
        @viewheight = @sh
      else
        @scaledviewwidth = setblocks * 32 * resscale
        @viewheight = ((setblocks * 168 / 10) & ~7) * resscale
      end
      @viewwidth = @scaledviewwidth
      # **The light tables are looked up in 320 space.**
      # `scalelight`'s index is `scale >> LIGHTSCALESHIFT`, and `scale` (rw_scale /
      # spryscale / xscale) is multiplied by s through `projection = centerxfrac`.
      # The table divides s back out with `j * SCREENWIDTH / @viewwidth`, but
      # **the table's length `MAXLIGHTSCALE = 48` is not multiplied by s**, so at s=6 the
      # index saturates at 1/6 of the distance, and near surfaces stick to the farthest (darkest) row.
      # Measured, a 1920x1200 view had a third of the brightness of the 320 one.
      # The fix is "put both the table and the index in 320 space": the table is built at
      # the base view width (`init_light_tables` below), and the index is divided by s just before the lookup (`light_index`).
      # At s=1, `@viewwidth_base == @viewwidth` and the divisor is 1, so it is identical to vanilla.
      @viewwidth_base = @viewwidth / resscale
      @centery = @viewheight / 2
      @centerx = @viewwidth / 2
      @centerxfrac = @centerx << 16
      @centeryfrac = @centery << 16
      @projection = @centerxfrac

      @viewwindowx = (@sw - @scaledviewwidth) >> 1
      @viewwindowy = @scaledviewwidth == @sw ? 0 : (@sh - 32 * resscale - @viewheight) >> 1

      @viewangletox = Array.new(FINEANGLES / 2, 0)
      @xtoviewangle = Array.new(@sw + 1, 0)
      @clipangle = 0
      init_texture_mapping

      @scalelight = Array.new(LIGHTLEVELS * MAXLIGHTSCALE, 0)
      @zlight = Array.new(LIGHTLEVELS * MAXLIGHTZ, 0)
      init_light_tables

      # The rest of `R_ExecuteSetViewSize`: the psprite scale and the plane tables
      @pspritescale = FRACUNIT * @viewwidth / SCREENWIDTH
      @pspriteiscale = FRACUNIT * SCREENWIDTH / @viewwidth
      @yslope = Array.new(@sh, 0)
      @distscale = Array.new(@sw, 0)
      init_plane_tables

      @screen = Bytes.buffer(@sw * @sh, 0)
      @ceilingclip = Array.new(@sw, 0)
      @floorclip = Array.new(@sw, 0)
      @ss_first = Array.new(MAXSEGS + 2, 0)
      @ss_last = Array.new(MAXSEGS + 2, 0)
      @newend = 0

      # visplane (`r_plane.c`)
      @pl_height = Array.new(MAXVISPLANES, 0)
      @pl_picnum = Array.new(MAXVISPLANES, 0)
      @pl_lightlevel = Array.new(MAXVISPLANES, 0)
      @pl_minx = Array.new(MAXVISPLANES, 0)
      @pl_maxx = Array.new(MAXVISPLANES, 0)
      # The visplane sentinel for "this column is empty". In vanilla `pl->top` is a
      # `byte`, so the **255** of `memset(..., 0xff, ...)` is itself the sentinel, and
      # `viewheight = 168 < 255` keeps it from colliding with real coordinates. **At high
      # resolution it collides** (168*8 = 1344 > 255), so for s > 1 it is replaced with a value
      # above viewheight. Every reader uses `== @plempty` / `<` / `<=`, so the value
      # itself means nothing. **At s = 1 it stays 255**: leaning toward the discipline
      # of not moving the 320 route's bytes by one bit.
      @plempty = resscale == 1 ? 255 : 0x7fff
      @pl_top = Array.new(MAXVISPLANES * @plw, @plempty)
      @pl_bottom = Array.new(MAXVISPLANES * @plw, 0)
      @lastvisplane = 0
      @floorplane = -1
      @ceilingplane = -1
      @spanstart = Array.new(@sh, 0)
      @cachedheight = Array.new(@sh, 0)
      @cacheddistance = Array.new(@sh, 0)
      @cachedxstep = Array.new(@sh, 0)
      @cachedystep = Array.new(@sh, 0)
      @basexscale = 0
      @baseyscale = 0
      @planeheight = 0
      @planezlight = 0
      @ds_source = ""

      # openings (the bump allocator of `lastopening`)
      @openings = Array.new(@maxopenings, 0)
      @lastopening = 0

      # drawseg
      @ds_curline = Array.new(MAXDRAWSEGS, 0)
      @ds_x1 = Array.new(MAXDRAWSEGS, 0)
      @ds_x2 = Array.new(MAXDRAWSEGS, 0)
      @ds_scale1 = Array.new(MAXDRAWSEGS, 0)
      @ds_scale2 = Array.new(MAXDRAWSEGS, 0)
      @ds_scalestep = Array.new(MAXDRAWSEGS, 0)
      @ds_silhouette = Array.new(MAXDRAWSEGS, 0)
      @ds_bsilheight = Array.new(MAXDRAWSEGS, 0)
      @ds_tsilheight = Array.new(MAXDRAWSEGS, 0)
      @ds_topkind = Array.new(MAXDRAWSEGS, 0)
      @ds_topbase = Array.new(MAXDRAWSEGS, 0)
      @ds_botkind = Array.new(MAXDRAWSEGS, 0)
      @ds_botbase = Array.new(MAXDRAWSEGS, 0)
      @ds_maskedbase = Array.new(MAXDRAWSEGS, -1)
      # "Does it have a masked midtexture" **cannot be decided by the sign of `@ds_maskedbase`**.
      # Vanilla holds `ds->maskedtexturecol = lastopening - rw_x`, **a pointer that
      # can be negative**, and checks presence with `if (ds->maskedtexturecol)`
      # (= whether it is NULL). When `lastopening < rw_x` the base is negative, so it
      # collides with the sentinel "-1 = none". Presence is kept in a separate array.
      @ds_masked = Array.new(MAXDRAWSEGS, 0)

      # vissprite
      @vs_x1 = Array.new(MAXVISSPRITES, 0)
      @vs_x2 = Array.new(MAXVISSPRITES, 0)
      @vs_scale = Array.new(MAXVISSPRITES, 0)
      @vs_patch = Array.new(MAXVISSPRITES, 0)
      @vs_texturemid = Array.new(MAXVISSPRITES, 0)
      @vs_xiscale = Array.new(MAXVISSPRITES, 0)
      @vs_startfrac = Array.new(MAXVISSPRITES, 0)
      @vs_cmap = Array.new(MAXVISSPRITES, 0)
      @vs_mobjflags = Array.new(MAXVISSPRITES, 0)
      @vs_gx = Array.new(MAXVISSPRITES, 0)
      @vs_gy = Array.new(MAXVISSPRITES, 0)
      @vs_gz = Array.new(MAXVISSPRITES, 0)
      @vs_gzt = Array.new(MAXVISSPRITES, 0)
      @vs_sorted = Array.new(MAXVISSPRITES, 0)
      @vs_taken = Array.new(MAXVISSPRITES, 0)
      @vis_n = 0
      @clipbot = Array.new(@sw, 0)
      @cliptop = Array.new(@sw, 0)
      # Vanilla's `mfloorclip` / `mceilingclip` are **one pointer each**, but
      # they point to 2 kinds of place:
      #   (a) `R_DrawSprite`'s **local arrays** `clipbot` / `cliptop`
      #   (b) `ds->sprbottomclip` / `ds->sprtopclip`, assigned by `R_RenderMaskedSegRange`
      #       (= inside `openings`)
      # (a) and (b) are separate storage, so writing one does not break the other.
      # Reusing `@clipbot` / `@cliptop` for both cuts a masked midtexture with
      # **the clip of the sprite drawn just before**.
      # `@mclip_mode` holds which one they point to.
      @mclip_mode = MCLIP_SPRITE
      @mclip_topkind = CLIP_NONE
      @mclip_topbase = 0
      @mclip_botkind = CLIP_NONE
      @mclip_botbase = 0
      @sector_validcount = Array.new(level.num_sectors, -1)
      @validcount = 0
      @spritelights = 0

      @viewx = 0
      @viewy = 0
      @viewz = 0
      @viewangle = 0
      @viewsin = 0
      @viewcos = 0
      @extralight = 0
      @sscount = 0
      @ds_count = 0
      @frontsector = 0
      @backsector = -1
      @curline = 0
      @rw_angle1 = 0
      @rw_normalangle = 0
      @rw_distance = 0
      @rw_x = 0
      @rw_stopx = 0
      @rw_scale = 0
      # `rw_scalestep` and the 3 `rw_*texturemid` **carry over across frames**.
      # In vanilla they are file-scope variables, and for a 1-column-wide wall or
      # "the side with no texture" they are not assigned, so the previous wall's values stay.
      @rw_scalestep = 0
      @rw_offset = 0
      @rw_centerangle = 0
      @rw_midtexturemid = 0
      @rw_toptexturemid = 0
      @rw_bottomtexturemid = 0
      @midtexture = 0
      @toptexture = 0
      @bottomtexture = 0
      @maskedtexture = 0
      @maskedtexturecol = -1
      @segtextured = 0
      @markfloor = false
      @markceiling = false
      @worldtop = 0
      @worldbottom = 0
      @worldhigh = 0
      @worldlow = 0
      @topfrac = 0
      @topstep = 0
      @bottomfrac = 0
      @bottomstep = 0
      @pixhigh = 0
      @pixhighstep = 0
      @pixlow = 0
      @pixlowstep = 0
      @walllights = 0
      @dc_colormap = 0
      @skytexturemid = 100 * FRACUNIT

      # The state of "the current column/span" during drawing (C's dc_* / ds_* globals).
      @dc_x = 0
      @dc_yl = 0
      @dc_yh = 0
      @dc_iscale = 0
      @dc_texturemid = 0
      @dc_srcbuf = ""
      @dc_srcofs = 0
      @spryscale = 0
      @sprtopscreen = 0
      @phase = 0
      @curpicnum = 0

      # The player's weapon (psprite). With no game logic, `P_SetupPsprites`'s resting
      # state is placed directly.
      @psp_state = -1
      @psp_sx = 0
      @psp_sy = 0
      @psp1_state = 0
      @psp1_sx = 0
      @psp1_sy = 0
      # ---- E052 (P004 Phase 4): fuzz (`MF_SHADOW`) ------------------------
      # `R_DrawFuzzColumn`'s `fuzzpos` is **global and carries over across
      # frames**. E1M5 has spectres (MT_SHADOWS), so
      # DEMO1 always goes through it (as forecast).
      # `fuzzoffset` is 50 values of +-SCREENWIDTH, in `r_draw.c` rather than
      # `tables.c` (one of the 6 embedded tables).
      @fuzzoffset = [
        1, -1, 1, -1, 1, 1, -1,
        1, 1, -1, 1, 1, 1, -1,
        1, 1, 1, -1, -1, -1, -1,
        1, -1, -1, 1, 1, 1, 1, -1,
        1, -1, 1, 1, -1, -1, 1,
        1, -1, -1, -1, -1, 1, 1,
        1, 1, -1, 1, 1, -1, 1
      ]
      @fuzzpos = 0
      @dc_fuzz = false
      @state_sprite = Info.state_sprite
      @state_frame = Info.state_frame

      # ---- P005 Phase 1 (E057): Job IR ------------------------------------
      # **The rings are always allocated ahead** (so as not to break zero allocation).
      # If `@jobmode` is 0 the old route (direct drawing) runs as it is:
      # **the CPU version is the permanent right answer**, so the route stays.
      #   0 = the old route / 1 = Job IR (checker strict) / 2 = Job IR (the checker only counts)
      @jobmode = 0
      @jobs = Jobs.new(@sw, @viewheight)
      @exec = JobExecutor.new(@jobs, colormap,
                              textures.tex_atlas, textures.flat_atlas,
                              @wad_data, @fuzzoffset, @sw,
                              @viewwindowx, @viewwindowy, @viewheight)
      # A job's source is 2 values, "resource number + offset inside it"
      # (the Job IR version of the old route's `@dc_srcbuf` / `@dc_srcofs`).
      @dc_srcres = Jobs::RES_ATLAS
      @dc_srcbase = 0

      init_traces
    end

    # Chooses which route to use at build/run time (the CPU version is the permanent right answer).
    def job_mode=(v)
      @jobmode = v
    end

    def job_mode
      @jobmode
    end

    # The job list itself (`bin/dump_jobs.rb` writes it out as the next stage's input).
    def jobs
      @jobs
    end

    # The size of one frame of Job IR and the checker's observations (the statistics were taken with this).
    def job_nwall
      @jobs.nwall
    end

    def job_nspan
      @jobs.nspan
    end

    def job_nmasked
      @jobs.nmasked
    end

    def job_nsched
      @jobs.nsched
    end

    def job_nzone
      @jobs.nzone
    end

    def job_max_k
      @jobs.max_k
    end

    def job_overlaps
      @jobs.overlaps
    end

    # Observations on the span side. Where `job_max_k` / `job_overlaps` look at walls
    # "per x", these look at spans "per y".
    def job_span_max_kx
      @jobs.span_max_kx
    end

    def job_span_overlaps
      @jobs.span_overlaps
    end

    # The running totals of the closed-form identity (not part of the per-frame `check`;
    # they grow only as far as the caller explicitly calls `job_check_span_closed`).
    def job_check_span_closed
      @jobs.check_span_closed
    end

    def job_span_closed_bad
      @jobs.span_closed_bad
    end

    def job_span_closed_px
      @jobs.span_closed_px
    end

    def job_span_ycarry
      @jobs.span_ycarry
    end

    def job_hi
      "#{@jobs.hi_wall}\t#{@jobs.hi_span}\t#{@jobs.hi_masked}\t#{@jobs.hi_sched}\t#{@jobs.hi_zone}"
    end

    # Observations on masked / fuzz / the opaque pass as a whole.
    # Read accessors in the same position as `job_max_k` (walls, phase 0) / `job_span_max_kx` (spans);
    # the drawing route does not change by one byte.
    def job_masked_max_kx
      @jobs.masked_max_kx
    end

    def job_fuzz_max_kx
      @jobs.fuzz_max_kx
    end

    def job_fuzz_n
      @jobs.fuzz_n
    end

    def job_wall_all_max_k
      @jobs.wall_all_max_k
    end

    def job_wall_all_overlaps
      @jobs.wall_all_overlaps
    end

    # A heavy measurement called explicitly (the same position as `check_span_closed`).
    def job_check_masked_dist
      @jobs.check_masked_dist(@fuzzoffset)
    end

    def job_check_opaque_cover
      @jobs.check_opaque_cover
    end

    def job_check_masked_runs
      @jobs.check_masked_runs(@fuzzoffset)
    end

    def job_masked_stats
      "#{@jobs.masked_ovpairs}\t#{@jobs.masked_ovpx}\t#{@jobs.masked_cover_px}\t" \
      "#{@jobs.fuzz_conflicts}\t#{@jobs.fuzz_raw}\t#{@jobs.fuzz_badrange}\t" \
      "#{@jobs.fuzz_suffix}\t#{@jobs.cover_dbl}\t#{@jobs.cover_bad}\t" \
      "#{@jobs.cover_oob}\t#{@jobs.cover_px}\t" \
      "#{@jobs.masked_runs}\t#{@jobs.masked_run_maxk}\t#{@jobs.fuzz_run_raw}\t" \
      "#{@jobs.masked_dispatches}\t#{@jobs.fuzz_chain_max}"
    end

    def job_totals
      "#{@jobs.tot_masked_ovpairs}\t#{@jobs.tot_masked_ovpx}\t#{@jobs.tot_masked_cover_px}\t" \
      "#{@jobs.tot_fuzz_conflicts}\t#{@jobs.tot_fuzz_raw}\t#{@jobs.tot_fuzz_badrange}\t" \
      "#{@jobs.tot_nonsuffix_frames}\t#{@jobs.tot_fuzz_frames}\t" \
      "#{@jobs.tot_cover_dbl}\t#{@jobs.tot_cover_bad}\t#{@jobs.tot_cover_px}\t" \
      "#{@jobs.tot_masked_runs}\t#{@jobs.max_masked_runs}\t#{@jobs.tot_fuzz_run_raw}\t" \
      "#{@jobs.tot_masked_dispatches}\t#{@jobs.max_masked_dispatches}\t" \
      "#{@jobs.tot_fuzz_chain_max}\t#{@jobs.tot_fuzz_selfref_px}"
    end

    # `extralight` becomes 1-2 for one tic when a weapon fires (`A_Light1` / `A_Light2`).
    # Before tics ran, 0 was enough (the hook was opened for the tic simulation).
    def extralight=(v)
      @extralight = v
    end

    def set_psprite(state, sx, sy)
      @psp_state = state
      @psp_sx = sx
      @psp_sy = sy
    end

    # `ps_flash` (`psprites[1]`). The weapon's muzzle flash. **Before tics ran it never
    # existed**, so it was never drawn. With tics running it appears on every shot
    # (the match split at DEMO1's tic 85 = 4 tics after the first shot).
    def set_psprite_flash(state, sx, sy)
      @psp1_state = state
      @psp1_sx = sx
      @psp1_sy = sy
    end

    def sscount
      @sscount
    end

    # Fills the frame buffer with 0 (the reference side's `memset(I_VideoBuffer, 0, ...)`).
    def clear_screen
      screen = @screen
      i = 0
      n = @sw * @sh
      while i < n
        screen.setbyte(i, 0)
        i += 1
      end
    end

    def pspritescale
      @pspritescale
    end

    def pspriteiscale
      @pspriteiscale
    end

    def skytexturemid
      @skytexturemid
    end

    # `R_RenderPlayerView`
    def render_player_view(viewx, viewy, viewz, viewangle)
      @viewx = viewx
      @viewy = viewy
      @viewz = viewz
      @viewangle = viewangle
      @viewsin = @finesine[viewangle >> ANGLETOFINESHIFT]
      @viewcos = @finesine[(viewangle >> ANGLETOFINESHIFT) + 2048]
      @sscount = 0
      @validcount += 1
      @ds_count = 0
      @vis_n = 0
      @visit_n = 0
      @wall_n = 0
      @column_n = 0
      @span_n = 0
      @phase = 0
      @jobs.reset if @jobmode != 0
      clear_clip_segs
      clear_planes
      render_bsp_node(@level.num_nodes - 1)
      @phase = 1
      @jobs.mark_phase1 if @jobmode != 0
      draw_planes
      @phase = 2
      draw_masked
      # The Job IR route: not one pixel has been written so far. The executor looks only at
      # the job list and draws in issue order. The bit-exact match with the old route holds after this one line.
      #
      # **`job_mode = 4` draws not one pixel here.**
      # It only queues jobs and returns; the caller draws (the GPU route =
      # `lib/doom/render_gpu.rb`, or `draw_jobs_cpu` below if refused).
      # The behaviour of modes 0 / 1 / 2 has not changed by one bit.
      @exec.run(@jobs, @jobmode == 1, @screen) if @jobmode == 1 || @jobmode == 2
    end

    # The partner of `job_mode = 4`. **The CPU executor draws a frame the GPU
    # refused.** A frame through here is exactly the same as a `job_mode = 2` frame,
    # and this executor is exactly what the 131 gates verify.
    def draw_jobs_cpu
      @exec.run(@jobs, false, @screen)
    end

    private

    def init_traces
      @visit_ss = Array.new(4096, 0)
      @visit_n = 0
      @wall_seg = Array.new(4096, 0)
      @wall_x1 = Array.new(4096, 0)
      @wall_x2 = Array.new(4096, 0)
      @wall_distance = Array.new(4096, 0)
      @wall_scale = Array.new(4096, 0)
      @wall_scalestep = Array.new(4096, 0)
      @wall_worldtop = Array.new(4096, 0)
      @wall_worldbottom = Array.new(4096, 0)
      @wall_mid = Array.new(4096, 0)
      @wall_top = Array.new(4096, 0)
      @wall_bottom = Array.new(4096, 0)
      @wall_markfloor = Array.new(4096, 0)
      @wall_markceiling = Array.new(4096, 0)
      @wall_segtextured = Array.new(4096, 0)
      @wall_topfrac = Array.new(4096, 0)
      @wall_topstep = Array.new(4096, 0)
      @wall_bottomfrac = Array.new(4096, 0)
      @wall_bottomstep = Array.new(4096, 0)
      @wall_offset = Array.new(4096, 0)
      @wall_centerangle = Array.new(4096, 0)
      @wall_midmid = Array.new(4096, 0)
      @wall_topmid = Array.new(4096, 0)
      @wall_botmid = Array.new(4096, 0)
      @wall_sil = Array.new(4096, 0)
      @wall_bsil = Array.new(4096, 0)
      @wall_tsil = Array.new(4096, 0)
      @wall_masked = Array.new(4096, 0)
      @wall_n = 0
      @column_tier = Array.new(65536, 0)
      @column_x = Array.new(65536, 0)
      @column_yl = Array.new(65536, 0)
      @column_yh = Array.new(65536, 0)
      @column_phase = Array.new(65536, 0)
      @column_texnum = Array.new(65536, 0)
      @column_texcol = Array.new(65536, 0)
      @column_iscale = Array.new(65536, 0)
      @column_texmid = Array.new(65536, 0)
      @column_cmap = Array.new(65536, 0)
      @column_n = 0
      @span_y = Array.new(65536, 0)
      @span_x1 = Array.new(65536, 0)
      @span_x2 = Array.new(65536, 0)
      @span_xfrac = Array.new(65536, 0)
      @span_yfrac = Array.new(65536, 0)
      @span_xstep = Array.new(65536, 0)
      @span_ystep = Array.new(65536, 0)
      @span_cmap = Array.new(65536, 0)
      @span_picnum = Array.new(65536, 0)
      @span_n = 0
    end

    # ---------------------------------------------------------------- initialization

    # `R_InitTextureMapping`
    def init_texture_mapping
      focallength = fixed_div(@centerxfrac, @finetangent[FINEANGLES / 4 + FIELDOFVIEW / 2])
      i = 0
      while i < FINEANGLES / 2
        ft = @finetangent[i]
        if ft > FRACUNIT * 2
          t = -1
        elsif ft < -FRACUNIT * 2
          t = @viewwidth + 1
        else
          t = (((ft * focallength >> 16 & M32) ^ SGN) - SGN)
          t = (((@centerxfrac - t + FRACUNIT - 1 & M32) ^ SGN) - SGN) >> 16
          t = -1 if t < -1
          t = @viewwidth + 1 if t > @viewwidth + 1
        end
        @viewangletox[i] = t
        i += 1
      end

      x = 0
      while x <= @viewwidth
        i = 0
        i += 1 while @viewangletox[i] > x
        @xtoviewangle[x] = (((i << ANGLETOFINESHIFT) - ANG90) & M32)
        x += 1
      end

      i = 0
      while i < FINEANGLES / 2
        @viewangletox[i] = 0 if @viewangletox[i] == -1
        @viewangletox[i] = @viewwidth if @viewangletox[i] == @viewwidth + 1
        i += 1
      end

      @clipangle = @xtoviewangle[0]
      @two_clipangle = ((2 * @clipangle) & M32)
    end

    # Turns `scale >> LIGHTSCALESHIFT` into **an index in 320 space** and clamps it.
    # Only one `/ @resscale` goes into the middle of vanilla's 3 lines (`index = scale>>12` /
    # `if index >= MAXLIGHTSCALE ...` / `colormap = walllights[index]`), and
    # at s=1 the divisor is 1, so it is **vanilla byte for byte**.
    def light_index(scale)
      index = (scale >> LIGHTSCALESHIFT) / @resscale
      index = MAXLIGHTSCALE - 1 if index >= MAXLIGHTSCALE
      index
    end

    # `R_ExecuteSetViewSize`'s scalelight and `R_InitLightTables`'s zlight.
    # C holds pointers to colormap rows; Ruby holds **row numbers (0..31)**.
    def init_light_tables
      i = 0
      while i < LIGHTLEVELS
        startmap = ((LIGHTLEVELS - 1 - i) * 2) * NUMCOLORMAPS / LIGHTLEVELS
        j = 0
        while j < MAXLIGHTSCALE
          level = startmap - j * SCREENWIDTH / @viewwidth_base / DISTMAP
          level = 0 if level < 0
          level = NUMCOLORMAPS - 1 if level >= NUMCOLORMAPS
          @scalelight[i * MAXLIGHTSCALE + j] = level
          j += 1
        end
        j = 0
        while j < MAXLIGHTZ
          scale = fixed_div(SCREENWIDTH / 2 * FRACUNIT, (j + 1) << LIGHTZSHIFT)
          scale >>= LIGHTSCALESHIFT
          level = startmap - scale / DISTMAP
          level = 0 if level < 0
          level = NUMCOLORMAPS - 1 if level >= NUMCOLORMAPS
          @zlight[i * MAXLIGHTZ + j] = level
          j += 1
        end
        i += 1
      end
    end

    # `R_ExecuteSetViewSize`'s yslope / distscale
    def init_plane_tables
      i = 0
      while i < @viewheight
        dy = ((i - @viewheight / 2) << 16) + FRACUNIT / 2
        dy = -dy if dy < 0
        @yslope[i] = fixed_div(@viewwidth / 2 * FRACUNIT, dy)
        i += 1
      end
      i = 0
      while i < @viewwidth
        cosadj = @finesine[(@xtoviewangle[i] >> ANGLETOFINESHIFT) + 2048]
        cosadj = -cosadj if cosadj < 0
        @distscale[i] = fixed_div(FRACUNIT, cosadj)
        i += 1
      end
    end

    # ---------------------------------------------------------------- angles

    def point_to_angle(px, py)
      x = (((px - @viewx & M32) ^ SGN) - SGN)
      y = (((py - @viewy & M32) ^ SGN) - SGN)
      return 0 if x == 0 && y == 0
      if x >= 0
        if y >= 0
          if x > y
            @tantoangle[slope_div(y, x)]
          else
            ((ANG90 - 1 - @tantoangle[slope_div(x, y)]) & M32)
          end
        else
          y = (((-y & M32) ^ SGN) - SGN)
          if x > y
            ((-@tantoangle[slope_div(y, x)]) & M32)
          else
            ((ANG270 + @tantoangle[slope_div(x, y)]) & M32)
          end
        end
      else
        x = (((-x & M32) ^ SGN) - SGN)
        if y >= 0
          if x > y
            ((ANG180 - 1 - @tantoangle[slope_div(y, x)]) & M32)
          else
            ((ANG90 + @tantoangle[slope_div(x, y)]) & M32)
          end
        else
          y = (((-y & M32) ^ SGN) - SGN)
          if x > y
            ((ANG180 + @tantoangle[slope_div(y, x)]) & M32)
          else
            ((ANG270 - 1 - @tantoangle[slope_div(x, y)]) & M32)
          end
        end
      end
    end

    # `SlopeDiv`: **arguments and arithmetic are unsigned 32-bit**.
    def slope_div(num, den)
      d = den & 0xffffffff
      return 2048 if d < 512
      ans = (((num & 0xffffffff) << 3) & 0xffffffff) / (d >> 8)
      ans <= 2048 ? ans : 2048
    end

    def point_to_dist(px, py)
      dx = (((px - @viewx & M32) ^ SGN) - SGN).abs
      dy = (((py - @viewy & M32) ^ SGN) - SGN).abs
      if dy > dx
        t = dx
        dx = dy
        dy = t
      end
      frac = dx != 0 ? fixed_div(dy, dx) : 0
      angle = ((@tantoangle[frac >> 5] + ANG90) & M32) >> ANGLETOFINESHIFT
      fixed_div(dx, @finesine[angle])
    end

    def scale_from_global_angle(visangle)
      anglea = ((ANG90 + ((visangle - @viewangle) & M32)) & M32)
      angleb = ((ANG90 + ((visangle - @rw_normalangle) & M32)) & M32)
      sinea = @finesine[anglea >> ANGLETOFINESHIFT]
      sineb = @finesine[angleb >> ANGLETOFINESHIFT]
      num = (((@projection * sineb >> 16 & M32) ^ SGN) - SGN)
      den = (((@rw_distance * sinea >> 16 & M32) ^ SGN) - SGN)
      if den > (num >> 16)
        scale = fixed_div(num, den)
        if scale > 64 * FRACUNIT
          scale = 64 * FRACUNIT
        elsif scale < 256
          scale = 256
        end
      else
        scale = 64 * FRACUNIT
      end
      scale
    end

    # **`FixedDiv` is kept closed inside the renderer.**
    # At the level stage calling `Doom::Fixed.div` still got a type, but at the drawing stage
    # the call sites grew to 6 (yslope / distscale / zlight / basexscale /
    # xscale / xiscale), and at once `div` widened to untyped, dragging
    # `point_to_dist` and `scale_from_global_angle` through it down to boxed poly.
    # `Doom::Fixed` stays as the home of the specification and the subject of a gate,
    # and the hot path uses its own equivalent formula. Their equivalence is checked from both sides by
    # `test/fixed_and_bsp.rb` and a gate (242 514 pairs).
    def fixed_div(a, b)
      aa = a < 0 ? -a : a
      ba = b < 0 ? -b : b
      if (aa >> 14) >= ba
        (a ^ b) < 0 ? -2147483648 : 2147483647
      else
        n = a << 16
        q = (n < 0 ? -n : n) / ba
        q = -q unless (n < 0) == (b < 0)
        ((q & M32) ^ SGN) - SGN
      end
    end

    def abs_angle(u)
      u >= 0x80000000 ? 0x100000000 - u : u
    end

    # ---------------------------------------------------------------- BSP

    def clear_clip_segs
      @ss_first[0] = -0x7fffffff
      @ss_last[0] = -1
      @ss_first[1] = @viewwidth
      @ss_last[1] = 0x7fffffff
      @newend = 2
    end

    # `R_ClearPlanes`
    def clear_planes
      i = 0
      while i < @viewwidth
        @floorclip[i] = @viewheight
        @ceilingclip[i] = -1
        i += 1
      end
      @lastvisplane = 0
      @lastopening = 0
      @floorplane = -1
      @ceilingplane = -1
      i = 0
      while i < @sh
        @cachedheight[i] = 0
        i += 1
      end
      angle = ((@viewangle - ANG90) & M32) >> ANGLETOFINESHIFT
      @basexscale = fixed_div(@finesine[angle + 2048], @centerxfrac)
      @baseyscale = -fixed_div(@finesine[angle], @centerxfrac)
    end

    def render_bsp_node(bspnum)
      if (bspnum & 0x8000) != 0
        subsector(bspnum == -1 ? 0 : (bspnum & 0x7fff))
        return
      end
      side = @level.point_on_side(@viewx, @viewy, bspnum)
      render_bsp_node(side == 0 ? @level.node_child0[bspnum] : @level.node_child1[bspnum])
      other = side ^ 1
      if check_bbox(bspnum, other)
        render_bsp_node(other == 0 ? @level.node_child0[bspnum] : @level.node_child1[bspnum])
      end
    end

    def check_bbox(n, child)
      b = n * 8 + child * 4
      bb = @level.node_bbox
      btop = bb[b]
      bbottom = bb[b + 1]
      bleft = bb[b + 2]
      bright = bb[b + 3]

      if @viewx <= bleft
        boxx = 0
      elsif @viewx < bright
        boxx = 1
      else
        boxx = 2
      end
      if @viewy >= btop
        boxy = 0
      elsif @viewy > bbottom
        boxy = 1
      else
        boxy = 2
      end
      boxpos = (boxy << 2) + boxx
      return true if boxpos == 5

      c = boxpos * 4
      x1 = bb[b + CHECKCOORD[c]]
      y1 = bb[b + CHECKCOORD[c + 1]]
      x2 = bb[b + CHECKCOORD[c + 2]]
      y2 = bb[b + CHECKCOORD[c + 3]]

      angle1 = ((point_to_angle(x1, y1) - @viewangle) & M32)
      angle2 = ((point_to_angle(x2, y2) - @viewangle) & M32)
      span = ((angle1 - angle2) & M32)
      return true if span >= ANG180

      tspan = ((angle1 + @clipangle) & M32)
      if tspan > @two_clipangle
        tspan = ((tspan - @two_clipangle) & M32)
        return false if tspan >= span
        angle1 = @clipangle
      end
      tspan = ((@clipangle - angle2) & M32)
      if tspan > @two_clipangle
        tspan = ((tspan - @two_clipangle) & M32)
        return false if tspan >= span
        angle2 = ((-@clipangle) & M32)
      end

      sx1 = @viewangletox[((angle1 + ANG90) & M32) >> ANGLETOFINESHIFT]
      sx2 = @viewangletox[((angle2 + ANG90) & M32) >> ANGLETOFINESHIFT]
      return false if sx1 == sx2
      sx2 -= 1

      st = 0
      st += 1 while @ss_last[st] < sx2
      return false if sx1 >= @ss_first[st] && sx2 <= @ss_last[st]
      true
    end

    def subsector(num)
      @sscount += 1
      if @trace
        @visit_ss[@visit_n] = num
        @visit_n += 1
      end
      lv = @level
      @frontsector = lv.ss_sector[num]
      front = @frontsector
      count = lv.ss_numlines[num]
      first = lv.ss_firstline[num]

      if lv.sector_floorheight[front] < @viewz
        @floorplane = find_plane(lv.sector_floorheight[front],
                                 lv.sector_floorpic[front],
                                 lv.sector_lightlevel[front])
      else
        @floorplane = -1
      end
      if lv.sector_ceilingheight[front] > @viewz ||
         lv.sector_ceilingpic[front] == lv.skyflatnum
        @ceilingplane = find_plane(lv.sector_ceilingheight[front],
                                   lv.sector_ceilingpic[front],
                                   lv.sector_lightlevel[front])
      else
        @ceilingplane = -1
      end

      add_sprites(front)

      i = 0
      while i < count
        add_line(first + i)
        i += 1
      end
    end

    def add_line(seg)
      lv = @level
      @curline = seg
      v1 = lv.seg_v1[seg]
      v2 = lv.seg_v2[seg]
      angle1 = point_to_angle(lv.vertex_x[v1], lv.vertex_y[v1])
      angle2 = point_to_angle(lv.vertex_x[v2], lv.vertex_y[v2])
      span = ((angle1 - angle2) & M32)
      return if span >= ANG180

      @rw_angle1 = angle1
      angle1 = ((angle1 - @viewangle) & M32)
      angle2 = ((angle2 - @viewangle) & M32)

      tspan = ((angle1 + @clipangle) & M32)
      if tspan > @two_clipangle
        tspan = ((tspan - @two_clipangle) & M32)
        return if tspan >= span
        angle1 = @clipangle
      end
      tspan = ((@clipangle - angle2) & M32)
      if tspan > @two_clipangle
        tspan = ((tspan - @two_clipangle) & M32)
        return if tspan >= span
        angle2 = ((-@clipangle) & M32)
      end

      x1 = @viewangletox[((angle1 + ANG90) & M32) >> ANGLETOFINESHIFT]
      x2 = @viewangletox[((angle2 + ANG90) & M32) >> ANGLETOFINESHIFT]
      return if x1 == x2

      back = lv.seg_backsector[seg]
      @backsector = back
      front = @frontsector
      solid = true
      if back >= 0
        if lv.sector_ceilingheight[back] <= lv.sector_floorheight[front] ||
           lv.sector_floorheight[back] >= lv.sector_ceilingheight[front]
          solid = true
        elsif lv.sector_ceilingheight[back] != lv.sector_ceilingheight[front] ||
              lv.sector_floorheight[back] != lv.sector_floorheight[front]
          solid = false
        else
          return if lv.sector_ceilingpic[back] == lv.sector_ceilingpic[front] &&
                    lv.sector_floorpic[back] == lv.sector_floorpic[front] &&
                    lv.sector_lightlevel[back] == lv.sector_lightlevel[front] &&
                    lv.side_midtexture[lv.seg_sidedef[seg]] == 0
          solid = false
        end
      end

      if solid
        clip_solid_wall_segment(x1, x2 - 1)
      else
        clip_pass_wall_segment(x1, x2 - 1)
      end
    end

    def clip_solid_wall_segment(first, last)
      start = 0
      start += 1 while @ss_last[start] < first - 1

      if first < @ss_first[start]
        if last < @ss_first[start] - 1
          store_wall_range(first, last)
          if @newend >= MAXSEGS
            raise LevelError, "solidsegs overflow (MAXSEGS=#{MAXSEGS}) — vanilla would overrun here"
          end
          nx = @newend
          @newend += 1
          while nx != start
            @ss_first[nx] = @ss_first[nx - 1]
            @ss_last[nx] = @ss_last[nx - 1]
            nx -= 1
          end
          @ss_first[nx] = first
          @ss_last[nx] = last
          return
        end
        store_wall_range(first, @ss_first[start] - 1)
        @ss_first[start] = first
      end

      return if last <= @ss_last[start]

      nx = start
      while last >= @ss_first[nx + 1] - 1
        store_wall_range(@ss_last[nx] + 1, @ss_first[nx + 1] - 1)
        nx += 1
        if last <= @ss_last[nx]
          @ss_last[start] = @ss_last[nx]
          crunch(start, nx)
          return
        end
      end

      store_wall_range(@ss_last[nx] + 1, last)
      @ss_last[start] = last
      crunch(start, nx)
    end

    def crunch(start, nx)
      return if nx == start
      s = start
      n = nx
      while n != @newend
        n += 1
        s += 1
        @ss_first[s] = @ss_first[n]
        @ss_last[s] = @ss_last[n]
      end
      @newend = s + 1
    end

    def clip_pass_wall_segment(first, last)
      start = 0
      start += 1 while @ss_last[start] < first - 1

      if first < @ss_first[start]
        if last < @ss_first[start] - 1
          store_wall_range(first, last)
          return
        end
        store_wall_range(first, @ss_first[start] - 1)
      end

      return if last <= @ss_last[start]

      while last >= @ss_first[start + 1] - 1
        store_wall_range(@ss_last[start] + 1, @ss_first[start + 1] - 1)
        start += 1
        return if last <= @ss_last[start]
      end

      store_wall_range(@ss_last[start] + 1, last)
    end

    # ---------------------------------------------------------------- visplane

    # `R_FindPlane`
    def find_plane(height, picnum, lightlevel)
      if picnum == @level.skyflatnum
        height = 0
        lightlevel = 0
      end
      i = 0
      while i < @lastvisplane
        if height == @pl_height[i] && picnum == @pl_picnum[i] &&
           lightlevel == @pl_lightlevel[i]
          return i
        end
        i += 1
      end
      raise LevelError, "R_FindPlane: no more visplanes (MAXVISPLANES=#{MAXVISPLANES})" if @lastvisplane == MAXVISPLANES
      i = @lastvisplane
      @lastvisplane += 1
      @pl_height[i] = height
      @pl_picnum[i] = picnum
      @pl_lightlevel[i] = lightlevel
      @pl_minx[i] = @sw
      @pl_maxx[i] = -1
      clear_plane_top(i)
      i
    end

    def clear_plane_top(i)
      b = i * @plw
      x = 0
      while x < @plw
        @pl_top[b + x] = @plempty
        x += 1
      end
    end

    # `R_CheckPlane`
    def check_plane(pl, start, stop)
      if start < @pl_minx[pl]
        intrl = @pl_minx[pl]
        unionl = start
      else
        unionl = @pl_minx[pl]
        intrl = start
      end
      if stop > @pl_maxx[pl]
        intrh = @pl_maxx[pl]
        unionh = stop
      else
        unionh = @pl_maxx[pl]
        intrh = stop
      end

      b = pl * @plw + 1
      x = intrl
      x += 1 while x <= intrh && @pl_top[b + x] == @plempty

      if x > intrh
        @pl_minx[pl] = unionl
        @pl_maxx[pl] = unionh
        return pl
      end

      raise LevelError, "R_CheckPlane: no more visplanes (MAXVISPLANES=#{MAXVISPLANES})" if @lastvisplane == MAXVISPLANES
      n = @lastvisplane
      @lastvisplane += 1
      @pl_height[n] = @pl_height[pl]
      @pl_picnum[n] = @pl_picnum[pl]
      @pl_lightlevel[n] = @pl_lightlevel[pl]
      @pl_minx[n] = start
      @pl_maxx[n] = stop
      clear_plane_top(n)
      n
    end

    # `R_DrawPlanes`
    def draw_planes
      lv = @level
      pl = 0
      while pl < @lastvisplane
        if @pl_minx[pl] > @pl_maxx[pl]
          pl += 1
          next
        end
        @curpicnum = @pl_picnum[pl]
        if @pl_picnum[pl] == lv.skyflatnum
          draw_sky_plane(pl)
          pl += 1
          next
        end

        @ds_source = @textures.flatdata(@pl_picnum[pl])
        ph = @pl_height[pl] - @viewz
        @planeheight = ph < 0 ? -ph : ph
        light = (@pl_lightlevel[pl] >> LIGHTSEGSHIFT) + @extralight
        light = LIGHTLEVELS - 1 if light >= LIGHTLEVELS
        light = 0 if light < 0
        @planezlight = light * MAXLIGHTZ

        b = pl * @plw + 1
        @pl_top[b + @pl_maxx[pl] + 1] = @plempty
        @pl_top[b + @pl_minx[pl] - 1] = @plempty

        stop = @pl_maxx[pl] + 1
        x = @pl_minx[pl]
        while x <= stop
          make_spans(x, @pl_top[b + x - 1], @pl_bottom[b + x - 1],
                     @pl_top[b + x], @pl_bottom[b + x])
          x += 1
        end
        pl += 1
      end
    end

    # A sky visplane becomes **column drawing of a texture**, not a flat.
    # `dc_colormap` is always row 0 (vanilla's hack so that INVUL's inversion does not apply).
    def draw_sky_plane(pl)
      tex = @level.skytexture
      buf = @textures.texdata(tex)
      b = pl * @plw + 1
      x = @pl_minx[pl]
      maxx = @pl_maxx[pl]
      while x <= maxx
        yl = @pl_top[b + x]
        yh = @pl_bottom[b + x]
        if yl <= yh
          angle = ((@viewangle + @xtoviewangle[x]) & M32) >> ANGLETOSKYSHIFT
          @dc_x = x
          @dc_yl = yl
          @dc_yh = yh
          @dc_iscale = @pspriteiscale
          @dc_texturemid = @skytexturemid
          @dc_colormap = 0
          @dc_srcbuf = buf
          c = (angle & @textures.widthmask(tex)) << 7
          @dc_srcofs = c
          @dc_srcbase = @textures.atlas_base(tex) + c if @jobmode != 0
          trace_column(4, tex, angle) if @trace
          draw_column
        end
        x += 1
      end
    end

    # `R_MakeSpans`
    def make_spans(x, t1, b1, t2, b2)
      while t1 < t2 && t1 <= b1
        map_plane(t1, @spanstart[t1], x - 1)
        t1 += 1
      end
      while b1 > b2 && b1 >= t1
        map_plane(b1, @spanstart[b1], x - 1)
        b1 -= 1
      end
      while t2 < t1 && t2 <= b2
        @spanstart[t2] = x
        t2 += 1
      end
      while b2 > b1 && b2 >= t2
        @spanstart[b2] = x
        b2 -= 1
      end
    end

    # `R_MapPlane`
    def map_plane(y, x1, x2)
      if @planeheight != @cachedheight[y]
        @cachedheight[y] = @planeheight
        distance = (((@planeheight * @yslope[y] >> 16 & M32) ^ SGN) - SGN)
        @cacheddistance[y] = distance
        xstep = (((distance * @basexscale >> 16 & M32) ^ SGN) - SGN)
        ystep = (((distance * @baseyscale >> 16 & M32) ^ SGN) - SGN)
        @cachedxstep[y] = xstep
        @cachedystep[y] = ystep
      else
        distance = @cacheddistance[y]
        xstep = @cachedxstep[y]
        ystep = @cachedystep[y]
      end

      length = (((distance * @distscale[x1] >> 16 & M32) ^ SGN) - SGN)
      angle = ((@viewangle + @xtoviewangle[x1]) & M32) >> ANGLETOFINESHIFT
      c = @finesine[angle + 2048]
      s = @finesine[angle]
      xfrac = (((@viewx + (((c * length >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN
      yfrac = (((-@viewy - (((s * length >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN

      index = distance >> LIGHTZSHIFT
      index = MAXLIGHTZ - 1 if index >= MAXLIGHTZ
      cmap = @zlight[@planezlight + index]

      if @trace
        i = @span_n
        @span_y[i] = y
        @span_x1[i] = x1
        @span_x2[i] = x2
        @span_xfrac[i] = xfrac
        @span_yfrac[i] = yfrac
        @span_xstep[i] = xstep
        @span_ystep[i] = ystep
        @span_cmap[i] = cmap
        @span_picnum[i] = @curpicnum
        @span_n = i + 1
      end

      draw_span(y, x1, x2, xfrac, yfrac, xstep, ystep, cmap)
    end

    # `R_DrawSpan`. **The live implementation of the reference (doomgeneric = the Chocolate
    # Doom line) is not linuxdoom's formula** (what was copied at first was the `#if 0` side
    # of the same file). It **packs x and y into one 32-bit `position`**:
    #
    #   position = ((xfrac << 10) & 0xffff0000) | ((yfrac >> 6) & 0x0000ffff)
    #   step     = ((xstep << 10) & 0xffff0000) | ((ystep >> 6) & 0x0000ffff)
    #   ytemp = (position >> 4) & 0x0fc0 ; xtemp = position >> 26 ; spot = xtemp | ytemp
    #
    # The top 16 bits are x (6 integer bits + 10 fraction bits), the bottom 16 bits y. **The
    # fraction is cut to 10 bits, and carries from y leak into x's field**, so the answer
    # differs from linuxdoom's formula. Measured, **1 025 pixels** disagreed.
    def draw_span(y, x1, x2, xfrac, yfrac, xstep, ystep, cmap)
      position = ((((xfrac & M32) << 10) & 0xffff0000) | (((yfrac & M32) >> 6) & 0xffff)) & M32
      step = ((((xstep & M32) << 10) & 0xffff0000) | (((ystep & M32) >> 6) & 0xffff)) & M32
      # The Job IR does not hold x/y fractions separately; it keeps **this packed position/step
      # as it is** (its meaning closes on one u32 addition). A flat is the atlas of 4096B planes.
      if @jobmode != 0
        @jobs.push_span(y, x1, x2, position, step,
                        @textures.flat_atlas_base(@curpicnum), cmap)
        return
      end
      # Take the ivar reads out of the loop (2 ivar loads per pixel vanish).
      src = @ds_source
      scr = @screen
      cmp = @colormap
      cm = cmap * 256
      o = (y + @viewwindowy) * @sw + x1 + @viewwindowx
      count = x2 - x1
      i = 0
      while i <= count
        spot = (position >> 26) | ((position >> 4) & 0x0fc0)
        scr.setbyte(o, cmp.getbyte(cm + src.getbyte(spot)))
        o += 1
        position = (position + step) & M32
        i += 1
      end
    end

    # ---------------------------------------------------------------- walls

    # `R_StoreWallRange`
    def store_wall_range(start, stop)
      return if @ds_count == MAXDRAWSEGS
      lv = @level
      seg = @curline
      sidedef = lv.seg_sidedef[seg]
      linedef = lv.seg_linedef[seg]

      flags = lv.line_flags
      flags[linedef] = flags[linedef] | ML_MAPPED

      @rw_normalangle = ((lv.seg_angle[seg] + ANG90) & M32)
      offsetangle = abs_angle(((@rw_normalangle - @rw_angle1) & M32))
      offsetangle = ANG90 if offsetangle > ANG90
      distangle = ANG90 - offsetangle
      hyp = point_to_dist(lv.vertex_x[lv.seg_v1[seg]], lv.vertex_y[lv.seg_v1[seg]])
      sineval = @finesine[distangle >> ANGLETOFINESHIFT]
      @rw_distance = (((hyp * sineval >> 16 & M32) ^ SGN) - SGN)

      ds = @ds_count
      @ds_curline[ds] = seg
      @ds_x1[ds] = start
      @ds_x2[ds] = stop
      @rw_x = start
      @rw_stopx = stop + 1
      @rw_scale = scale_from_global_angle(((@viewangle + @xtoviewangle[start]) & M32))
      @ds_scale1[ds] = @rw_scale
      if stop > start
        scale2 = scale_from_global_angle(((@viewangle + @xtoviewangle[stop]) & M32))
        @ds_scale2[ds] = scale2
        num = scale2 - @rw_scale
        q = (num < 0 ? -num : num) / (stop - start)
        q = -q if num < 0
        @rw_scalestep = ((q & M32) ^ SGN) - SGN
        @ds_scalestep[ds] = @rw_scalestep
      else
        @ds_scale2[ds] = @ds_scale1[ds]
        @ds_scalestep[ds] = @rw_scalestep
      end

      front = @frontsector
      back = @backsector
      @worldtop = (((lv.sector_ceilingheight[front] - @viewz & M32) ^ SGN) - SGN)
      @worldbottom = (((lv.sector_floorheight[front] - @viewz & M32) ^ SGN) - SGN)

      @midtexture = 0
      @toptexture = 0
      @bottomtexture = 0
      @maskedtexture = 0
      @ds_maskedbase[ds] = -1
      @ds_masked[ds] = 0

      if back < 0
        # Goes through `texturetranslation[]` (`r_segs.c`). **Animated wall textures**
        # turn into another number here. This was the cause of the split at DEMO1's
        # tic 60. Looking up `textureheight[]` is
        # **not translated**: vanilla writes it that way.
        @midtexture = @textures.translate_texture(lv.side_midtexture[sidedef])
        @markfloor = true
        @markceiling = true
        if (lv.line_flags[linedef] & ML_DONTPEGBOTTOM) != 0
          vtop = lv.sector_floorheight[front] + @textures.theight(lv.side_midtexture[sidedef])
          @rw_midtexturemid = (((vtop - @viewz & M32) ^ SGN) - SGN)
        else
          @rw_midtexturemid = @worldtop
        end
        @rw_midtexturemid = (((@rw_midtexturemid + lv.side_rowoffset[sidedef] & M32) ^ SGN) - SGN)

        @ds_silhouette[ds] = SIL_BOTH
        @ds_topkind[ds] = CLIP_SCREENHEIGHT
        @ds_botkind[ds] = CLIP_NEGONE
        @ds_bsilheight[ds] = 0x7fffffff
        @ds_tsilheight[ds] = -0x80000000
      else
        @ds_topkind[ds] = CLIP_NONE
        @ds_botkind[ds] = CLIP_NONE
        @ds_silhouette[ds] = SIL_NONE

        if lv.sector_floorheight[front] > lv.sector_floorheight[back]
          @ds_silhouette[ds] = SIL_BOTTOM
          @ds_bsilheight[ds] = lv.sector_floorheight[front]
        elsif lv.sector_floorheight[back] > @viewz
          @ds_silhouette[ds] = SIL_BOTTOM
          @ds_bsilheight[ds] = 0x7fffffff
        end

        if lv.sector_ceilingheight[front] < lv.sector_ceilingheight[back]
          @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_TOP
          @ds_tsilheight[ds] = lv.sector_ceilingheight[front]
        elsif lv.sector_ceilingheight[back] < @viewz
          @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_TOP
          @ds_tsilheight[ds] = -0x80000000
        end

        if lv.sector_ceilingheight[back] <= lv.sector_floorheight[front]
          @ds_botkind[ds] = CLIP_NEGONE
          @ds_bsilheight[ds] = 0x7fffffff
          @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_BOTTOM
        end
        if lv.sector_floorheight[back] >= lv.sector_ceilingheight[front]
          @ds_topkind[ds] = CLIP_SCREENHEIGHT
          @ds_tsilheight[ds] = -0x80000000
          @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_TOP
        end

        @worldhigh = (((lv.sector_ceilingheight[back] - @viewz & M32) ^ SGN) - SGN)
        @worldlow = (((lv.sector_floorheight[back] - @viewz & M32) ^ SGN) - SGN)

        if lv.sector_ceilingpic[front] == lv.skyflatnum &&
           lv.sector_ceilingpic[back] == lv.skyflatnum
          @worldtop = @worldhigh
        end

        @markfloor = @worldlow != @worldbottom ||
                     lv.sector_floorpic[back] != lv.sector_floorpic[front] ||
                     lv.sector_lightlevel[back] != lv.sector_lightlevel[front]
        @markceiling = @worldhigh != @worldtop ||
                       lv.sector_ceilingpic[back] != lv.sector_ceilingpic[front] ||
                       lv.sector_lightlevel[back] != lv.sector_lightlevel[front]

        if lv.sector_ceilingheight[back] <= lv.sector_floorheight[front] ||
           lv.sector_floorheight[back] >= lv.sector_ceilingheight[front]
          @markceiling = true
          @markfloor = true
        end

        if @worldhigh < @worldtop
          @toptexture = @textures.translate_texture(lv.side_toptexture[sidedef])
          if (lv.line_flags[linedef] & ML_DONTPEGTOP) != 0
            @rw_toptexturemid = @worldtop
          else
            vtop = lv.sector_ceilingheight[back] + @textures.theight(lv.side_toptexture[sidedef])
            @rw_toptexturemid = (((vtop - @viewz & M32) ^ SGN) - SGN)
          end
        end
        if @worldlow > @worldbottom
          @bottomtexture = @textures.translate_texture(lv.side_bottomtexture[sidedef])
          if (lv.line_flags[linedef] & ML_DONTPEGBOTTOM) != 0
            @rw_bottomtexturemid = @worldtop
          else
            @rw_bottomtexturemid = @worldlow
          end
        end
        # These 2 lines **run whether or not there is a texture** (vanilla's position as it is).
        # `rw_*texturemid` are file scope, so rowoffset piles up.
        @rw_toptexturemid = (((@rw_toptexturemid + lv.side_rowoffset[sidedef] & M32) ^ SGN) - SGN)
        @rw_bottomtexturemid = (((@rw_bottomtexturemid + lv.side_rowoffset[sidedef] & M32) ^ SGN) - SGN)

        if lv.side_midtexture[sidedef] != 0
          @maskedtexture = 1
          @maskedtexturecol = @lastopening - @rw_x
          @ds_maskedbase[ds] = @maskedtexturecol
          @ds_masked[ds] = 1
          @lastopening += @rw_stopx - @rw_x
          if @lastopening > @maxopenings
            raise LevelError, "openings overflow (MAXOPENINGS=#{@maxopenings})"
          end
        end
      end

      @segtextured = @midtexture | @toptexture | @bottomtexture | @maskedtexture

      if @segtextured != 0
        # `rw_offset` (the end of `R_StoreWallRange`). All angle_t (unsigned).
        offsetangle = ((@rw_normalangle - @rw_angle1) & M32)
        offsetangle = ((-offsetangle) & M32) if offsetangle > ANG180
        offsetangle = ANG90 if offsetangle > ANG90
        sineval = @finesine[offsetangle >> ANGLETOFINESHIFT]
        @rw_offset = (((hyp * sineval >> 16 & M32) ^ SGN) - SGN)
        if ((@rw_normalangle - @rw_angle1) & M32) < ANG180
          @rw_offset = (((-@rw_offset & M32) ^ SGN) - SGN)
        end
        @rw_offset = (((@rw_offset + lv.side_textureoffset[sidedef] + lv.seg_offset[seg] & M32) ^ SGN) - SGN)
        @rw_centerangle = ((ANG90 + @viewangle - @rw_normalangle) & M32)

        lightnum = (lv.sector_lightlevel[front] >> LIGHTSEGSHIFT) + @extralight
        if lv.vertex_y[lv.seg_v1[seg]] == lv.vertex_y[lv.seg_v2[seg]]
          lightnum -= 1
        elsif lv.vertex_x[lv.seg_v1[seg]] == lv.vertex_x[lv.seg_v2[seg]]
          lightnum += 1
        end
        lightnum = 0 if lightnum < 0
        lightnum = LIGHTLEVELS - 1 if lightnum >= LIGHTLEVELS
        @walllights = lightnum * MAXLIGHTSCALE
      end

      @markfloor = false if lv.sector_floorheight[front] >= @viewz
      if lv.sector_ceilingheight[front] <= @viewz &&
         lv.sector_ceilingpic[front] != lv.skyflatnum
        @markceiling = false
      end

      @worldtop >>= 4
      @worldbottom >>= 4

      half = @centeryfrac >> 4
      m = ((@rw_scalestep * @worldtop >> 16 & M32) ^ SGN) - SGN
      @topstep = ((-m & M32) ^ SGN) - SGN
      m = ((@worldtop * @rw_scale >> 16 & M32) ^ SGN) - SGN
      @topfrac = (((half - m) & M32) ^ SGN) - SGN
      m = ((@rw_scalestep * @worldbottom >> 16 & M32) ^ SGN) - SGN
      @bottomstep = ((-m & M32) ^ SGN) - SGN
      m = ((@worldbottom * @rw_scale >> 16 & M32) ^ SGN) - SGN
      @bottomfrac = (((half - m) & M32) ^ SGN) - SGN

      if back >= 0
        @worldhigh >>= 4
        @worldlow >>= 4
        if @worldhigh < @worldtop
          m = ((@worldhigh * @rw_scale >> 16 & M32) ^ SGN) - SGN
          @pixhigh = (((half - m) & M32) ^ SGN) - SGN
          m = ((@rw_scalestep * @worldhigh >> 16 & M32) ^ SGN) - SGN
          @pixhighstep = ((-m & M32) ^ SGN) - SGN
        end
        if @worldlow > @worldbottom
          m = ((@worldlow * @rw_scale >> 16 & M32) ^ SGN) - SGN
          @pixlow = (((half - m) & M32) ^ SGN) - SGN
          m = ((@rw_scalestep * @worldlow >> 16 & M32) ^ SGN) - SGN
          @pixlowstep = ((-m & M32) ^ SGN) - SGN
        end
      end

      trace_wall if @trace

      if @markceiling
        raise LevelError, "markceiling with no ceilingplane (seg #{seg})" if @ceilingplane < 0
        @ceilingplane = check_plane(@ceilingplane, @rw_x, @rw_stopx - 1)
      end
      if @markfloor
        raise LevelError, "markfloor with no floorplane (seg #{seg})" if @floorplane < 0
        @floorplane = check_plane(@floorplane, @rw_x, @rw_stopx - 1)
      end

      render_seg_loop

      # Saves the sprite clip information into openings.
      # The **pointer with a negative offset** `ds_p->sprtopclip = lastopening - start`
      # is replaced with 2 values (base, x).
      if ((@ds_silhouette[ds] & SIL_TOP) != 0 || @maskedtexture != 0) &&
         @ds_topkind[ds] == CLIP_NONE
        i = 0
        n = @rw_stopx - start
        while i < n
          @openings[@lastopening + i] = @ceilingclip[start + i]
          i += 1
        end
        @ds_topkind[ds] = CLIP_OPENINGS
        @ds_topbase[ds] = @lastopening - start
        @lastopening += n
        raise LevelError, "openings overflow (MAXOPENINGS=#{@maxopenings})" if @lastopening > @maxopenings
      end
      if ((@ds_silhouette[ds] & SIL_BOTTOM) != 0 || @maskedtexture != 0) &&
         @ds_botkind[ds] == CLIP_NONE
        i = 0
        n = @rw_stopx - start
        while i < n
          @openings[@lastopening + i] = @floorclip[start + i]
          i += 1
        end
        @ds_botkind[ds] = CLIP_OPENINGS
        @ds_botbase[ds] = @lastopening - start
        @lastopening += n
        raise LevelError, "openings overflow (MAXOPENINGS=#{@maxopenings})" if @lastopening > @maxopenings
      end
      if @maskedtexture != 0 && (@ds_silhouette[ds] & SIL_TOP) == 0
        @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_TOP
        @ds_tsilheight[ds] = -0x80000000
      end
      if @maskedtexture != 0 && (@ds_silhouette[ds] & SIL_BOTTOM) == 0
        @ds_silhouette[ds] = @ds_silhouette[ds] | SIL_BOTTOM
        @ds_bsilheight[ds] = 0x7fffffff
      end
      @ds_count += 1
    end

    def trace_wall
      ds = @ds_count
      i = @wall_n
      @wall_seg[i] = @curline
      @wall_x1[i] = @rw_x
      @wall_x2[i] = @rw_stopx - 1
      @wall_distance[i] = @rw_distance
      @wall_scale[i] = @rw_scale
      @wall_scalestep[i] = @rw_scalestep
      @wall_worldtop[i] = @worldtop
      @wall_worldbottom[i] = @worldbottom
      @wall_mid[i] = @midtexture
      @wall_top[i] = @toptexture
      @wall_bottom[i] = @bottomtexture
      @wall_markfloor[i] = @markfloor ? 1 : 0
      @wall_markceiling[i] = @markceiling ? 1 : 0
      @wall_segtextured[i] = @segtextured
      @wall_topfrac[i] = @topfrac
      @wall_topstep[i] = @topstep
      @wall_bottomfrac[i] = @bottomfrac
      @wall_bottomstep[i] = @bottomstep
      @wall_offset[i] = @rw_offset
      @wall_centerangle[i] = @rw_centerangle
      @wall_midmid[i] = @rw_midtexturemid
      @wall_topmid[i] = @rw_toptexturemid
      @wall_botmid[i] = @rw_bottomtexturemid
      @wall_sil[i] = @ds_silhouette[ds]
      @wall_bsil[i] = @ds_bsilheight[ds]
      @wall_tsil[i] = @ds_tsilheight[ds]
      @wall_masked[i] = @ds_masked[ds]
      @wall_n = i + 1
    end

    def trace_column(tier, texnum, texcol)
      i = @column_n
      @column_phase[i] = @phase
      @column_tier[i] = tier
      @column_x[i] = @dc_x
      @column_yl[i] = @dc_yl
      @column_yh[i] = @dc_yh
      @column_texnum[i] = texnum
      @column_texcol[i] = texcol
      @column_iscale[i] = @dc_iscale
      @column_texmid[i] = @dc_texturemid
      @column_cmap[i] = @dc_colormap
      @column_n = i + 1
    end

    # `R_RenderSegLoop`
    def render_seg_loop
      lv = @level
      while @rw_x < @rw_stopx
        x = @rw_x

        yl = (((@topfrac + HEIGHTUNIT - 1 & M32) ^ SGN) - SGN) >> HEIGHTBITS
        cc = @ceilingclip[x]
        yl = cc + 1 if yl < cc + 1

        if @markceiling
          top = @ceilingclip[x] + 1
          bottom = yl - 1
          bottom = @floorclip[x] - 1 if bottom >= @floorclip[x]
          if top <= bottom
            b = @ceilingplane * @plw + 1 + x
            @pl_top[b] = top
            @pl_bottom[b] = bottom
          end
        end

        yh = @bottomfrac >> HEIGHTBITS
        fc = @floorclip[x]
        yh = fc - 1 if yh >= fc

        if @markfloor
          top = yh + 1
          bottom = @floorclip[x] - 1
          top = @ceilingclip[x] + 1 if top <= @ceilingclip[x]
          if top <= bottom
            b = @floorplane * @plw + 1 + x
            @pl_top[b] = top
            @pl_bottom[b] = bottom
          end
        end

        texturecolumn = 0
        if @segtextured != 0
          angle = ((@rw_centerangle + @xtoviewangle[x]) & M32) >> ANGLETOFINESHIFT
          # When rw_centerangle + xtoviewangle[x] is exactly ANG180, angle is
          # 4096, one past finetangent's last entry. Vanilla's R_RenderSegLoop
          # makes this same read in C and gets the next table in memory,
          # finesine[0], so that is what is read here. It is reached only at
          # -res 960x600 and above (DEMO1, tic 321, column 735 of 1280); the
          # table is not extended because the CORE render entry takes it as a
          # buffer of exactly 4096 (examples/doom/core/catalog.tsv).
          ft = angle == @finetangent.length ? @finesine[0] : @finetangent[angle]
          m = ((ft * @rw_distance >> 16 & M32) ^ SGN) - SGN
          texturecolumn = ((((@rw_offset - m) & M32) ^ SGN) - SGN) >> 16
          index = light_index(@rw_scale)
          @dc_colormap = @scalelight[@walllights + index]
          @dc_x = x
          # `dc_iscale = 0xffffffff / rw_scale` is **an unsigned 32-bit division**.
          @dc_iscale = M32 / (@rw_scale & M32)
        end

        if @midtexture != 0
          @dc_yl = yl
          @dc_yh = yh
          @dc_texturemid = @rw_midtexturemid
          set_texture_column(@midtexture, texturecolumn)
          trace_column(0, @midtexture, texturecolumn) if @trace
          draw_column
          @ceilingclip[x] = (((@viewheight) & M16 ^ SGN16) - SGN16)
          @floorclip[x] = -1
        else
          if @toptexture != 0
            mid = @pixhigh >> HEIGHTBITS
            @pixhigh = (((@pixhigh + @pixhighstep & M32) ^ SGN) - SGN)
            mid = @floorclip[x] - 1 if mid >= @floorclip[x]
            if mid >= yl
              @dc_yl = yl
              @dc_yh = mid
              @dc_texturemid = @rw_toptexturemid
              set_texture_column(@toptexture, texturecolumn)
              trace_column(1, @toptexture, texturecolumn) if @trace
              draw_column
              @ceilingclip[x] = (((mid) & M16 ^ SGN16) - SGN16)
            else
              @ceilingclip[x] = (((yl - 1) & M16 ^ SGN16) - SGN16)
            end
          elsif @markceiling
            @ceilingclip[x] = (((yl - 1) & M16 ^ SGN16) - SGN16)
          end

          if @bottomtexture != 0
            mid = (((@pixlow + HEIGHTUNIT - 1 & M32) ^ SGN) - SGN) >> HEIGHTBITS
            @pixlow = (((@pixlow + @pixlowstep & M32) ^ SGN) - SGN)
            mid = @ceilingclip[x] + 1 if mid <= @ceilingclip[x]
            if mid <= yh
              @dc_yl = mid
              @dc_yh = yh
              @dc_texturemid = @rw_bottomtexturemid
              set_texture_column(@bottomtexture, texturecolumn)
              trace_column(2, @bottomtexture, texturecolumn) if @trace
              draw_column
              @floorclip[x] = (((mid) & M16 ^ SGN16) - SGN16)
            else
              @floorclip[x] = (((yh + 1) & M16 ^ SGN16) - SGN16)
            end
          elsif @markfloor
            @floorclip[x] = (((yh + 1) & M16 ^ SGN16) - SGN16)
          end

          if @maskedtexture != 0
            # C's `maskedtexturecol` is `short[]`, so it is truncated to 16 bits.
            @openings[@maskedtexturecol + x] = ((texturecolumn & M16) ^ SGN16) - SGN16
          end
        end

        @rw_scale = (((@rw_scale + @rw_scalestep & M32) ^ SGN) - SGN)
        @topfrac = (((@topfrac + @topstep & M32) ^ SGN) - SGN)
        @bottomfrac = (((@bottomfrac + @bottomstep & M32) ^ SGN) - SGN)
        @rw_x = x + 1
      end
    end

    # The 2-value version of `R_GetColumn` (buffer and offset).
    def set_texture_column(tex, col)
      @dc_srcbuf = @textures.texdata(tex)
      # Written as a formula without calling `column_offset`. The column windows are laid out
      # **at a fixed 128, not the height** (`Textures::TEXCOL_STRIDE`), so
      # `(col & widthmask) << 7`.
      c = (col & @textures.widthmask(tex)) << 7
      @dc_srcofs = c
      # In the Job IR it becomes an offset inside the one atlas (always a multiple of 128).
      @dc_srcbase = @textures.atlas_base(tex) + c if @jobmode != 0
    end

    # `R_DrawColumn`. **`& 127` is a mask that assumes a texture column height of 128**, and
    # textures not 128 high do not wrap correctly in vanilla either (reproducing it is required).
    # `frac += fracstep` wraps at 32 bits.
    def draw_column(use_zone_window = false)
      return emit_column if @jobmode != 0
      return draw_fuzz_column if @dc_fuzz
      count = @dc_yh - @dc_yl
      return if count < 0
      buf = @dc_srcbuf
      ofs = @dc_srcofs
      scr = @screen
      cmp = @colormap
      cm = @dc_colormap * 256
      fracstep = @dc_iscale & M32
      frac = (@dc_texturemid + (@dc_yl - @centery) * fracstep) & M32
      o = (@dc_yl + @viewwindowy) * @sw + @dc_x + @viewwindowx
      i = 0
      while i <= count
        source_index = ofs + ((frac >> 16) & 127)
        source_byte = use_zone_window ? @zonewin.getbyte(source_index) : buf.getbyte(source_index)
        scr.setbyte(o, cmp.getbyte(cm + source_byte))
        o += @sw
        frac = (frac + fracstep) & M32
        i += 1
      end
    end

    # ---- queue one job instead of drawing directly -----------------------------
    #
    # The phase decides the bank: phase 0 (walls) and phase 1 (sky)
    # **always read from the texture column atlas**, so they go to the wall bank; phase 2/3 (masked)
    # read posts of patch lumps, so they go to the masked bank.
    #
    # Fuzz (`R_DrawFuzzColumn`) **fixes `fuzzpos` here**.
    # Vanilla's `fuzzpos` advances by one per pixel and carries over across columns and
    # frames, but **the issue order of columns is deterministic**, so once the starting
    # phase is baked into the job, the executor can draw without looking at other jobs
    # ("a sequence that can be computed in advance, not an order dependence").
    # The y clipping (`yl==0 -> 1` / `yh==viewheight-1 -> viewheight-2`) is done
    # here too. A job's y-interval becomes **the interval really painted**, and
    # check #4 means something.
    def emit_column
      if @phase < 2
        @jobs.push_wall(@dc_x, @dc_yl, @dc_yh, @dc_iscale, @dc_texturemid,
                        @dc_srcbase, @dc_colormap)
      elsif @dc_fuzz
        yl = @dc_yl
        yh = @dc_yh
        yl = 1 if yl == 0
        yh = @viewheight - 2 if yh == @viewheight - 1
        fp = @fuzzpos
        count = yh - yl
        if count >= 0
          n = fp + count + 1
          n -= 50 while n >= 50
          @fuzzpos = n
        end
        @jobs.push_masked(@dc_x, yl, yh, 0, 0, Jobs::RES_WAD, 0, 0, fp)
      else
        @jobs.push_masked(@dc_x, @dc_yl, @dc_yh, @dc_iscale, @dc_texturemid,
                          @dc_srcres, @dc_srcbase, @dc_colormap, -1)
      end
    end

    # `R_DrawFuzzColumn` (`r_draw.c`). **It reads no texture**: it writes
    # the pixel one line above or below on the screen already drawn, darkened with colormap row 6.
    # So "drawing the same things in the same order" is a precondition, and
    # `@fuzzpos` keeps advancing across frames.
    def draw_fuzz_column
      yl = @dc_yl
      yh = @dc_yh
      yl = 1 if yl == 0
      yh = @viewheight - 2 if yh == @viewheight - 1
      count = yh - yl
      return if count < 0
      scr = @screen
      cmp = @colormap
      o = (yl + @viewwindowy) * @sw + @dc_x + @viewwindowx
      i = 0
      while i <= count
        scr.setbyte(o, cmp.getbyte(6 * 256 + scr.getbyte(o + @fuzzoffset[@fuzzpos] * @sw)))
        @fuzzpos += 1
        @fuzzpos = 0 if @fuzzpos == 50
        o += @sw
        i += 1
      end
    end

    # ---------------------------------------------------------------- sprites

    # `R_AddSprites`. The link order of `sec->thinglist` is the order vissprites are made.
    def add_sprites(sec)
      return if @sector_validcount[sec] == @validcount
      @sector_validcount[sec] = @validcount
      lightnum = (@level.sector_lightlevel[sec] >> LIGHTSEGSHIFT) + @extralight
      lightnum = 0 if lightnum < 0
      lightnum = LIGHTLEVELS - 1 if lightnum >= LIGHTLEVELS
      @spritelights = lightnum * MAXLIGHTSCALE
      t = @things.sector_head[sec]
      while t >= 0
        project_sprite(t)
        t = @things.thing_next[t]
      end
    end

    # `R_ProjectSprite`
    def project_sprite(thing)
      th = @things
      tr_x = (((th.mobj_x[thing] - @viewx & M32) ^ SGN) - SGN)
      tr_y = (((th.mobj_y[thing] - @viewy & M32) ^ SGN) - SGN)
      gxt = (((tr_x * @viewcos >> 16 & M32) ^ SGN) - SGN)
      gyt = (((tr_y * @viewsin >> 16 & M32) ^ SGN) - SGN)
      gyt = (((-gyt & M32) ^ SGN) - SGN)
      tz = (((gxt - gyt & M32) ^ SGN) - SGN)
      return if tz < MINZ

      xscale = fixed_div(@projection, tz)

      gxt = (((tr_x * @viewsin >> 16 & M32) ^ SGN) - SGN)
      gxt = (((-gxt & M32) ^ SGN) - SGN)
      gyt = (((tr_y * @viewcos >> 16 & M32) ^ SGN) - SGN)
      tx = (((-(gyt + gxt) & M32) ^ SGN) - SGN)
      atx = tx < 0 ? -tx : tx
      # `tz * 4` is equivalent to `tz << 2`, but `<<` is ambiguous with Array#push, and
      # if tz's type is decided late it is misread as push and promoted to int_array.
      # That burns into fixed_div's parameters and 8 methods fall to boxed
      # (one line of source made a frame 2.69 times slower; the same discipline as for type inference elsewhere).
      return if atx > (((tz * 4) & M32) ^ SGN) - SGN

      sp = @sprites
      spr = th.mobj_sprite[thing]
      frame = th.mobj_frame[thing] & Info::FF_FRAMEMASK
      if frame >= sp.numframes(spr)
        raise LevelError, "invalid sprite frame #{spr}:#{frame}"
      end
      if sp.frame_rotate(spr, frame) != 0
        ang = point_to_angle(th.mobj_x[thing], th.mobj_y[thing])
        rot = ((ang - th.mobj_angle[thing] + 0x90000000) & M32) >> 29
        lump = sp.frame_lump(spr, frame, rot)
        flip = sp.frame_flip(spr, frame, rot)
      else
        lump = sp.frame_lump(spr, frame, 0)
        flip = sp.frame_flip(spr, frame, 0)
      end

      tx = (((tx - sp.spriteoffset(lump) & M32) ^ SGN) - SGN)
      x1 = (((@centerxfrac + (((tx * xscale >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN
      x1 >>= 16
      return if x1 > @viewwidth
      tx = (((tx + sp.spritewidth(lump) & M32) ^ SGN) - SGN)
      x2 = (((@centerxfrac + (((tx * xscale >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN
      x2 = (x2 >> 16) - 1
      return if x2 < 0

      raise LevelError, "vissprite overflow (MAXVISSPRITES=#{MAXVISSPRITES})" if @vis_n == MAXVISSPRITES
      v = @vis_n
      @vis_n += 1
      flags = th.mobj_flags[thing]
      @vs_mobjflags[v] = flags
      @vs_scale[v] = xscale
      @vs_gx[v] = th.mobj_x[thing]
      @vs_gy[v] = th.mobj_y[thing]
      @vs_gz[v] = th.mobj_z[thing]
      gzt = (((th.mobj_z[thing] + sp.spritetopoffset(lump) & M32) ^ SGN) - SGN)
      @vs_gzt[v] = gzt
      @vs_texturemid[v] = (((gzt - @viewz & M32) ^ SGN) - SGN)
      @vs_x1[v] = x1 < 0 ? 0 : x1
      @vs_x2[v] = x2 >= @viewwidth ? @viewwidth - 1 : x2
      iscale = fixed_div(FRACUNIT, xscale)
      if flip != 0
        @vs_startfrac[v] = sp.spritewidth(lump) - 1
        @vs_xiscale[v] = (((-iscale & M32) ^ SGN) - SGN)
      else
        @vs_startfrac[v] = 0
        @vs_xiscale[v] = iscale
      end
      if @vs_x1[v] > x1
        d = (((@vs_xiscale[v] * (@vs_x1[v] - x1) & M32) ^ SGN) - SGN)
        @vs_startfrac[v] = (((@vs_startfrac[v] + d & M32) ^ SGN) - SGN)
      end
      @vs_patch[v] = lump

      if (flags & Info::MF_TRANSLATION) != 0
        raise LevelError, "MF_TRANSLATION (player colour) sprites are not implemented yet"
      end
      if (th.mobj_frame[thing] & Info::FF_FULLBRIGHT) != 0
        @vs_cmap[v] = 0
      else
        index = light_index(xscale)
        @vs_cmap[v] = @scalelight[@spritelights + index]
      end
    end

    # `R_SortVisSprites`: copies vanilla's **selection sort** as it is.
    # A strict `<`, so equal values do not swap (stable). The result is far to near (ascending scale).
    def sort_vissprites
      i = 0
      while i < @vis_n
        @vs_taken[i] = 0
        i += 1
      end
      k = 0
      while k < @vis_n
        best = -1
        bestscale = 0x7fffffff
        i = 0
        while i < @vis_n
          if @vs_taken[i] == 0
            best = i if best < 0
            if @vs_scale[i] < bestscale
              bestscale = @vs_scale[i]
              best = i
            end
          end
          i += 1
        end
        @vs_taken[best] = 1
        @vs_sorted[k] = best
        k += 1
      end
    end

    # `R_DrawMasked`
    def draw_masked
      sort_vissprites
      k = 0
      while k < @vis_n
        draw_sprite(@vs_sorted[k])
        k += 1
      end
      ds = @ds_count - 1
      while ds >= 0
        render_masked_seg_range(ds, @ds_x1[ds], @ds_x2[ds]) if @ds_masked[ds] != 0
        ds -= 1
      end
      @phase = 3
      @jobs.mark_phase3 if @jobmode != 0
      draw_player_sprites
    end

    def clip_value(kind, base, x)
      return @viewheight if kind == CLIP_SCREENHEIGHT
      return -1 if kind == CLIP_NEGONE
      @openings[base + x]
    end

    # `R_DrawSprite`
    def draw_sprite(spr)
      x = @vs_x1[spr]
      while x <= @vs_x2[spr]
        @clipbot[x] = -2
        @cliptop[x] = -2
        x += 1
      end

      ds = @ds_count - 1
      while ds >= 0
        if @ds_x1[ds] > @vs_x2[spr] || @ds_x2[ds] < @vs_x1[spr] ||
           (@ds_silhouette[ds] == 0 && @ds_masked[ds] == 0)
          ds -= 1
          next
        end
        r1 = @ds_x1[ds] < @vs_x1[spr] ? @vs_x1[spr] : @ds_x1[ds]
        r2 = @ds_x2[ds] > @vs_x2[spr] ? @vs_x2[spr] : @ds_x2[ds]
        if @ds_scale1[ds] > @ds_scale2[ds]
          lowscale = @ds_scale2[ds]
          scale = @ds_scale1[ds]
        else
          lowscale = @ds_scale1[ds]
          scale = @ds_scale2[ds]
        end

        if scale < @vs_scale[spr] ||
           (lowscale < @vs_scale[spr] &&
            point_on_seg_side(@vs_gx[spr], @vs_gy[spr], @ds_curline[ds]) == 0)
          render_masked_seg_range(ds, r1, r2) if @ds_masked[ds] != 0
          ds -= 1
          next
        end

        silhouette = @ds_silhouette[ds]
        silhouette &= ~SIL_BOTTOM if @vs_gz[spr] >= @ds_bsilheight[ds]
        silhouette &= ~SIL_TOP if @vs_gzt[spr] <= @ds_tsilheight[ds]

        if silhouette == 1
          x = r1
          while x <= r2
            @clipbot[x] = clip_value(@ds_botkind[ds], @ds_botbase[ds], x) if @clipbot[x] == -2
            x += 1
          end
        elsif silhouette == 2
          x = r1
          while x <= r2
            @cliptop[x] = clip_value(@ds_topkind[ds], @ds_topbase[ds], x) if @cliptop[x] == -2
            x += 1
          end
        elsif silhouette == 3
          x = r1
          while x <= r2
            @clipbot[x] = clip_value(@ds_botkind[ds], @ds_botbase[ds], x) if @clipbot[x] == -2
            @cliptop[x] = clip_value(@ds_topkind[ds], @ds_topbase[ds], x) if @cliptop[x] == -2
            x += 1
          end
        end
        ds -= 1
      end

      x = @vs_x1[spr]
      while x <= @vs_x2[spr]
        @clipbot[x] = @viewheight if @clipbot[x] == -2
        @cliptop[x] = -1 if @cliptop[x] == -2
        x += 1
      end

      # `mfloorclip = clipbot; mceilingclip = cliptop;`: assigned **after the drawseg loop
      # has ended**. Inside the loop `R_RenderMaskedSegRange` points
      # `mfloorclip` at the drawseg's side, so restoring it here is
      # vanilla's order.
      @mclip_mode = MCLIP_SPRITE
      draw_vissprite(spr, true)
    end

    # `R_PointOnSegSide`
    def point_on_seg_side(x, y, seg)
      lv = @level
      lx = lv.vertex_x[lv.seg_v1[seg]]
      ly = lv.vertex_y[lv.seg_v1[seg]]
      ldx = (((lv.vertex_x[lv.seg_v2[seg]] - lx & M32) ^ SGN) - SGN)
      ldy = (((lv.vertex_y[lv.seg_v2[seg]] - ly & M32) ^ SGN) - SGN)
      if ldx == 0
        return x <= lx ? (ldy > 0 ? 1 : 0) : (ldy < 0 ? 1 : 0)
      end
      if ldy == 0
        return y <= ly ? (ldx < 0 ? 1 : 0) : (ldx > 0 ? 1 : 0)
      end
      dx = (((x - lx & M32) ^ SGN) - SGN)
      dy = (((y - ly & M32) ^ SGN) - SGN)
      neg = 0
      neg += 1 if ldy < 0
      neg += 1 if ldx < 0
      neg += 1 if dx < 0
      neg += 1 if dy < 0
      if neg.odd?
        return ((ldy < 0) != (dx < 0)) ? 1 : 0
      end
      left = (((ldy >> 16) * dx >> 16 & M32) ^ SGN) - SGN
      right = ((dy * (ldx >> 16) >> 16 & M32) ^ SGN) - SGN
      right < left ? 0 : 1
    end

    # `R_DrawVisSprite`. If `use_clip` is false, it is a psprite (clipped to the whole screen).
    def draw_vissprite(vis, use_clip)
      patch = @vs_patch[vis]
      l = @sprites.lump_pos(patch)
      lnum = @sprites.lump_num(patch)
      lend = @sprites.lump_end(patch)
      @dc_fuzz = (@vs_mobjflags[vis] & Info::MF_SHADOW) != 0
      @dc_colormap = @vs_cmap[vis]
      iscale = @vs_xiscale[vis]
      @dc_iscale = iscale < 0 ? -iscale : iscale
      @dc_texturemid = @vs_texturemid[vis]
      frac = @vs_startfrac[vis]
      @spryscale = @vs_scale[vis]
      m = ((@dc_texturemid * @spryscale >> 16 & M32) ^ SGN) - SGN
      @sprtopscreen = (((@centeryfrac - m) & M32) ^ SGN) - SGN

      x = @vs_x1[vis]
      while x <= @vs_x2[vis]
        texcol = frac >> 16
        @dc_x = x
        colofs = Bytes.i32(@wad_data, l + 8 + texcol * 4)
        draw_masked_column(lnum, l, lend, l + colofs, use_clip, x)
        frac = (((frac + @vs_xiscale[vis]) & M32) ^ SGN) - SGN
        x += 1
      end
      @dc_fuzz = false
    end

    # `R_DrawMaskedColumn`. `lnum` / `lpos` / `lend` are the number, start and end of the patch
    # lump holding the post, used only **when `dc_source` goes outside the lump**.
    def draw_masked_column(lnum, lpos, lend, p, use_clip, x)
      basetexturemid = @dc_texturemid
      if use_clip
        if @mclip_mode == MCLIP_SPRITE
          floorlim = @clipbot[x]
          ceillim = @cliptop[x]
        else
          # `mfloorclip = ds->sprbottomclip; mceilingclip = ds->sprtopclip`
          floorlim = clip_value(@mclip_botkind, @mclip_botbase, x)
          ceillim = clip_value(@mclip_topkind, @mclip_topbase, x)
        end
      else
        floorlim = @viewheight
        ceillim = -1
      end
      limit = @wad_data.bytesize
      while true
        raise LevelError, "masked column runs past the WAD end" if p + 2 > limit
        td = @wad_data.getbyte(p)
        break if td == 0xff
        len = @wad_data.getbyte(p + 1)
        # `spryscale * topdelta` is a 32-bit multiplication (it can overflow in vanilla).
        m = (((@spryscale * td) & M32) ^ SGN) - SGN
        topscreen = (((@sprtopscreen + m) & M32) ^ SGN) - SGN
        m = (((@spryscale * len) & M32) ^ SGN) - SGN
        bottomscreen = (((topscreen + m) & M32) ^ SGN) - SGN
        yl = (((topscreen + FRACUNIT - 1) & M32) ^ SGN) - SGN
        yl >>= 16
        yh = (((bottomscreen - 1) & M32) ^ SGN) - SGN
        yh >>= 16
        yh = floorlim - 1 if yh >= floorlim
        yl = ceillim + 1 if yl <= ceillim
        if yl <= yh
          @dc_yl = yl
          @dc_yh = yh
          # `R_DrawColumn` always reads `dc_source[(frac>>16) & 127]`, masked with 127,
          # so **up to 128 bytes outside the post are visible**
          # (the first line's `frac` can be slightly negative from rounding, and then the
          # index is 127: a famous vanilla artifact). If 128 bytes remain in the lump they
          # can be read as they are, but **a post near the end crosses a zone block
          # boundary**, so it is remade with `Wad#zone_window`
          # (which reproduces the zone's block layout).
          # The window is reused and consumed by the next synchronous draw.
          # DEMO1 tic 500 to 5026 used it 207,719 times in the pin-update check.
          use_zone_window = false
          if p + 3 + 128 <= lend
            @dc_srcbuf = @wad_data
            @dc_srcofs = p + 3
            # Job IR: points straight into the WAD (not in the atlas).
            @dc_srcres = Jobs::RES_WAD
            @dc_srcbase = p + 3
          elsif @jobmode != 0
            # One reused buffer is not enough: jobs run later, so
            # the window must live until the end of the frame. Take it from the ring.
            zb = @jobs.alloc_zone_window
            @wad.zone_window_into(lnum, p + 3 - lpos, @jobs.zonebuf, zb)
            @dc_srcres = Jobs::RES_ZONE
            @dc_srcbase = zb
          else
            @wad.zone_window(lnum, p + 3 - lpos, @zonewin)
            use_zone_window = true
            @dc_srcofs = 0
          end
          @dc_texturemid = (((basetexturemid - (td << 16)) & M32) ^ SGN) - SGN
          trace_column(3, -1, td) if @trace
          draw_column(use_zone_window)
        end
        p += len + 4
      end
      @dc_texturemid = basetexturemid
    end

    # `R_DrawPlayerSprites`: **there are 2 psprites** (`ps_weapon` and `ps_flash`).
    def draw_player_sprites
      draw_psprite(@psp_state, @psp_sx, @psp_sy)
      draw_psprite(@psp1_state, @psp1_sx, @psp1_sy)
    end

    # `R_DrawPSprite`
    def draw_psprite(pstate, psx, psy)
      return if pstate <= 0
      @psp_state = pstate
      @psp_sx = psx
      @psp_sy = psy
      draw_psprite_body
    end

    def draw_psprite_body
      return if @psp_state < 0
      lv = @level
      ss = lv.point_in_subsector(@viewx, @viewy)
      lightnum = (lv.sector_lightlevel[lv.ss_sector[ss]] >> LIGHTSEGSHIFT) + @extralight
      lightnum = 0 if lightnum < 0
      lightnum = LIGHTLEVELS - 1 if lightnum >= LIGHTLEVELS
      @spritelights = lightnum * MAXLIGHTSCALE

      sp = @sprites
      spr = @state_sprite[@psp_state]
      frame = @state_frame[@psp_state] & Info::FF_FRAMEMASK
      lump = sp.frame_lump(spr, frame, 0)
      flip = sp.frame_flip(spr, frame, 0)

      tx = (((@psp_sx - 160 * FRACUNIT & M32) ^ SGN) - SGN)
      tx = (((tx - sp.spriteoffset(lump) & M32) ^ SGN) - SGN)
      x1 = (((@centerxfrac + (((tx * @pspritescale >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN
      x1 >>= 16
      return if x1 > @viewwidth
      tx = (((tx + sp.spritewidth(lump) & M32) ^ SGN) - SGN)
      x2 = (((@centerxfrac + (((tx * @pspritescale >> 16 & M32) ^ SGN) - SGN)) & M32) ^ SGN) - SGN
      x2 = (x2 >> 16) - 1
      return if x2 < 0

      # A psprite borrows the last vissprite slot (vanilla uses `avis` on the stack).
      v = MAXVISSPRITES - 1
      @vs_mobjflags[v] = 0
      m = (((@psp_sy - sp.spritetopoffset(lump)) & M32) ^ SGN) - SGN
      @vs_texturemid[v] = ((((BASEYCENTER << 16) + FRACUNIT / 2 - m) & M32) ^ SGN) - SGN
      @vs_x1[v] = x1 < 0 ? 0 : x1
      @vs_x2[v] = x2 >= @viewwidth ? @viewwidth - 1 : x2
      @vs_scale[v] = @pspritescale
      if flip != 0
        @vs_xiscale[v] = (((-@pspriteiscale & M32) ^ SGN) - SGN)
        @vs_startfrac[v] = sp.spritewidth(lump) - 1
      else
        @vs_xiscale[v] = @pspriteiscale
        @vs_startfrac[v] = 0
      end
      if @vs_x1[v] > x1
        d = (((@vs_xiscale[v] * (@vs_x1[v] - x1) & M32) ^ SGN) - SGN)
        @vs_startfrac[v] = (((@vs_startfrac[v] + d & M32) ^ SGN) - SGN)
      end
      @vs_patch[v] = lump
      if (@state_frame[@psp_state] & Info::FF_FULLBRIGHT) != 0
        @vs_cmap[v] = 0
      else
        @vs_cmap[v] = @scalelight[@spritelights + MAXLIGHTSCALE - 1]
      end
      draw_vissprite(v, false)
    end

    # `R_RenderMaskedSegRange`
    def render_masked_seg_range(ds, x1, x2)
      lv = @level
      # `mfloorclip = ds->sprbottomclip; mceilingclip = ds->sprtopclip;`
      # This is the gap that was found later. Without it a masked midtexture is cut by
      # **the clipbot/cliptop of the sprite drawn just before**.
      # It never showed in a pixel in E1M5 (DEMO1), but in E1M3 (DEMO2) it split
      # 370 tics / 821 pixels.
      @mclip_mode = MCLIP_DRAWSEG
      @mclip_topkind = @ds_topkind[ds]
      @mclip_topbase = @ds_topbase[ds]
      @mclip_botkind = @ds_botkind[ds]
      @mclip_botbase = @ds_botbase[ds]
      seg = @ds_curline[ds]
      front = lv.seg_frontsector[seg]
      back = lv.seg_backsector[seg]
      texnum = @textures.translate_texture(lv.side_midtexture[lv.seg_sidedef[seg]])

      lightnum = (lv.sector_lightlevel[front] >> LIGHTSEGSHIFT) + @extralight
      if lv.vertex_y[lv.seg_v1[seg]] == lv.vertex_y[lv.seg_v2[seg]]
        lightnum -= 1
      elsif lv.vertex_x[lv.seg_v1[seg]] == lv.vertex_x[lv.seg_v2[seg]]
        lightnum += 1
      end
      lightnum = 0 if lightnum < 0
      lightnum = LIGHTLEVELS - 1 if lightnum >= LIGHTLEVELS
      @walllights = lightnum * MAXLIGHTSCALE

      base = @ds_maskedbase[ds]
      @rw_scalestep = @ds_scalestep[ds]
      @spryscale = (((@ds_scale1[ds] + (x1 - @ds_x1[ds]) * @rw_scalestep & M32) ^ SGN) - SGN)

      if (lv.line_flags[lv.seg_linedef[seg]] & ML_DONTPEGBOTTOM) != 0
        mid = lv.sector_floorheight[front] > lv.sector_floorheight[back] ?
              lv.sector_floorheight[front] : lv.sector_floorheight[back]
        @dc_texturemid = (((mid + @textures.theight(texnum) - @viewz & M32) ^ SGN) - SGN)
      else
        mid = lv.sector_ceilingheight[front] < lv.sector_ceilingheight[back] ?
              lv.sector_ceilingheight[front] : lv.sector_ceilingheight[back]
        @dc_texturemid = (((mid - @viewz & M32) ^ SGN) - SGN)
      end
      @dc_texturemid = (((@dc_texturemid + lv.side_rowoffset[lv.seg_sidedef[seg]] & M32) ^ SGN) - SGN)

      buf = @textures.texdata(texnum)
      x = x1
      while x <= x2
        col = @openings[base + x]
        if col != 0x7fff
          index = light_index(@spryscale)
          @dc_colormap = @scalelight[@walllights + index]
          m = ((@dc_texturemid * @spryscale >> 16 & M32) ^ SGN) - SGN
          @sprtopscreen = (((@centeryfrac - m) & M32) ^ SGN) - SGN
          @dc_iscale = M32 / (@spryscale & M32)
          @dc_x = x
          # The composite buffer has no post headers, so the form "reread as a post",
          # `R_GetColumn(...) - 3`, cannot be used. A masked midtexture is a single-patch
          # texture with transparency, so **the original patch lump's posts are walked directly**.
          draw_masked_texture_column(texnum, col, x)
          @openings[base + x] = 0x7fff
        end
        @spryscale = (((@spryscale + @rw_scalestep & M32) ^ SGN) - SGN)
        x += 1
      end
    end

    # One column of a masked midtexture. Vanilla moves `R_GetColumn`'s return back 3 bytes
    # and reads it as a post structure, so **it assumes a single-patch column**
    # (a column that needs composing would put pixels where the post header is and break; a known vanilla limit).
    # The same assumption here: walk the patch lump's posts.
    def draw_masked_texture_column(tex, col, x)
      c = col & @textures.widthmask(tex)
      lp = @textures.collump(tex, c)
      if lp < 0
        raise LevelError,
              "masked midtexture #{tex} column #{c} needs compositing — vanilla cannot draw this"
      end
      ll = @wad.lump(lp)
      l = ll.pos
      draw_masked_column(lp, l, l + ll.size,
                         l + @textures.colofs(tex, c) - 3, true, x)
    end
  end
end
