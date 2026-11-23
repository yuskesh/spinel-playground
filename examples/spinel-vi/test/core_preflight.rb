# spinel-tier: full
# E101 small-stage feasibility baseline. This is intentionally not a claim
# about the deferred 10 MiB / 100000-operation target.
require_relative "../lib/editor_core"

original = "0123456789abcdef" * 4096 # 64 KiB
table = SpinelVi::PieceTable.new(original)
i = 0
while i < 1000
  pos = (i * 37) % (table.length + 1)
  table.insert(pos, "Z")
  table.delete(pos, 1)
  i += 1
end

puts "preflight bytes=#{table.length} ops=#{i} added=#{table.added.bytesize} pieces=#{table.pieces.length} valid=#{table.check_invariants}"
