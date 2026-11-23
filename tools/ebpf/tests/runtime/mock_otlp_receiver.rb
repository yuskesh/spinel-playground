# frozen_string_literal: true
#
# mock_otlp_receiver.rb — a minimal OTLP/HTTP receiver for the OTLP harnesses.
#
#   ruby tests/runtime/mock_otlp_receiver.rb --port N [--out FILE [--append]]
#     [--protoc PROTOC] [--repo-root DIR] [--cert PEM [--client-ca PEM]]
#
# Each POST to /v1/metrics, /v1/traces or /v1/logs is captured to --out and
# answered 200 with an empty ExportXServiceResponse (0 bytes is a valid empty
# protobuf). The capture is written before the reply, so a sender that has
# its 200 can read it at once. --out is overwritten per request unless
# --append is given, for a test that sends several requests.
#
#   application/x-protobuf  `protoc --decode` of the body, in the text format
#                           (OTEL_PROTO_DIR or REPO_ROOT/third_party/
#                           opentelemetry-proto holds the .proto files)
#   application/json        the body as sent, once JSON.parse accepts it
#
# A refused body is captured as DECODE_ERROR and the reason. Each header is
# logged on stderr as `[mock-otlp] header NAME: VALUE`, and a gzip body
# (Content-Encoding: gzip) is inflated first and logged as `gunzip -> NB`.
#
# --cert (certificate and key in one PEM) serves HTTPS; --client-ca also
# requires a client certificate that it verifies.

require "json"
require "optparse"
require "zlib"
require_relative "mock_support"

DECODE = {
  "/v1/metrics" => ["opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest",
                    "opentelemetry/proto/collector/metrics/v1/metrics_service.proto"],
  "/v1/traces" => ["opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest",
                   "opentelemetry/proto/collector/trace/v1/trace_service.proto"],
  "/v1/logs" => ["opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest",
                 "opentelemetry/proto/collector/logs/v1/logs_service.proto"]
}.freeze
TAG = "mock-otlp"

opts = { port: 4318, out: "", append: false, protoc: "protoc", repo_root: ".", cert: "", client_ca: "" }
OptionParser.new do |o|
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--out FILE") { |v| opts[:out] = v }
  o.on("--append") { opts[:append] = true }
  o.on("--protoc PATH") { |v| opts[:protoc] = v }
  o.on("--repo-root DIR") { |v| opts[:repo_root] = v }
  o.on("--cert PEM") { |v| opts[:cert] = v }
  o.on("--client-ca PEM") { |v| opts[:client_ca] = v }
end.parse!(ARGV)

CAPTURE = Mutex.new

def decode(opts, path, ctype, body)
  if ctype.include?("application/json")
    begin
      JSON.parse(body)
      body
    rescue JSON::ParserError => e
      "DECODE_ERROR\n#{e.message}"
    end
  elsif DECODE.key?(path) && ctype.include?("application/x-protobuf")
    MockSupport.protoc_decode(opts[:protoc], opts[:repo_root], *DECODE[path], body)
  else
    ""
  end
end

def handle(io, opts)
  req = MockSupport.read_request(io)
  return if req.nil?

  method, path, headers, body = req
  headers.each { |k, v| MockSupport.log(TAG, "header #{k}: #{v}") }
  unless method == "POST"
    MockSupport.respond(io, 501, "Not Implemented", [["Content-Type", "text/plain"]], "unsupported method\n")
    return
  end
  if MockSupport.header(headers, "content-encoding").to_s.strip == "gzip"
    body = Zlib.gunzip(body).b
    MockSupport.log(TAG, "gunzip -> #{body.bytesize}B")
  end
  ctype = MockSupport.header(headers, "content-type").to_s
  MockSupport.log(TAG, "POST #{path} ctype=#{ctype} #{body.bytesize}B")
  decoded = decode(opts, path, ctype, body)
  CAPTURE.synchronize do
    File.open(opts[:out], opts[:append] ? "ab" : "wb") { |f| f.write(decoded) } unless opts[:out].empty?
  end
  $stderr.write("----- mock-otlp decoded -----\n#{decoded}-----------------------------\n")
  $stderr.flush
  MockSupport.respond(io, 200, "OK", [["Content-Type", "application/x-protobuf"]])
end

scheme = "http"
tls = nil
unless opts[:cert].empty?
  ca = opts[:client_ca].empty? ? nil : opts[:client_ca]
  tls = MockSupport.tls_context(cert: opts[:cert], client_ca: ca)
  scheme = ca ? "https+mtls" : "https"
end
MockSupport.log(TAG, "listening on #{scheme}://127.0.0.1:#{opts[:port]}")
MockSupport.serve(opts[:port], TAG, tls: tls) { |io| handle(io, opts) }
