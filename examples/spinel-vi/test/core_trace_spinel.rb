# Same fixed operation trace as core_flat_oracle.rb, applied to PieceTable.
# Kept separate to preserve differential independence.
# spinel-tier: full
require_relative "../lib/editor_core"

def digest(text)
  h = 1469598103934665603
  i = 0
  while i < text.bytesize
    h = ((h ^ text.getbyte(i)) * 1099511628211) & 0xffffffffffffffff
    i += 1
  end
  lines = 1
  i = 0
  while i < text.bytesize
    lines += 1 if text.getbyte(i) == 10
    i += 1
  end
  [text.bytesize, h, lines]
end

def line_starts_digest(index)
  h = 1469598103934665603
  line = 0
  while line < index.line_count
    h = ((h ^ index.line_start(line)) * 1099511628211) & 0xffffffffffffffff
    line += 1
  end
  [index.line_count, h]
end

SEEDS = [1, 17, 49374]
INITIALS = ["", "one\ntwo\n", "abcd\x00\n\x00ef"]
si = 0
while si < SEEDS.length
  seed = SEEDS[si]
  initial = INITIALS[si]
  table = SpinelVi::PieceTable.new(initial)
  cursor = SpinelVi::Cursor.new
  state = seed
  step = 0
  while step < 160
    state = (state * 1103515245 + 12345) & 0x7fffffff
    if state % 4 == 0 || table.length == 0
      pos = state % (table.length + 1)
      payloads = ["", "A", "xy", "\n", "\x00Z", "q\nR"]
      bytes = payloads[(state >> 8) % payloads.length]
      table.insert(pos, bytes)
      cursor.move_to(pos + bytes.bytesize, table)
    else
      pos = state % table.length
      count = 1 + ((state >> 7) % (table.length - pos))
      table.delete(pos, count)
      cursor.move_to(pos, table) if cursor.offset > pos
      cursor.move_to(pos, table) if cursor.offset > pos + count
    end
    cursor.move_to(table.length, table) if cursor.offset > table.length
    text = table.slice(0, table.length)
    d = digest(text)
    starts = line_starts_digest(table.line_index)
    puts "#{seed},#{step},#{d[0]},#{d[1]},#{d[2]},#{cursor.offset},#{cursor.line(table)},#{cursor.column(table)},#{starts[0]},#{starts[1]}"
    step += 1
  end
  si += 1
end
