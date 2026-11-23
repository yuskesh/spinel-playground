# frozen_string_literal: true
#
# tests/doom-core/core-state.rb — the shared scalar buffer, assembled by Full.
#
#   ruby tests/doom-core/core-state.rb
#
# Scalars share one i64 buffer, `core_state`. `state-schema.rb` writes each
# slot's index and initial -- a fill or `prepared:NAME` -- to `slots.tsv`, and
# `Doom::Core::Resources.core_state` assembles the buffer from it before the
# session opens. These are its controls, on slot tables written here, with
# expectations written here: the values a slot must hold, the neighbours it
# must not touch, and every malformed table refused by name before a byte is
# packed.
ROOT = File.expand_path("../..", __dir__)
require_relative File.join(ROOT, "examples/doom/core/full/session")
require_relative File.join(ROOT, "examples/doom/core/full/resources")
require "tmpdir"

RES = Doom::Core::Resources
$fails = 0
def check(label, got, want)
  ok = got == want
  $fails += 1 unless ok
  puts format("%-4s %s%s", ok ? "pass" : "FAIL", label, ok ? "" : " (got #{got.inspect}, want #{want.inspect})")
end

HEADER = "#field\tindex\tinitial\torigin\n"
def table(dir, name, body, header: HEADER)
  path = File.join(dir, "#{name}.tsv")
  File.write(path, "# a slot table written by core-state.rb\n" + header + body)
  path
end

def row(field, index, initial) = "#{field}\t#{index}\t#{initial}\tX@@#{field}\n"
def i64(v) = [v].pack("q<")

# The message a refusal gives, or "accepted". Any OTHER error is reported with
# its class, so a check that stopped refusing and crashed instead fails by name
# rather than taking the whole run down.
def refusal
  yield
  "accepted"
rescue RES::PreparationError, Doom::Core::SessionError => e
  e.message.sub(/\A.*?\.tsv(:\d+)?: /, "")
rescue StandardError => e
  "#{e.class}: #{e.message}"
end

# A value, or the error that replaced it.
def value
  yield
rescue StandardError => e
  "#{e.class}: #{e.message}"
end

Dir.mktmpdir do |d|
  puts "== each slot holds its own initial =="
  good = table(d, "good", row("a", 0, "0") + row("b", 1, "-1") + row("c", 2, "97") +
                          row("d", 3, "prepared:d_start") + row("e", 4, "0"))
  bytes = RES.core_state(slots: good, count: 5, prepared: { "d_start" => i64(2_686_976) })
  vals = bytes.unpack("q<*")
  check "five slots, forty bytes", bytes.bytesize, 40
  check "a fill of -1 is -1, not 0", vals[1], -1
  check "a nonzero fill is that value", vals[2], 97
  check "a prepared scalar is the eight bytes Full has", vals[3], 2_686_976
  check "and the slots beside them are untouched", [vals[0], vals[4]], [0, 0]
  check "an i64 edge survives", RES.core_state(
    slots: table(d, "edge", row("lo", 0, "-9223372036854775808") + row("hi", 1, "9223372036854775807")),
    count: 2, prepared: {}).unpack("q<*"), [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807]
  # The index, not the row order, decides the cell.
  shuffled = table(d, "shuffled", row("z", 1, "5") + row("y", 0, "-7"))
  check "rows out of order go to their own indices",
        RES.core_state(slots: shuffled, count: 2, prepared: {}).unpack("q<*"), [-7, 5]

  puts "== and a table that cannot say that is refused before packing =="
  check "a prepared scalar Full did not prepare",
        refusal { RES.core_state(slots: good, count: 5, prepared: {}) },
        "d (slot 3) wants prepared:d_start, which Full did not prepare"
  check "a prepared scalar of seven bytes",
        refusal { RES.core_state(slots: good, count: 5, prepared: { "d_start" => "\0" * 7 }) },
        "d (slot 3): prepared:d_start is 7 byte(s), and a scalar slot is 8"
  check "and of nine",
        refusal { RES.core_state(slots: good, count: 5, prepared: { "d_start" => "\0" * 9 }) },
        "d (slot 3): prepared:d_start is 9 byte(s), and a scalar slot is 8"
  check "a slot count that is not the buffer's",
        refusal { RES.core_state(slots: good, count: 6, prepared: { "d_start" => i64(0) }) },
        "core_state holds 6 and #{good} lists 5 slot(s)"
  check "a fill outside i64",
        refusal { RES.core_state(slots: table(d, "big", row("a", 0, "9223372036854775808")), count: 1, prepared: {}) },
        "a (slot 0): 9223372036854775808 is outside i64"
  check "one prepared name claimed by two slots",
        refusal { RES.core_state(slots: table(d, "twice", row("a", 0, "prepared:p") + row("b", 1, "prepared:p")),
                                 count: 2, prepared: { "p" => i64(1) }) },
        "prepared:p is claimed by a and b"
  check "a missing slot",
        refusal { RES.core_state(slots: table(d, "gap", row("a", 0, "0") + row("b", 2, "0")), count: 2, prepared: {}) },
        "2 slot(s) and no slot 1; indices must be 0 to 1"
  check "two fields in one slot",
        refusal { RES.core_state(slots: table(d, "dupidx", row("a", 0, "0") + row("b", 0, "0")), count: 2, prepared: {}) },
        "b and a both claim slot 0"
  check "one field in two slots",
        refusal { RES.core_state(slots: table(d, "dupfield", row("a", 0, "0") + row("a", 1, "0")), count: 2, prepared: {}) },
        "a is listed twice"
  check "an index that is not a number",
        refusal { RES.core_state(slots: table(d, "badidx", row("a", "x", "0")), count: 1, prepared: {}) },
        "a: index \"x\" is not a non-negative integer"
  check "a negative index",
        refusal { RES.core_state(slots: table(d, "negidx", row("a", "-1", "0")), count: 1, prepared: {}) },
        "a: index \"-1\" is not a non-negative integer"
  check "an initial that is neither",
        refusal { RES.core_state(slots: table(d, "badinit", row("a", 0, "zero")), count: 1, prepared: {}) },
        "a: initial \"zero\" is neither an integer nor prepared:NAME"
  check "a row of the wrong width",
        refusal { RES.core_state(slots: table(d, "width", "a\t0\t0\n"), count: 1, prepared: {}) },
        "3 column(s), want 4"
  check "the old two-column table",
        refusal { RES.core_state(slots: table(d, "old", "a\t0\n", header: "#field\tindex\n"), count: 1, prepared: {}) },
        "columns field, index, want field, index, initial, origin"

  puts "== the session reads the same table, and only one that fits =="
  buf = File.join(d, "buffers.tsv")
  File.write(buf, "#name\trole\telement\tcount\tinitial\ncore_state\tpersistent\ti64\t5\tprepared:core_state\n")
  s = Doom::Core::Session.open(buffers: buf, slots: good, prepared: { "core_state" => bytes })
  layout = [{ "field" => "c", "element" => "i64", "count" => 1, "bytes" => 8 },
            { "field" => "b", "element" => "i64", "count" => 1, "bytes" => 8 },
            { "field" => "d", "element" => "i64", "count" => 1, "bytes" => 8 }]
  check "a snapshot reads each scalar at its own slot", value { s.snapshot(layout).unpack("q<*") }, [97, -1, 2_686_976]

  # A MANIFEST THAT DOES NOT DESCRIBE THE SLOT BUFFER IS REFUSED AT `open`,
  # BEFORE ANYTHING IS ALLOCATED -- not left to fail later at a snapshot, and
  # not opened with the slots' initials lost. `Session.new` is what allocates,
  # so it is watched: a refusal here must come before it is ever called.
  S = Doom::Core::Session
  allocations = 0
  real_new = S.method(:new)
  S.define_singleton_method(:new) { |*a| allocations += 1; real_new.call(*a) }
  opened = lambda do |row, prepared|
    File.write(buf, "#name\trole\telement\tcount\tinitial\n#{row}\n")
    before = allocations
    msg = refusal { S.open(buffers: buf, slots: good, prepared: prepared) }
    [msg, allocations - before]
  end
  check "the generated form opens, and allocates once",
        opened.call("core_state\tpersistent\ti64\t5\tprepared:core_state", { "core_state" => bytes }),
        ["accepted", 1]
  check "a slot table that is not the buffer's length is refused before allocation",
        opened.call("core_state\tpersistent\ti64\t4\tprepared:core_state", { "core_state" => bytes.byteslice(0, 32) }),
        ["core_state holds 4 and #{good} lists 5 slot(s)", 0]
  check "a u8 core_state is refused before allocation",
        opened.call("core_state\tpersistent\tu8\t5\tprepared:core_state", { "core_state" => "\0" * 5 }),
        ["core_state is u8; every slot is one i64", 0]
  check "the old zero-filled core_state is refused, not opened with -1 lost",
        opened.call("core_state\tpersistent\ti64\t5\t0", {}),
        ["core_state opens as 0, which would drop each slot's own initial; it must be prepared:core_state", 0]
  check "a core_state that is not persistent is refused",
        opened.call("core_state\tscratch\ti64\t5\tprepared:core_state", { "core_state" => bytes }),
        ["core_state is scratch; the slot buffer is persistent", 0]
  check "a slot table with no core_state is refused",
        opened.call("other\tpersistent\ti64\t5\t0", {}),
        ["#{good} lists 5 slot(s) and the manifest has 0 core_state buffer(s)", 0]
  S.singleton_class.send(:remove_method, :new)
end

puts "core-state: #{$fails.zero? ? 'all pass' : "#{$fails} fail"}"
exit($fails.zero? ? 0 : 1)
