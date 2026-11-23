# tools/wasm/lib/edge/http.rb -- outbound HTTP for the edge family
# (R016 T-3/T-4 `edge/http` = (arena+, {workers, fastly}); the semantics are
# R008 D-3, decided by E058 and unchanged by the E091 rename).
#
#   require "edge/http"
#
#   r = Edge::HTTP.request(:get, "https://example.com/", backend: "origin")
#   r.status                      # 200.  404 and 500 are answers too.
#   r["content-type"]
#   r.body.bytesize
#
#   Edge::HTTP.get(url, backend: "origin")
#   Edge::HTTP.post(url, payload, backend: "origin", headers: { "X-K" => "v" })
#
# ★ THE VERB IS AN ARGUMENT, NOT A METHOD NAME (P008 検討点 A, confirmed
#   2026-08-19).  `request` is the primitive and maps 1:1 onto the single
#   sp_host_fetch thunk; `get` and `post` are the only two sugars, because they
#   are what programs actually write.  put/delete arrive when something in the
#   tree needs them (P008 Phase 4.5), and the upper bound is the IANA method
#   registry -- a verb outside it stays spelled as `request(:verb, ...)`
#   forever.  E063's rule, applied to a method table: do not add a name that
#   has no behaviour behind it.
#
# ★ `backend:` is the one place the two platforms genuinely differ, and the
#   difference is deliberately visible rather than smoothed over (R008 D-3):
#
#     Workers   the URL is the destination.  backend: is accepted and ignored.
#     Fastly    every outbound request names a backend from the service
#               configuration; a URL alone reaches nothing.  Omitting backend:
#               is an ArgumentError at the call, BEFORE any traffic.
#
#   It raises rather than picking a default because the alternative failure is
#   the worst kind this target keeps designing out: the program asks for
#   https://api.example.com, the request goes somewhere else, and a 200 comes
#   back to say it worked.  Writing `backend: "origin"` unconditionally is
#   correct on both platforms, which is what makes one .rb portable.
#
# Buffered, both directions: the request body is sent whole and the response
# body is read whole before the call returns.  There is no streaming here (and
# none in layer 0 either -- see the E013/E014 limits).
require "edge/bridge"

module Edge
  module HTTP
    # A response is whatever the other end said, including a 404 or a 503.
    # Only a failure to *reach* the other end raises (IOError) -- "the server
    # answered 500" is information, not an exception (R003 §3-1: an observable
    # answer is an answer).
    class Response
      attr_reader :status, :body, :headers

      def initialize(status, body, headers)
        @status = status
        @body = body
        @headers = headers
      end

      # Header lookup is case-insensitive; keys are stored lower-cased.
      def [](name)
        @headers[name.to_s.downcase]
      end

      def ok?
        @status >= 200 && @status < 300
      end

      def content_type
        @headers["content-type"]
      end

      def to_s
        @body
      end
    end

    # THE primitive.  `verb` may be a Symbol (:get) or a String ("GET"); it is
    # upcased and passed through verbatim, so any method the other end
    # understands is reachable without this file growing a name for it.
    def self.request(verb, url, backend: nil, headers: nil, body: nil)
      payload = body.nil? ? "" : body.to_s
      status = Edge::Bridge.sp_host_fetch(url.to_s, verb.to_s.upcase, payload,
                                          payload.bytesize,
                                          Edge::Bridge.format_headers(headers),
                                          backend.nil? ? "" : backend.to_s)
      # Sequenced into locals on purpose: as two arguments of one call, C leaves
      # their evaluation unsequenced.  (The C side also gives the body and the
      # headers separate buffers, so this is belt and braces.)
      payload_body = Edge::Bridge.sp_host_res_body
      payload_head = Edge::Bridge.sp_host_res_headers
      Response.new(status, payload_body, Edge::Bridge.parse_headers(payload_head))
    end

    def self.get(url, headers: nil, backend: nil)
      request(:get, url, headers: headers, backend: backend)
    end

    def self.post(url, body, headers: nil, backend: nil)
      request(:post, url, body: body, headers: headers, backend: backend)
    end

    # The run-time question "is the bridge behind this build?", asked where a
    # program that only requires edge/http will look for it.
    def self.available?
      Edge.available?
    end
  end
end
