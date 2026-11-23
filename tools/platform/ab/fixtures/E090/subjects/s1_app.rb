# spinel-tier: full
# E090 positive subject -- R016 s1's shape with the E090 stub capabilities:
# tier magic comment + edge-family requires + platform chosen by a T-5 profile.
#   spinel-wasm s1_app.rb --profile tools/platform/profiles/workers-full.yaml -I subjects/root
#   spinel-wasm s1_app.rb --profile tools/platform/profiles/fastly-full.yaml  -I subjects/root
# Porting = swapping the profile; the response must be byte-identical (E058).
require "edge/cgi"
require "edge/http"

path = Edge::CGI.request_path
if path == "/probe"
  Edge::CGI.respond(200, "cgi=" + path + " q=" + Edge::CGI.request_query + " http=" + Edge::HTTP.probe)
end
Edge::CGI.respond(200, "root http=" + Edge::HTTP.probe)
