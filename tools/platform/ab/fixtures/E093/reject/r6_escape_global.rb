# spinel-tier: arena
# The real escape subject (an escape that outlives the request). The expected message in the research was
#   "reference to request-scoped object escapes to $cache;
#    tier arena frees all request memory at end of request"
require "edge/cgi"

$cache = {}
req = Edge::CGI.request
$cache[req.path] = req.body
Edge::CGI.respond(200, "cached\n")
