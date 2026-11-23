# doom/lib/doom/texture.rb
#
# Composing wall textures (`R_InitTextures` / `R_GenerateLookup` / `R_GenerateComposite` /
# `R_GetColumn` in `r_data.c`) and taking out flats.
#
# **The heart of vanilla is "a column covered by only one patch is not composed".**
# What `R_GetColumn` returns is
#
#   - a single-patch column -> **the start of the pixel array of a post inside the patch lump**
#     (`columnofs[x-x1] + 3`). Even if the post is shorter than the column, vanilla does not
#     care and reads on into the lump's following bytes.
#   - a multi-patch column -> a raw pixel column of `height` bytes inside the composite buffer.
#
# Ruby **materializes each texture as a column-major width x height String**, and a
# single-patch column **copies `height` bytes as they are** from the WAD's offset.
# That way `R_GetColumn` becomes **one buffer and `col * height`** rather than the 2 values
# (buffer, offset), and branches and allocation vanish from the drawing loop.
# The values are exactly vanilla's: a gate checks they match the reference side's
# `texcolumns.bin` (`height` bytes taken from each R_GetColumn return) byte for byte.
#
# `texturewidthmask` **is smaller than the width for widths that are not powers of 2** (width=24 -> mask=15).
# `R_GetColumn`'s `col &= mask` is visible vanilla behaviour, so reproducing it is required.
#
# Generation is **lazy** (as in vanilla). The composite depends only on its inputs, so it does
# not affect determinism. A texture first touched inside the frame loop is made there, but
# from the second frame on nothing is allocated (an instrument checks this).

require_relative "errors"
require_relative "bytes"

module Doom
  class Textures
    FRACBITS = 16

    # `R_DrawColumn` / `R_DrawFuzzColumn` / `R_DrawMaskedColumn` read
    # `dc_source[(frac>>16) & 127]`, **always masked with 127**.
    # So 128 bytes per column are visible, and the materialized window is aligned
    # to 128 too (not to the height). What shows outside the column for textures shorter
    # than 128 was the main cause of DEMO1's frame differences.
    TEXCOL_STRIDE = 128

    attr_reader :numtextures, :numflats, :firstflat, :numpatches, :short_columns, :marker_flats

    def initialize(wad, texnames)
      @wad = wad
      @data = wad.data
      @names = texnames
      @numtextures = 0

      load_pnames(wad)
      @tex_name = []
      @tex_width = []
      @tex_height = []
      @tex_patchcount = []
      @tex_patchbase = []
      @tex_widthmask = []
      @tex_theight = []
      @tex_compositesize = []
      @patch_originx = []
      @patch_originy = []
      @patch_lump = []
      @col_base = []
      @collump = []
      @colofs = []

      add_texture_lump(wad, "TEXTURE1")
      add_texture_lump(wad, "TEXTURE2") if wad.index_of("TEXTURE2") >= 0

      i = 0
      while i < @numtextures
        generate_lookup(i)
        i += 1
      end

      # The materialized texture bodies (an empty String = not made yet).
      @texdata = Array.new(@numtextures, "")

      # flats: firstflat..lastflat of `R_InitFlats`. Numbers are 0-based.
      @firstflat = wad.num_for_name("F_START") + 1
      @numflats = wad.num_for_name("F_END") - @firstflat
      @flatdata = Array.new(@numflats, "")
      @short_columns = 0
      @marker_flats = 0
      # ---- atlases ------------------------------------------------------------------
      # A Job IR job holds **one offset inside one resource**, not the 2 values
      # "buffer + offset" (only one buffer can be passed to the GPU). The texture column
      # atlas = every texture's 128B windows laid out in order; the
      # flat atlas = every flat's 4096B plane laid out in order.
      # **The contents are a reordering, not a remake.**
      # **The atlases are allocated only once, here.** With 2 assignment sites,
      # Spinel lowers that String ivar to a handle representation (`sp_String*`)
      # and emits a COW loop copying the whole thing twice per `setbyte`
      # (useless for a 1.38 MB atlas; moreover `sp_str_concat` cuts at NUL,
      # so **bytesize becomes 0** and it fails with `index 0 out of string`).
      # The contents are packed by `precache_all` -> `fill_atlas`.
      @tex_atlas_base = Array.new(@numtextures, 0)
      n = 0
      t = 0
      while t < @numtextures
        @tex_atlas_base[t] = n
        n += @tex_width[t] * TEXCOL_STRIDE
        t += 1
      end
      @tex_atlas_size = n
      @tex_atlas = Bytes.buffer(n, 0)
      @flat_atlas_size = @numflats * 4096
      @flat_atlas = Bytes.buffer(@flat_atlas_size, 0)
      # The receiver for `Wad#zone_window` (reused; used only inside generate_texture).
      @win = Bytes.buffer(TEXCOL_STRIDE, 0)
      init_pic_anims
    end

    # ---- animated flats / textures --------------------------------------------------
    #
    # `P_InitPicAnims` (`p_spec.c`) builds `anims[]` by checking, for each row of
    # `animdefs[]`, "are the start and end names in the WAD", and
    # `P_UpdateSpecials` rewrites `flattranslation[]` / `texturetranslation[]` every tic.
    # Before tics ran the **identity mapping** was enough, but
    # DEMO1's E1M5 has NUKAGE (7 sectors with special 7), so
    # **the floor's picture changes every 8 tics**. Required for frames to match.
    ANIMDEFS = [
      # [istexture, endname, startname, speed]
      [0, "NUKAGE3", "NUKAGE1", 8],
      [0, "FWATER4", "FWATER1", 8],
      [0, "SWATER4", "SWATER1", 8],
      [0, "LAVA4", "LAVA1", 8],
      [0, "BLOOD3", "BLOOD1", 8],
      [0, "RROCK08", "RROCK05", 8],
      [0, "SLIME04", "SLIME01", 8],
      [0, "SLIME08", "SLIME05", 8],
      [0, "SLIME12", "SLIME09", 8],
      [1, "BLODGR4", "BLODGR1", 8],
      [1, "SLADRIP3", "SLADRIP1", 8],
      [1, "BLODRIP4", "BLODRIP1", 8],
      [1, "FIREWALL", "FIREWALA", 8],
      [1, "GSTFONT3", "GSTFONT1", 8],
      [1, "FIRELAVA", "FIRELAV3", 8],
      [1, "FIREMAG3", "FIREMAG1", 8],
      [1, "FIREBLU2", "FIREBLU1", 8],
      [1, "ROCKRED3", "ROCKRED1", 8],
      [1, "BFALL4", "BFALL1", 8],
      [1, "SFALL4", "SFALL1", 8],
      [1, "WFALL4", "WFALL1", 8],
      [1, "DBRAIN4", "DBRAIN1", 8]
    ].freeze

    def init_pic_anims
      @texturetranslation = Array.new(@numtextures, 0)
      i = 0
      while i < @numtextures
        @texturetranslation[i] = i
        i += 1
      end
      @flattranslation = Array.new(@numflats, 0)
      i = 0
      while i < @numflats
        @flattranslation[i] = i
        i += 1
      end
      @anim_istexture = []
      @anim_basepic = []
      @anim_numpics = []
      @anim_speed = []
      @num_anims = 0
      i = 0
      while i < ANIMDEFS.length
        row = ANIMDEFS[i]
        i += 1
        # `animdef_t` is in the order `{istexture, endname, startname, speed}`
        # (`p_spec.c`). **The end is written first.** Reversed, numpics goes
        # negative and it fails (this is where it first failed).
        if row[0] == 1
          next if @names.texture_num_or_none(row[2]) < 0
          picnum = @names.texture_num(row[1])
          basepic = @names.texture_num(row[2])
        else
          next if @wad.index_of(row[2]) < 0
          picnum = @names.flat_num(row[1])
          basepic = @names.flat_num(row[2])
        end
        n = picnum - basepic + 1
        raise LevelError, "bad anim cycle #{row[1]}..#{row[2]} (#{n})" if n < 2
        @anim_istexture[@num_anims] = row[0]
        @anim_basepic[@num_anims] = basepic
        @anim_numpics[@num_anims] = n
        @anim_speed[@num_anims] = row[3]
        @num_anims += 1
      end
    end

    # The animation part of `P_UpdateSpecials`.
    def animate(leveltime)
      a = 0
      while a < @num_anims
        base = @anim_basepic[a]
        n = @anim_numpics[a]
        sp = @anim_speed[a]
        i = base
        while i < base + n
          pic = base + ((leveltime / sp + i) % n)
          if @anim_istexture[a] == 1
            @texturetranslation[i] = pic
          else
            @flattranslation[i] = pic
          end
          i += 1
        end
        a += 1
      end
    end

    # `texturetranslation[t]`. Applied where the renderer decides a wall texture number.
    def translate_texture(t)
      @texturetranslation[t]
    end

    def texture_width(t)
      @tex_width[t]
    end

    def texture_height(t)
      @tex_height[t]
    end

    def texture_name(t)
      @tex_name[t]
    end

    def texture_patchcount(t)
      @tex_patchcount[t]
    end

    def widthmask(t)
      @tex_widthmask[t]
    end

    # `textureheight[]` = height << FRACBITS (used for `R_StoreWallRange`'s pegging)
    def theight(t)
      @tex_theight[t]
    end

    def compositesize(t)
      @tex_compositesize[t]
    end

    def patch_origin_x(t, k)
      @patch_originx[@tex_patchbase[t] + k]
    end

    def patch_origin_y(t, k)
      @patch_originy[@tex_patchbase[t] + k]
    end

    def patch_lumpnum(t, k)
      @patch_lump[@tex_patchbase[t] + k]
    end

    def collump(t, x)
      @collump[@col_base[t] + x]
    end

    def colofs(t, x)
      @colofs[@col_base[t] + x]
    end

    # The materialized version of `R_GetColumn`. It returns **one buffer**, and a column starts
    # at `column_offset(t, col)`. The caller looks the two up separately (no allocation).
    def column_buffer(t)
      s = @texdata[t]
      return s if s.bytesize > 0
      s = generate_texture(t)
      @texdata[t] = s
      s
    end

    # ---- materializing ahead, and accessors that "do not generate" ----------------
    #
    # `column_buffer` / `flat` **generate lazily**. At run time it settles within a few dozen
    # tics after the level starts (47 on DEMO1), but **statically the edge from the frame loop
    # to `generate_texture` does not vanish**, so the `realtime_def` checker
    # (tools/realtime/spinel-rtcheck) refuses it.
    # "Happens not to run" is not a proof.
    #
    # So an equivalent of `R_PrecacheLevel` is provided, and the frame loop calls only
    # **accessors without a generation branch** (`texdata` / `flatdata`). That way
    # lazy generation vanishes from the call graph **structurally**.
    # The same bytes are made in the same order (the `@next_lump` that `zone_window` looks at
    # depends only on the WAD directory, not on the order of materialization).
    def precache_all
      t = 0
      while t < @numtextures
        column_buffer(t)
        t += 1
      end
      p = 0
      while p < @numflats
        materialize_flat(p)
        p += 1
      end
      fill_atlas
    end

    # ---- building the atlases one at a time --------------------------------------
    #
    # **It only reorders the contents of `texdata` / `flatdata` as they are.**
    # It makes not one byte and drops not one byte: the atlas's
    # `atlas_base(t) + k` equals byte `k` of `texdata(t)`
    # (a gate checks all 1 274 944 B every time).
    #
    # This is also where a counterexample to an earlier forecast came from.
    # "Bytes from the zone that cannot be reached are not in the atlas": they are.
    # `generate_texture` has **already materialized them** with `Wad#zone_window`,
    # and the atlas only reorders that.
    # **Do not use `@texdata[t].bytesize`** (the same family of compiler defect).
    # `@texdata` is a poly array mixing the frozen literals of `Array.new(n, "")` with
    # Strings from `Bytes.buffer`, and calling `bytesize` on it makes Spinel
    # **compile it and then return a poly Integer**. Passing that value to
    # `Array.new(n, 0)` gives **an empty Array, quietly**, and
    # `Bytes.buffer` returns `""` (printed with `#{n}` the right value shows, so
    # it is hard to notice). A column's length can be computed as `@tex_width[t] * TEXCOL_STRIDE`:
    # `generate_texture` makes it that way, so there is no need to ask the String its length.
    # **Writing into the atlas is done by "a method that takes the destination as an argument".**
    # Writing to a local taken through the ivar, as in `a = @tex_atlas; a.setbyte(...)`,
    # makes Spinel lower that String ivar to **a handle representation (`sp_String*`)**.
    # Each `setbyte` on a handle becomes
    #
    #   sp_str_concat(sp_String_cstr(h), "")  -> copies the whole thing
    #   sp_str_setbyte_cow(...)               -> copies it once more
    #   sp_String_set_bin(h, ...)             -> writes it back
    #
    # so for a 1.38 MB atlas every byte written copies 2.7 MB.
    # Moreover `sp_str_concat` cuts at NUL, so **bytesize becomes 0**, and
    # the next `setbyte(0, ...)` fails with `index 0 out of string`.
    # **Passing the destination as an argument**, as `Wad#zone_window(lp, cofs, @win)` does,
    # keeps it a `const char*` with a plain `setbyte`.
    def fill_atlas
      t = 0
      while t < @numtextures
        copy_bytes(@tex_atlas, @tex_atlas_base[t], @texdata[t],
                   @tex_width[t] * TEXCOL_STRIDE)
        t += 1
      end
      p = 0
      while p < @numflats
        copy_bytes(@flat_atlas, p * 4096, @flatdata[p], 4096)
        p += 1
      end
    end

    # Gate: checks on every byte (1 379 328 B) **that the atlas is only a reordering of
    # `texdata`**. Returns the number of bytes that disagree (0 expected).
    # As long as it is 0, the bytes the Job IR route reads are the bytes the old route reads:
    # even the bytes from the zone that were sealed earlier are **in the atlas as they are**
    # (an earlier forecast is refuted here).
    def atlas_check
      bad = 0
      t = 0
      while t < @numtextures
        s = @texdata[t]
        b = @tex_atlas_base[t]
        m = @tex_width[t] * TEXCOL_STRIDE
        i = 0
        while i < m
          bad += 1 if @tex_atlas.getbyte(b + i) != s.getbyte(i)
          i += 1
        end
        t += 1
      end
      p = 0
      while p < @numflats
        s = @flatdata[p]
        b = p * 4096
        i = 0
        while i < 4096
          bad += 1 if @flat_atlas.getbyte(b + i) != s.getbyte(i)
          i += 1
        end
        p += 1
      end
      bad
    end

    def copy_bytes(dst, dstofs, src, n)
      i = 0
      while i < n
        dst.setbyte(dstofs + i, src.getbyte(i))
        i += 1
      end
    end

    def tex_atlas
      @tex_atlas
    end

    def tex_atlas_size
      @tex_atlas_size
    end

    # At which byte of the atlas texture `t`'s column 0 starts.
    # Column `col`'s window starts at `atlas_base(t) + ((col & widthmask(t)) << 7)`, and
    # is **always a multiple of 128** (check #2 looks at this).
    def atlas_base(t)
      @tex_atlas_base[t]
    end

    def flat_atlas
      @flat_atlas
    end

    def flat_atlas_size
      @flat_atlas_size
    end

    # **Goes through the translation**, like `flatdata` (there are animated flats).
    def flat_atlas_base(picnum)
      @flattranslation[picnum] * 4096
    end

    # An accessor that does not generate. **Correct only after precache_all.**
    def texdata(t)
      @texdata[t]
    end

    def flatdata(picnum)
      @flatdata[@flattranslation[picnum]]
    end

    # The spacing between columns is **fixed at 128, not the texture's height** (`TEXCOL_STRIDE`).
    # `R_DrawColumn` always reads `dc_source[(frac>>16) & 127]`, masked with 127, so for
    # textures shorter than 128 up to 128 bytes outside the column are **visible**.
    # What shows there in vanilla depends on where the column came from:
    # for a single-patch column, the rest of the patch lump; for a multi-patch column,
    # **the next multi-patch column** of `texturecomposite`. Both are materialized into the
    # 128-byte window, so indexes 0..127 can be looked up as they are.
    def column_offset(t, col)
      (col & @tex_widthmask[t]) * TEXCOL_STRIDE
    end

    # flat number -> a 4096-byte plane of raw palette indexes.
    def flat(picnum)
      materialize_flat(@flattranslation[picnum])
    end

    # The body of `flat`'s materialization. The argument is the **already translated** flat number.
    def materialize_flat(picnum)
      s = @flatdata[picnum]
      return s if s.bytesize > 0
      l = @wad.lump(@firstflat + picnum)
      # F_START..F_END includes the 0-byte markers F1_START / F1_END, and
      # vanilla gives them flat numbers too (measured: numbers 0 and 55).
      # They have no contents, so they are treated as 4096 zero bytes (the reference side agrees).
      if l.size == 4096
        s = @data.byteslice(l.pos, 4096)
      else
        @marker_flats += 1
        s = Bytes.buffer(4096, 0)
      end
      @flatdata[picnum] = s
      s
    end

    def flat_name(picnum)
      @wad.lump(@firstflat + picnum).name
    end

    private

    # PNAMES: int32 nummappatches / char[8] x n. Names are resolved to lump numbers.
    # Those that cannot be resolved may stay -1 (they fail only when referenced).
    def load_pnames(wad)
      data = wad.bytes_by_name("PNAMES")
      raise LevelError, "PNAMES: too small (#{data.bytesize} bytes)" if data.bytesize < 4
      n = Bytes.i32(data, 0)
      raise LevelError, "PNAMES: bad nummappatches #{n}" if n < 0
      need = 4 + n * 8
      if data.bytesize < need
        raise LevelError, "PNAMES: truncated (#{data.bytesize} < #{need})"
      end
      @numpatches = n
      @patchlookup = Array.new(n, -1)
      i = 0
      while i < n
        @patchlookup[i] = wad.index_of(Bytes.name8_upper(data, 4 + i * 8))
        i += 1
      end
    end

    def add_texture_lump(wad, lumpname)
      data = wad.bytes_by_name(lumpname)
      n = Bytes.i32(data, 0)
      i = 0
      while i < n
        off = Bytes.i32(data, 4 + i * 4)
        if off < 0 || off + 22 > data.bytesize
          raise LevelError, "#{lumpname}: texture #{i} offset #{off} out of range"
        end
        t = @numtextures
        @tex_name[t] = Bytes.name8(data, off)
        w = Bytes.i16(data, off + 12)
        h = Bytes.i16(data, off + 14)
        pc = Bytes.i16(data, off + 20)
        if w <= 0 || h <= 0 || pc <= 0
          raise LevelError, "#{lumpname}: texture #{i} (#{@tex_name[t]}) has width=#{w} height=#{h} patchcount=#{pc}"
        end
        if off + 22 + pc * 10 > data.bytesize
          raise LevelError, "#{lumpname}: texture #{i} patch list runs past the lump end"
        end
        @tex_width[t] = w
        @tex_height[t] = h
        @tex_patchcount[t] = pc
        @tex_theight[t] = h << FRACBITS
        j = 1
        j <<= 1 while j * 2 <= w
        @tex_widthmask[t] = j - 1
        @tex_patchbase[t] = @patch_lump.length
        k = 0
        while k < pc
          o = off + 22 + k * 10
          @patch_originx << Bytes.i16(data, o)
          @patch_originy << Bytes.i16(data, o + 2)
          p = Bytes.i16(data, o + 4)
          if p < 0 || p >= @numpatches || @patchlookup[p] < 0
            raise LevelError,
                  "#{lumpname}: texture #{@tex_name[t]} patch #{k} references PNAMES entry #{p} which does not resolve"
          end
          @patch_lump << @patchlookup[p]
          k += 1
        end
        @numtextures += 1
        i += 1
      end
    end

    # `R_GenerateLookup`. `colofs` is `unsigned short` in C, so it wraps at 16 bits.
    def generate_lookup(t)
      w = @tex_width[t]
      h = @tex_height[t]
      base = @collump.length
      @col_base[t] = base
      counts = Array.new(w, 0)
      x = 0
      while x < w
        @collump << 0
        @colofs << 0
        x += 1
      end

      pc = @tex_patchcount[t]
      k = 0
      while k < pc
        pl = @patch_lump[@tex_patchbase[t] + k]
        ox = @patch_originx[@tex_patchbase[t] + k]
        lp = @wad.lump(pl).pos
        pw = Bytes.i16(@data, lp)
        x1 = ox
        x2 = x1 + pw
        x = x1 < 0 ? 0 : x1
        x2 = w if x2 > w
        while x < x2
          counts[x] += 1
          @collump[base + x] = pl
          @colofs[base + x] = (Bytes.i32(@data, lp + 8 + (x - x1) * 4) + 3) & 0xffff
          x += 1
        end
        k += 1
      end

      size = 0
      x = 0
      while x < w
        if counts[x] == 0
          # Vanilla printfs and returns (a texture with holes). This port
          # fails; a gate checks the shareware IWAD has none.
          raise LevelError, "texture #{@tex_name[t]}: column #{x} has no patch"
        end
        if counts[x] > 1
          @collump[base + x] = -1
          @colofs[base + x] = size
          raise LevelError, "texture #{@tex_name[t]} is >64k" if size > 0x10000 - h
          size += h
        end
        x += 1
      end
      @tex_compositesize[t] = size
    end

    # Materializes, per column, the 128-byte window `R_GetColumn` returns.
    #
    # Vanilla **returns different memory depending on where the column came from** (`R_GetColumn` in `r_data.c`):
    #
    #   a single-patch column (`collump > 0`) -> `W_CacheLumpNum(lump) + colofs`
    #       = the patch lump's own bytes. Reading past the column's height shows
    #         **the rest of the same lump** (the next post's header or the next column's data).
    #   a multi-patch column (`collump < 0`) -> `texturecomposite[tex] + colofs`
    #       = the composite buffer. **Only multi-patch columns** are packed in x order
    #         (`R_GenerateLookup`'s `size += h` happens only when `counts[x] > 1`).
    #         Reading past the column's height shows **the start of the next multi-patch column**.
    #
    # Earlier these 2 were mixed into one `w x h` buffer when materialized, and
    # outside the column was filled with 0. `R_DrawColumn`'s `& 127` **always goes outside
    # the column** for textures shorter than 128, so this makes a visible difference
    # (most of the 365 differing tics in DEMO1).
    def generate_texture(t)
      w = @tex_width[t]
      h = @tex_height[t]
      base = @col_base[t]

      # 1. Make `texturecomposite` in the same layout as vanilla
      #    (only the multi-patch columns, packed in `colofs` order).
      csize = @tex_compositesize[t]
      comp = Bytes.buffer(csize + 1, 0)
      pc = @tex_patchcount[t]
      k = 0
      while k < pc
        pl = @patch_lump[@tex_patchbase[t] + k]
        ox = @patch_originx[@tex_patchbase[t] + k]
        oy = @patch_originy[@tex_patchbase[t] + k]
        l = @wad.lump(pl)
        lp = l.pos
        pw = Bytes.i16(@data, lp)
        x1 = ox
        x2 = x1 + pw
        x = x1 < 0 ? 0 : x1
        x2 = w if x2 > w
        while x < x2
          if @collump[base + x] < 0
            draw_column_in_cache(lp + Bytes.i32(@data, lp + 8 + (x - x1) * 4),
                                 comp, @colofs[base + x], oy, h, lp + l.size)
          end
          x += 1
        end
        k += 1
      end

      # 2. Cut a 128-byte window per column. Indexes 0..127 equal
      #    `R_GetColumn(t, x)[i]` byte for byte.
      out = Bytes.buffer(w * TEXCOL_STRIDE, 0)
      x = 0
      while x < w
        o = x * TEXCOL_STRIDE
        lp = @collump[base + x]
        if lp >= 0
          l = @wad.lump(lp)
          cofs = @colofs[base + x]
          # Vanilla sometimes reads outside the lump here: when the column is near the
          # lump's end and the 128-byte window runs past the lump. What `R_GetColumn`
          # returns is the copy `W_CacheLumpNum` took into the zone, so past it
          # **the next zone block** is visible. `Wad#zone_window` reproduces that layout.
          # Columns **whose lump did not even hold the column's height** are
          # counted in `short_columns`.
          @short_columns += 1 if l.size - cofs < h
          @wad.zone_window(lp, cofs, @win)
          i = 0
          while i < TEXCOL_STRIDE
            out.setbyte(o + i, @win.getbyte(i))
            i += 1
          end
        else
          cofs = @colofs[base + x]
          avail = csize - cofs
          avail = 0 if avail < 0
          n = avail < TEXCOL_STRIDE ? avail : TEXCOL_STRIDE
          i = 0
          while i < n
            out.setbyte(o + i, comp.getbyte(cofs + i))
            i += 1
          end
        end
        x += 1
      end
      out
    end

    # `R_DrawColumnInCache`. **When `position < 0`, `source` does not advance**:
    # this vanilla behaviour looks like a bug but is visible, so it is copied (`count` bytes
    # from the post's start are written to `cache[0]`).
    def draw_column_in_cache(p, out, cbase, originy, cacheheight, limit)
      while p < limit
        td = @data.getbyte(p)
        break if td == 0xff
        len = @data.getbyte(p + 1)
        count = len
        position = originy + td
        if position < 0
          count += position
          position = 0
        end
        count = cacheheight - position if position + count > cacheheight
        if count > 0
          src = p + 3
          i = 0
          while i < count
            out.setbyte(cbase + position + i, @data.getbyte(src + i))
            i += 1
          end
        end
        p += len + 4
      end
    end
  end
end
