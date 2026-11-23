# frozen_string_literal: true
#
# tools/doom/net_frames.rb -- DOOM's frames as the board sends them over UDP
# (decision 0024), reassembled, digested and checked against the console.
#
# The library of tools/doom/net-viewer.rb, kept apart so that its test drives
# the same code with recorded datagrams.
#
# THE WIRE is version 3, decision 0025 point 15. One datagram is one message
# of a `udp:` channel (decision 0014 §5, no header of its own). Integers are
# little-endian. Every message opens with the kind (u8), the version (u8, 3;
# a message of any kind with another version is bad, version 2 included) and
# the boot id (u32, never 0), then:
#
#   0x50 'P'  the palette: 768 bytes, 256 RGB triples (PLAYPAL's first
#             palette; the port applies no other, rule D-4), at boot and
#             every second; each replaces the one held for its boot
#   0x43 'C'  a piece of one frame's 8-bit screen:
#               tic u32, index u8, count u8, then where the tic's input came
#               from: the controller's session id u32, the sequence number
#               the tic used u32 and the input's state u8 (0 no input, 1
#               holding an applied message's state, 2 released by the
#               time-out); then the bytes
#             a frame is PIECES pieces of CHUNK bytes, the last one the rest
#             of the screen's SCREEN bytes
#             "no input" is session 0 and sequence 0, and an input of state 1
#             or 2 has a session; a piece that says otherwise, or a state
#             above 2, is bad
#   0x53 'S'  the M7's counts since boot, every second: latest tic u32,
#             frames sent, frames not sent (the 35-a-second choice), frames
#             dropped (the ring full), messages dropped, each u32
#
# There is no 0x54 `T`: the M33 sends no report of its own (the board lane
# reads its counts with the debugger), so a `T` is a bad datagram of an
# unknown kind.
#
# Anything else -- another version, boot id 0, another kind, a message of
# the wrong size, a piece whose index or count does not fit the screen -- is
# a bad datagram, counted by reason and not used.
#
# THE INPUT, within a frame. All of a frame's pieces carry the same three
# input fields; a frame whose pieces disagree is closed as incomplete
# (`mismatch`), with no piece missing, and not used.
#
# BOOTS ARE NEVER COMBINED. Each boot id has its own frames, palette and
# counts. The board puts no further piece of a frame once its ring was full
# for one, so a frame it dropped arrives incomplete or not at all, as one the
# network lost does.
#
# WHAT A DROP IS, within a boot. A frame is complete when every one of its
# pieces arrived. Datagrams may come out of order, so a tic stays open until
# a piece of a tic more than `window` later arrives, or the input ends; it is
# then closed as incomplete, with the number of pieces it lacks. A tic no
# piece arrived for, between the first and the last tic seen, is absent. A
# piece that arrives a second time is a duplicate, and one for a tic already
# closed is late; both are counted and not used. A piece of a tic more than
# `window` below the highest seen, of no frame already closed, is a tic going
# BACKWARDS: two boots sharing an id. It is counted and not used.
#
# THE DIGESTS are FNV-1a 64 of the first VIEW bytes (the view, above the
# status bar) and of the whole screen, in 16 lowercase hex digits: what
# examples/doom/core/board/frame_digests.c computes for the console's
# `F <tic> <view> <full> <cycles>` line (tools/doom/board-frames.rb reads it).
require_relative "../app/lib/core_app/console"

module NetFrames
  WIDTH = 320
  HEIGHT = 200
  SCREEN = WIDTH * HEIGHT
  # 168 rows: the board's `Frame.digests(renderer_screen, 53760, dig)`
  VIEW = WIDTH * 168
  CHUNK = 1280
  PIECES = (SCREEN + CHUNK - 1) / CHUNK
  VERSION = 3
  COMMON = 6
  PALETTE = 0x50
  PIECE = 0x43
  STREAM = 0x53
  PIECE_HEADER = COMMON + 15
  PALETTE_BYTES = 768
  STREAM_BYTES = COMMON + 20

  # FNV-1a 64 in two 32-bit halves, so that every step stays a Fixnum: the
  # prime is 2**40 + 0x1b3, and h * prime mod 2**64 is
  # (hi * 0x1b3 + (lo * 0x1b3 >> 32) + lo * 2**8) * 2**32 + lo * 0x1b3, each
  # half mod 2**32.
  # A frame took 4.5 ms this way and 22 ms with a 64-bit Integer (Ruby 3.3,
  # Debian x86_64, 2026-10-22).
  FNV_HI = 0xcbf29ce4
  FNV_LO = 0x84222325
  FNV_LOW_PRIME = 0x1b3
  MASK32 = 0xffffffff

  # The digest of the first `cut` bytes and of all of them, in one pass.
  def self.fnv1a64_prefix(bytes, cut)
    hi = FNV_HI
    lo = FNV_LO
    head = nil
    i = 0
    bytes.each_byte do |c|
      head = format("%08x%08x", hi, lo) if i == cut
      lo ^= c
      m = lo * FNV_LOW_PRIME
      hi = (hi * FNV_LOW_PRIME + (m >> 32) + (lo << 8)) & MASK32
      lo = m & MASK32
      i += 1
    end
    all = format("%08x%08x", hi, lo)
    [head || (cut == i ? all : nil), all]
  end

  def self.fnv1a64(bytes) = fnv1a64_prefix(bytes, 0)[1]

  # [view, full] of one screen
  def self.digests(screen, view = VIEW) = fnv1a64_prefix(screen, view)

  # One datagram: [:palette, boot, rgb], [:piece, boot, tic, index, count,
  # bytes, input], [:stream, boot, counts] or [:bad, reason]. A piece's input
  # is [session, sequence, state].
  def self.decode(dgram)
    d = dgram.b
    return [:bad, "shorter than the common header"] if d.bytesize < COMMON

    kind, version, boot = d.unpack("CCL<")
    return [:bad, "version #{version}"] unless version == VERSION
    return [:bad, "boot id 0"] if boot.zero?

    case kind
    when PALETTE
      return [:bad, "palette of #{d.bytesize - COMMON} bytes"] unless d.bytesize == COMMON + PALETTE_BYTES

      [:palette, boot, d.byteslice(COMMON, PALETTE_BYTES)]
    when PIECE
      return [:bad, "short piece header"] if d.bytesize < PIECE_HEADER

      tic, index, count, session, seq, state = d.unpack("@#{COMMON}L<CCL<L<C")
      body = d.byteslice(PIECE_HEADER, d.bytesize - PIECE_HEADER)
      return [:bad, "piece count #{count}, not #{PIECES}"] unless count == PIECES
      return [:bad, "piece index #{index} of #{count}"] unless index < count

      want = index == count - 1 ? SCREEN - CHUNK * (count - 1) : CHUNK
      return [:bad, "piece #{index} of #{body.bytesize} bytes, not #{want}"] unless body.bytesize == want
      return [:bad, "input state #{state}"] if state > 2
      return [:bad, "no input with a session or sequence"] if state.zero? && (session != 0 || seq != 0)
      return [:bad, "input state #{state} with session 0"] if state != 0 && session.zero?

      [:piece, boot, tic, index, count, body, [session, seq, state]]
    when STREAM
      return [:bad, "stream counts of #{d.bytesize} bytes"] unless d.bytesize == STREAM_BYTES

      tic, sent, not_sent, dropped, messages = d.unpack("@#{COMMON}L<5")
      [:stream, boot, { tic: tic, sent: sent, not_sent: not_sent, dropped: dropped, messages_dropped: messages }]
    else
      [:bad, format("kind 0x%02x", kind)]
    end
  end

  # One boot's frames. #piece and #finish return the frames they close, each
  # { boot:, tic:, screen:, input: } when complete or { boot:, tic:, missing: }
  # when not (with mismatch: true, and missing 0, when every piece arrived
  # but they disagree on the input). input is { session:, seq:, state: }.
  class Boot
    attr_reader :id, :palette, :stats, :stream, :backwards

    def initialize(id, window)
      @id = id
      @window = window
      @open = {}
      @input = {}
      @mixed = {}
      @closed = {}
      @palette = nil
      @first = nil
      @last = nil
      @stream = nil
      @backwards = []
      @stats = Hash.new(0)
    end

    def palette=(rgb)
      @stats[:palettes] += 1
      @stats[:palette_changed] += 1 if @palette && @palette != rgb
      @palette = rgb
    end

    # the latest S (by its tic; they may come out of order), and whether
    # its counts add up: each tic is exactly one of sent, not sent, dropped
    def stream=(counts)
      @stats[:streams] += 1
      @stats[:stream_inconsistent] += 1 unless counts[:sent] + counts[:not_sent] + counts[:dropped] == counts[:tic] + 1
      @stream = counts if @stream.nil? || counts[:tic] >= @stream[:tic]
    end

    def piece(tic, index, count, body, input)
      if @closed.key?(tic)
        @stats[:late] += 1
        return []
      end
      if !@open.key?(tic) && @last && tic < @last - @window
        @stats[:backwards] += 1
        @backwards << tic
        return []
      end
      @first = tic if @first.nil? || tic < @first
      @last = tic if @last.nil? || tic > @last
      slot = (@open[tic] ||= Array.new(count))
      if slot[index]
        @stats[:duplicates] += 1
        return []
      end
      slot[index] = body
      @input[tic] ||= input
      @mixed[tic] = true if @input[tic] != input
      done = []
      done << close(tic) if slot.all?
      @open.keys.select { |t| t < tic - @window }.sort.each { |t| done << close(t) }
      done
    end

    def finish
      @open.keys.sort.map { |t| close(t) }
    end

    # tics between the first and the last seen that no piece arrived for
    def absent
      return [] unless @first

      (@first..@last).reject { |t| @closed.key?(t) || @open.key?(t) }
    end

    private

    def close(tic)
      slot = @open.delete(tic)
      session, seq, state = @input.delete(tic)
      mixed = @mixed.delete(tic)
      @closed[tic] = true
      if slot.all? && mixed
        @stats[:incomplete] += 1
        @stats[:input_mismatch] += 1
        { boot: @id, tic: tic, missing: 0, mismatch: true }
      elsif slot.all?
        @stats[:complete] += 1
        @stats[:before_palette] += 1 unless @palette
        @stats[:"input_#{state}"] += 1
        { boot: @id, tic: tic, screen: slot.join, input: { session: session, seq: seq, state: state } }
      else
        missing = slot.count(&:nil?)
        @stats[:incomplete] += 1
        @stats[:pieces_missing] += missing
        { boot: @id, tic: tic, missing: missing }
      end
    end
  end

  # Datagrams in, frames out, each boot apart (#boots, in the order their
  # first datagram came).
  class Assembler
    attr_reader :stats, :boots

    def initialize(window: 8)
      @window = window
      @boots = {}
      @stats = Hash.new(0)
      @bad = Hash.new(0)
    end

    def bad_reasons = @bad

    def boot(id) = (@boots[id] ||= Boot.new(id, @window))

    def feed(dgram)
      @stats[:datagrams] += 1
      kind, id, *rest = NetFrames.decode(dgram)
      if kind == :bad
        @stats[:bad] += 1
        @bad[id] += 1
        return []
      end
      b = boot(id)
      b.stats[:datagrams] += 1
      case kind
      when :palette then b.palette = rest[0]
      when :stream then b.stream = rest[0]
      else return b.piece(*rest)
      end
      []
    end

    def finish
      @boots.values.flat_map(&:finish)
    end
  end

  Console = Struct.new(:frames, :boots, :dropped_frames, :dropped_messages, :not_sent, :tics, keyword_init: true)

  class Console
    # The frames the board says it did not send, or nil when it does not say
    # (no `N` line): those its ring dropped when full and those the
    # 35-a-second choice left out.
    def unsent_frames = dropped_frames && dropped_frames + not_sent

    # the boot the console's `B` line names (nil without one or with two)
    def boot = boots.size == 1 ? boots[0] : nil
  end

  # What the board's console says about the frames, from the 0014 frames of
  # its log (the lines tools/doom/board-frames.rb judges): `frames`, tic =>
  # [view, full] from each `F` line; `boots`, the ids of its `B` lines (one
  # console is one boot; `F` lines may come before `B`, since the M7 writes
  # it at the first tic the M33 has published the id); from
  # `N <frames dropped> <messages dropped> <frames not sent>` before `D`,
  # those counts (nil without the line; the first Clarification's `N` had no
  # third count, and sent every frame, so it reads as 0); `tics` from `D`.
  def self.console(bytes)
    parsed = CoreApp::Console.parse(bytes)
    out = Console.new(frames: {}, boots: [])
    parsed.frames.each do |(_ch, payload)|
      l = payload.pack("C*").chomp
      if (m = l.match(/\AF ([0-9a-f]{16}) ([0-9a-f]{16}) ([0-9a-f]{16}) [0-9a-f]{16}\z/))
        out.frames[m[1].to_i(16)] = [m[2], m[3]]
      elsif (m = l.match(/\AB ([0-9a-f]{16})\z/))
        out.boots << m[1].to_i(16)
      elsif (m = l.match(/\AN ([0-9a-f]{16}) ([0-9a-f]{16})(?: ([0-9a-f]{16}))?\z/))
        out.dropped_frames = m[1].to_i(16)
        out.dropped_messages = m[2].to_i(16)
        out.not_sent = m[3] ? m[3].to_i(16) : 0
      elsif (m = l.match(/\AD ([0-9a-f]{16})\z/))
        out.tics = m[1].to_i(16)
      end
    end
    out
  end

  # A recording of datagrams, as net-viewer.rb --record writes it and
  # --replay reads it: each one as its length (u32) and its bytes.
  module Recording
    def self.write(io, dgram)
      io.write([dgram.bytesize].pack("L<"), dgram.b)
    end

    def self.each(bytes)
      b = bytes.b
      i = 0
      while i < b.bytesize
        raise ArgumentError, "recording cut inside a length at byte #{i}" if i + 4 > b.bytesize

        n = b.unpack1("L<", offset: i)
        raise ArgumentError, "recording cut inside a datagram at byte #{i}" if i + 4 + n > b.bytesize

        yield b.byteslice(i + 4, n)
        i += 4 + n
      end
    end

    # The same, read while it is being written: #feed takes the bytes as
    # they come and yields each datagram once all of it is there.
    class Reader
      def initialize
        @buf = +"".b
      end

      def pending = @buf.bytesize

      def feed(bytes)
        @buf << bytes.b
        i = 0
        while i + 4 <= @buf.bytesize
          n = @buf.unpack1("L<", offset: i)
          break if i + 4 + n > @buf.bytesize

          yield @buf.byteslice(i + 4, n)
          i += 4 + n
        end
        @buf = @buf.byteslice(i, @buf.bytesize - i)
      end
    end
  end

  # Nearest-neighbour scaling of an 8-bit screen through the palette, to a
  # binary PPM (P6) of out_w x out_h.
  class Scaler
    attr_reader :out_w, :out_h

    def initialize(out_w, out_h)
      @out_w = out_w
      @out_h = out_h
      @xs = Array.new(out_w) { |x| x * WIDTH / out_w }
      @ys = Array.new(out_h) { |y| y * HEIGHT / out_h }
    end

    def ppm(screen, palette)
      rgb = Array.new(256) { |i| palette.byteslice(3 * i, 3) }
      rows = {}
      body = @ys.map do |sy|
        rows[sy] ||= begin
          src = screen.byteslice(sy * WIDTH, WIDTH)
          @xs.map { |sx| rgb[src.getbyte(sx)] }.join
        end
      end
      "P6\n#{@out_w} #{@out_h}\n255\n".b + body.join
    end

    # the output size for --aspect: 1:1 keeps 320x200 pixels square, 4:3
    # stretches the rows as a CRT showed them (200 -> 240), each times scale;
    # fill is exactly `size`
    def self.size_for(aspect, scale, size)
      case aspect
      when "1:1" then [WIDTH * scale, HEIGHT * scale]
      when "4:3" then [WIDTH * scale, HEIGHT * 6 / 5 * scale]
      when "fill" then size or raise ArgumentError, "--aspect fill needs --size WxH"
      else raise ArgumentError, "--aspect #{aspect}: one of 1:1, 4:3, fill"
      end
    end
  end
end
