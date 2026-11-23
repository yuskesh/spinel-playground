# Connects the terminal page to a shell on this machine: it serves the page,
# and carries bytes between one WebSocket and one PTY.
#
#   bridge WEB_DIR [PORT]
#
# Anyone who reaches the WebSocket gets a shell, so it listens on 127.0.0.1
# only, and a connection needs this run's token, a local Host and a local Origin.
require "socket"
require "digest"

module Native
  ffi_source <<~C
    #ifdef __APPLE__
    #include <util.h>
    #else
    #include <pty.h>
    #endif
    #include <signal.h>
    #include <stdlib.h>
    #include <sys/ioctl.h>
    #include <unistd.h>

    /* Starts a login shell on a new PTY and answers the master's descriptor.
     * Exited shells are reaped by ignoring SIGCHLD; the child restores it. */
    int bridge_spawn(const char *shell, int cols, int rows) {
      struct winsize size = {0};
      int master = -1;
      size.ws_col = cols;
      size.ws_row = rows;
      signal(SIGCHLD, SIG_IGN);
      pid_t pid = forkpty(&master, NULL, NULL, &size);
      if (pid < 0) return -1;
      if (pid == 0) {
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        setenv("TERM", "xterm-256color", 1);
        execl(shell, shell, "-l", (char *)NULL);
        _exit(127);
      }
      return master;
    }

    /* The kernel tells the shell's foreground job with SIGWINCH. */
    int bridge_resize(int master, int cols, int rows) {
      struct winsize size = {0};
      size.ws_col = cols;
      size.ws_row = rows;
      return ioctl(master, TIOCSWINSZ, &size);
    }
  C
  ffi_func :bridge_spawn, [:str, :int, :int], :int
  ffi_func :bridge_resize, [:int, :int, :int], :int
end

# RFC 6455 framing, for the server's side of the connection.
module Frame
  CONTINUATION = 0
  TEXT = 1
  BINARY = 2
  CLOSE = 8
  PING = 9
  PONG = 10
  MAX_PAYLOAD = 1 << 20
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  def self.accept_key(key)
    Digest::SHA1.base64digest(key + GUID)
  end

  def self.encode(opcode, payload)
    size = payload.bytesize
    head = [0x80 | opcode].pack("C")
    if size < 126
      head << [size].pack("C")
    elsif size < 65536
      head << [126, size].pack("Cn")
    else
      head << [127, size].pack("CQ>")
    end
    head + payload
  end

  def self.unmask(buffer, mask_at, size)
    bytes = Array.new(size, 0)
    size.times do |i|
      bytes[i] = buffer.getbyte(mask_at + 4 + i) ^ buffer.getbyte(mask_at + i % 4)
    end
    bytes.pack("C*")
  end
end

# A terminal size from the page, kept within what a PTY can sensibly be.
module Size
  MAX = 2000

  def self.dimension(text, default)
    value = text.to_i
    value.between?(1, MAX) ? value : default
  end
end

# A connection that has not finished sending its HTTP request.
class Pending
  attr_reader :socket, :request

  def initialize(socket)
    @socket = socket
    @request = String.new
  end

  def complete?
    @request.include?("\r\n\r\n")
  end
end

Request = Struct.new(:target, :path, :query, :headers)

# One shell, and the bytes queued in both directions.
class Session
  COLS = 80
  ROWS = 24
  MAX_QUEUED = 1 << 20
  CHUNK = 16384

  attr_reader :socket, :pty

  def initialize(socket, pty)
    @socket = socket
    @pty = pty
    @incoming = String.new
    @to_pty = String.new
    @to_socket = String.new
    @closing = false
    @done = false
  end

  def done?
    @done
  end

  def wants_socket_read?
    !@closing && @to_pty.bytesize < MAX_QUEUED
  end

  def wants_pty_read?
    !@closing && @to_socket.bytesize < MAX_QUEUED
  end

  def wants_socket_write?
    !@to_socket.empty?
  end

  def wants_pty_write?
    !@to_pty.empty?
  end

  def read_socket
    data = @socket.read_nonblock(CHUNK)
    @incoming << data
    drain_frames
  rescue IO::WaitReadable
    nil
  rescue EOFError, SystemCallError
    @done = true
  end

  def read_pty
    data = @pty.read_nonblock(CHUNK)
    @to_socket << Frame.encode(Frame::BINARY, data)
  rescue IO::WaitReadable
    nil
  rescue EOFError, SystemCallError
    # The shell has exited.
    @to_socket << Frame.encode(Frame::CLOSE, "")
    @closing = true
  end

  def write_socket
    sent = @socket.write_nonblock(@to_socket)
    @to_socket = @to_socket.byteslice(sent, @to_socket.bytesize - sent)
    @done = true if @closing && @to_socket.empty?
  rescue IO::WaitWritable
    nil
  rescue SystemCallError
    @done = true
  end

  def write_pty
    sent = @pty.write_nonblock(@to_pty)
    @to_pty = @to_pty.byteslice(sent, @to_pty.bytesize - sent)
  rescue IO::WaitWritable
    nil
  rescue SystemCallError
    @done = true
  end

  def close
    @pty.close
    @socket.close
  rescue SystemCallError, IOError
    nil
  end

  private

  def drain_frames
    loop do
      break unless take_frame
    end
  end

  # Handles one complete frame from the front of @incoming; false when there is none.
  def take_frame
    return false if @incoming.bytesize < 2
    final = @incoming.getbyte(0) & 0x80 != 0
    opcode = @incoming.getbyte(0) & 15
    masked = @incoming.getbyte(1) & 0x80 != 0
    size = @incoming.getbyte(1) & 127
    at = 2
    if size == 126
      return false if @incoming.bytesize < 4
      size = @incoming.byteslice(2, 2).unpack1("n")
      at = 4
    elsif size == 127
      return false if @incoming.bytesize < 10
      size = @incoming.byteslice(2, 8).unpack1("Q>")
      at = 10
    end
    # RFC 6455 requires a client to mask every frame; a size report is one frame.
    if !masked || size > Frame::MAX_PAYLOAD || (opcode == Frame::TEXT && !final)
      @done = true
      return false
    end
    total = at + 4 + size
    return false if @incoming.bytesize < total
    payload = Frame.unmask(@incoming, at, size)
    @incoming = @incoming.byteslice(total, @incoming.bytesize - total)
    deliver(opcode, payload)
    !@done
  end

  def deliver(opcode, payload)
    if opcode == Frame::CONTINUATION || opcode == Frame::BINARY
      @to_pty << payload
    elsif opcode == Frame::TEXT
      resize(payload)
    elsif opcode == Frame::PING
      @to_socket << Frame.encode(Frame::PONG, payload)
    elsif opcode == Frame::CLOSE
      @done = true
    end
  end

  # A text frame is the page's "COLS ROWS"; the shell's bytes are binary.
  def resize(text)
    cols, rows = text.split(" ", 2)
    Native.bridge_resize(@pty.fileno, Size.dimension(cols.to_s, COLS), Size.dimension(rows.to_s, ROWS))
  end
end

class Bridge
  ASSETS = {
    "index.html" => "text/html",
    "main.mjs" => "text/javascript",
    "wasi_shim.mjs" => "text/javascript",
    "quad.wgsl" => "text/plain",
    "glyph.wgsl" => "text/plain",
    "shell.wasm" => "application/wasm"
  }.freeze

  def initialize(web_dir, port)
    @web_dir = web_dir
    @server = TCPServer.new("127.0.0.1", port)
    @port = @server.addr[1]
    @token = Random.urandom(16).unpack1("H*")
    @hosts = ["127.0.0.1:#{@port}", "localhost:#{@port}"]
    @pending = []
    @session = nil
  end

  def run
    puts "http://127.0.0.1:#{@port}/?token=#{@token}"
    $stdout.flush
    loop { step }
  end

  private

  def step
    readers = [@server]
    @pending.each { |p| readers << p.socket }
    writers = []
    session = @session
    if session
      readers << session.socket if session.wants_socket_read?
      readers << session.pty if session.wants_pty_read?
      writers << session.socket if session.wants_socket_write?
      writers << session.pty if session.wants_pty_write?
    end
    readable, writable = IO.select(readers, writers)
    accept_new if readable.include?(@server)
    @pending.dup.each { |p| read_pending(p) if readable.include?(p.socket) }
    pump(session, readable, writable) if session
  end

  def pump(session, readable, writable)
    session.read_socket if readable.include?(session.socket)
    session.read_pty if readable.include?(session.pty)
    session.write_socket if writable.include?(session.socket)
    session.write_pty if writable.include?(session.pty)
    return unless session.done?
    session.close
    @session = nil
  end

  def accept_new
    @pending << Pending.new(@server.accept_nonblock)
  rescue IO::WaitReadable
    nil
  end

  def read_pending(pending)
    pending.request << pending.socket.read_nonblock(4096)
    if pending.request.bytesize > 16384
      finish(pending, respond(431, "text/plain", "too large\n"))
    elsif pending.complete?
      answer(pending)
    end
  rescue IO::WaitReadable
    nil
  rescue EOFError, SystemCallError
    drop(pending)
  end

  def drop(pending)
    @pending.delete(pending)
    pending.socket.close
  end

  def finish(pending, response)
    pending.socket.write(response)
    drop(pending)
  rescue SystemCallError
    drop(pending)
  end

  def parse(text)
    lines = text.split("\r\n")
    target = lines[0].split(" ")[1] || "/"
    path, query = target.split("?", 2)
    headers = {}
    lines.drop(1).each do |line|
      name, value = line.split(":", 2)
      headers[name.strip.downcase] = value.strip if name && value
    end
    params = {}
    (query || "").split("&").each do |pair|
      name, value = pair.split("=", 2)
      params[name] = value || "" if name
    end
    Request.new(target, path, params, headers)
  end

  def answer(pending)
    if pending.request.split("\r\n").empty?
      finish(pending, respond(400, "text/plain", "no request line\n"))
      return
    end
    request = parse(pending.request)
    if !@hosts.include?(request.headers.fetch("host", ""))
      finish(pending, respond(403, "text/plain", "forbidden host\n"))
    elsif request.headers.fetch("upgrade", "").downcase == "websocket"
      upgrade(pending, request)
    else
      serve(pending, request)
    end
  end

  def serve(pending, request)
    name = request.path == "/" ? "index.html" : request.path.delete_prefix("/")
    type = ASSETS[name]
    if type
      finish(pending, respond(200, type, File.binread(File.join(@web_dir, name))))
    else
      finish(pending, respond(404, "text/plain", "not found\n"))
    end
  end

  def upgrade(pending, request)
    origin = request.headers.fetch("origin", "")
    allowed = @hosts.map { |host| "http://#{host}" }
    key = request.headers.fetch("sec-websocket-key", "")
    if request.path != "/shell" || request.query.fetch("token", "") != @token || !allowed.include?(origin) || key.empty?
      finish(pending, respond(403, "text/plain", "forbidden\n"))
    elsif @session
      finish(pending, respond(409, "text/plain", "a shell is already connected\n"))
    else
      cols = Size.dimension(request.query.fetch("cols", ""), Session::COLS)
      rows = Size.dimension(request.query.fetch("rows", ""), Session::ROWS)
      start_session(pending, key, cols, rows)
    end
  end

  def start_session(pending, key, cols, rows)
    master = Native.bridge_spawn(ENV.fetch("SHELL", "/bin/sh"), cols, rows)
    if master < 0
      finish(pending, respond(500, "text/plain", "could not start a shell\n"))
      return
    end
    pending.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                         "Sec-WebSocket-Accept: #{Frame.accept_key(key)}\r\n\r\n")
    @pending.delete(pending)
    @session = Session.new(pending.socket, IO.for_fd(master, "r+b"))
  end

  def respond(status, type, body)
    "HTTP/1.1 #{status} OK\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
      "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + body
  end
end

if ARGV.empty?
  warn "usage: bridge WEB_DIR [PORT]"
  exit 64
end
Signal.trap("PIPE", "IGNORE")
Bridge.new(ARGV[0], ARGV.size > 1 ? ARGV[1].to_i : 8000).run
