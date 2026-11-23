# frozen_string_literal: true
#
# mock_otlp_grpc.rb — a minimal OTLP/gRPC receiver for the OTLP harnesses.
#
#   ruby tests/runtime/mock_otlp_grpc.rb --port N [--out FILE]
#     [--protoc PROTOC] [--repo-root DIR] [--cert PEM --key PEM]
#
# Unary Export calls of the metrics, trace and logs services over HTTP/2 with
# prior knowledge (h2c), or over TLS with ALPN h2 when --cert and --key are
# given (grpcs). The request message is decoded with `protoc --decode` (as in
# mock_otlp_receiver.rb) and written to --out, overwritten per call, before
# the reply; the reply is an empty ExportXServiceResponse and grpc-status 0.
# Each request header that is not a pseudo-header is logged on stderr as
# `[mock-grpc] meta NAME: VALUE`.
#
# The HTTP/2 side is written here, not taken from a library. It reads what a
# conforming client may send for one unary call per stream: SETTINGS (acked),
# PING (acked), WINDOW_UPDATE, PRIORITY, HEADERS with CONTINUATION, padding,
# HPACK with Huffman and the dynamic table (mock_hpack.rb), DATA (answered
# with WINDOW_UPDATE), RST_STREAM and GOAWAY. A frame above the default
# 16384-byte size, a malformed frame or header block is a connection error:
# GOAWAY with its code, then the connection is closed. The gRPC side checks
# the method, the content-type and the 5-byte message envelope (a compressed
# message needs grpc-encoding gzip), and answers a refused call with its
# grpc-status and grpc-message.

require "optparse"
require "zlib"
require_relative "mock_support"
require_relative "mock_hpack"

DECODE = {
  "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export" =>
    ["opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest",
     "opentelemetry/proto/collector/metrics/v1/metrics_service.proto"],
  "/opentelemetry.proto.collector.trace.v1.TraceService/Export" =>
    ["opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest",
     "opentelemetry/proto/collector/trace/v1/trace_service.proto"],
  "/opentelemetry.proto.collector.logs.v1.LogsService/Export" =>
    ["opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest",
     "opentelemetry/proto/collector/logs/v1/logs_service.proto"]
}.freeze
TAG = "mock-grpc"
PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".b
MAX_FRAME = 16_384

# RFC 9113 frame types, flags and error codes
DATA = 0x0
HEADERS = 0x1
PRIORITY = 0x2
RST_STREAM = 0x3
SETTINGS = 0x4
PUSH_PROMISE = 0x5
PING = 0x6
GOAWAY = 0x7
WINDOW_UPDATE = 0x8
CONTINUATION = 0x9
END_STREAM = 0x1
ACK = 0x1
END_HEADERS = 0x4
PADDED = 0x8
PRIORITY_FLAG = 0x20
PROTOCOL_ERROR = 0x1
FRAME_SIZE_ERROR = 0x6
COMPRESSION_ERROR = 0x9

# gRPC status codes
GRPC_OK = 0
GRPC_UNIMPLEMENTED = 12
GRPC_INTERNAL = 13

opts = { port: 4317, out: "", protoc: "protoc", repo_root: ".", cert: "", key: "" }
OptionParser.new do |o|
  o.on("--port N", Integer) { |v| opts[:port] = v }
  o.on("--out FILE") { |v| opts[:out] = v }
  o.on("--protoc PATH") { |v| opts[:protoc] = v }
  o.on("--repo-root DIR") { |v| opts[:repo_root] = v }
  o.on("--cert PEM") { |v| opts[:cert] = v }
  o.on("--key PEM") { |v| opts[:key] = v }
end.parse!(ARGV)

CAPTURE = Mutex.new

# A connection error (RFC 9113 5.4.1): sent as GOAWAY, then the end.
class ConnectionError < StandardError
  attr_reader :code

  def initialize(code, msg)
    super(msg)
    @code = code
  end
end

# One HTTP/2 connection, served on its own thread.
class Connection
  def initialize(io, opts)
    @io = io
    @opts = opts
    @hpack = MockHpack::Decoder.new
    @streams = {} # id => {headers:, block:, data:, ended:}
    @last = 0
    @continuing = nil # the stream whose header block awaits CONTINUATION
  end

  def run
    preface = @io.read(PREFACE.bytesize)
    return if preface.nil? # a client that only connected

    raise ConnectionError.new(PROTOCOL_ERROR, "not the HTTP/2 client preface") unless preface.b == PREFACE

    frame(SETTINGS, 0, 0)
    while (f = read_frame)
      dispatch(*f)
    end
  rescue ConnectionError => e
    MockSupport.log(TAG, "connection error #{e.code}: #{e.message}")
    frame(GOAWAY, 0, 0, [@last, e.code].pack("NN") + e.message.b)
  rescue MockHpack::Error => e
    MockSupport.log(TAG, "connection error #{COMPRESSION_ERROR}: #{e.message}")
    frame(GOAWAY, 0, 0, [@last, COMPRESSION_ERROR].pack("NN") + e.message.b)
  end

  private

  def read_frame
    head = @io.read(9)
    return nil if head.nil? || head.empty?
    raise ConnectionError.new(PROTOCOL_ERROR, "the connection ends inside a frame header") if head.bytesize < 9

    hi, lo, type, flags, sid = head.unpack("CnCCN")
    len = (hi << 16) | lo
    raise ConnectionError.new(FRAME_SIZE_ERROR, "a #{len}-byte frame, above #{MAX_FRAME}") if len > MAX_FRAME

    payload = len.zero? ? "".b : @io.read(len)
    raise ConnectionError.new(PROTOCOL_ERROR, "the connection ends inside a frame") if payload.nil? || payload.bytesize < len

    [type, flags, sid & 0x7fff_ffff, payload.b]
  end

  def frame(type, flags, sid, payload = "".b)
    len = payload.bytesize
    @io.write([len >> 16, len & 0xffff, type, flags, sid].pack("CnCCN") + payload)
    @io.flush
  end

  def dispatch(type, flags, sid, payload)
    if @continuing && type != CONTINUATION
      raise ConnectionError.new(PROTOCOL_ERROR, "a header block left open by stream #{@continuing}")
    end

    case type
    when SETTINGS then settings(flags, sid, payload)
    when PING
      raise ConnectionError.new(PROTOCOL_ERROR, "PING on stream #{sid}") unless sid.zero?
      raise ConnectionError.new(FRAME_SIZE_ERROR, "a #{payload.bytesize}-byte PING") unless payload.bytesize == 8

      frame(PING, ACK, 0, payload) if (flags & ACK).zero?
    when WINDOW_UPDATE, PRIORITY then nil # nothing here sends enough to wait on a window
    when HEADERS then headers(flags, sid, payload)
    when CONTINUATION then continuation(flags, sid, payload)
    when DATA then data(flags, sid, payload)
    when RST_STREAM then @streams.delete(sid)
    when GOAWAY then raise EOFError, "the client sent GOAWAY"
    when PUSH_PROMISE then raise ConnectionError.new(PROTOCOL_ERROR, "PUSH_PROMISE from a client")
    end
  end

  def settings(flags, sid, payload)
    raise ConnectionError.new(PROTOCOL_ERROR, "SETTINGS on stream #{sid}") unless sid.zero?
    return if flags & ACK != 0
    raise ConnectionError.new(FRAME_SIZE_ERROR, "a SETTINGS payload of #{payload.bytesize} bytes") unless (payload.bytesize % 6).zero?

    frame(SETTINGS, ACK, 0)
  end

  # The payload with its padding (and a HEADERS frame's priority) removed.
  def unpad(flags, payload, priority: false)
    pad = 0
    if flags & PADDED != 0
      raise ConnectionError.new(FRAME_SIZE_ERROR, "a padded frame with no pad length") if payload.empty?

      pad = payload.getbyte(0)
      payload = payload.byteslice(1..)
    end
    payload = payload.byteslice(5..) || "".b if priority && flags & PRIORITY_FLAG != 0
    raise ConnectionError.new(PROTOCOL_ERROR, "padding longer than the frame") if pad > payload.bytesize

    payload.byteslice(0, payload.bytesize - pad)
  end

  def headers(flags, sid, payload)
    raise ConnectionError.new(PROTOCOL_ERROR, "HEADERS on stream 0") if sid.zero?

    block = unpad(flags, payload, priority: true)
    st = @streams[sid]
    if st.nil?
      raise ConnectionError.new(PROTOCOL_ERROR, "stream #{sid} is not a new client stream") if sid.even? || sid <= @last

      @last = sid
      st = @streams[sid] = { headers: nil, trailers: nil, block: "".b, data: "".b, ended: false }
    elsif st[:ended]
      raise ConnectionError.new(PROTOCOL_ERROR, "HEADERS on closed stream #{sid}")
    end
    st[:block] = block
    st[:ended] ||= flags & END_STREAM != 0
    if flags & END_HEADERS != 0
      header_block(sid, st)
    else
      @continuing = sid
    end
  end

  def continuation(flags, sid, payload)
    raise ConnectionError.new(PROTOCOL_ERROR, "CONTINUATION without an open header block") unless @continuing == sid

    st = @streams[sid]
    st[:block] << payload
    return if flags & END_HEADERS == 0

    @continuing = nil
    header_block(sid, st)
  end

  def header_block(sid, st)
    list = @hpack.decode(st[:block])
    st[:block] = "".b
    if st[:headers].nil?
      st[:headers] = list
    else
      st[:trailers] = list
    end
    call(sid, st) if st[:ended]
  end

  def data(flags, sid, payload)
    st = @streams[sid]
    raise ConnectionError.new(PROTOCOL_ERROR, "DATA on stream #{sid}, which is not open") if st.nil? || st[:ended] || st[:headers].nil?

    st[:data] << unpad(flags, payload)
    unless payload.empty?
      frame(WINDOW_UPDATE, 0, 0, [payload.bytesize].pack("N"))
      frame(WINDOW_UPDATE, 0, sid, [payload.bytesize].pack("N")) if (flags & END_STREAM).zero?
    end
    return if (flags & END_STREAM).zero?

    st[:ended] = true
    call(sid, st)
  end

  # The unary call on a stream whose request has ended.
  def call(sid, st)
    @streams.delete(sid)
    hs = st[:headers]
    get = ->(n) { (hs.find { |k, _| k == n } || [])[1] }
    hs.each { |k, v| MockSupport.log(TAG, "meta #{k}: #{v}") unless k.start_with?(":") }
    path = get.call(":path").to_s
    return reply(sid, GRPC_UNIMPLEMENTED, "the method is POST, not #{get.call(':method')}") unless get.call(":method") == "POST"
    return reply(sid, GRPC_UNIMPLEMENTED, "content-type #{get.call('content-type')}") unless get.call("content-type").to_s.start_with?("application/grpc")
    return reply(sid, GRPC_UNIMPLEMENTED, "method not found: #{path}") unless DECODE.key?(path)

    msg, why = message(st[:data], get.call("grpc-encoding"))
    return reply(sid, GRPC_INTERNAL, why) if msg.nil?

    decoded = MockSupport.protoc_decode(@opts[:protoc], @opts[:repo_root], *DECODE[path], msg)
    $stderr.write("[#{TAG}] #{path} #{msg.bytesize}B\n----- decoded -----\n#{decoded}-------------------\n")
    $stderr.flush
    CAPTURE.synchronize { File.binwrite(@opts[:out], decoded) } unless @opts[:out].empty?
    reply(sid, GRPC_OK, nil, "\x00\x00\x00\x00\x00".b) # one empty response message
  end

  # The one request message of a unary call, inflated when compressed, or
  # [nil, why].
  def message(body, encoding)
    return [nil, "a #{body.bytesize}-byte body has no message envelope"] if body.bytesize < 5

    compressed, len = body.unpack("CN")
    return [nil, "the envelope says #{len} bytes, the body holds #{body.bytesize - 5}"] unless body.bytesize == 5 + len

    msg = body.byteslice(5, len)
    case compressed
    when 0 then [msg, nil]
    when 1
      return [nil, "a compressed message with grpc-encoding #{encoding.inspect}"] unless encoding == "gzip"

      MockSupport.log(TAG, "gunzip -> #{Zlib.gunzip(msg).bytesize}B")
      [Zlib.gunzip(msg).b, nil]
    else [nil, "compressed flag #{compressed}"]
    end
  rescue Zlib::Error => e
    [nil, "gzip: #{e.message}"]
  end

  def reply(sid, status, why, body = nil)
    MockSupport.log(TAG, "grpc-status #{status}#{why ? ": #{why}" : ''}") unless status == GRPC_OK
    head = [[":status", "200"], ["content-type", "application/grpc+proto"]]
    trailers = [["grpc-status", status.to_s]]
    trailers << ["grpc-message", why] if why
    if body
      frame(HEADERS, END_HEADERS, sid, MockHpack.encode(head))
      frame(DATA, 0, sid, body)
      frame(HEADERS, END_HEADERS | END_STREAM, sid, MockHpack.encode(trailers))
    else # trailers-only
      frame(HEADERS, END_HEADERS | END_STREAM, sid, MockHpack.encode(head + trailers))
    end
  end
end

scheme = "grpc"
tls = nil
if !opts[:cert].empty? && !opts[:key].empty?
  tls = MockSupport.tls_context(cert: opts[:cert], key: opts[:key], alpn: ["h2"])
  scheme = "grpcs"
end
MockSupport.log(TAG, "listening on #{scheme}://127.0.0.1:#{opts[:port]}")
MockSupport.serve(opts[:port], TAG, tls: tls) do |io|
  if tls && io.alpn_protocol != "h2"
    MockSupport.log(TAG, "TLS client did not select ALPN h2 (#{io.alpn_protocol.inspect})")
    next
  end
  Connection.new(io, opts).run
end
