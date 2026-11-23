# doom/lib/doom/wad.rb
#
# The WAD reader.
#
#   header 12 B     : identification[4] / numlumps int32 LE / infotableofs int32 LE
#   directory 16 B  : filepos int32 LE / size int32 LE / name char[8] (NUL padding)
#
# 3 design points:
#
# 1. **The whole WAD is read into one String.** 4 MB allocated once with `File.binread`;
#    lumps are taken out with `byteslice`, and numbers read directly with `getbyte`.
#    No `unpack` (see the top of Doom::Bytes).
# 2. **For a repeated name the last wins.** Vanilla's `W_CheckNumForName` scans the directory
#    from the end to the start. **Assigning into a Hash from the start** means the same.
# 3. **All checking is done here.** The header, the directory and each lump's range are
#    checked at construction, and anything broken fails with `Doom::WadError`. This prevents,
#    structurally, "it read, and then somehow the picture breaks".

require_relative "errors"
require_relative "bytes"

module Doom
  # One directory entry.
  class Lump
    attr_reader :index, :name, :pos, :size

    def initialize(index, name, pos, size)
      @index = index
      @name = name
      @pos = pos
      @size = size
    end

    # A lump of size 0 is a namespace marker (`S_START` / `F_END` and the like).
    # filepos means nothing.
    def marker?
      @size == 0
    end
  end

  class Wad
    HEADER_SIZE = 12
    DIRENT_SIZE = 16

    attr_reader :magic, :lumps

    def initialize(path)
      @path = path
      @data = File.binread(path)
      @lumps = []
      @index = {}
      parse_header
      parse_directory
    end

    def bytesize
      @data.bytesize
    end

    def count
      @lumps.length
    end

    def lump(i)
      raise WadError, "lump index out of range: #{i} (numlumps=#{@lumps.length})" if i < 0 || i >= @lumps.length
      @lumps[i]
    end

    # Vanilla's `W_CheckNumForName`: -1 if not found. The last wins.
    def index_of(name)
      @index.key?(name) ? @index[name] : -1
    end

    # Vanilla's `W_GetNumForName`: fails if not found.
    def num_for_name(name)
      i = index_of(name)
      raise WadError, "lump not found: #{name}" if i < 0
      i
    end

    def bytes(i)
      l = lump(i)
      @data.byteslice(l.pos, l.size)
    end

    def bytes_by_name(name)
      bytes(num_for_name(name))
    end

    # Takes only the hash without touching the lump's bytes (makes no byteslice).
    # Returns a 16-digit hex string (see the FNV section of Bytes).
    def fnv1a64_hex(i)
      l = lump(i)
      Bytes.fnv1a64_hex_range(@data, l.pos, l.size)
    end

    # A level's lumps follow the map marker in a fixed order.
    # They are looked up relative to the marker, not by name.
    def map_lump(mapname, sub)
      base = index_of(mapname)
      return -1 if base < 0
      j = base + 1
      last = base + 10
      last = @lumps.length - 1 if last > @lumps.length - 1
      while j <= last
        return j if @lumps[j].name == sub
        j += 1
      end
      -1
    end

    # The raw buffer (the whole WAD): passed to Picture.decode to read offsets directly.
    def data
      @data
    end

    # ------------------------------------------------------------------
    # Reproduces **the 128 bytes beyond** the pointer `W_CacheLumpNum` returns
    # ------------------------------------------------------------------
    #
    # `R_DrawColumn` / `R_DrawMaskedColumn` always read `dc_source[(frac>>16) & 127]`,
    # masked with 127, so **a post near the end of a lump reads outside its column**.
    # Vanilla's `dc_source` is not the WAD's bytes themselves but **a copy inside the zone**
    # that `W_CacheLumpNum` got with `Z_Malloc`, so past the lump the next zone block
    # is visible. Measured on the pinned doomgeneric `dcb7a8db` / arm64 build
    # (the evidence was a recorded dump of the zone headers),
    # what is there is
    #
    #   [the lump's contents, size bytes]
    #   [zero padding to MEM_ALIGN = sizeof(void*) = 8]
    #   [memblock_t, 40 bytes: size / (4 bytes of padding) / user / tag / id / next / prev]
    #   [the contents of **the next lump in WAD directory order**]
    #
    # where `size` is the next block's total bytes `((size+7)&~7) + 40`, `tag` is
    # `PU_CACHE = 8` and `id` is `ZONEID = 0x1d4a11` (all 20 observed cases agree).
    # **`user` / `next` / `prev` are pointers and change from run to run**, so they are
    # 0 here. DEMO1's 5 024 frames never read them (if they were read, L6 would split,
    # so it would not pass quietly).
    #
    # **This is not a specification but a reproduction of the reference implementation's undefined behaviour.**
    ZONE_HEADER = 40           # sizeof(memblock_t) (arm64)
    ZONE_ALIGN = 8             # MEM_ALIGN = sizeof(void *)
    ZONE_TAG_CACHE = 8         # PU_CACHE
    ZONE_ID = 0x1d4a11         # ZONEID

    # `out` is a reused 128-byte buffer (the caller owns it, so no allocation happens).
    def zone_window(lumpnum, off, out)
      zone_window_into(lumpnum, off, out, 0)
    end

    # The Job IR route takes zone windows into a **ring** (jobs run later, so
    # one reused buffer is not enough). `base` is the offset in the ring.
    def zone_window_into(lumpnum, off, out, base)
      ln = lumpnum
      a = off
      i = 0
      while i < 128
        l = @lumps[ln]
        if a < l.size
          out.setbyte(base + i, @data.getbyte(l.pos + a))
          i += 1
          a += 1
        else
          j = a - l.size
          pad = (((l.size + 7) >> 3) << 3) - l.size
          if j < pad + ZONE_HEADER
            out.setbyte(base + i, j < pad ? 0 : zone_header_byte(ln, j - pad))
            i += 1
            a += 1
          else
            nx = @next_lump[ln]
            if nx < 0
              out.setbyte(base + i, 0)
              i += 1
              a += 1
            else
              ln = nx
              a = j - pad - ZONE_HEADER
            end
          end
        end
      end
    end

    # Byte `k` of the `memblock_t` placed right after lump `ln`.
    # That header describes **the next block**.
    def zone_header_byte(ln, k)
      nx = @next_lump[ln]
      return 0 if nx < 0
      if k < 4
        sz = (((@lumps[nx].size + 7) >> 3) << 3) + ZONE_HEADER
        (sz >> (k << 3)) & 0xff
      elsif k >= 16 && k < 20
        k == 16 ? ZONE_TAG_CACHE : 0
      elsif k >= 20 && k < 24
        (ZONE_ID >> ((k - 20) << 3)) & 0xff
      else
        0                      # user / next / prev are pointers (cannot be reproduced)
      end
    end

    private

    def parse_header
      if @data.bytesize < HEADER_SIZE
        raise WadError, "truncated WAD header: #{@data.bytesize} bytes (need #{HEADER_SIZE})"
      end
      m = @data.byteslice(0, 4)
      unless m == "IWAD" || m == "PWAD"
        raise WadError, "not a WAD: identification=#{m.inspect}"
      end
      @magic = m
      @numlumps = Bytes.i32(@data, 4)
      @infotableofs = Bytes.i32(@data, 8)
      raise WadError, "negative numlumps: #{@numlumps}" if @numlumps < 0
      raise WadError, "directory offset before header: infotableofs=#{@infotableofs}" if @infotableofs < HEADER_SIZE
      dir_end = @infotableofs + @numlumps * DIRENT_SIZE
      if dir_end > @data.bytesize
        raise WadError,
              "truncated directory: infotableofs=#{@infotableofs} numlumps=#{@numlumps} " \
              "needs #{dir_end} bytes but file is #{@data.bytesize}"
      end
    end

    def parse_directory
      i = 0
      while i < @numlumps
        e = @infotableofs + i * DIRENT_SIZE
        pos = Bytes.i32(@data, e)
        size = Bytes.i32(@data, e + 4)
        name = Bytes.name8(@data, e + 8)
        raise WadError, "lump #{i} (#{name}): negative size #{size}" if size < 0
        if size > 0
          raise WadError, "lump #{i} (#{name}): negative filepos #{pos}" if pos < 0
          if pos + size > @data.bytesize
            raise WadError,
                  "lump #{i} (#{name}): extends past EOF (filepos=#{pos} size=#{size} " \
                  "file=#{@data.bytesize})"
          end
        end
        l = Lump.new(i, name, pos, size)
        @lumps << l
        @index[name] = i     # assigned from the start = the last wins (as in vanilla)
        i += 1
      end
      build_next_lump
    end

    # For `zone_window`: for each lump, **the lump placed next in the zone** (= the next lump
    # with contents in directory order). Namespace markers (size 0) are not `Z_Malloc`ed, so they are skipped.
    def build_next_lump
      n = @lumps.length
      @next_lump = Array.new(n, -1)
      nx = -1
      i = n - 1
      while i >= 0
        @next_lump[i] = nx
        nx = i if @lumps[i].size > 0
        i -= 1
      end
    end
  end
end
