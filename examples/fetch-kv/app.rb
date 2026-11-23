# Outbound HTTP and a KV binding from Ruby, through the host bridge
# (R003 §2-4 layer 1, E014; namespaces are R016 T-4 as migrated by E091).
# Build with --host-api:
#
#   ../../tools/wasm/spinel-wasm examples/fetch.rb -o app.wasm --host-api
#
# and give the worker a KV namespace it may reach, in wrangler.toml:
#
#   [[kv_namespaces]]
#   binding = "MY_KV"
#   id = "..."
#   [vars]
#   SPINEL_HOST_KV = "MY_KV"      # reachability is an explicit decision
#
# One capability = one require: this program pays for edge/http, edge/kv and
# edge/cgi and for nothing else (E055).  Nothing here is asynchronous on the
# Ruby side -- the suspend happens under the module (JSPI), and this program is
# written exactly as it would be if the network were synchronous.
require "edge/cgi"
require "edge/http"
require "edge/kv"

req = Edge::CGI.request
target = ENV["FETCH_URL"].to_s
target = "https://example.com/" if target.empty?

unless Edge.available?
  puts "the host bridge is not installed (build with --host-api)"
  exit 1
end

case req.path
when "/kv"
  ns = ENV["SPINEL_HOST_KV"].to_s.split(",")[0].to_s.strip
  if ns.empty?
    puts "no KV namespace is reachable; set SPINEL_HOST_KV in wrangler.toml"
    exit 1
  end
  hits = Edge::KV.get(ns, "hits").to_i + 1
  Edge::KV.put(ns, "hits", hits.to_s)
  puts "#{ns}.hits = #{hits}"
else
  r = Edge::HTTP.get(target, headers: { "User-Agent" => "spinel-wasm" },
                     backend: "origin")
  puts "GET #{target}"
  puts "status: #{r.status}"
  puts "type:   #{r["content-type"]}"
  puts "bytes:  #{r.body.bytesize}"
  puts
  # A non-2xx is an answer, not an exception: the body is here either way.
  puts r.body[0, 400]
end
