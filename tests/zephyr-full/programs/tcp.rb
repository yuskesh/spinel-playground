# A TCP round trip through Zephyr's sockets and picolibc's stdio: one line to
# the echo peer (tests/zephyr-full/echo-peer.rb) and its echo back. The peer's
# address comes from the build (spinel-zephyr-full --peer HOST:PORT).
require "socket"
host, port = ENV.fetch("ZFULL_PEER").split(":")
s = TCPSocket.new(host, port.to_i)
s.write("hello from spinel\n")
puts s.gets
s.close
puts "closed"
