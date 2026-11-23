# Ordinary Ruby. Nothing here mentions the configuration it is built under.
# It allocates, retains some of what it allocates for the whole run, and prints
# results that depend on everything having stayed alive.
$kept = []
def build(n)
  rows = []
  n.times do |i|
    rows << { "id" => i, "name" => "row-#{i}", "tags" => ["a", "b", i.to_s] }
  end
  rows
end
rows = build(2000)
$kept << rows.first
$kept << rows.last
2000.times { |i| "garbage #{i}" }        # allocated and dropped
puts rows.length
puts rows.map { |r| r["name"].length }.sum
puts rows.select { |r| r["id"] % 500 == 0 }.map { |r| r["id"] }.inspect
puts $kept.first["name"]
puts $kept.last["name"]
h = Hash.new(0)
rows.each { |r| r["tags"].each { |t| h[t] += 1 } }
puts h["a"]
