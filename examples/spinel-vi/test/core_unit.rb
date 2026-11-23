# spinel-tier: full
# Minimal deterministic fixture for the TUI-independent Phase 1 core.
require_relative "../lib/editor_core"

table = SpinelVi::PieceTable.new("one\ntwo\n")
table.insert(3, "!")
table.delete(0, 1)
table.insert(table.length, "\x00z")

cursor = SpinelVi::Cursor.new
cursor.move_to(4, table)

puts "text=#{table.materialize.inspect}"
puts "slice=#{table.slice(2, 4).inspect}"
puts "length=#{table.length} pieces=#{table.pieces.length}"
puts "line=#{cursor.line(table)} column=#{cursor.column(table)}"
puts "find=#{table.find_piece(0)}"
puts "invariants=#{table.check_invariants}"

table.delete(0, table.length)
puts "empty=#{table.empty?} pieces=#{table.pieces.length} lines=#{table.line_index.line_count}"

begin
  table.find_piece(0)
rescue IndexError
  puts "empty-find=loud"
end
