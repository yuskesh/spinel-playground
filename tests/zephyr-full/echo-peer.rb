# tests/zephyr-full/echo-peer.rb -- the peer tcp.rb talks to: accepts a
# connection, reads one line, writes it back and closes; logs who connected.
#
#   ruby tests/zephyr-full/echo-peer.rb [PORT]   (default 7777)
require "socket"
port = Integer(ARGV.fetch(0, "7777"))
srv = TCPServer.new("0.0.0.0", port)
$stdout.sync = true
puts "listening #{port}"
loop do
  c = srv.accept
  puts "#{Time.now.strftime('%H:%M:%S')} from #{c.peeraddr[3]}"
  line = c.gets
  puts "got #{line.inspect}"
  c.write(line) if line
  c.close
end
