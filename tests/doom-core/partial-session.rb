# frozen_string_literal: true
#
# tests/doom-core/partial-session.rb — the produced bytes through a real session.
#
#   ruby tests/doom-core/partial-session.rb BUFFERS PART_LAYOUT PART_BIN OUT_BUFFERS OUT_BIN [CORRUPT] [DROP]
#
# `Session.open` refuses a prepared name it was given no bytes for, so a
# session over the PRODUCTION schema cannot be opened until Full produces all
# 226. This opens one over a TEST-ONLY SUBSET instead: the fields Full does
# produce, their buffers selected out of the generated `buffers.tsv`, and their
# independently produced bytes handed in as prepared data.
#
# WHAT IT SHOWS: those bytes reach a real `Session`, survive
# `Session#snapshot` at the canonical layout, and come out equal to the
# original's.
#
# WHAT IT DOES NOT SHOW: anything about the whole DOOM initial state. It opens
# only the prepared fields -- persistent ones among them, and prepared scalars
# through a `core_state` Full assembles from every slot -- with no adapter and
# no game, and the fields whose initial is a fill are not in it. A subset
# opening is not the schema being accepted.
#
# CORRUPT is `field:index`, damaged BEFORE the session receives it, so the
# comparison downstream has to name that field and index. DROP is a prepared
# name withheld, so the session's own refusal is exercised.
ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/session")
require_relative File.join(ROOT, "examples/doom/core/full/reference")
S = Doom::Core::Session
R = Doom::Core::Reference
W = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze

PROG = File.basename(__FILE__)
unless (5..7).cover?(ARGV.length)
  abort("usage: #{PROG} BUFFERS PART_LAYOUT PART_BIN OUT_BUFFERS OUT_BIN [CORRUPT] [DROP]")
end
buffers, part_layout, part_bin, out_buffers, out_bin, corrupt, drop = ARGV

layout = R.read_layout(part_layout)
names = layout.map { |f| f["field"] }

# THE THREE SETS MUST BE THE SAME SET. The layout's fields, the buffers
# selected for them, and the prepared names handed over are three lists that
# could disagree; a session that opened over two of them and compared the
# third would be measuring something nobody named.
rows = S.read_buffers(buffers)
# A SCALAR is not a buffer: it is a slot in `core_state`, listed in the
# slots.tsv beside BUFFERS. A prepared scalar in the layout is carried like a
# prepared array, and `core_state` is then assembled by Full from every slot
# -- fills from the table, prepared scalars from these bytes -- so a slot the
# layout does not carry and the table does not fill is refused, not zeroed.
slots_path = File.join(File.dirname(buffers), "slots.tsv")
slot_rows = File.exist?(slots_path) ? S.read_slots(slots_path) : {}
selected = rows.select { |r| names.include?(r["name"]) }
scalar_units = names.select { |n| slot_rows.key?(n) }.map do |n|
  { "name" => n, "element" => "i64", "count" => 1, "initial" => slot_rows[n]["initial"] }
end
missing = names - selected.map { |r| r["name"] } - scalar_units.map { |r| r["name"] }
missing.empty? or
  abort("#{PROG}: #{missing.length} field(s) in the layout have no buffer: " +
        missing.first(3).join(", "))

# The bytes, cut from the produced snapshot at the layout's own offsets.
blob = File.binread(part_bin)
blob.bytesize == layout.sum { |f| f["bytes"] } or
  abort("#{PROG}: #{part_bin} is #{blob.bytesize} byte(s) and the layout describes " \
        "#{layout.sum { |f| f['bytes'] }}")
prepared = {}
prepared_of = {}
(selected + scalar_units).each do |r|
  r["initial"].to_s.start_with?("prepared:") or
    abort("#{PROG}: #{r['name']} is not a prepared field; this lane only carries those")
  prepared_of[r["name"]] = r["initial"].sub("prepared:", "")
end
layout.each do |f|
  prepared[prepared_of[f["field"]]] = blob.byteslice(f["offset"], f["bytes"])
end

if corrupt && !corrupt.empty?
  fname, idx = corrupt.split(":")
  idx = Integer(idx, 10)
  row = layout.find { |f| f["field"] == fname } or abort("#{PROG}: no #{fname} here")
  data = prepared[prepared_of[fname]].dup
  o = idx * W[row["element"]]
  o + W[row["element"]] <= data.bytesize or abort("#{PROG}: #{fname}[#{idx}] is past the end")
  data.setbyte(o, data.getbyte(o) ^ 0xff)
  prepared[prepared_of[fname]] = data
  warn("#{PROG}: corrupted #{fname}[#{idx}] before the session received it")
end
prepared.delete(prepared_of[drop]) if drop && !drop.empty?

shared = nil
unless scalar_units.empty?
  require_relative File.join(ROOT, "examples/doom/core/full/resources")
  shared = rows.find { |r| r["name"] == "core_state" } or
    abort("#{PROG}: the layout carries scalar slots and #{buffers} has no core_state")
  prepared["core_state"] = Doom::Core::Resources.core_state(
    slots: slots_path, count: shared["count"], prepared: prepared)
end

# THE TEST MANIFEST `Session.open` READS. It has to exist before the session
# opens, because `Session.open` takes a PATH, so this is an input rather than
# a result and it is written here on purpose.
#
# WHAT THAT MEANS FOR A REFUSAL, precisely: the checks above leave nothing
# behind, and a DROP -- a prepared name withheld, refused by the session
# itself -- leaves this manifest written and NO SNAPSHOT. Measured: 3647 bytes
# of manifest, no `OUT_BIN`. An earlier version of this comment said a refusal
# leaves nothing behind, which is true of the checks above it and not of the
# session's own refusal below.
text = +"# Generated by #{PROG} -- a test-only subset, not the production schema.\n"
text << "#name\trole\telement\tcount\tinitial\n"
((shared ? [shared] : []) + selected).each do |r|
  text << [r["name"], r["role"], r["element"], r["count"], r["initial"]].join("\t") << "\n"
end
File.write(out_buffers, text)

sess = S.open(buffers: out_buffers, prepared: prepared, slots: shared ? slots_path : nil)
File.binwrite(out_bin, sess.snapshot(layout))
warn("#{PROG}: #{layout.length} field(s) through a real session, #{File.size(out_bin)} byte(s)")
