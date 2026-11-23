# frozen_string_literal: true
#
# tests/doom-core/source-edges.rb — the compiled source entries at every buffer's edge.
#
#   ruby tests/doom-core/source-edges.rb cases OUT     the cases, for edges.c
#   ruby tests/doom-core/source-edges.rb expected OUT  what edges.c must print
#   ruby tests/doom-core/source-edges.rb liar OUT      the AddressSanitizer control
#   ruby tests/doom-core/source-edges.rb liar-exec OUT the same control, in the executor
#   ruby tests/doom-core/source-edges.rb liar-push OUT and a WRITE past, in the wall push
#   ruby tests/doom-core/source-edges.rb divergence OUT  what CRuby does where CORE is ARITHMETIC
#
# docs/core/doom-source-alias.md asks for the last valid and the first invalid
# index of each resource. A CORE entry checks every load and store against the
# count its caller declared, and an index outside is SPINEL_CORE_BOUNDS (3) --
# with nothing stored by the failing access, the result word not written, and
# (0007's ABI: no rollback) whatever an EARLIER access in the same call wrote
# left in place. So every buffer face of every entry gets a PAIR: the case that
# reaches the exact last element, and the same case changed in ONE field so it
# reaches one past. The resources are also reached one BELOW zero, which the
# lower-end check exists for.
#
#   faces   column: scr cmap atlas wad zonewin srcres srcbase
#           span:   scr cmap flat srcres srcbase
#           masked job: scr cmap wad zonebuf
#           producers: state and its two indices
#           zone window: wad lump_pos lump_size next_lump out
#           ring slot allocator: state and the counter's index, zone_slots (and
#           CAPACITY when full); Jobs#reset: state, the reset table, the index
#           reset to 1
#           executor: scr cmap atlas flat wad zonebuf fuzzoffset, the three
#           banks through the schedule's record indices, sc_kind sc_idx,
#           state and the schedule length's index, the four frame constants;
#           the fuzz column's read above and below the screen
#           pushes (wall, span, masked): the bank at the count and one past, the
#           bank's and the schedule's capacity (CAPACITY when full), sc_kind
#           and sc_idx, the capacity buffers, both counter indices, a negative
#           count, and `count * NF` one past i64; phase marks: both indices
#           checks (disjoint, span, masked, wall_all): the count table past the
#           screen dimension, the dimension buffer, the bank's last read cell,
#           each slot table at the second slot, a full column (CAPACITY), a job
#           past the screen, every counter index, an empty job; disjoint's
#           `lo * NF` one past i64
#           the planes' walk (draw_planes, with make_spans and map_plane, and
#           draw_sky_plane): every plane array at the plane and one past, the
#           loop's bound and start, the sentinel columns, every table the one
#           span reads, the span bank, the schedule, both capacities (CAPACITY
#           when full), every cell index, the empty plane, the light clamp, the
#           cached row, a negative light index, `planeheight * yslope` one past
#           i64; and for a sky plane its column rows, the sky texture's width
#           mask and atlas base, the wall bank and its capacity, the prepared
#           sky scale and middle, every column cell index, and the sky angle's
#           sum one past i64; clear_planes: the clip arrays,
#           the row cache, the prepared constants, every cell index, a
#           saturating fixed_div, and `viewangle - ANG90` one past i64
#
# EVERY EXPECTED LINE CRUBY CAN ANSWER IS DERIVED: the generator runs
# examples/doom/core/src/source.rb, src/zone.rb, src/executor.rb, src/jobs.rb, src/checks.rb, src/fixed.rb,
# src/planespan.rb, src/planes.rb and the fixture's entries.rb
# under CRuby over buffers that REFUSE an index outside their length -- where a
# Ruby Array would answer nil, grow, or count from its end -- and records the
# status (0, 3 on a refused index, 4 on `core_fail(:capacity)`), the result and
# every cell changed by then. So the "last" of each pair is checked to be in
# range by execution, and a BOUNDS case's stored prefix is CRuby's too; an
# answer the table declares must agree with what CRuby derives. ARITHMETIC is
# the exception: CRuby's integers do not overflow, so those answers are
# declared, and `divergence` records what CRuby does instead.
ROOT = File.expand_path("../..", __dir__)
mode, out = ARGV
%w[cases expected liar liar-exec liar-push divergence].include?(mode) && out or
  abort("usage: source-edges.rb cases|expected|liar|liar-exec|liar-push|divergence OUT")

NONE = -1
ATLAS = 0
WAD = 1
ZONE = 2
FLAT = 3

Case = Struct.new(:name, :entry, :bufs, :scalars, :expect) do
  # expect: nil (derive by running the port) or [status, changed-text]
  def with(name, expect: self.expect, bufs: {}, scalars: {})
    c = Case.new(name, entry, self.bufs.map(&:dup), self.scalars.dup, expect)
    bufs.each do |b, fields|
      i = c.bufs.index { |x| x[0] == b } or raise "no buffer #{b}"
      c.bufs[i] = c.bufs[i].dup
      fields.each { |k, v| c.bufs[i][{ count: 2, alloc: 3, fill: 4 }.fetch(k)] = v }
      c.bufs[i][3] = c.bufs[i][2] if fields.key?(:count) && !fields.key?(:alloc)
    end
    scalars.each { |k, v| c.scalars[scalar_names.index(k) || raise("no scalar #{k}")] = v }
    c
  end

  def scalar_names = SCALARS.fetch(entry)
  # A count and an allocation equal to it are one field: the exact allocation
  # follows the count. They are two only for the liar, where they differ.
  def cells
    bufs.flat_map { |n, e, count, alloc, fill| [n, e, count == alloc ? count.to_s : "#{count}/#{alloc}", fill] } +
      scalars.map(&:to_s)
  end
end

SCALARS = {
  "col" => %i[i_res i_base x yl yh iscale texmid colormap_row centery sw vwx vwy],
  "span" => %i[i_res i_base y x1 x2 xfrac yfrac xstep ystep colormap_row sw vwx vwy],
  "mjob" => %i[srcres srcbase x yl yh iscale texmid colormap_row centery width vwx vwy],
  "none" => %i[i_res i_base], "tex" => %i[i_res i_base atlas_base widthmask col],
  "mask" => %i[i_res i_base post_ofs lump_end queued zone_slot], "flat" => %i[i_res i_base flat_base],
  "zone" => %i[lumpnum off base], "zalloc" => %i[i_nzone], "jreset" => %i[i_fuzz_suffix],
  "exec" => %i[i_nsched],
  "pwall" => %i[i_nwall i_nsched x yl yh iscale texmid srcofs cmap],
  "pspan" => %i[i_nspan i_nsched y x1 x2 position step srcofs cmap],
  "pmask" => %i[i_nmasked i_nsched x yl yh iscale texmid srcres srcofs cmap fuzz],
  "ph1" => %i[i_nwall i_wall_phase0_n], "ph3" => %i[i_nmasked i_masked_phase2_n],
  "cdis" => %i[lo i_hi i_max_k i_overlaps], "cspan" => %i[i_nspan i_span_max_kx i_span_overlaps],
  "cmask" => %i[i_nmasked i_fuzz_n i_masked_max_kx i_fuzz_max_kx],
  "call" => %i[i_nwall i_wall_all_max_k i_wall_all_overlaps],
  "dplanes" => %i[i_viewz i_extralight i_planeheight i_planezlight i_curpicnum i_basexscale i_baseyscale i_viewangle
                  i_viewx i_viewy i_nspan i_nsched i_lastvisplane i_nwall i_dc_x i_dc_yl i_dc_yh i_dc_iscale
                  i_dc_texturemid i_dc_colormap i_dc_srcofs i_dc_srcbase pl_from],
  "cplanes" => %i[i_viewangle i_lastvisplane i_lastopening i_floorplane i_ceilingplane i_basexscale i_baseyscale]
}.freeze

def buf(name, elem, count, fill) = [name, elem, count, count, fill]

B3 = [3, "untouched"].freeze # a bounds failure that wrote nothing
D3 = [3, "untouched", :derived].freeze # a bounds failure after stores CRuby derives
cases = []
pairs = []
pair = lambda do |last, past|
  cases << last << past
  pairs << [last, past]
end

# ---- the column: one pixel at scr[15] of a 4x4 screen, reading texel 127 ----
# The selector and base are cells 0 and 1 of the state buffer.
col = Case.new("col", "col",
               [buf("scr", "u8", 16, "zero"), buf("cmap", "u8", 512, "seq"), buf("atlas", "u8", 256, "seq"),
                buf("wad", "u8", 200, "seq"), buf("zonewin", "u8", 128, "seq"), buf("state", "i64", 2, "list:#{ATLAS},128")],
               [0, 1, 3, 3, 3, 0, 127 << 16, 0, 0, 4, 0, 0], nil)
pair.(col.with("col-atlas-last"), col.with("col-atlas-past", expect: B3, bufs: { "state" => { fill: "list:#{ATLAS},129" } }))
cases << col.with("col-atlas-below", expect: B3, bufs: { "state" => { fill: "list:#{ATLAS},-128" } })
wad = col.with("col-wad", bufs: { "state" => { fill: "list:#{WAD},72" } })
pair.(wad.with("col-wad-last"), wad.with("col-wad-past", expect: B3, bufs: { "state" => { fill: "list:#{WAD},73" } }))
cases << wad.with("col-wad-below", expect: B3, bufs: { "state" => { fill: "list:#{WAD},-128" } })
zone = col.with("col-zone", bufs: { "state" => { fill: "list:#{ZONE},0" } })
pair.(zone.with("col-zonewin-last"), zone.with("col-zonewin-past", expect: B3, bufs: { "state" => { fill: "list:#{ZONE},1" } }))
cases << zone.with("col-zonewin-below", expect: B3, bufs: { "state" => { fill: "list:#{ZONE},-128" } })
# atlas[255] is 255, so colormap row 1 reads cmap[511]
cm = col.with("col-cmap", scalars: { colormap_row: 1 })
pair.(cm.with("col-cmap-last"), cm.with("col-cmap-past", expect: B3, bufs: { "cmap" => { count: 511 } }))
cases << col.with("col-cmap-below", expect: B3, scalars: { colormap_row: -1 })
pair.(col.with("col-scr-last"), col.with("col-scr-past", expect: B3, bufs: { "scr" => { count: 15 } }))
cases << col.with("col-scr-below", expect: B3, scalars: { x: -13 })
# THE STATE BUFFER'S INDICES: the selector's cell at the state's last index, one
# past, one below; then the base's.
ires = col.with("col-ires", bufs: { "state" => { count: 3, fill: "list:#{ATLAS},128,#{ATLAS}" } })
pair.(ires.with("col-state-ires-last", scalars: { i_res: 2 }), ires.with("col-state-ires-past", expect: B3, scalars: { i_res: 3 }))
cases << ires.with("col-state-ires-below", expect: B3, scalars: { i_res: -1 })
ibase = col.with("col-ibase", bufs: { "state" => { count: 3, fill: "list:#{ATLAS},128,128" } })
pair.(ibase.with("col-state-ibase-last", scalars: { i_base: 2 }), ibase.with("col-state-ibase-past", expect: B3, scalars: { i_base: 3 }))
cases << ibase.with("col-state-ibase-below", expect: B3, scalars: { i_base: -1 })
# Two pixels, the second read past the atlas: the first pixel stays written.
two = col.with("col-prefix", scalars: { yl: 2, centery: 2, iscale: 1 << 16, texmid: 126 << 16 },
                             bufs: { "state" => { fill: "list:#{ATLAS},129" } })
pair.(two.with("col-prefix-last", bufs: { "state" => { fill: "list:#{ATLAS},128" } }),
      two.with("col-prefix-past", expect: [3, "untouched", "scr[11]=255"]))
cases << col.with("col-selector-none", bufs: { "state" => { fill: "list:#{NONE},128" } })
cases << col.with("col-selector-flat", bufs: { "state" => { fill: "list:#{FLAT},128" } })
cases << col.with("col-empty", scalars: { yl: 3, yh: 2 })

# ---- the span: one pixel at scr[15], reading flat spot 4095 ----
span = Case.new("span", "span",
                [buf("scr", "u8", 16, "zero"), buf("cmap", "u8", 512, "seq"), buf("flat", "u8", 4096, "seq"),
                 buf("state", "i64", 2, "list:#{FLAT},0")],
                [0, 1, 3, 3, 3, 0x3f0000, 0x3f0000, 0, 0, 0, 4, 0, 0], nil)
pair.(span.with("span-flat-last"), span.with("span-flat-past", expect: B3, bufs: { "state" => { fill: "list:#{FLAT},1" } }))
cases << span.with("span-flat-below", expect: B3, bufs: { "state" => { fill: "list:#{FLAT},-4096" } })
scm = span.with("span-cmap", scalars: { colormap_row: 1 })
pair.(scm.with("span-cmap-last"), scm.with("span-cmap-past", expect: B3, bufs: { "cmap" => { count: 511 } }))
cases << span.with("span-cmap-below", expect: B3, scalars: { colormap_row: -1 })
pair.(span.with("span-scr-last"), span.with("span-scr-past", expect: B3, bufs: { "scr" => { count: 15 } }))
cases << span.with("span-scr-below", expect: B3, scalars: { x1: -13, x2: -13 })
sres = span.with("span-ires", bufs: { "state" => { count: 3, fill: "list:#{FLAT},0,#{FLAT}" } })
pair.(sres.with("span-state-ires-last", scalars: { i_res: 2 }), sres.with("span-state-ires-past", expect: B3, scalars: { i_res: 3 }))
cases << sres.with("span-state-ires-below", expect: B3, scalars: { i_res: -1 })
sbase = span.with("span-ibase", bufs: { "state" => { count: 3, fill: "list:#{FLAT},0,0" } })
pair.(sbase.with("span-state-ibase-last", scalars: { i_base: 2 }), sbase.with("span-state-ibase-past", expect: B3, scalars: { i_base: 3 }))
cases << sbase.with("span-state-ibase-below", expect: B3, scalars: { i_base: -1 })
cases << span.with("span-selector-atlas", bufs: { "state" => { fill: "list:#{ATLAS},0" } })

# ---- the masked job: one pixel at scr[15], texel 127, from the IWAD or the ring ----
mjob = Case.new("mjob", "mjob",
                [buf("scr", "u8", 16, "zero"), buf("cmap", "u8", 512, "seq"), buf("wad", "u8", 256, "seq"),
                 buf("zonebuf", "u8", 256, "seq")],
                [WAD, 128, 3, 3, 3, 0, 127 << 16, 0, 0, 4, 0, 0], nil)
pair.(mjob.with("mjob-wad-last"), mjob.with("mjob-wad-past", expect: B3, scalars: { srcbase: 129 }))
cases << mjob.with("mjob-wad-below", expect: B3, scalars: { srcbase: -128 })
ring = mjob.with("mjob-ring", scalars: { srcres: ZONE })
pair.(ring.with("mjob-zonebuf-last"), ring.with("mjob-zonebuf-past", expect: B3, scalars: { srcbase: 129 }))
cases << ring.with("mjob-zonebuf-below", expect: B3, scalars: { srcbase: -128 })
mcm = mjob.with("mjob-cmap", scalars: { colormap_row: 1 })
pair.(mcm.with("mjob-cmap-last"), mcm.with("mjob-cmap-past", expect: B3, bufs: { "cmap" => { count: 511 } }))
cases << mjob.with("mjob-cmap-below", expect: B3, scalars: { colormap_row: -1 })
pair.(mjob.with("mjob-scr-last"), mjob.with("mjob-scr-past", expect: B3, bufs: { "scr" => { count: 15 } }))
cases << mjob.with("mjob-scr-below", expect: B3, scalars: { x: -13 })
cases << mjob.with("mjob-selector-atlas", scalars: { srcres: ATLAS })
cases << mjob.with("mjob-selector-none", scalars: { srcres: NONE })

# ---- the producers: three state cells opening at 77, selector 0 and base 1 ----
cells = [buf("state", "i64", 3, "list:77,77,77")]
none = Case.new("none", "none", cells, [0, 1], nil)
pair.(none.with("none-ires-last", scalars: { i_res: 2 }), none.with("none-ires-past", expect: B3, scalars: { i_res: 3 }))
cases << none.with("none-ires-below", expect: B3, scalars: { i_res: -1 })
# the selector is stored before the base is reached: that store stays.
pair.(none.with("none-ibase-last", scalars: { i_base: 2 }), none.with("none-ibase-past", expect: [3, "untouched", "state[0]=-1"], scalars: { i_base: 3 }))
tex = Case.new("tex", "tex", cells, [0, 1, 1000, 63, 70], nil)
pair.(tex.with("tex-ibase-last", scalars: { i_base: 2 }), tex.with("tex-ibase-past", expect: [3, "untouched", "state[0]=0"], scalars: { i_base: 3 }))
mask = Case.new("mask", "mask", cells, [0, 1, 100, 228, 1, 256], nil)
cases << mask.with("mask-in-lump-last")                             # exactly 128 left: the IWAD
cases << mask.with("mask-zone-queued", scalars: { lump_end: 227 })  # 127 left: the ring slot
cases << mask.with("mask-zone-direct", scalars: { lump_end: 227, queued: 0 })
pair.(mask.with("mask-ires-last", scalars: { i_res: 2 }), mask.with("mask-ires-past", expect: B3, scalars: { i_res: 3 }))
flat = Case.new("flat", "flat", cells, [0, 1, 8192], nil)
pair.(flat.with("flat-ibase-last", scalars: { i_base: 2 }), flat.with("flat-ibase-past", expect: [3, "untouched", "state[0]=3"], scalars: { i_base: 3 }))

# ---- the zone window producer: 128 bytes of a lump and what the zone put after it ----
# Two lumps: 0 at 0 for 200 bytes, then lump 1, which the zone holds next, at
# 200 for 50. The directory arrays are the resident fields' shape.
zone = Case.new("zone", "zone",
                [buf("wad", "u8", 256, "seq"), buf("lump_pos", "i64", 2, "list:0,200"),
                 buf("lump_size", "i64", 2, "list:200,50"), buf("next_lump", "i64", 2, "list:1,-1"),
                 buf("out", "u8", 128, "zero")],
                [0, 0, 0], nil)
# the window itself: all 128 inside the lump, and one starting 100 in, which
# crosses the padding and the 40-byte header into lump 1
pair.(zone.with("zone-out-last"), zone.with("zone-out-past", expect: D3, bufs: { "out" => { count: 127 } }))
cases << zone.with("zone-out-below", expect: D3, scalars: { base: -1 })
cross = zone.with("zone-cross", scalars: { off: 100 })
cases << cross.with("zone-header-and-next-lump")
# the IWAD bytes: lump 0 moved so its last byte is the IWAD's last, then one further
zwad = zone.with("zone-wad", bufs: { "lump_pos" => { fill: "list:128,200" }, "lump_size" => { fill: "list:128,50" } })
pair.(zwad.with("zone-wad-last"), zwad.with("zone-wad-past", expect: D3, bufs: { "lump_pos" => { fill: "list:129,200" } }))
# the directory: the last lump, and one past it
pair.(zone.with("zone-lump-last", scalars: { lumpnum: 1 }, bufs: { "lump_pos" => { fill: "list:0,128" }, "lump_size" => { fill: "list:200,128" } }),
      zone.with("zone-lump-past", expect: D3, scalars: { lumpnum: 2 },
                                  bufs: { "lump_pos" => { fill: "list:0,128" }, "lump_size" => { fill: "list:200,128" } }))
# the next-lump chain: a next lump past the directory is read while computing a header byte
pair.(cross.with("zone-next-last", bufs: { "next_lump" => { fill: "list:1,-1" } }),
      cross.with("zone-next-past", expect: D3, bufs: { "next_lump" => { fill: "list:2,-1" } }))
cases << cross.with("zone-no-next-lump", bufs: { "next_lump" => { fill: "list:-1,-1" } })

# ---- the ring's slot allocator: the counter in state cell 1, the slot count its own buffer ----
zalloc = Case.new("zalloc", "zalloc", [buf("state", "i64", 2, "list:77,3071"), buf("zone_slots", "i64", 1, "val:3072")], [1], nil)
pair.(zalloc.with("zalloc-last-slot"), zalloc.with("zalloc-full", expect: [4, "untouched", :derived], bufs: { "state" => { fill: "list:77,3072" } }))
pair.(zalloc.with("zalloc-inzone-last", bufs: { "state" => { fill: "list:3071,3071" } }, scalars: { i_nzone: 1 }),
      zalloc.with("zalloc-inzone-past", expect: B3, bufs: { "state" => { fill: "list:3071,3071" } }, scalars: { i_nzone: 2 }))
cases << zalloc.with("zalloc-inzone-below", expect: B3, scalars: { i_nzone: -1 })
pair.(zalloc.with("zalloc-slots-last"), zalloc.with("zalloc-slots-past", expect: B3, bufs: { "zone_slots" => { count: 0 } }))

# ---- Jobs#reset: cells 0 and 2 to 0 through the table, cell 3 to 1 ----
jreset = Case.new("jreset", "jreset", [buf("state", "i64", 4, "list:7,7,7,7"), buf("zero_slots", "i64", 2, "list:0,2")], [3], nil)
pair.(jreset.with("jreset-table-last", bufs: { "zero_slots" => { fill: "list:0,3" } }),
      jreset.with("jreset-table-past", expect: D3, bufs: { "zero_slots" => { fill: "list:0,4" } }))
cases << jreset.with("jreset-table-below", expect: D3, bufs: { "zero_slots" => { fill: "list:0,-1" } })
pair.(jreset.with("jreset-suffix-last"), jreset.with("jreset-suffix-past", expect: D3, scalars: { i_fuzz_suffix: 4 }))
cases << jreset.with("jreset-empty-table", bufs: { "zero_slots" => { count: 0, fill: "zero" } })

# ---- the executor: a 4x4 screen, a schedule of four jobs, one pixel each ----
# wall record 0 draws scr[15] from atlas[255]; span record 0 scr[11] from flat
# spot 4095; masked record 0 scr[7] from wad[255]; masked record 1 is a fuzz
# column at scr[3], reading scr[7] -- the pixel the job before it drew --
# through fuzzoffset[49] and colormap row 6, cmap[1791]. The schedule length is
# state cell 0; the frame constants are one-element buffers.
WALL0 = [3, 3, 3, 0, 127 << 16, 128, 0].freeze
SPAN0 = [2, 3, 3, 0xfc00fc00, 0, 0, 0].freeze
MASK0 = [3, 1, 1, 0, 127 << 16, WAD, 128, 0, -1].freeze
FUZZ1 = [3, 0, 0, 0, 0, 0, 0, 0, 49].freeze
def list(*v) = "list:#{v.flatten.join(',')}"
ex = Case.new("exec", "exec",
              [buf("scr", "u8", 16, "zero"), buf("cmap", "u8", 1792, "seq"), buf("atlas", "u8", 256, "seq"),
               buf("flat", "u8", 4096, "seq"), buf("wad", "u8", 256, "seq"), buf("zonebuf", "u8", 256, "seq"),
               buf("fuzzoffset", "i64", 50, "val:1"), buf("wall", "i64", 7, list(WALL0)),
               buf("span", "i64", 7, list(SPAN0)), buf("masked", "i64", 18, list(MASK0, FUZZ1)),
               buf("sc_kind", "i64", 4, list(0, 1, 2, 2)), buf("sc_idx", "i64", 4, list(0, 0, 0, 1)),
               buf("state", "i64", 1, list(4)), buf("width", "i64", 1, "val:4"), buf("centery", "i64", 1, "val:0"),
               buf("vwx", "i64", 1, "val:0"), buf("vwy", "i64", 1, "val:0")],
              [0], nil)
wall_at = ->(k, v) { list(WALL0.each_with_index.map { |x, i| i == k ? v : x }) }
span_at = ->(k, v) { list(SPAN0.each_with_index.map { |x, i| i == k ? v : x }) }
mask_at = ->(k, v) { list(MASK0.each_with_index.map { |x, i| i == k ? v : x }, FUZZ1) }
fuzz_at = ->(k, v) { list(MASK0, FUZZ1.each_with_index.map { |x, i| i == k ? v : x }) }
cases << ex.with("exec-all-four")
# the wall runs first, so its refusals leave the screen untouched; every later
# job's refusal leaves the earlier jobs' pixels, which CRuby derives
pair.(ex.with("exec-atlas-last"), ex.with("exec-atlas-past", expect: B3, bufs: { "wall" => { fill: wall_at.(5, 129) } }))
cases << ex.with("exec-atlas-below", expect: B3, bufs: { "wall" => { fill: wall_at.(5, -128) } })
pair.(ex.with("exec-flat-last"), ex.with("exec-flat-past", expect: D3, bufs: { "flat" => { count: 4095 } }))
cases << ex.with("exec-flat-below", expect: D3, bufs: { "span" => { fill: span_at.(5, -4096) } })
pair.(ex.with("exec-wad-last"), ex.with("exec-wad-past", expect: D3, bufs: { "masked" => { fill: mask_at.(6, 129) } }))
cases << ex.with("exec-wad-below", expect: D3, bufs: { "masked" => { fill: mask_at.(6, -128) } })
exz = ex.with("exec-ring", bufs: { "masked" => { fill: mask_at.(5, ZONE) } })
pair.(exz.with("exec-zonebuf-last"), exz.with("exec-zonebuf-past", expect: D3, bufs: { "zonebuf" => { count: 255 } }))
cases << ex.with("exec-selector-atlas-reads-wad", bufs: { "masked" => { fill: mask_at.(5, ATLAS) } })
pair.(ex.with("exec-cmap-last"), ex.with("exec-cmap-past", expect: D3, bufs: { "cmap" => { count: 1791 } }))
cases << ex.with("exec-wall-cmap-below", expect: B3, bufs: { "wall" => { fill: wall_at.(6, -1) } })
cases << ex.with("exec-span-cmap-below", expect: D3, bufs: { "span" => { fill: span_at.(6, -1) } })
cases << ex.with("exec-masked-cmap-below", expect: D3, bufs: { "masked" => { fill: mask_at.(7, -1) } })
pair.(ex.with("exec-scr-last"), ex.with("exec-scr-past", expect: B3, bufs: { "scr" => { count: 15 } }))
cases << ex.with("exec-wall-scr-below", expect: B3, bufs: { "wall" => { fill: wall_at.(0, -13) } })
cases << ex.with("exec-span-scr-below", expect: D3, bufs: { "span" => { fill: span_at.(0, -1) } })
cases << ex.with("exec-masked-scr-below", expect: D3, bufs: { "masked" => { fill: mask_at.(0, -5) } })
# the fuzz column reads the table at its phase, and the screen a row away
pair.(ex.with("exec-fuzzoffset-last"), ex.with("exec-fuzzoffset-past", expect: D3, bufs: { "fuzzoffset" => { count: 49 } }))
pair.(ex.with("exec-fuzz-read-last", bufs: { "fuzzoffset" => { fill: "val:3" } }),
      ex.with("exec-fuzz-read-past", expect: D3, bufs: { "fuzzoffset" => { fill: "val:4" } }))
cases << ex.with("exec-fuzz-read-below", expect: D3, bufs: { "fuzzoffset" => { fill: "val:-1" } })
# two fuzz rows from phase 49: the phase wraps to 0, not to 50
cases << ex.with("exec-fuzz-wrap", bufs: { "masked" => { fill: fuzz_at.(2, 1) } })
# the schedule's record indices, one past each bank and one below
pair.(ex.with("exec-wall-bank-last"), ex.with("exec-wall-bank-past", expect: B3, bufs: { "sc_idx" => { fill: list(1, 0, 0, 1) } }))
cases << ex.with("exec-wall-bank-below", expect: B3, bufs: { "sc_idx" => { fill: list(-1, 0, 0, 1) } })
pair.(ex.with("exec-span-bank-last"), ex.with("exec-span-bank-past", expect: D3, bufs: { "sc_idx" => { fill: list(0, 1, 0, 1) } }))
pair.(ex.with("exec-masked-bank-last"), ex.with("exec-masked-bank-past", expect: D3, bufs: { "sc_idx" => { fill: list(0, 0, 0, 2) } }))
# the schedule itself: its length past sc_kind, and past sc_idx
pair.(ex.with("exec-sc-kind-last"), ex.with("exec-sc-kind-past", expect: D3, bufs: { "state" => { fill: list(5) } }))
ex5 = ex.with("exec-five", bufs: { "sc_kind" => { count: 5, fill: list(0, 1, 2, 2, 0) }, "state" => { fill: list(5) } })
pair.(ex5.with("exec-sc-idx-last", bufs: { "sc_idx" => { count: 5, fill: list(0, 0, 0, 1, 0) } }),
      ex5.with("exec-sc-idx-past", expect: D3, bufs: { "sc_idx" => { count: 4, alloc: 5, fill: list(0, 0, 0, 1, 0) } }))
cases << ex.with("exec-kind-other-is-masked", bufs: { "sc_kind" => { fill: list(0, 1, 7, 7) } })
cases << ex.with("exec-empty-schedule", bufs: { "state" => { fill: list(0) } })
cases << ex.with("exec-empty-wall", bufs: { "wall" => { fill: wall_at.(1, 4) } })
# the schedule length's cell in state, and the frame constants
exs = ex.with("exec-state", bufs: { "state" => { count: 2, fill: list(9, 4) } })
pair.(exs.with("exec-state-last", scalars: { i_nsched: 1 }), exs.with("exec-state-past", expect: B3, scalars: { i_nsched: 2 }))
cases << exs.with("exec-state-below", expect: B3, scalars: { i_nsched: -1 })
%w[width centery vwx vwy].each do |k|
  pair.(ex.with("exec-#{k}-last"), ex.with("exec-#{k}-past", expect: B3, bufs: { k => { count: 0 } }))
end

# ---- the pushes: one record into an empty bank, its schedule entry ----
# state cell 0 is the bank's count, cell 1 the schedule's; the record's fields
# are 11, 12, ...; sc_kind and sc_idx open at 9, so the kind and index written
# are seen even when they are 0.
PUSH_KINDS = { "pwall" => ["wall", "cap_wall", :i_nwall, 7], "pspan" => ["span", "cap_span", :i_nspan, 7],
               "pmask" => ["masked", "cap_masked", :i_nmasked, 9] }.freeze
push_bases = {}
PUSH_KINDS.each do |entry, (bank, cap, icount, nf)|
  pb = Case.new(entry, entry,
                [buf("state", "i64", 2, list(0, 0)), buf(bank, "i64", nf, "zero"), buf("sc_kind", "i64", 1, "val:9"),
                 buf("sc_idx", "i64", 1, "val:9"), buf(cap, "i64", 1, "val:1"), buf("cap_sched", "i64", 1, "val:1")],
                [0, 1] + (11...(11 + nf)).to_a, nil)
  push_bases[entry] = pb
  cases << pb.with("#{entry}-one")
  # the bank: the record's last cell, and one past it after the first cells are stored
  pair.(pb.with("#{entry}-bank-last"), pb.with("#{entry}-bank-past", expect: D3, bufs: { bank => { count: nf - 1 } }))
  # the second record: the count indexes the bank
  two = pb.with("#{entry}-second", bufs: { "state" => { fill: list(1, 0) }, bank => { count: 2 * nf }, cap => { fill: "val:2" } })
  pair.(two.with("#{entry}-bank2-last"), two.with("#{entry}-bank2-past", expect: D3, bufs: { bank => { count: 2 * nf - 1 } }))
  cases << pb.with("#{entry}-count-below", expect: B3, bufs: { "state" => { fill: list(-1, 0) } })
  # the capacities: a full bank stores nothing; a full schedule after the record is stored
  pair.(two.with("#{entry}-cap-last"), two.with("#{entry}-cap-full", expect: [4, "untouched", :derived], bufs: { cap => { fill: "val:1" } }))
  pair.(pb.with("#{entry}-sched-cap-last"), pb.with("#{entry}-sched-cap-full", expect: [4, "untouched", :derived], bufs: { "cap_sched" => { fill: "val:0" } }))
  pair.(pb.with("#{entry}-capbuf-last"), pb.with("#{entry}-capbuf-past", expect: B3, bufs: { cap => { count: 0 } }))
  pair.(pb.with("#{entry}-schedcapbuf-last"), pb.with("#{entry}-schedcapbuf-past", expect: D3, bufs: { "cap_sched" => { count: 0 } }))
  # the schedule: its entry at the schedule's count, and one past
  s2 = pb.with("#{entry}-sched2", bufs: { "state" => { fill: list(0, 1) }, "cap_sched" => { fill: "val:2" },
                                          "sc_kind" => { count: 2 }, "sc_idx" => { count: 2 } })
  pair.(s2.with("#{entry}-sc-kind-last"), s2.with("#{entry}-sc-kind-past", expect: D3, bufs: { "sc_kind" => { count: 1, alloc: 2 } }))
  pair.(s2.with("#{entry}-sc-idx-last"), s2.with("#{entry}-sc-idx-past", expect: D3, bufs: { "sc_idx" => { count: 1, alloc: 2 } }))
  # the counters' cells in state
  s3 = pb.with("#{entry}-state3", bufs: { "state" => { count: 3, fill: list(0, 0, 0) } })
  pair.(s3.with("#{entry}-icount-last", scalars: { icount => 2 }), s3.with("#{entry}-icount-past", expect: B3, scalars: { icount => 3 }))
  cases << s3.with("#{entry}-icount-below", expect: B3, scalars: { icount => -1 })
  pair.(s3.with("#{entry}-insched-last", scalars: { i_nsched: 2 }), s3.with("#{entry}-insched-past", expect: D3, scalars: { i_nsched: 3 }))
end
# the phase marks: cells 0, 1 and 2 hold 5, 9 and 7; the mark copies cell 0 into cell 1
{ "ph1" => %i[i_nwall i_wall_phase0_n], "ph3" => %i[i_nmasked i_masked_phase2_n] }.each do |entry, (from, to)|
  ph = Case.new(entry, entry, [buf("state", "i64", 3, list(5, 9, 7))], [0, 1], nil)
  cases << ph.with("#{entry}-mark")
  pair.(ph.with("#{entry}-from-last", scalars: { from => 2 }), ph.with("#{entry}-from-past", expect: B3, scalars: { from => 3 }))
  cases << ph.with("#{entry}-from-below", expect: B3, scalars: { from => -1 })
  pair.(ph.with("#{entry}-to-last", scalars: { to => 2 }), ph.with("#{entry}-to-past", expect: B3, scalars: { to => 3 }))
end

# ---- the checks: two jobs in screen column (or row) 1 of a 2-wide screen, overlapping ----
# state cell 0 is the job count (for disjoint, the phase-0 bound), cells 1.. the
# statistics, which open at 0. The count table has the screen dimension's
# length; each slot table holds CAP slots per column.
CHECKS = {
  # entry => [bank, record fields, recs, count table, cap, slot tables, dimension, count index, counter indices]
  "cdis" => ["wall", 7, [[1, 0, 5, 0, 0, 0, 0], [1, 3, 8, 0, 0, 0, 0]], "xcount", 64, %w[xyl xyh], "width", :i_hi, %i[i_max_k i_overlaps]],
  "cspan" => ["span", 7, [[1, 0, 5, 0, 0, 0, 0], [1, 3, 8, 0, 0, 0, 0]], "ycount", 256, %w[yx1 yx2], "height", :i_nspan,
              %i[i_span_max_kx i_span_overlaps]],
  "cmask" => ["masked", 9, [[1, 0, 5, 0, 0, 0, 0, 0, -1], [1, 3, 8, 0, 0, 0, 0, 0, 7]], "mcount", 256, %w[mlo mhi mseq mfz], "width",
              :i_nmasked, %i[i_fuzz_n i_masked_max_kx i_fuzz_max_kx]],
  "call" => ["wall", 7, [[1, 0, 5, 0, 0, 0, 0], [1, 3, 8, 0, 0, 0, 0]], "xcount", 64, %w[xyl xyh], "width", :i_nwall,
             %i[i_wall_all_max_k i_wall_all_overlaps]]
}.freeze
check_bases = {}
CHECKS.each do |entry, (bank, nf, recs, ctab, cap, slots, dim, icount, counters)|
  ncells = 1 + counters.length
  # the highest bank cell a record's scan reads: the second record's yh (or x2), or masked's fuzz
  last_read = entry == "cmask" ? nf + 8 : nf + 2
  bufs = [buf("state", "i64", ncells, list(2, Array.new(counters.length, 0))), buf(bank, "i64", last_read + 1, list(recs.flatten.first(last_read + 1))),
          buf(ctab, "i64", 2, "zero")] +
         slots.map { |t| buf(t, "i64", cap + 2, "zero") } + [buf(dim, "i64", 1, "val:2")]
  scal = (entry == "cdis" ? [0] : []) + [0] + (1..counters.length).to_a
  cb = Case.new(entry, entry, bufs, scal, nil)
  check_bases[entry] = cb
  cases << cb.with("#{entry}-two")
  pair.(cb.with("#{entry}-bank-last"), cb.with("#{entry}-bank-past", expect: D3, bufs: { bank => { count: last_read } }))
  pair.(cb.with("#{entry}-counttab-last"), cb.with("#{entry}-counttab-past", expect: D3, bufs: { ctab => { count: 1 } }))
  pair.(cb.with("#{entry}-dim-last"), cb.with("#{entry}-dim-past", expect: B3, bufs: { dim => { count: 0 } }))
  slots.each do |t|
    pair.(cb.with("#{entry}-#{t}-last"), cb.with("#{entry}-#{t}-past", expect: D3, bufs: { t => { count: cap + 1 } }))
  end
  # a job in column 2 of a 2-wide screen
  cases << cb.with("#{entry}-job-past-screen", expect: D3, bufs: { bank => { fill: list([2] + recs.flatten[1, last_read]) } })
  cases << cb.with("#{entry}-empty-job", bufs: { bank => { fill: list(recs[0][0], 6, 5, recs.flatten[3, last_read - 2]) } })
  sc = cb.with("#{entry}-state", bufs: { "state" => { count: ncells + 1, fill: list(2, Array.new(counters.length, 0), 2) } })
  pair.(sc.with("#{entry}-icount-last", scalars: { icount => ncells }), sc.with("#{entry}-icount-past", expect: B3, scalars: { icount => ncells + 1 }))
  cases << cb.with("#{entry}-icount-below", expect: B3, scalars: { icount => -1 })
  counters.each do |ci|
    cases << cb.with("#{entry}-#{ci.to_s.delete_prefix('i_')}-past", expect: D3, scalars: { ci => ncells })
  end
  # a full column: CAP non-empty jobs in column 0 succeed, one more is CAPACITY
  one = recs[0].dup
  one[0] = 0
  full = cb.with("#{entry}-full", bufs: { "state" => { fill: list(cap, Array.new(counters.length, 0)) },
                                          bank => { count: (cap + 1) * nf, fill: list(Array.new(cap + 1) { one }) },
                                          ctab => { fill: "zero" } })
  pair.(full.with("#{entry}-cap-last"), full.with("#{entry}-cap-full", expect: [4, "untouched", :derived],
                                                   bufs: { "state" => { fill: list(cap + 1, Array.new(counters.length, 0)) } }))
end
# ---- the planes' walk: plane 0, one column, one span ----
# Plane 0 covers column 1 of a 2-wide view at row 1; its stride is 4, so its top
# and bottom are cells 1..3 (cell 0 unused, 1 and 3 the sentinels). Column 1
# starts the run at row 1 and column 2 ends it: one span at row 1 from x 1 to
# 1. state cells 0-11 are viewz, extralight, planeheight, planezlight,
# curpicnum, basexscale, baseyscale, viewangle, viewx, viewy, nspan and nsched;
# 12 is lastvisplane (1: the walk is plane 0 alone), 13 nwall, 14-21 the column
# cells dc_x, dc_yl, dc_yh, dc_iscale, dc_texturemid, dc_colormap, dc_srcofs and
# dc_srcbase. The plane's height is 1.0 above viewz 0, so the distance is 1.0 and
# the light index 0; flattranslation[0] is 2; the sky flat is 9.
DP_STATE = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0].freeze
dp = Case.new("dplanes", "dplanes",
              [buf("state", "i64", 22, list(DP_STATE)), buf("pl_minx", "i64", 1, "val:1"), buf("pl_maxx", "i64", 1, "val:1"),
               buf("pl_picnum", "i64", 1, "val:0"), buf("pl_height", "i64", 1, "val:65536"), buf("pl_lightlevel", "i64", 1, "val:0"),
               buf("pl_top", "i64", 4, list(0, 0, 1, 0)), buf("pl_bottom", "i64", 4, list(0, 0, 1, 0)),
               buf("spanstart", "i64", 4, "zero"), buf("cachedheight", "i64", 4, "zero"), buf("cacheddistance", "i64", 4, "zero"),
               buf("cachedxstep", "i64", 4, "zero"), buf("cachedystep", "i64", 4, "zero"), buf("yslope", "i64", 4, "val:65536"),
               buf("distscale", "i64", 2, "val:65536"), buf("xtoviewangle", "i64", 2, "zero"), buf("finesine", "i64", 2049, "val:1"),
               buf("zlight", "i64", 1, "val:5"), buf("flattranslation", "i64", 1, "val:2"), buf("span", "i64", 7, "zero"),
               buf("sc_kind", "i64", 1, "val:9"), buf("sc_idx", "i64", 1, "val:9"), buf("cap_span", "i64", 1, "val:1"),
               buf("cap_sched", "i64", 1, "val:1"), buf("plw", "i64", 1, "val:4"), buf("plempty", "i64", 1, "val:255"),
               buf("skyflatnum", "i64", 1, "val:9"), buf("tex_widthmask", "i64", 1, "val:255"), buf("tex_atlas_base", "i64", 1, "val:1000"),
               buf("wall", "i64", 7, "zero"), buf("cap_wall", "i64", 1, "val:1"), buf("skytexture", "i64", 1, "val:0"),
               buf("pspriteiscale", "i64", 1, "val:65536"), buf("skytexturemid", "i64", 1, "val:6553600")],
              (0..21).to_a + [0], nil)
cases << dp.with("dplanes-one")
# the plane's one-cell arrays at plane 0, one past with a count of 0
%w[pl_minx pl_maxx pl_picnum pl_height pl_lightlevel].each do |t|
  pair.(dp.with("dplanes-#{t}-last"), dp.with("dplanes-#{t}-past", expect: D3, bufs: { t => { count: 0 } }))
end
# the walk's bound and start: one more plane than the arrays have, and a start below 0
cases << dp.with("dplanes-bound-past", expect: D3, bufs: { "state" => { fill: list(DP_STATE.each_with_index.map { |v, i| i == 12 ? 2 : v }) } })
cases << dp.with("dplanes-from-below", expect: B3, scalars: { pl_from: -1 })
cases << dp.with("dplanes-from-at-bound", scalars: { pl_from: 1 })
# the right sentinel is pl_top's last cell; pl_bottom's last cell is read at column 2
pair.(dp.with("dplanes-pl-top-last"), dp.with("dplanes-pl-top-past", expect: D3, bufs: { "pl_top" => { count: 3 } }))
pair.(dp.with("dplanes-pl-bottom-last"), dp.with("dplanes-pl-bottom-past", expect: D3, bufs: { "pl_bottom" => { count: 3 } }))
%w[plw plempty skyflatnum].each do |t|
  pair.(dp.with("dplanes-#{t}-last"), dp.with("dplanes-#{t}-past", expect: D3, bufs: { t => { count: 0 } }))
end
# the span's tables: row 1, column 1
%w[cachedheight cacheddistance cachedxstep cachedystep yslope].each do |t|
  pair.(dp.with("dplanes-#{t}-last", bufs: { t => { count: 2 } }), dp.with("dplanes-#{t}-past", expect: D3, bufs: { t => { count: 1 } }))
end
%w[distscale xtoviewangle].each do |t|
  pair.(dp.with("dplanes-#{t}-last"), dp.with("dplanes-#{t}-past", expect: D3, bufs: { t => { count: 1 } }))
end
pair.(dp.with("dplanes-finesine-last"), dp.with("dplanes-finesine-past", expect: D3, bufs: { "finesine" => { count: 2048 } }))
%w[zlight flattranslation].each do |t|
  pair.(dp.with("dplanes-#{t}-last"), dp.with("dplanes-#{t}-past", expect: D3, bufs: { t => { count: 0 } }))
end
pair.(dp.with("dplanes-spanstart-last", bufs: { "spanstart" => { count: 2 } }),
      dp.with("dplanes-spanstart-past", expect: D3, bufs: { "spanstart" => { count: 1 } }))
pair.(dp.with("dplanes-span-last"), dp.with("dplanes-span-past", expect: D3, bufs: { "span" => { count: 6 } }))
pair.(dp.with("dplanes-sc-kind-last"), dp.with("dplanes-sc-kind-past", expect: D3, bufs: { "sc_kind" => { count: 0 } }))
pair.(dp.with("dplanes-sc-idx-last"), dp.with("dplanes-sc-idx-past", expect: D3, bufs: { "sc_idx" => { count: 0 } }))
pair.(dp.with("dplanes-cap-last"), dp.with("dplanes-cap-full", expect: [4, "untouched", :derived], bufs: { "cap_span" => { fill: "val:0" } }))
pair.(dp.with("dplanes-sched-cap-last"), dp.with("dplanes-sched-cap-full", expect: [4, "untouched", :derived], bufs: { "cap_sched" => { fill: "val:0" } }))
# every cell index of a drawn plane: the state's last cell, and one past
dst = dp.with("dplanes-state", bufs: { "state" => { count: 23, fill: list(DP_STATE, 0) } })
%i[i_viewz i_extralight i_planeheight i_planezlight i_curpicnum i_basexscale i_viewangle i_viewx i_nspan i_nsched].each do |ci|
  pair.(dst.with("dplanes-#{ci.to_s.delete_prefix('i_')}-last", scalars: { ci => 22 }),
        dst.with("dplanes-#{ci.to_s.delete_prefix('i_')}-past", expect: D3, scalars: { ci => 23 }))
end
cases << dst.with("dplanes-lastvisplane-past", expect: B3, scalars: { i_lastvisplane: 23 })
cases << dp.with("dplanes-empty", bufs: { "pl_minx" => { fill: "val:2" } })
# the light clamps at 15 rows, so the colormap row is zlight[15 * 128]
pair.(dp.with("dplanes-light-clamp-last", bufs: { "pl_lightlevel" => { fill: "val:255" }, "zlight" => { count: 1921, fill: "val:5" } }),
      dp.with("dplanes-light-clamp-past", expect: D3, bufs: { "pl_lightlevel" => { fill: "val:255" }, "zlight" => { count: 1920, fill: "val:5" } }))
cases << dp.with("dplanes-light-below", bufs: { "state" => { fill: list(DP_STATE.each_with_index.map { |v, i| i == 1 ? -20 : v }) } })
# a row whose cached height is the plane's: the cached distance and steps are read back
cases << dp.with("dplanes-cached-row", bufs: { "cachedheight" => { fill: list(0, 65_536, 0, 0) }, "cacheddistance" => { fill: "val:131072" },
                                               "cachedxstep" => { fill: "val:7" }, "cachedystep" => { fill: "val:9" } })
# the height is an absolute value, so a negative distance needs a negative row
# slope: then the light index is below zlight
cases << dp.with("dplanes-zlight-below", expect: D3, bufs: { "yslope" => { fill: "val:-65536" } })

# ---- a sky plane: plane 0 is the sky flat, its one column 1 runs over row 1 ----
# The column's sky angle is 0, so its texture column is 0 and its source base is
# the sky texture's atlas base, 1000; one wall job, colormap row 0.
sk = dp.with("dplanes-sky", bufs: { "pl_picnum" => { fill: "val:9" } })
cases << sk.with("dplanes-sky-one")
pair.(sk.with("dplanes-sky-pl-top-last", bufs: { "pl_top" => { count: 3 } }),
      sk.with("dplanes-sky-pl-top-past", expect: D3, bufs: { "pl_top" => { count: 2 } }))
pair.(sk.with("dplanes-sky-pl-bottom-last", bufs: { "pl_bottom" => { count: 3 } }),
      sk.with("dplanes-sky-pl-bottom-past", expect: D3, bufs: { "pl_bottom" => { count: 2 } }))
pair.(sk.with("dplanes-sky-xtoviewangle-last"), sk.with("dplanes-sky-xtoviewangle-past", expect: D3, bufs: { "xtoviewangle" => { count: 1 } }))
%w[skytexture tex_widthmask tex_atlas_base cap_wall pspriteiscale skytexturemid].each do |t|
  pair.(sk.with("dplanes-sky-#{t}-last"), sk.with("dplanes-sky-#{t}-past", expect: D3, bufs: { t => { count: 0 } }))
end
pair.(sk.with("dplanes-sky-wall-last"), sk.with("dplanes-sky-wall-past", expect: D3, bufs: { "wall" => { count: 6 } }))
pair.(sk.with("dplanes-sky-cap-last"), sk.with("dplanes-sky-cap-full", expect: [4, "untouched", :derived], bufs: { "cap_wall" => { fill: "val:0" } }))
pair.(sk.with("dplanes-sky-sched-cap-last"), sk.with("dplanes-sky-sched-cap-full", expect: [4, "untouched", :derived], bufs: { "cap_sched" => { fill: "val:0" } }))
pair.(sk.with("dplanes-sky-sc-kind-last"), sk.with("dplanes-sky-sc-kind-past", expect: D3, bufs: { "sc_kind" => { count: 0 } }))
skst = sk.with("dplanes-sky-state", bufs: { "state" => { count: 23, fill: list(DP_STATE, 0) } })
%i[i_nwall i_dc_x i_dc_yl i_dc_yh i_dc_iscale i_dc_texturemid i_dc_colormap i_dc_srcofs i_dc_srcbase].each do |ci|
  pair.(skst.with("dplanes-sky-#{ci.to_s.delete_prefix('i_')}-last", scalars: { ci => 22 }),
        skst.with("dplanes-sky-#{ci.to_s.delete_prefix('i_')}-past", expect: D3, scalars: { ci => 23 }))
end
# a sky column with no run pushes nothing; a wider texture column comes from the angle
cases << sk.with("dplanes-sky-no-run", bufs: { "pl_top" => { fill: list(0, 0, 2, 0) } })
cases << sk.with("dplanes-sky-angle", bufs: { "xtoviewangle" => { fill: "val:#{3 << 22}" } })

# ---- clear_planes: a 2-wide view, a 4-row screen ----
# state cells 0-6 are viewangle, lastvisplane, lastopening, floorplane,
# ceilingplane, basexscale and baseyscale. viewangle is ANG90, so the fine angle
# is 0; finesine is 1.0 and the half-width 2.0, so the scales are 0.5 and -0.5.
CP_STATE = [0x40000000, 7, 7, 7, 7, 7, 7].freeze
cp = Case.new("cplanes", "cplanes",
              [buf("state", "i64", 7, list(CP_STATE)), buf("floorclip", "i64", 2, "val:7"), buf("ceilingclip", "i64", 2, "val:7"),
               buf("cachedheight", "i64", 4, "val:7"), buf("finesine", "i64", 2049, "val:65536"), buf("centerxfrac", "i64", 1, "val:131072"),
               buf("viewwidth", "i64", 1, "val:2"), buf("viewheight", "i64", 1, "val:3"), buf("sh", "i64", 1, "val:4")],
              (0..6).to_a, nil)
cases << cp.with("cplanes-one")
%w[floorclip ceilingclip].each do |t|
  pair.(cp.with("cplanes-#{t}-last"), cp.with("cplanes-#{t}-past", expect: D3, bufs: { t => { count: 1 } }))
end
pair.(cp.with("cplanes-cachedheight-last"), cp.with("cplanes-cachedheight-past", expect: D3, bufs: { "cachedheight" => { count: 3 } }))
pair.(cp.with("cplanes-finesine-last"), cp.with("cplanes-finesine-past", expect: D3, bufs: { "finesine" => { count: 2048 } }))
%w[centerxfrac viewwidth viewheight sh].each do |t|
  pair.(cp.with("cplanes-#{t}-last"), cp.with("cplanes-#{t}-past", expect: D3, bufs: { t => { count: 0 } }))
end
cst = cp.with("cplanes-state", bufs: { "state" => { count: 8, fill: list(CP_STATE, 0x40000000) } })
%i[i_viewangle i_lastvisplane i_lastopening i_floorplane i_ceilingplane i_basexscale i_baseyscale].each do |ci|
  pair.(cst.with("cplanes-#{ci.to_s.delete_prefix('i_')}-last", scalars: { ci => 7 }),
        cst.with("cplanes-#{ci.to_s.delete_prefix('i_')}-past", expect: D3, scalars: { ci => 8 }))
end
# fixed_div saturates instead of dividing when the quotient would not fit
cases << cp.with("cplanes-div-saturates", bufs: { "centerxfrac" => { fill: "val:1" } })

# disjoint from the second job: lo is a value, not a cell
# disjoint from the second job: lo is a value, not a cell
cases << check_bases["cdis"].with("cdis-lo-one", scalars: { lo: 1 })

# ---- the arithmetic edges ----
# The kernel computes in checked i64 and CRuby does not overflow at all, so
# here the two DIVERGE: one past each edge is SPINEL_CORE_ARITHMETIC (2), and
# CRuby computes a value -- which `divergence` prints, so the difference is a
# recorded fact and not something the table leaves out. Each pair is one edit
# apart. Where the value just inside the edge is not a drawable column, its
# own status is declared and the pair shows WHICH check answers first.
I64_MAX = 9_223_372_036_854_775_807
arith = []
apair = lambda do |last, past|
  cases << last << past
  arith << [last, past]
end
# the texture producer: `atlas_base + ((col & widthmask) << 7)`, the addition...
apair.(tex.with("tex-add-last", scalars: { atlas_base: I64_MAX - 16_256, widthmask: 127, col: 127 }),
       tex.with("tex-add-past", expect: [2, "untouched", "state[0]=0"],
                                scalars: { atlas_base: I64_MAX - 16_255, widthmask: 127, col: 127 }))
# ...and the shift: under a 57-bit mask, 2**56 - 1 shifted by 7 fits and 2**56 does not
apair.(tex.with("tex-shift-last", scalars: { atlas_base: 0, widthmask: (1 << 57) - 1, col: (1 << 56) - 1 }),
       tex.with("tex-shift-past", expect: [2, "untouched", "state[0]=0"],
                                  scalars: { atlas_base: 0, widthmask: (1 << 57) - 1, col: 1 << 56 }))
# the masked producer's `post_ofs + 128`, which it evaluates before storing anything
apair.(mask.with("mask-add-last", scalars: { post_ofs: I64_MAX - 128, lump_end: I64_MAX }),
       mask.with("mask-add-past", expect: [2, "untouched"], scalars: { post_ofs: I64_MAX - 127, lump_end: I64_MAX }))
# the column's `(yl - centery) * fracstep`: 2**31 x (2**32 - 1) fits, 2**31 + 1 does not
frac = col.with("col-frac", scalars: { iscale: (1 << 32) - 1, texmid: 0 })
apair.(frac.with("col-frac-last", scalars: { centery: 3 - (1 << 31) }),
       frac.with("col-frac-past", expect: [2, "untouched"], scalars: { centery: 3 - (1 << 31) - 1 }))
# the span's `(y + vwy) * sw + x1`: just inside, the offset is a real i64 and
# outside the screen, so BOUNDS answers; one more and the product overflows
sof = span.with("span-offset", scalars: { x1: 0, x2: 0 })
apair.(sof.with("span-offset-last", expect: B3, scalars: { sw: I64_MAX / 3 }),
       sof.with("span-offset-past", expect: [2, "untouched"], scalars: { sw: I64_MAX / 3 + 1 }))
# the allocator's `i * 128`, after it has stored i + 1
big = zalloc.with("zalloc-mul", bufs: { "zone_slots" => { fill: "val:#{I64_MAX}" } })
apair.(big.with("zalloc-mul-last", bufs: { "state" => { fill: "list:77,#{(1 << 56) - 1}" } }),
       big.with("zalloc-mul-past", expect: [2, "untouched", "state[1]=#{(1 << 56) + 1}"], bufs: { "state" => { fill: "list:77,#{1 << 56}" } }))

# the executor's wall `(yl - centery) * fracstep`, the same edge inside the whole run
exf = ex.with("exec-frac", bufs: { "wall" => { fill: list(3, 3, 3, (1 << 32) - 1, 0, 128, 0) } })
apair.(exf.with("exec-frac-last", bufs: { "centery" => { fill: "val:-2147483645" } }),
       exf.with("exec-frac-past", expect: [2, "untouched"], bufs: { "centery" => { fill: "val:-2147483646" } }))

# a push's `count * NF`: the largest count whose product fits indexes past the bank
# (BOUNDS); one more and the product overflows
PUSH_KINDS.each do |entry, (_bank, cap, _icount, nf)|
  big = push_bases[entry].with("#{entry}-mul", bufs: { cap => { fill: "val:#{I64_MAX}" } })
  apair.(big.with("#{entry}-mul-last", expect: B3, bufs: { "state" => { fill: list(I64_MAX / nf, 0) } }),
         big.with("#{entry}-mul-past", expect: [2, "untouched"], bufs: { "state" => { fill: list(I64_MAX / nf + 1, 0) } }))
end

# disjoint's first job at `lo`: its record's `lo * NF + 1` and `+ 2` still fit
# one below I64_MAX / 7, and the read is past the bank (BOUNDS); at I64_MAX / 7
# the product is I64_MAX itself -- 7 divides it -- and `+ 1` overflows
big_lo = check_bases["cdis"].with("cdis-lo", bufs: { "state" => { fill: list(I64_MAX, 0, 0) } })
apair.(big_lo.with("cdis-lo-add-last", expect: B3, scalars: { lo: I64_MAX / 7 - 1 }),
       big_lo.with("cdis-lo-add-past", expect: [2, "untouched"], scalars: { lo: I64_MAX / 7 }))

# map_plane's `planeheight * yslope[y]` inside the walk: yslope 1.0, the largest
# height whose product fits and one more, after the height is cached
dph = dp.with("dplanes-ph", bufs: { "yslope" => { fill: "val:65536" } })
apair.(dph.with("dplanes-ph-mul-last", expect: D3, bufs: { "pl_height" => { fill: "val:#{I64_MAX / 65_536}" } }),
       dph.with("dplanes-ph-mul-past", expect: [2, "untouched", "state[2]=#{I64_MAX / 65_536 + 1},pl_top[1]=255,pl_top[3]=255,spanstart[1]=1,cachedheight[1]=#{I64_MAX / 65_536 + 1}"],
                bufs: { "pl_height" => { fill: "val:#{I64_MAX / 65_536 + 1}" } }))
# the sky column's `viewangle + xtoviewangle[x]`: xtoviewangle 1, the largest view
# angle whose sum fits and one more, after curpicnum is set
sky_ang = sk.with("dplanes-sky-ang", bufs: { "xtoviewangle" => { fill: "val:1" } })
apair.(sky_ang.with("dplanes-sky-angle-add-last", bufs: { "state" => { fill: list(DP_STATE.each_with_index.map { |v, i| i == 7 ? I64_MAX - 1 : v }) } }),
       sky_ang.with("dplanes-sky-angle-add-past", expect: [2, "untouched", "state[4]=9"],
                    bufs: { "state" => { fill: list(DP_STATE.each_with_index.map { |v, i| i == 7 ? I64_MAX : v }) } }))
# clear_planes' `viewangle - ANG90`: with every cell already what the clear writes,
# the lowest angle whose difference fits, and one below
cleared = cp.with("cplanes-cleared", bufs: { "floorclip" => { fill: "val:3" }, "ceilingclip" => { fill: "val:-1" },
                                             "cachedheight" => { fill: "zero" } })
apair.(cleared.with("cplanes-angle-last", bufs: { "state" => { fill: list(-I64_MAX - 1 + 0x40000000, 0, 0, -1, -1, 0, 0) } }),
       cleared.with("cplanes-angle-past", expect: [2, "untouched"], bufs: { "state" => { fill: list(-I64_MAX - 1 + 0x40000000 - 1, 0, 0, -1, -1, 0, 0) } }))

# EACH PAIR IS ONE EDIT APART, and the edit is where the pair says. A pair that
# differed in two fields would not show which one was refused.
one_edit = lambda do |a, b|
  d = a.cells.zip(b.cells).count { |x, y| x != y }
  d == 1 or abort("source-edges.rb: #{a.name} and #{b.name} differ in #{d} fields, not one")
end
pairs.each do |a, b|
  one_edit.(a, b)
  a.expect.nil? && b.expect && [3, 4].include?(b.expect[0]) or
    abort("source-edges.rb: #{a.name}/#{b.name} is not a success and a BOUNDS or CAPACITY failure")
end
arith.each do |a, b|
  one_edit.(a, b)
  b.expect && b.expect[0] == 2 or abort("source-edges.rb: #{b.name} is not an ARITHMETIC case")
  a.expect.nil? || a.expect[0] != 2 or abort("source-edges.rb: #{a.name} is ARITHMETIC too; the pair shows no edge")
end
names = cases.map(&:name)
names.uniq.length == names.length or abort("source-edges.rb: duplicate case names")

def emit_case(c)
  lines = ["case #{c.name} #{c.entry}"]
  c.bufs.each { |n, e, count, alloc, fill| lines << "buf #{n} #{e} #{count} #{alloc} #{fill}" }
  lines << "scalars #{c.scalars.join(' ')}"
  lines << "end"
  lines.join("\n") + "\n"
end

# Running the Ruby port on a case, to derive its expected line.
# `core_fail(:capacity)` is the boundary's CAPACITY; here it is a raise.
class PortCapacity < StandardError; end
# decision 0022's word intrinsics for CRuby (tools/core/intrinsics.rb): CORE
# compiles core_w32_add and the rest itself, and the units call them as
# top-level methods, which plain Ruby needs defined. Never packed.
load File.join(ROOT, "tools/core/intrinsics.rb")
module Port
  def core_fail(_category) = raise(PortCapacity)
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/source.rb")), "source.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/zone.rb")), "zone.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/executor.rb")), "executor.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/jobs.rb")), "jobs.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/checks.rb")), "checks.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/fixed.rb")), "fixed.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/planespan.rb")), "planespan.rb")
  module_eval(File.read(File.join(ROOT, "examples/doom/core/src/planes.rb")), "planes.rb")
  module_eval(File.read(File.join(ROOT, "tests/doom-core/fixtures/source/src/entries.rb")), "entries.rb")
  module_function(*instance_methods(false), *private_instance_methods(false))
end

# A buffer that refuses an index outside 0...length, reading or writing, where a
# Ruby Array would answer nil, grow, or count from its end. It is how CRuby can
# say what a BOUNDS case does -- which elements it stored before the refusal --
# instead of the table only declaring it.
class StrictBuf
  class Bounds < StandardError; end
  def initialize(a) = @a = a
  def [](i)
    (0...@a.length).cover?(i) or raise Bounds
    @a[i]
  end
  def []=(i, v)
    (0...@a.length).cover?(i) or raise Bounds
    @a[i] = v
  end
end

def fill_array(count, fill)
  case fill
  when "seq" then Array.new(count) { |i| i & 255 }
  when "zero" then Array.new(count, 0)
  when /\Alist:/ then fill.delete_prefix("list:").split(",").map { |v| Integer(v, 10) }.first(count)
  else Array.new(count, Integer(fill.delete_prefix("val:"), 10))
  end
end

# The Ruby port run on a case over strict buffers: status 0 with the result,
# 3 where an index was refused, 4 where it asked for CAPACITY -- and every
# element it had stored by then.
def derive(c)
  arrays = c.bufs.map { |_n, _e, count, _alloc, fill| fill_array(count, fill) }
  arrays.each_with_index { |a, i| a.length == c.bufs[i][2] or abort("source-edges.rb: #{c.name}: #{c.bufs[i][0]}'s fill has #{a.length} of #{c.bufs[i][2]}") }
  before = arrays.map(&:dup)
  args = c.bufs.each_with_index.flat_map { |(_n, _e, count), i| [StrictBuf.new(arrays[i]), count] } + c.scalars
  status, result = begin
    [0, Port.send("dc_sp_#{c.entry}", *args)]
  rescue StrictBuf::Bounds
    [3, "untouched"]
  rescue PortCapacity
    [4, "untouched"]
  end
  changed = c.bufs.each_with_index.flat_map do |(n), i|
    (0...arrays[i].length).select { |k| arrays[i][k] != before[i][k] }.map { |k| "#{n}[#{k}]=#{arrays[i][k]}" }
  end
  "#{c.name} status #{status} result #{result} changed #{changed.empty? ? 'none' : changed.join(',')}"
end

case mode
when "cases"
  File.write(out, cases.map { |c| emit_case(c) }.join)
when "expected"
  # EVERY CASE CRUBY CAN ANSWER IS DERIVED, and a declared answer has to agree
  # with it: a last-valid case must come out status 0, and a BOUNDS or CAPACITY
  # case exactly as the table declares it -- or, marked :derived, with the
  # elements CRuby stored before the refusal. ARITHMETIC is the one declared
  # answer CRuby cannot give, since its integers do not overflow; `divergence`
  # records what it does instead.
  File.write(out, cases.map do |c|
    status, result, changed = c.expect
    if status == 2
      "#{c.name} status #{status} result #{result} changed #{changed || 'none'}"
    else
      got = derive(c)
      want_prefix = "#{c.name} status #{status || 0} "
      got.start_with?(want_prefix) or abort("source-edges.rb: #{c.name}: declared status #{status || 0}, CRuby says: #{got}")
      if c.expect && changed != :derived
        declared = "#{c.name} status #{status} result #{result} changed #{changed || 'none'}"
        got == declared or abort("source-edges.rb: #{c.name}: declared #{declared.inspect}, CRuby says #{got.inspect}")
      end
      got
    end
  end.join("\n") + "\n")
when "divergence"
  # What CRuby does with each ARITHMETIC case: the value it computes, or what it
  # raises when that value then has nowhere to go.
  File.write(out, cases.select { |c| c.expect && c.expect[0] == 2 }.map do |c|
    arrays = c.bufs.map do |_n, _e, count, _alloc, fill|
      fill_array(count, fill)
    end
    before = arrays.map(&:dup)
    args = c.bufs.each_with_index.flat_map { |(_n, _e, count), i| [arrays[i], count] } + c.scalars
    begin
      r = Port.send("dc_sp_#{c.entry}", *args)
      changed = c.bufs.each_with_index.flat_map do |(n), i|
        (0...arrays[i].length).select { |k| arrays[i][k] != before[i][k] }.map { |k| "#{n}[#{k}]=#{arrays[i][k]}" }
      end
      "#{c.name} cruby result #{r} changed #{changed.empty? ? 'none' : changed.join(',')}"
    rescue StandardError => e
      "#{c.name} cruby raises #{e.class}"
    end
  end.join("\n") + "\n")
when "liar"
  # A caller that declares 257 atlas bytes over an allocation of 256 and reads
  # the 257th. The count is the caller's claim and 0007 says the compiler cannot
  # establish a foreign pointer's real capacity, so the entry's own check passes
  # it; under AddressSanitizer the read must be reported FROM INSIDE the entry.
  liar = col.with("col-liar", bufs: { "atlas" => { count: 257, alloc: 256 }, "state" => { fill: "list:0,129" } })
  File.write(out, emit_case(liar))
when "liar-exec"
  # The executor's span declaring 4097 flat bytes over 4096, reading the 4097th:
  # the wall has drawn, and the span's read must be reported from inside the entry.
  File.write(out, emit_case(ex.with("exec-liar", bufs: { "flat" => { count: 4097, alloc: 4096 }, "span" => { fill: span_at.(5, 1) } })))
when "liar-push"
  # The wall push's bank declaring two records over an allocation of one, and
  # the second record pushed: the first store past the allocation is reported.
  File.write(out, emit_case(push_bases["pwall"].with("pwall-liar", bufs: { "state" => { fill: list(1, 0) }, "wall" => { count: 14, alloc: 7 },
                                                                            "cap_wall" => { fill: "val:2" } })))
end
