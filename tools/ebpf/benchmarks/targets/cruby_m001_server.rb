# benchmarks/targets/cruby_m001_server.rb
#
# Plain CRuby HTTP/1.0 server using stdlib only (TCPServer + IO#gets).
# Designed to mirror examples/http_server/M001/server.rb as closely as
# possible so the comparison stays honest:
#
#   - single accept loop (one process, no threads, no workers)
#   - HTTP/1.0 + `Connection: close` (no keepalive)
#   - same routes: GET / -> "hello\n", GET /health -> "OK\n",
#                   non-GET -> 405, unknown -> 404, malformed -> 400
#   - same one-write-per-response (Content-Length + Connection: close)
#
# Run:
#   ruby benchmarks/targets/cruby_m001_server.rb
# Stop: Ctrl+C

# A CRuby target for comparing another implementation's performance with: an
# oracle under AGENTS.md, so it serves only on the owner's instruction.
require_relative "../../../oracle/gate"
exit 0 unless OracleGate.allow?("tools/ebpf/benchmarks/targets/cruby_m001_server.rb", "whole")
require "socket"

PORT = (ENV["SPINEL_HTTP_PORT"] || "8080").to_i

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

server = TCPServer.new("127.0.0.1", PORT)
puts "[server] CRuby M001-equivalent HTTP/1.0 on 127.0.0.1:#{PORT} (PID #{Process.pid})"

loop do
  client = server.accept

  # Request line + drain header lines until blank.
  request_line = client.gets("\r\n") || ""
  verb, path, _ = request_line.split(" ", 3)
  loop do
    line = client.gets("\r\n")
    break if line.nil? || line == "\r\n" || line.empty?
  end

  client.write(route(verb, path))
  client.close
end
