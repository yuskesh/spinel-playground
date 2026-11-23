# frozen_string_literal: true
#
# tests/doom-core/build-session.rb — the session's side of task 5's comparison.
#
#   ruby tests/doom-core/build-session.rb BUFFERS LAYOUT [OUT] [REF.bin] [CORRUPT]
#
# Opens a session over the generated buffers.tsv and writes its canonical
# snapshot.
#
# WITH A REFERENCE SNAPSHOT, the prepared fields carry REAL DATA: each one's
# bytes are sliced out of the original's snapshot at the layout's offset and
# handed to the session, which checks the length itself. Without one they are
# zeros, which is what this did before.
#
# WHAT THAT DOES AND DOES NOT CHECK. Prepared bytes come FROM the original, so
# comparing them back against the original cannot show that their VALUE is
# right -- it shows the TRANSPORT is: the right bytes reach the right field at
# the right offset with the right length. That is worth checking and it is not
# the same claim, so tests/doom-core/state.sh counts those fields separately
# rather than folding them into agreement.
#
# CORRUPT is `field:index`. It writes one wrong cell into that field's prepared
# data before the session receives it, so the comparison downstream has to name
# that field and index. Without it, a transport comparison whose two sides were
# cut from one buffer would agree no matter what the transport did.

ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/session")
require_relative File.join(ROOT, "examples/doom/core/full/reference")
S = Doom::Core::Session
R = Doom::Core::Reference
W = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }
buffers, layout_path, out, ref_path, corrupt = ARGV
rows = S.read_buffers(buffers)
layout_rows = R.read_layout(layout_path)
# Where each field's bytes sit in the canonical snapshot, so a prepared
# field's real data can be cut out of the original's.
at = {}
off = 0
layout_rows.each do |f|
  n = f["count"] * W[f["element"]]
  at[f["field"]] = [off, n]
  off += n
end
ref_bytes = ref_path && !ref_path.empty? ? File.binread(ref_path) : nil
# Which field each prepared NAME belongs to, so a slice can be found for it.
field_of = {}
rows.each do |r|
  next unless r["initial"].start_with?("prepared:")
  field_of[r["initial"].sub("prepared:", "")] = r["name"]
end
# THE SHARED SCALAR BUFFER IS NOT SLICED: Full assembles it from slots.tsv
# below. What IS sliced is each scalar that is itself `prepared:NAME` -- one
# i64 at its own field in the layout -- so a prepared scalar travels the same
# way as a prepared array, and CORRUPT can name it.
slots_path = File.join(File.dirname(buffers), "slots.tsv")
slot_rows = File.exist?(slots_path) ? S.read_slots(slots_path) : {}
units = rows.reject { |r| r["name"] == "core_state" }
slot_rows.each do |field, s|
  next unless s["initial"].start_with?("prepared:")
  units << { "name" => field, "element" => "i64", "count" => 1, "initial" => s["initial"] }
end
# Full hands over BYTES. The declared count is elements, so the prepared data
# for an i64 field of one element is eight bytes and not one.
prepared = {}
units.each do |r|
  next unless r["initial"].start_with?("prepared:")
  name = r["initial"].sub("prepared:", "")
  want = r["count"] * W[r["element"]]
  if ref_bytes
    # A REFERENCE WAS GIVEN, SO IT HAS TO SUPPLY THE BYTES. Falling back to
    # zeros here made an EMPTY reference file look like a successful run:
    # every prepared field quietly became zeros and the comparison downstream
    # compared zeros with zeros. Mac review of 4a8ba23 found it. If a slice
    # cannot be taken at the declared offset and length, that is a fact about
    # the reference and it is said out loud.
    o, n = at[r["name"]]
    o or abort("build-session: #{r['name']} is not in the layout")
    n == want or
      abort("build-session: #{r['name']}: the layout says #{n} bytes and the " \
            "buffer declares #{want}")
    slice = ref_bytes.byteslice(o, n)
    slice && slice.bytesize == n or
      abort("build-session: #{r['name']}: the reference has no #{n} bytes at #{o} " \
            "(it is #{ref_bytes.bytesize} bytes)")
    prepared[name] = slice
  else
    prepared[name] = "\0".b * want
  end
end
unless corrupt.nil? || corrupt.empty?
  fname, idx = corrupt.split(":")
  idx = Integer(idx, 10)
  row = units.find { |r| r["name"] == fname && r["initial"].start_with?("prepared:") }
  row or raise "no prepared field named #{fname.inspect}"
  name = row["initial"].sub("prepared:", "")
  w = W[row["element"]]
  data = prepared[name].dup
  o = idx * w
  o + w <= data.bytesize or raise "#{fname}[#{idx}] is past the end"
  # One cell, changed to something it is not. The width is the element's, so
  # the damage is a whole element rather than a byte inside one.
  old_cell = data.byteslice(o, w)
  data.setbyte(o, (data.getbyte(o) ^ 0xff))
  prepared[name] = data
  STDERR.puts "corrupted #{fname}[#{idx}] #{old_cell.unpack1('H*')} -> " \
              "#{data.byteslice(o, w).unpack1('H*')}"
end
if (shared = rows.find { |r| r["name"] == "core_state" })
  require_relative File.join(ROOT, "examples/doom/core/full/resources")
  prepared["core_state"] = Doom::Core::Resources.core_state(
    slots: slots_path, count: shared["count"], prepared: prepared)
end
sess = S.open(buffers: buffers, prepared: prepared, slots: slots_path)
snap = sess.snapshot(layout_rows)
puts "bytes #{snap.bytesize}"
puts "total #{sess.bytes_total}"
File.binwrite(out, snap) if out
