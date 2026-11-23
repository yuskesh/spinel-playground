# spinel-tier: arena
# The real escape-case subject (depends on GC semantics). The expected message in the research was
#   "finalizer depends on GC semantics; tier arena never runs collect()"
# GC.start is the current form of that intent -- ObjectSpace.define_finalizer
# is failed first by the existing whole-AOT refusal, but GC.start today **passes silently**
# and becomes a no-op. The refusal message has the reviewed format.
require "edge/cgi"

GC.start
Edge::CGI.respond(200, "unreachable\n")
