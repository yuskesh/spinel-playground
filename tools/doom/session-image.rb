# frozen_string_literal: true
#
# tools/doom/session-image.rb — a session at open, written as decision 0021's image.
#
#   ruby tools/doom/session-image.rb --catalog native-catalog.tsv --snapshot native-0.bin \
#        --out DIR [--schema examples/doom/core/state.tsv] [--fields examples/doom/core/entries/fields.tsv]
#
# The playable program's session opener (tests/doom-core/native/open.rb, or
# tests/doom-core/native/bound.rb's `open`) writes the session at open as the
# canonical snapshot -- every field but scratch, in schema order, fixed width,
# little endian, no padding (tools/doom/state-schema.rb) -- and the catalog the
# counts were resolved against. This keeps what the three entries are handed
# -- the fields entries/fields.tsv binds, `core_state`, and the `derived:`
# index tables -- and splits it into the two parts a board holds (decision
# 0021, "A host-prepared session image"). A schema field no entry is handed
# (the original's own copies, such as `wad_data`) is left out.
#
#   resources.bin  every handed `resource` field, in schema order, then the
#                  derived index tables (each position's core_state slot, as
#                  i64, in entries/<table>'s order), each at an offset that is
#                  a multiple of 8. On the board it is read in place from the
#                  NOR; on the host it is mapped read-only and each resource
#                  field bound to its offset (NativeSession#bind_resource).
#   writable.bin   the initial contents of the writable side: `core_state`
#                  first (one i64 per scalar slot, in schema order -- the rule
#                  is native_session.rb's: count 1, element i64, role other
#                  than resource), then every other handed persistent and
#                  output field, each at a multiple of 8. Copied to RAM once.
#   image.tsv      one row per buffer: name, role, element, count, part
#                  (`resource`, `derived`, `core_state`, `writable` or
#                  `scratch`), offset in bytes within its file, and bytes. A
#                  `derived` row is in resources.bin; a scratch field has no
#                  initial contents, so it is in no file: its offset is in a
#                  separate zeroed region the holder allocates.
#   image.sha256   the sha256 of the three files above, in sha256sum's format,
#                  so `sha256sum -c` checks them; the board checks the two
#                  binary parts before its first tic.
#
# --demo NAME (decision 0021, 2026-10-20) also records where the demo lump
# NAME is inside the IWAD the image already holds (`renderer_wad_data`), as a
# `#demo NAME offset N tics T playpal P` line of image.tsv (P: the PLAYPAL
# lump's offset, for decision 0024's palette message): the board application reads
# each tic's command from there. The lump is found through the WAD's own
# directory and checked by examples/doom/lib/doom/demo.rb's rules -- version
# 109, one player, no deathmatch, a DEMOMARKER after the last tic -- and a
# lump that breaks one is refused by name.
#
# Refused, naming the cause: a count the catalog does not measure, an element
# the schema does not know, and a snapshot whose length is not the layout's.

require "digest"
require "fileutils"
require "optparse"

ROOT = File.expand_path("../..", __dir__)
WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
ALIGN = 8

opt = { schema: File.join(ROOT, "examples/doom/core/state.tsv"),
        fields: File.join(ROOT, "examples/doom/core/entries/fields.tsv") }
OptionParser.new do |o|
  o.on("--schema PATH") { |v| opt[:schema] = v }
  o.on("--fields PATH") { |v| opt[:fields] = v }
  o.on("--catalog PATH") { |v| opt[:catalog] = v }
  o.on("--snapshot PATH") { |v| opt[:snapshot] = v }
  o.on("--out DIR") { |v| opt[:out] = v }
  o.on("--demo NAME") { |v| opt[:demo] = v }
end.parse!
%i[catalog snapshot out].each { |k| opt[k] or abort("session-image: --#{k} is required") }

catalog = {}
File.foreach(opt[:catalog]) do |ln|
  kind, name, n = ln.chomp.split("\t")
  catalog[name] = Integer(n, 10) if kind == "count"
end

fields = File.readlines(opt[:schema]).reject { |l| l.start_with?("#") || l.strip.empty? }.map do |l|
  name, role, element, count = l.chomp.split("\t")
  WIDTH.key?(element) or abort("session-image: #{name} has element #{element}, which this tool does not know")
  kind, arg = count.split(":", 2)
  n = if kind == "fixed"
        Integer(arg, 10)
      else
        catalog.key?(arg) or abort("session-image: #{name} counts #{arg}, which #{opt[:catalog]} does not measure")
        catalog[arg]
      end
  { name: name, role: role, element: element, count: n, bytes: n * WIDTH[element] }
end

snap = File.binread(opt[:snapshot])
want = fields.reject { |f| f[:role] == "scratch" }.sum { |f| f[:bytes] }
snap.bytesize == want or
  abort("session-image: #{opt[:snapshot]} is #{snap.bytesize} byte(s); the schema and catalog lay out #{want}")
at = 0
fields.each do |f|
  next if f[:role] == "scratch"
  f[:data] = snap.byteslice(at, f[:bytes])
  at += f[:bytes]
end

pad = ->(io) { io << ("\0" * ((ALIGN - io.bytesize % ALIGN) % ALIGN)) }
slots = fields.select { |f| f[:count] == 1 && f[:element] == "i64" && f[:role] != "resource" }
slot_of = slots.each_with_index.to_h { |f, k| [f[:name], k] }
rows_of = ->(path) { File.readlines(path).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") } }
handed = rows_of.(opt[:fields]).map { |r| r[2] }.uniq
derived = handed.select { |h| h.start_with?("derived:") }
names = fields.to_h { |f| [f[:name], f] }
(handed - derived - ["core_state"]).each do |h|
  names.key?(h) or abort("session-image: #{opt[:fields]} hands #{h}, which the schema does not have")
  slot_of.key?(h) and abort("session-image: #{opt[:fields]} hands #{h} as a buffer, but it is a core_state slot")
end
fields.select! { |f| slot_of.key?(f[:name]) || handed.include?(f[:name]) }
# EVERY i64 CELL THE ENTRIES ARE HANDED FITS i32 (decisions 0019 and 0022):
# on the board the three entries compute at 32 bits, and loading an i64 cell
# outside i32 is ARITHMETIC. A 32-bit word belongs in an i32 cell as its signed
# pattern (examples/doom/core/widths-repr.tsv), which Full's preparation
# writes; a value past i32 here is refused by name, not converted.
fields.each do |f|
  next unless f[:element] == "i64" && f[:data]
  f[:data].unpack("q<*").each_with_index do |v, i|
    next if v.between?(-2_147_483_648, 2_147_483_647)
    abort("session-image: #{f[:name]}[#{i}] is #{v}, outside i32; the 32-bit entries cannot load it")
  end
end
res = +"".b
wr = +"".b
rows = []
slots.each_with_index do |f, k|
  # A scratch slot has no initial value; its slot is zero.
  wr << (f[:data] || ("\0" * 8))
  rows << [f, "core_state", k * 8]
end
scratch_at = 0
fields.each do |f|
  next if slots.include?(f)
  case f[:role]
  when "resource"
    pad.(res)
    rows << [f, "resource", res.bytesize]
    res << f[:data]
  when "scratch"
    scratch_at += (ALIGN - scratch_at % ALIGN) % ALIGN
    rows << [f, "scratch", scratch_at]
    scratch_at += f[:bytes]
  else
    pad.(wr)
    rows << [f, "writable", wr.bytesize]
    wr << f[:data]
  end
end
derived.each do |h|
  table = rows_of.(File.join(File.dirname(opt[:fields]), h.split(":", 2)[1]))
  vals = table.map do |r|
    field = r[-1] # the last column, as tools/doom/core-native-prep.rb reads it
    slot_of.key?(field) or abort("session-image: #{h} names #{field}, which is not a core_state slot")
    slot_of[field]
  end
  f = { name: h, role: "derived", element: "i64", count: vals.length, bytes: vals.length * 8 }
  pad.(res)
  rows << [f, "derived", res.bytesize]
  res << vals.pack("q<*")
end

# The demo lump, by examples/doom/lib/doom/demo.rb's rules, in the IWAD the
# image holds: [offset in renderer_wad_data, tics].
demo = nil
if opt[:demo]
  wadf = fields.find { |f| f[:name] == "renderer_wad_data" } or abort("session-image: --demo needs renderer_wad_data, which the schema does not hold")
  wad = wadf[:data]
  abort("session-image: renderer_wad_data is no WAD (#{wad.byteslice(0, 4).inspect})") unless %w[IWAD PWAD].include?(wad.byteslice(0, 4))
  numlumps, dir = wad.byteslice(4, 8).unpack("l<l<")
  lump = (0...numlumps).map { |k| wad.byteslice(dir + 16 * k, 16).unpack("l<l<Z8") }.find { |_, _, n| n == opt[:demo] }
  abort("session-image: demo lump not found: #{opt[:demo]}") unless lump
  pos, size, = lump
  data = wad.byteslice(pos, size)
  abort("session-image: #{opt[:demo]}: #{size} bytes is too short") if size < 14
  abort("session-image: #{opt[:demo]}: demo version #{data.getbyte(0)} is not 109 (DOOM 1.9)") unless data.getbyte(0) == 109
  abort("session-image: #{opt[:demo]}: only single player demos are supported") unless data.bytes[9, 4] == [1, 0, 0, 0]
  abort("session-image: #{opt[:demo]}: deathmatch demos are not supported") unless data.getbyte(4).zero?
  o = 13
  n = 0
  while o + 3 < size && data.getbyte(o) != 0x80
    n += 1
    o += 4
  end
  abort("session-image: #{opt[:demo]}: no DEMOMARKER (0x80) at offset #{o}") unless o < size && data.getbyte(o) == 0x80
  # the palette lump beside it (decision 0024: the board application puts
  # PLAYPAL's first palette, its first 768 bytes, as the stream's palette)
  pal = (0...numlumps).map { |k| wad.byteslice(dir + 16 * k, 16).unpack("l<l<Z8") }.find { |_, _, nm| nm == "PLAYPAL" }
  # a WAD without one (a synthetic test WAD) records none, and an application
  # that names Image::PLAYPAL_OFFSET is then refused by the checked boundary
  demo = [pos, n, pal && pal[1] >= 768 ? pal[0] : nil]
end

FileUtils.mkdir_p(opt[:out])
File.binwrite(File.join(opt[:out], "resources.bin"), res)
File.binwrite(File.join(opt[:out], "writable.bin"), wr)
tsv = +"# Generated by tools/doom/session-image.rb -- do not edit.\n"
tsv << "# A session at open as decision 0021's image; the header of the tool says what each part is.\n"
tsv << "#parts\tresources.bin #{res.bytesize}\twritable.bin #{wr.bytesize}\tscratch #{scratch_at}\n"
tsv << "#demo\t#{opt[:demo]}\toffset #{demo[0]}\ttics #{demo[1]}#{demo[2] ? "\tplaypal #{demo[2]}" : ""}\n" if demo
tsv << "#name\trole\telement\tcount\tpart\toffset\tbytes\n"
rows.sort_by { |f, _, _| fields.index(f) || fields.length }.each do |f, part, off|
  tsv << [f[:name], f[:role], f[:element], f[:count], part, off, f[:bytes]].join("\t") << "\n"
end
File.write(File.join(opt[:out], "image.tsv"), tsv)
sums = %w[resources.bin writable.bin image.tsv].map do |n|
  "#{Digest::SHA256.file(File.join(opt[:out], n)).hexdigest}  #{n}\n"
end
File.write(File.join(opt[:out], "image.sha256"), sums.join)

nres = rows.count { |_, p, _| p == "resource" }
nder = rows.count { |_, p, _| p == "derived" }
nwr = rows.count { |_, p, _| p == "writable" }
nsc = rows.count { |_, p, _| p == "scratch" }
puts "session-image: #{nres} resource buffer(s) and #{nder} derived table(s), #{res.bytesize} byte(s); " \
     "core_state #{slots.length} slot(s) and #{nwr} writable buffer(s), #{wr.bytesize} byte(s); " \
     "#{nsc} scratch buffer(s), #{scratch_at} byte(s) in no file"
