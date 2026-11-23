# Explicit release and exit processing: neither depends on the collector.
path = "/tmp/spinel_arena_res.txt"
File.open(path, "w") { |f| f.puts "written in a block" }
f = File.open(path, "r")
puts f.gets.chomp
f.close
puts f.closed?
at_exit { puts "at_exit ran" }
END { puts "END ran" }
puts "body done"
File.delete(path) if File.exist?(path)
