# E091 reject subject k3: the same collision spelled as a class, and in a file
# the entry only REQUIRES -- the check reads the whole resolved require graph
# (spinel-typedump ast), not just the entry.
require_relative "k3_lib"

puts Cloudflare.mine
