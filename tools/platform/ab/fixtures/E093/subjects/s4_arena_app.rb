# spinel-tier: arena
# E093 positive subject -- R016_samples/s4_arena_app.rb made buildable.
#
#   spinel-wasm s4_arena_app.rb --profile tools/platform/profiles/workers-full.yaml \
#               --host-api -o s4.wasm
#
# The declaration alone selects --request-arena (E090 g07).  What E093 adds is
# that the declaration is now EARNED: arenacheck proves the two arena
# properties before the build starts --
#   (1) no GC-semantics name is mentioned,
#   (2) nothing that outlives the request holds a heap value.
# Everything below is request-scoped: `req` and the two strings are locals, and
# the only thing that leaves the process is the KV write and the response.
require "edge/cgi"
require "edge/kv"

req = Edge::CGI.request
Edge::KV.put("SPINEL_KV", "post:" + req.path, req.body)
Edge::CGI.respond(200, "saved " + req.path + " (" + req.body.bytesize.to_s + " bytes)\n")
