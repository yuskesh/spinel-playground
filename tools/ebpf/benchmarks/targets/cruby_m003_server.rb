# benchmarks/targets/cruby_m003_server.rb
#
# Plain CRuby HTTP/1.0 server with fork-based workers + SO_REUSEPORT.
# Mirrors examples/http_server/M003/server.rb so the comparison stays
# honest. Each worker creates its own listening socket on the same
# port; the kernel sk_reuseport_default does the per-syn fanout.
#
# Run (4 workers, default):
#   ruby benchmarks/targets/cruby_m003_server.rb
# Run with custom worker count:
#   SPINEL_HTTP_WORKERS=8 ruby benchmarks/targets/cruby_m003_server.rb
# Stop: Ctrl+C (parent forwards SIGTERM to workers via process group)

# A CRuby target for comparing another implementation's performance with: an
# oracle under AGENTS.md, so it serves only on the owner's instruction.
require_relative "../../../oracle/gate"
exit 0 unless OracleGate.allow?("tools/ebpf/benchmarks/targets/cruby_m003_server.rb", "whole")
require "socket"

PORT    = (ENV["SPINEL_HTTP_PORT"]    || "8080").to_i
WORKERS = (ENV["SPINEL_HTTP_WORKERS"] || "4").to_i

def build_response(status, body)
  "HTTP/1.0 #{status}\r\n" \
    "Content-Type: text/plain\r\n" \
    "Content-Length: #{body.bytesize}\r\n" \
    "Connection: close\r\n" \
    "\r\n" \
    "#{body}"
end

def route(verb, path)
  return build_response("400 Bad Request",        "Bad Request\n")        if verb.nil? || path.nil?
  return build_response("405 Method Not Allowed", "Method Not Allowed\n") if verb != "GET"
  return build_response("200 OK",                 "hello\n")              if path == "/"
  return build_response("200 OK",                 "OK\n")                 if path == "/health"
  build_response("404 Not Found", "Not Found\n")
end

def worker_loop(idx)
  sock = Socket.new(:INET, :STREAM, 0)
  sock.setsockopt(:SOCKET, :REUSEPORT, 1)
  sock.setsockopt(:SOCKET, :REUSEADDR, 1)
  sock.bind(Socket.pack_sockaddr_in(PORT, "127.0.0.1"))
  sock.listen(1024)
  puts "[server] CRuby M003 worker #{idx} PID #{Process.pid} on 127.0.0.1:#{PORT}"

  loop do
    client, _ = sock.accept
    request_line = client.gets("\r\n") || ""
    verb, path, _ = request_line.split(" ", 3)
    loop do
      line = client.gets("\r\n")
      break if line.nil? || line == "\r\n" || line.empty?
    end
    client.write(route(verb, path))
    client.close
  end
end

# Parent: spawn workers, wait for any to die, kill the rest.
Process.setpgrp
pids = WORKERS.times.map do |i|
  fork { worker_loop(i) }
end
puts "[server] parent PID #{Process.pid}, #{WORKERS} workers spawned: #{pids.inspect}"

trap("INT")  { pids.each { |p| Process.kill("TERM", p) rescue nil }; exit(0) }
trap("TERM") { pids.each { |p| Process.kill("TERM", p) rescue nil }; exit(0) }

pids.each { |p| Process.wait(p) rescue nil }
