# frozen_string_literal: true
#
# tests/doom-core/lump-directory.rb — the directory arrays, entry by entry.
#
#   ruby tests/doom-core/lump-directory.rb [IWAD]
#
# `Lump@@name/pos/size` are replaced in the schema by `wad_lump_name/pos/size`,
# one value per directory entry (docs/core/doom-lump-directory.md). Full builds
# them in `Resources` and the reference builds them in `Reference`, separately.
# This checks both against expectations written HERE, on two WADs:
#
#   * a SYNTHETIC WAD, generated below and not a file anyone downloaded, which
#     carries the two cases doom1.wad has none of: a lower-case name, and a
#     name slot with non-zero bytes after its NUL;
#   * the real IWAD, when given, for the whole directory, a duplicate name, a
#     marker's non-zero position and the last entry.
ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/lib/doom/wad")
require_relative File.join(ROOT, "examples/doom/core/full/resources")
require_relative File.join(ROOT, "examples/doom/core/full/reference")
require "tmpdir"

RES = Doom::Core::Resources
REF = Doom::Core::Reference
$fails = 0
def check(label, got, want)
  ok = got == want
  $fails += 1 unless ok
  puts format("%-4s %s%s", ok ? "pass" : "FAIL", label, ok ? "" : " (got #{got.inspect}, want #{want.inspect})")
end

def full(wad, field, width = nil)
  RES::PerEntry.new(wad, field, width).entries
end

def ref(wad, field)
  kind, value = REF.field_value({ "Wad" => wad }, "Lump@@#{field}")
  kind == :ok ? value : [kind, value]
end

# --- a synthetic WAD -------------------------------------------------------
# Header `IWAD`, a lump count and a directory offset, then the data and the
# directory. Each directory entry is filepos, size and an 8-byte name SLOT --
# the slot is written RAW here, so one can hold bytes after its NUL.
slots = [
  ["DATA1\0\0\0",     4],   # an ordinary name
  ["lower\0\0\0",     2],   # lower case, which the directory does not fold
  ["ab\0XyZ\0Q",      3],   # bytes AFTER the NUL, which are not the name
  ["MARK\0\0\0\0",    0],   # a zero-size marker
  ["DUP\0\0\0\0\0",   1],
  ["DUP\0\0\0\0\0",   5],   # the same name again: a lookup must find this one
]
data = +"".b
dir = +"".b
off = 12
slots.each do |slot, size|
  # a marker's pos is set to something nonzero on purpose: it must be carried
  pos = size.zero? ? 9999 : off + data.bytesize
  data << ("\x5a".b * size)
  dir << [pos, size].pack("l<l<") << slot.b
end
wad_bytes = "IWAD".b + [slots.length, 12 + data.bytesize].pack("l<l<") + data + dir

Dir.mktmpdir do |d|
  path = File.join(d, "synthetic.wad")
  File.binwrite(path, wad_bytes)
  w = Doom::Wad.new(path)

  puts "== a synthetic wad, for what doom1.wad cannot show =="
  check "it has the six entries written", w.count, 6

  names = full(w, "name", 8)
  check "the name array is eight bytes per entry", names.bytesize, 48
  check "a lower-case name is stored lower case",
        names.byteslice(8, 8), "lower\0\0\0".b
  check "a slot with bytes after its NUL stores only the name, zero-padded",
        names.byteslice(16, 8), "ab\0\0\0\0\0\0".b
  check "and not the raw slot",
        names.byteslice(16, 8) == "ab\0XyZ\0Q".b, false
  check "the reference builds the same name bytes, separately",
        ref(w, "name"), names

  pos = full(w, "pos")
  check "a zero-size marker keeps its position, not a zero", pos[3], 9999
  check "and the reference agrees", ref(w, "pos")[3], 9999
  check "sizes are carried per entry", full(w, "size"), [4, 2, 3, 0, 1, 5]
  check "and the reference agrees", ref(w, "size"), [4, 2, 3, 0, 1, 5]

  check "both DUP entries are present at their own indices",
        [names.byteslice(32, 8), names.byteslice(40, 8)], ["DUP\0\0\0\0\0".b] * 2
  check "and the name lookup resolves to the LAST one", w.index_of("DUP"), 5
  check "a name lookup is case-sensitive", w.index_of("LOWER"), -1
end

# --- the name-byte count, at its bound ------------------------------------
# Only numbers: nothing of either size is allocated. The bound is the byte
# length a buffer may have, U64_MAX, so the largest count is U64_MAX / 8.
puts "== the name-byte count is bounded before it is multiplied =="
def refusal(count)
  RES.lump_name_bytes(count)
  "accepted"
rescue RES::PreparationError => e
  e.message
end
max = RES::U64_MAX / 8
check "the largest count is 2305843009213693951", max, 2_305_843_009_213_693_951
check "which is accepted, just inside U64_MAX", RES.lump_name_bytes(max), 18_446_744_073_709_551_608
check "and one more is refused before the product",
      refusal(max + 1),
      "2305843009213693952 lumps need 8 * 2305843009213693952 name bytes, " \
      "more than 18446744073709551615; the most is 2305843009213693951"
check "a negative count is refused", refusal(-1),
      "a lump count must be a non-negative Integer, not -1"
check "and so is one that is not an Integer", refusal(nil),
      "a lump count must be a non-negative Integer, not nil"
check "an empty directory has no name bytes", RES.lump_name_bytes(0), 0

# --- the real IWAD --------------------------------------------------------
if (iwad = ARGV[0]) && File.exist?(iwad)
  puts "== the real directory =="
  w = Doom::Wad.new(iwad)
  n = w.count
  names = full(w, "name", 8)
  check "every entry has eight name bytes", names.bytesize, 8 * n
  check "Full and the reference build the same name bytes", ref(w, "name"), names
  pos = full(w, "pos")
  size = full(w, "size")
  check "and the same positions", ref(w, "pos"), pos
  check "and the same sizes", ref(w, "size"), size
  mismatch = (0...n).count do |i|
    l = w.lump(i)
    pos[i] != l.pos || size[i] != l.size ||
      names.byteslice(8 * i, 8) != l.name.b + ("\0".b * (8 - l.name.bytesize))
  end
  check "every one of the #{n} entries matches its Lump", mismatch, 0
  thing_idx = (0...n).select { |i| w.lump(i).name == "THINGS" }
  check "THINGS appears once per map", thing_idx.length, 9
  check "and its lookup resolves to the last", w.index_of("THINGS"), thing_idx.last
  e = w.index_of("E1M1")
  check "the E1M1 marker has size 0", size[e], 0
  check "and keeps its position 67500", pos[e], 67_500
  check "the last entry is carried like the rest",
        [pos[n - 1], size[n - 1]],
        [w.lump(n - 1).pos, w.lump(n - 1).size]
end

puts "lump-directory: #{$fails.zero? ? 'all pass' : "#{$fails} fail"}"
exit($fails.zero? ? 0 : 1)
