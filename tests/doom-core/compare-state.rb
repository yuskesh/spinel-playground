# frozen_string_literal: true
#
# tests/doom-core/compare-state.rb — decision 0008 task 5's snapshot comparator.
#
#   ruby tests/doom-core/compare-state.rb --layout FILE --a FILE --b FILE
#                                         [--label-a NAME --label-b NAME]
#
# Two canonical snapshots of the same schema, compared field by field. The
# layout is `snapshot.tsv` as tools/doom/state-schema.rb generated it: schema
# order, fixed width, little endian, no padding, no addresses, no scratch.
#
# WHAT IT REPORTS IS THE FIRST DIFFERENCE, and it names the field, the index
# within it and -- when the snapshots carry one -- the tic. A comparator that
# printed a count of differing bytes would say two runs disagree without
# saying where, and the whole point of a canonical layout is that "where" is a
# field and an index rather than an offset into someone's struct.
#
# A MISSING, DUPLICATE OR EXTRA RECORD IS A FAILURE, not a smaller comparison.
# Two snapshots that agree on the fields they both have, while one of them is
# missing a field, are not equal; they are incomparable, and saying so is the
# only honest answer.

require "optparse"

PROG = "compare-state"

opt = { label_a: "a", label_b: "b" }
OptionParser.new do |o|
  o.on("--layout FILE") { |v| opt[:layout] = v }
  o.on("--a FILE") { |v| opt[:a] = v }
  o.on("--b FILE") { |v| opt[:b] = v }
  o.on("--label-a NAME") { |v| opt[:label_a] = v }
  o.on("--label-b NAME") { |v| opt[:label_b] = v }
  o.on("--tic N", Integer) { |v| opt[:tic] = v }
end.parse!

CATEGORIES = %w[usage layout length record value].freeze
def refuse(category, message)
  CATEGORIES.include?(category) or raise "unknown category #{category.inspect}"
  warn("#{PROG}: #{category}: #{message}")
  exit(1)
end

%i[layout a b].each { |k| opt[k] or refuse("usage", "--#{k} is required") }
[opt[:layout], opt[:a], opt[:b]].each do |f|
  File.exist?(f) or refuse("usage", "no file at #{f}")
end

WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
SIGNED = { "u8" => false, "i8" => true, "u16" => false, "i16" => true, "i32" => true, "u32" => false, "i64" => true }.freeze

fields = []
seen = {}
offset = 0
declared_total = nil
File.foreach(opt[:layout]).with_index(1) do |ln, i|
  if ln.start_with?("#total\t")
    declared_total = ln.chomp.split("\t", -1)[3].to_i
    next
  end
  next if ln.start_with?("#") || ln.strip.empty?
  f = ln.chomp.split("\t", -1)
  f.length == 5 or refuse("layout", "#{opt[:layout]}:#{i}: #{f.length} column(s), want 5")
  name, element, count, bytes, at = f
  WIDTH.key?(element) or refuse("layout", "#{opt[:layout]}:#{i}: element #{element.inspect} is not one of #{WIDTH.keys.join(', ')}")
  seen[name] and
    refuse("record", "#{opt[:layout]}:#{i}: #{name} appears twice in the layout, at line #{seen[name]} and here")
  seen[name] = i
  n = Integer(count, 10)
  want_bytes = n * WIDTH[element]
  Integer(bytes, 10) == want_bytes or
    refuse("layout", "#{opt[:layout]}:#{i}: #{name} says #{bytes} bytes and #{n} x #{element} is #{want_bytes}")
  # The offsets are the running sum, with nothing skipped and nothing padded.
  # Checked here rather than trusted, because a layout with a gap would make
  # every field after it compare the wrong bytes and still look plausible.
  Integer(at, 10) == offset or
    refuse("layout", "#{opt[:layout]}:#{i}: #{name} begins at #{at} and the fields before it end at #{offset}")
  fields << { "name" => name, "element" => element, "count" => n,
              "bytes" => want_bytes, "offset" => offset }
  offset += want_bytes
end
fields.empty? and refuse("layout", "the layout describes no fields")
if declared_total && declared_total != offset
  refuse("layout", "the layout's own total is #{declared_total} and its fields are #{offset} bytes")
end

a = File.binread(opt[:a])
b = File.binread(opt[:b])
[[opt[:label_a], opt[:a], a], [opt[:label_b], opt[:b], b]].each do |label, path, bytes|
  next if bytes.bytesize == offset
  refuse("length", "#{label} (#{path}) is #{bytes.bytesize} bytes and the layout describes #{offset}")
end

def read_at(bytes, at, element)
  case element
  when "u8" then bytes.getbyte(at)
  when "i8" then bytes.byteslice(at, 1).unpack1("c")
  when "u16" then bytes.byteslice(at, 2).unpack1("S<")
  when "i16" then bytes.byteslice(at, 2).unpack1("s<")
  when "i32" then bytes.byteslice(at, 4).unpack1("l<")
  when "u32" then bytes.byteslice(at, 4).unpack1("L<")
  else bytes.byteslice(at, 8).unpack1("q<")
  end
end

where = opt[:tic] ? " at tic #{opt[:tic]}" : ""
fields.each do |f|
  w = WIDTH[f["element"]]
  # The whole field first: most fields agree, and comparing the slice is one
  # memcmp rather than `count` unpacks. The per-element walk below only runs
  # where they differ, which is where the index has to be exact.
  next if a.byteslice(f["offset"], f["bytes"]) == b.byteslice(f["offset"], f["bytes"])
  (0...f["count"]).each do |i|
    at = f["offset"] + i * w
    va = read_at(a, at, f["element"])
    vb = read_at(b, at, f["element"])
    next if va == vb
    refuse("value",
           "#{f['name']}[#{i}]#{where}: #{opt[:label_a]} has #{va} and #{opt[:label_b]} has #{vb} " \
           "(#{f['element']}, byte #{at})")
  end
  # The slices differ and no element does, which can only happen if the layout
  # and the reader disagree about the element width.
  refuse("layout",
         "#{f['name']} differs as bytes and agrees as #{f['element']} elements; " \
         "the layout's width for it is wrong")
end

puts "#{PROG}: #{fields.length} field(s), #{offset} bytes, #{opt[:label_a]} and #{opt[:label_b]} agree#{where}"
