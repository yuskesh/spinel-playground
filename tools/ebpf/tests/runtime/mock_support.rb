# frozen_string_literal: true
#
# mock_support.rb — what the three mock servers of the OTLP harnesses share:
# the accept loop, TLS on the server side, HTTP/1.1 request reading and the
# protoc decode of a request body.
#
# The mocks run under CRuby with its bundled openssl, zlib and json; they are
# not meant to be compiled by Spinel, whose openssl package is client-only.
# They are this repository's own implementation, written to the behaviour of
# spinel-ebpf's Python mocks (23fa4b0, not imported), not a port of them.

require "openssl"
require "open3"
require "socket"

module MockSupport
  module_function

  # One line on stderr, flushed: the harnesses read the mocks' logs.
  def log(tag, msg)
    $stderr.write("[#{tag}] #{msg}\n")
    $stderr.flush
  end

  # The opentelemetry-proto checkout protoc reads the .proto files from:
  # OTEL_PROTO_DIR (a user-local pin, as NANOPB_DIR is), else the repository's
  # own third_party/opentelemetry-proto.
  def proto_root(repo_root)
    dir = ENV["OTEL_PROTO_DIR"]
    dir = File.join(repo_root, "third_party", "opentelemetry-proto") if dir.nil? || dir.empty?
    File.expand_path(dir, repo_root)
  end

  # `protoc --decode=MESSAGE` of BODY, run in REPO_ROOT. The text format, or
  # DECODE_ERROR and protoc's message when protoc refuses the bytes.
  def protoc_decode(protoc, repo_root, message, proto, body)
    out, err, st = Open3.capture3(protoc, "--decode=#{message}", "-I", proto_root(repo_root), proto,
                                  stdin_data: body, binmode: true, chdir: repo_root)
    st.success? ? out : "DECODE_ERROR\n#{err}"
  rescue SystemCallError => e
    "DECODE_ERROR\n#{e.message}\n"
  end

  # A TLS server context: the certificate chain and key from PEM files (one
  # file may hold both), a client certificate required and checked against
  # CLIENT_CA when one is given, and ALPN restricted to ALPN when given.
  def tls_context(cert:, key: nil, client_ca: nil, alpn: nil)
    pem = File.read(cert)
    ctx = OpenSSL::SSL::SSLContext.new
    certs = pem.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?/m)
                .map { |c| OpenSSL::X509::Certificate.new(c) }
    raise ArgumentError, "#{cert}: no certificate" if certs.empty?

    ctx.cert = certs.first
    ctx.extra_chain_cert = certs.drop(1) unless certs.size == 1
    ctx.key = OpenSSL::PKey.read(key ? File.read(key) : pem)
    if client_ca
      ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
      ctx.ca_file = client_ca
    end
    if alpn
      ctx.alpn_protocols = alpn
      # no protocol in common ends the handshake with no_application_protocol
      ctx.alpn_select_cb = lambda do |offered|
        offered.find { |p| alpn.include?(p) } ||
          raise(OpenSSL::SSL::SSLError, "ALPN: the client offers #{offered.inspect}, not #{alpn.inspect}")
      end
    end
    ctx
  end

  # Accept connections on 127.0.0.1:PORT for ever, each in its own thread.
  # With a TLS context the handshake happens in that thread, so a client that
  # connects and closes without TLS (a readiness probe) costs one failed
  # handshake and does not hold up the next client.
  def serve(port, tag, tls: nil)
    server = TCPServer.new("127.0.0.1", port)
    loop do
      sock = server.accept
      Thread.new(sock) do |s|
        io = s
        begin
          if tls
            io = OpenSSL::SSL::SSLSocket.new(s, tls)
            io.sync_close = true
            io.accept
          end
          yield io
        rescue StandardError => e # one client's failure is logged; the server goes on
          log(tag, "connection: #{e.class}: #{e.message}")
        ensure
          begin
            io.close
          rescue StandardError
            nil
          end
        end
      end
    end
  end

  # One HTTP/1.1 request: [method, target, headers, body], the headers as
  # [name, value] pairs in the order sent, the body Content-Length bytes.
  # nil when the client closed without a request line.
  def read_request(io)
    line = io.gets("\r\n", 8192)
    return nil if line.nil? || line.strip.empty?

    method, target, = line.split(" ", 3)
    headers = []
    while (h = io.gets("\r\n", 8192))
      h = h.chomp("\r\n").chomp("\n")
      break if h.empty?

      name, value = h.split(":", 2)
      headers << [name.strip, value.to_s.strip]
    end
    len = header(headers, "content-length").to_i
    body = len.positive? ? read_exact(io, len) : "".b
    [method, target, headers, body]
  end

  # The first value of header NAME, case-insensitively, or nil.
  def header(headers, name)
    pair = headers.find { |k, _| k.casecmp?(name) }
    pair && pair[1]
  end

  # Exactly N bytes, or EOFError.
  def read_exact(io, n)
    buf = io.read(n)
    raise EOFError, "end of stream after #{buf ? buf.bytesize : 0} of #{n} byte(s)" if buf.nil? || buf.bytesize < n

    buf.b
  end

  def respond(io, status, reason, headers, body = "")
    head = +"HTTP/1.1 #{status} #{reason}\r\n"
    headers.each { |k, v| head << "#{k}: #{v}\r\n" }
    head << "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
    io.write(head)
    io.write(body) unless body.empty?
    io.flush
  end
end
