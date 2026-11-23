# spinel-tier: full
# Independent E101 oracle. This file deliberately does not inspect PieceTable
# internals: it models the same byte edits with flat String reconstruction.
require_relative "../lib/editor_core"

class FlatOracle
  attr_reader :text

  def initialize(text)
    @text = text.dup
  end

  def insert(pos, bytes)
    @text = @text.byteslice(0, pos).to_s + bytes + @text.byteslice(pos, @text.bytesize - pos).to_s
  end

  def delete(pos, count)
    @text = @text.byteslice(0, pos).to_s + @text.byteslice(pos + count, @text.bytesize - pos - count).to_s
  end
end

def check_equal(table, oracle, label)
  got = table.materialize
  raise "#{label}: text mismatch" unless got == oracle.text
  raise "#{label}: length mismatch" unless table.length == oracle.text.bytesize
  raise "#{label}: invariant failure" unless table.check_invariants
  li = table.line_index
  expected_lines = 1
  i = 0
  while i < oracle.text.bytesize
    expected_lines += 1 if oracle.text.getbyte(i) == 10
    i += 1
  end
  raise "#{label}: line count mismatch" unless li.line_count == expected_lines
  off = 0
  while off <= oracle.text.bytesize
    expected_line = 0
    j = 0
    while j < off
      expected_line += 1 if oracle.text.getbyte(j) == 10
      j += 1
    end
    raise "#{label}: line lookup mismatch" unless li.line_at(off) == expected_line
    off += 1
  end
end

def run_seed(seed, initial)
  table = SpinelVi::PieceTable.new(initial)
  oracle = FlatOracle.new(initial)
  state = seed
  check_equal(table, oracle, "seed=#{seed}:initial")
  step = 0
  while step < 160
    state = (state * 1103515245 + 12345) & 0x7fffffff
    if state % 4 == 0 || oracle.text.bytesize == 0
      pos = state % (oracle.text.bytesize + 1)
      payloads = ["", "A", "xy", "\n", "\x00Z", "q\nR"]
      bytes = payloads[(state >> 8) % payloads.length]
      table.insert(pos, bytes)
      oracle.insert(pos, bytes)
      op = "insert(#{pos},#{bytes.bytesize})"
    else
      pos = state % oracle.text.bytesize
      count = 1 + ((state >> 7) % (oracle.text.bytesize - pos))
      table.delete(pos, count)
      oracle.delete(pos, count)
      op = "delete(#{pos},#{count})"
    end
    check_equal(table, oracle, "seed=#{seed}:step=#{step}:#{op}")
    step += 1
  end
  puts "PASS seed=#{seed} bytes=#{oracle.text.bytesize} pieces=#{table.pieces.length}"
end

SEEDS = [1, 17, 49374]
INITIALS = ["", "one\ntwo\n", "abcd\x00\n\x00ef"]
si = 0
while si < SEEDS.length
  run_seed(SEEDS[si], INITIALS[si])
  si += 1
end
