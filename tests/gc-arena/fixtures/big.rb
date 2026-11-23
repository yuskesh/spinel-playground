n = (ARGV[0] || "10").to_i
a = []
n.times { a << "x" * 1_000_000 }
puts a.length
