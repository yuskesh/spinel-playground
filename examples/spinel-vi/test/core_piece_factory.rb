# spinel-tier: full
# The private factory is the sole Piece construction boundary. Non-integer
# values must fail before its .to_i calls can silently coerce them.
require_relative "../lib/editor_core"

table = SpinelVi::PieceTable.new("x")

begin
  table.send(:make_piece, "0", 0, 1)
rescue TypeError
  puts "factory-source=loud"
end

begin
  table.send(:make_piece, 0, 0.5, 1)
rescue TypeError
  puts "factory-offset=loud"
end

begin
  table.send(:make_piece, 0, 0, nil)
rescue TypeError
  puts "factory-length=loud"
end
