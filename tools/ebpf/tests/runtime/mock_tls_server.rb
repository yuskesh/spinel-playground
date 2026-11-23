# frozen_string_literal: true
#
# mock_tls_server.rb — the HTTPS peer of run_otlp_tls_smoke.sh.
#
#   ruby tests/runtime/mock_tls_server.rb PORT PEM
#
# PEM holds the certificate and its key. A GET is answered 200 with the body
# `ok`; anything else 501. A client that connects and closes without TLS
# (the harness's readiness probe) is logged and does not stop the server.

require_relative "mock_support"

TAG = "mock-tls"
port = Integer(ARGV.fetch(0))
pem = ARGV.fetch(1)
tls = MockSupport.tls_context(cert: pem)
MockSupport.log(TAG, "listening on 127.0.0.1:#{port}")
MockSupport.serve(port, TAG, tls: tls) do |io|
  req = MockSupport.read_request(io)
  next if req.nil?

  if req[0] == "GET"
    MockSupport.respond(io, 200, "OK", [], "ok")
  else
    MockSupport.respond(io, 501, "Not Implemented", [])
  end
end
