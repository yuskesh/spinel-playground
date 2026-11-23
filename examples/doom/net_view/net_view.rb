# examples/doom/net_view/net_view.rb -- shows the frames the FRDM-IMXRT1186
# sends over UDP (decision 0024), in an SDL2 window, and with --keys sends
# the keyboard to it (decision 0025).
#
#   net_view [--port 5029] [--bind ADDR] [--idle SECONDS]   live: the board
#            [--keys [ADDR:]PORT [--script FILE] [--first-seq N]]
#   net_view --replay FILE                                   a recording
#
#   the rest, either way:
#     [--record FILE]  append every datagram received, in the form
#                      tools/doom/net-viewer.rb --replay reads
#     [--fps N]        show at most N frames a second (0, the default: no
#                      limit; the board already sends at most 35)
#     [--scale N]      the window's scale (3: 960x600)
#     [--tics N]       stop once N frames of the boot shown have been closed
#     [--bmp FILE]     at the end, write the last frame shown as a BMP
#     [--hold]         at the end, keep the window until it is closed
#
# Compiled by Spinel, as bin/doom.rb is (build.sh beside this file), and the
# same Doom::Video shows it: the palette (768 B) and the 8-bit screen
# (64,000 B) go to ../native/sp_sdl_shim.c as they are. The socket is
# sp_udp_shim.c, beside this file.
#
# THE WIRE is version 3, decision 0025 point 15, as tools/doom/net_frames.rb
# reads it. One datagram is one message, its integers little-endian. Every
# message opens with the kind (u8), the version (u8, 3) and the boot id (u32,
# never 0), then:
#   'P' 0x50  768 bytes of palette (774 B), at boot and every second
#   'C' 0x43  tic u32, index u8, count u8 (50), the tic's input: the
#             controller's session id u32, the sequence number it used u32,
#             its state u8 (0 none, 1 held, 2 released by the time-out);
#             1,280 bytes of the screen (1,301 B)
#   'S' 0x53  the M7's counts: latest tic, frames sent, not sent, dropped,
#             messages dropped, u32 each (26 B)
# Another version (2 included), boot id 0, another kind or a message of the
# wrong size is a bad datagram, counted and not used. So is a piece whose
# state is above 2, of state 0 with a session or a sequence, or of state 1 or
# 2 with session 0. That includes 'T' (0x54), the M33's counts, which
# decision 0024 has abolished.
#
# BOOTS are never combined: each boot id has its own frames, palette and
# counts. The window shows the newest boot, the last whose first datagram
# arrived; a board that restarts is followed to its new boot, and the frames
# of any other boot are counted as not shown. A palette replaces the one held
# for its boot.
#
# FRAMES, within a boot. A tic's frame is complete when all 50 pieces
# arrived, and its pieces agree on the input (one that disagrees is closed
# as incomplete, counted as mismatched, and not shown). Datagrams may come out of order, so a tic stays open until a piece
# of a tic more than 8 later arrives, or the input ends; it is then closed as
# incomplete and not shown. A piece for a tic already closed is late, and one
# that arrived before is a duplicate. A piece of a tic more than 8 below the
# highest seen, of no tic closed, is a tic going backwards (two boots sharing
# an id); it is counted and not used.
#
# SHOWING. The newest complete frame is shown; a frame that a newer one
# replaced before it could be shown, or one older than the frame on screen,
# is counted as not shown. Live, the datagrams already received are taken
# first, so a viewer that falls behind skips to the newest frame rather than
# queueing old ones. A frame before its boot's first palette waits for it.
#
# This viewer judges nothing: the digests, the console and the drops are
# tools/doom/net-viewer.rb's, which reads a --record file with --replay.
#
# THE KEYS (decision 0025), live only and only with --keys ADDR:PORT, the
# board's address and its inbound port, or --keys PORT: then the address is
# the source of the first datagram of the boot shown (a board on DHCP need
# not be known in advance), and follows the board to a new boot's source; a
# datagram of the same boot from another address changes nothing. Either
# way the viewer prints `keys to ADDR:PORT for boot ID` once the destination
# is known, and again when it changes. The viewer chooses a controller
# session id when it starts (u32, never 0) and sends nothing until it knows
# the boot it shows; then, from the socket it receives on, one 'K' message
# per send, 17 bytes, little-endian:
#   kind 'K' 0x4B u8, version 1 u8, the session id u32, the boot id shown
#   u32, the sequence number u32, and the mask: 3 bytes, bit i set when
#   Doom::TiccmdBuilder::WATCHED_KEYS[i] is down (bit 0 the first byte's
#   lowest; the top 6 bits of the third byte 0)
# The mask is read after each pump, as bin/doom.rb's read_keys reads the
# keys. A message goes at 35 a second, and again whenever the mask changes;
# the sequence number advances by 1, modulo 2^32, on every send (--first-seq
# sets the first, 1 by default). While the window does not have the
# keyboard's focus every key is sent released, and at the end one message
# with every key released is sent, best effort. A send that fails is
# counted, not retried. --script FILE takes the keys from a key script
# (lib/doom/input.rb's KeyScript; its tic is the count of 35-a-second sends)
# in place of the keyboard and its focus.
#
# LATENCY (decision 0025 point 15), measured and not judged. Each send's
# key sample time is kept for the last 1,024 sequence numbers. A complete
# frame of the boot shown, of state 1 and this viewer's session, is matched
# on (boot, session, sequence) to that sample, once at the first frame
# received with it and once at the first presented with it: two spans, the
# key sample to the frame's receipt and the key sample to the call of
# present. Neither is when the frame appeared on the screen. Frames of
# state 0 or 2, another session's and a number no longer kept are not
# matched; the last are counted.
#
# The summary on stdout: one line for the datagrams, the bad ones (with the
# first one's reason), the boots and the frames shown and not shown; then
# per boot, its datagrams, palettes, frames complete and incomplete (and of
# those, mismatched), and its late, duplicate and backwards pieces, and its
# latest S. With --keys: the sends (on a change, at the period, failed) and
# the two spans' count, minimum, median and maximum in microseconds. Exit 2
# on a usage error or a recording cut short, 1 when the window or the socket
# fails, 0 otherwise.

require_relative "../lib/doom/video"
require_relative "../lib/doom/input"

module NetView
  module Udp
    ffi_func :sp_udp_open,   [:str, :int],    :int64
    ffi_func :sp_udp_rcvbuf, [:int64],        :int
    ffi_func :sp_udp_recv,   [:int64, :int],  :binstr
    ffi_func :sp_udp_status, [:int64],        :int
    ffi_func :sp_udp_send,   [:int64, :str, :int, :str, :int], :int
    ffi_func :sp_udp_from,   [:int64],        :str
    ffi_func :sp_udp_close,  [:int64],        :void
    ffi_func :sp_udp_error,  [],              :str
    ffi_func :sp_view_focused, [],            :int
  end

  WIDTH = 320
  HEIGHT = 200
  CHUNK = 1280
  PIECES = 50
  VERSION = 3
  COMMON = 6
  PIECE_HEADER = 21
  PALETTE_BYTES = 768
  STREAM_BYTES = 26
  WINDOW = 8

  def self.u32(d, o)
    d.getbyte(o) | (d.getbyte(o + 1) << 8) | (d.getbyte(o + 2) << 16) | (d.getbyte(o + 3) << 24)
  end

  def self.hex8(n)
    s = n.to_s(16)
    s = "0" + s while s.length < 8
    s
  end

  # One boot's frames, palette and counts.
  class Boot
    attr_reader :id, :datagrams, :palettes, :complete, :incomplete, :missing,
                :mismatched, :by_state, :late, :duplicate, :backwards, :palette, :frame,
                :frame_tic, :frame_session, :frame_seq, :frame_state,
                :streams, :s_tic, :s_sent, :s_not_sent, :s_dropped, :s_messages, :source

    # source: the address its first datagram came from ("" from a recording)
    def initialize(id, source)
      @id = id
      @source = source
      @open = {}        # tic -> its pieces, "" for one not yet here
      @have = {}        # tic -> how many of them are here
      @input = {}       # tic -> its first piece's input, "session seq state"
      @mixed = {}       # tic -> true once a piece disagreed with it
      @closed = {}      # tic -> true, complete or not
      @newest = -1
      @datagrams = 0
      @palettes = 0
      @complete = 0
      @incomplete = 0
      @missing = 0
      @mismatched = 0
      @by_state = [0, 0, 0]  # complete frames by their input's state
      @late = 0
      @duplicate = 0
      @backwards = 0
      @palette = ""
      @frame = ""
      @frame_tic = -1
      @frame_session = 0
      @frame_seq = 0
      @frame_state = 0
      @streams = 0
      @s_tic = -1
      @s_sent = 0
      @s_not_sent = 0
      @s_dropped = 0
      @s_messages = 0
    end

    def count
      @datagrams += 1
    end

    def palette=(rgb)
      @palettes += 1
      @palette = rgb
    end

    # the latest S, by its tic (they may come out of order)
    def stream(tic, sent, not_sent, dropped, messages)
      @streams += 1
      return if tic < @s_tic

      @s_tic = tic
      @s_sent = sent
      @s_not_sent = not_sent
      @s_dropped = dropped
      @s_messages = messages
    end

    # true when the piece completed its frame (#frame, #frame_tic and its
    # input, #frame_session, #frame_seq, #frame_state)
    def piece(tic, index, body, session, seq, state)
      if @closed.key?(tic)
        @late += 1
        return false
      end
      if !@open.key?(tic) && @newest >= 0 && tic < @newest - WINDOW
        @backwards += 1
        return false
      end
      @newest = tic if tic > @newest
      input = "#{session} #{seq} #{state}"
      unless @open.key?(tic)
        @open[tic] = Array.new(PIECES, "")
        @have[tic] = 0
        @input[tic] = input
      end
      pieces = @open[tic]
      if pieces[index].bytesize != 0
        @duplicate += 1
        return false
      end
      pieces[index] = body
      @have[tic] = @have[tic] + 1
      @mixed[tic] = true if @input[tic] != input
      done = false
      if @have[tic] == PIECES
        mixed = @mixed.key?(tic)
        @open.delete(tic)
        @have.delete(tic)
        @input.delete(tic)
        @mixed.delete(tic)
        @closed[tic] = true
        if mixed
          @incomplete += 1
          @mismatched += 1
        else
          @frame = pieces.join
          @frame_tic = tic
          @frame_session = session
          @frame_seq = seq
          @frame_state = state
          @by_state[state] += 1
          @complete += 1
          done = true
        end
      end
      close_below(tic - WINDOW)
      done
    end

    # close every open tic below `limit` as incomplete
    def close_below(limit)
      gone = []
      @open.each_key { |t| gone << t if t < limit }
      gone.each do |t|
        @incomplete += 1
        @missing += PIECES - @have[t]
        @open.delete(t)
        @have.delete(t)
        @input.delete(t)
        @mixed.delete(t)
        @closed[t] = true
      end
    end

    # the input ended: what is still open is incomplete
    def finish
      close_below(@newest + 1) if @newest >= 0
    end

    def closed
      @complete + @incomplete
    end
  end

  # Datagrams in, each to its boot; the newest boot is the one shown.
  class Stream
    attr_reader :datagrams, :bad, :bad_reason, :order, :current, :last

    def initialize
      @boots = {}
      @order = []       # boot ids, in the order their first datagram came
      @current = 0
      @last = 0         # the boot of the last datagram used
      @datagrams = 0
      @bad = 0
      @bad_reason = ""
    end

    def boot(id)
      @boots[id]
    end

    def reject(reason)
      @bad += 1
      @bad_reason = reason if @bad_reason == ""
      0
    end

    # 0 nothing to show, 1 a palette, 2 a complete frame, 3 a new boot
    # (then the newest; its datagram is used as well, and #feed answers 3
    # whatever it was), each of boot #last
    # `from`: the datagram's source address ("" from a recording)
    def feed(d, from)
      @datagrams += 1
      n = d.bytesize
      return reject("shorter than the common header") if n < COMMON

      kind = d.getbyte(0)
      version = d.getbyte(1)
      id = NetView.u32(d, 2)
      return reject("version #{version}") if version != VERSION
      return reject("boot id 0") if id == 0

      if kind == 0x50
        return reject("palette of #{n - COMMON} bytes") if n != COMMON + PALETTE_BYTES
      elsif kind == 0x43
        return reject("short piece header") if n < PIECE_HEADER
        return reject("piece count #{d.getbyte(11)}, not #{PIECES}") if d.getbyte(11) != PIECES
        return reject("piece index #{d.getbyte(10)} of #{PIECES}") if d.getbyte(10) >= PIECES
        return reject("piece #{d.getbyte(10)} of #{n - PIECE_HEADER} bytes, not #{CHUNK}") if n - PIECE_HEADER != CHUNK
        st = d.getbyte(20)
        return reject("input state #{st}") if st > 2
        return reject("no input with a session or sequence") if st == 0 && (NetView.u32(d, 12) != 0 || NetView.u32(d, 16) != 0)
        return reject("input state #{st} with session 0") if st != 0 && NetView.u32(d, 12) == 0
      elsif kind == 0x53
        return reject("stream counts of #{n} bytes") if n != STREAM_BYTES
      else
        return reject("kind 0x#{kind.to_s(16)}")
      end

      fresh = false
      unless @boots.key?(id)
        @boots[id] = Boot.new(id, from)
        @order << id
        @current = id
        fresh = true
      end
      b = @boots[id]
      b.count
      @last = id
      r = 0
      if kind == 0x50
        b.palette = d.byteslice(COMMON, PALETTE_BYTES)
        r = 1
      elsif kind == 0x43
        r = 2 if b.piece(NetView.u32(d, 6), d.getbyte(10), d.byteslice(PIECE_HEADER, CHUNK),
                         NetView.u32(d, 12), NetView.u32(d, 16), d.getbyte(20))
      else
        b.stream(NetView.u32(d, 6), NetView.u32(d, 10), NetView.u32(d, 14), NetView.u32(d, 18), NetView.u32(d, 22))
      end
      fresh ? 3 : r
    end

    def finish
      @order.each { |id| @boots[id].finish }
    end

    # frames closed in the boot shown
    def closed
      @current == 0 ? 0 : @boots[@current].closed
    end
  end

  # The window, and which frame it shows next.
  class Display
    attr_reader :shown, :skipped, :video, :shown_session, :shown_seq, :shown_state, :present_us

    def initialize(scale, fps)
      @video = Doom::Video.new("DOOM from the board", WIDTH, HEIGHT, scale)
      @pending_session = 0
      @pending_seq = 0
      @pending_state = 0
      @shown_session = 0
      @shown_seq = 0
      @shown_state = 0
      @present_us = 0
      @period = fps > 0 ? 1_000_000 / fps : 0
      @due = 0
      @has_palette = false
      @pending = ""
      @pending_tic = -1
      @last_tic = -1
      @last_us = 0
      @shown = 0
      @skipped = 0
    end

    def palette=(pal)
      @video.palette = pal
      @has_palette = true
    end

    # a new boot: its tics start again, and its palette is its own
    def new_boot
      drop_pending
      @has_palette = false
      @last_tic = -1
    end

    def offer(tic, screen, session, seq, state)
      if tic <= @last_tic || tic <= @pending_tic
        @skipped += 1
        return
      end
      @skipped += 1 if @pending_tic >= 0
      @pending = screen
      @pending_tic = tic
      @pending_session = session
      @pending_seq = seq
      @pending_state = state
    end

    # a frame of a boot not shown
    def pass
      @skipped += 1
    end

    def pending?
      @pending_tic >= 0 && @has_palette
    end

    def now
      @video.elapsed_us
    end

    # microseconds until the next frame may be shown (0: now)
    def wait_us
      w = @due - now
      w > 0 ? w : 0
    end

    def since_last_us
      now - @last_us
    end

    # true when a frame was presented (#shown_session, #shown_seq,
    # #shown_state, and #present_us, when present was called)
    def show
      return false unless pending?

      @present_us = now
      @video.present(@pending)
      @shown_session = @pending_session
      @shown_seq = @pending_seq
      @shown_state = @pending_state
      @shown += 1
      @last_tic = @pending_tic
      @pending_tic = -1
      @pending = ""
      t = now
      @last_us = t
      @due = @due + @period
      @due = t if @due < t
      true
    end

    # a frame never shown for want of a palette counts as not shown
    def drop_pending
      if @pending_tic >= 0
        @skipped += 1
        @pending_tic = -1
      end
    end

    def quit?
      @video.pump
    end

    def delay_ms(ms)
      @video.delay_ms(ms)
    end

    def save_bmp(path)
      @video.save_bmp(path)
    end

    def close
      @video.close
    end
  end

  # --record: each datagram as its length (u32, little-endian) and its bytes
  class Recorder
    def initialize(path)
      @f = File.open(path, "wb")
    end

    def write(d)
      n = d.bytesize
      @f.write([n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff].pack("C*"))
      @f.write(d)
    end

    def close
      @f.close
    end
  end

  # --keys: the controller of decision 0025, its sends and its latency spans
  class Controller
    PERIOD_US = 28_571  # 35 a second
    HISTORY = 1024      # the sequence numbers whose sample time is kept
    MASK32 = 0xffffffff

    attr_reader :enabled, :session, :first_seq, :last_seq, :sends, :periodic, :changes, :finals,
                :failed, :first_error, :forgotten, :rx_spans, :pr_spans

    # addr "" with a port: the boot's source address (--keys PORT)
    def initialize(addr, port, session, first_seq, script)
      @enabled = port > 0
      @addr = addr
      @port = port
      @dest = ""        # where the keys go now, and for which boot
      @dest_boot = 0
      @session = session
      @first_seq = first_seq
      @seq = first_seq
      @last_seq = -1
      @scripted = script != ""
      @script = @scripted ? Doom::KeyScript.new(script) : nil
      @ks = Doom::KeyState.new
      @started = false
      @mask = 0
      @boot = 0
      @next_us = 0
      @period_n = 0     # sends at the period so far: the script's tic
      @sends = 0
      @periodic = 0
      @changes = 0
      @finals = 0
      @failed = 0
      @first_error = ""
      @h_seq = Array.new(HISTORY, -1)
      @h_boot = Array.new(HISTORY, 0)
      @h_us = Array.new(HISTORY, 0)
      @h_rx = Array.new(HISTORY, 0)
      @h_pr = Array.new(HISTORY, 0)
      @forgotten = 0
      @rx_spans = []
      @pr_spans = []
    end

    # the 18 watched keys as the mask: bit i is WATCHED_KEYS[i]
    def mask_of(video)
      codes = Doom::TiccmdBuilder::WATCHED_KEYS
      down = @ks.down
      if @scripted
        @script.apply(@ks, @period_n)
      elsif Udp.sp_view_focused == 0
        return 0
      end
      m = 0
      i = 0
      while i < codes.length
        on = @scripted ? down[codes[i]] : video.key(codes[i])
        m |= 1 << i if on != 0
        i += 1
      end
      m
    end

    # after a pump: a send when the period has come, or the mask or the boot
    # shown changed; nothing before the boot (and with --keys PORT, its
    # source) is known
    def tick(sock, video, boot, source, now)
      return if !@enabled || boot == 0

      dest = @addr != "" ? @addr : source
      return if dest == ""

      if dest != @dest || boot != @dest_boot
        @dest = dest
        @dest_boot = boot
        puts "net_view: keys to #{dest}:#{@port} for boot #{NetView.hex8(boot)}"
      end
      m = mask_of(video)
      unless @started
        @started = true
        @next_us = now
      end
      if now >= @next_us
        send(sock, boot, m, now)
        @periodic += 1
        @period_n += 1
        @next_us += PERIOD_US
        @next_us = now + PERIOD_US if @next_us <= now
      elsif m != @mask || boot != @boot
        send(sock, boot, m, now)
        @changes += 1
      end
    end

    # milliseconds until the next send at the period (0: now)
    def wait_ms(now)
      return 20 if !@enabled || !@started

      w = @next_us - now
      w > 0 ? (w + 999) / 1000 : 0
    end

    # the end: every key released, once, best effort
    def finish(sock, boot, now)
      return if !@enabled || !@started || boot == 0

      send(sock, boot, 0, now)
      @finals += 1
    end

    def send(sock, boot, m, now)
      s = @session
      q = @seq
      msg = [0x4b, 1, s & 0xff, (s >> 8) & 0xff, (s >> 16) & 0xff, (s >> 24) & 0xff,
             boot & 0xff, (boot >> 8) & 0xff, (boot >> 16) & 0xff, (boot >> 24) & 0xff,
             q & 0xff, (q >> 8) & 0xff, (q >> 16) & 0xff, (q >> 24) & 0xff,
             m & 0xff, (m >> 8) & 0xff, (m >> 16) & 0xff].pack("C*")
      @sends += 1
      if Udp.sp_udp_send(sock, @dest, @port, msg, msg.bytesize) != msg.bytesize
        @failed += 1
        @first_error = Udp.sp_udp_error if @first_error == ""
      end
      k = q % HISTORY
      @h_seq[k] = q
      @h_boot[k] = boot
      @h_us[k] = now
      @h_rx[k] = 0
      @h_pr[k] = 0
      @last_seq = q
      @seq = (q + 1) & MASK32
      @mask = m
      @boot = boot
    end

    # the slot of (boot, this session, seq), or -1: not this session's held
    # input, or a number no longer kept
    def slot(boot, session, seq, state)
      return -1 if !@enabled || state != 1 || session != @session

      k = seq % HISTORY
      return k if @h_seq[k] == seq && @h_boot[k] == boot

      -1
    end

    # a complete frame of the boot shown was received at `now`
    def received(boot, session, seq, state, now)
      k = slot(boot, session, seq, state)
      if k < 0
        @forgotten += 1 if @enabled && state == 1 && session == @session
        return
      end
      return if @h_rx[k] != 0

      @h_rx[k] = 1
      @rx_spans << now - @h_us[k]
    end

    # a frame was presented, present called at `at`
    def presented(boot, session, seq, state, at)
      k = slot(boot, session, seq, state)
      return if k < 0 || @h_pr[k] != 0

      @h_pr[k] = 1
      @pr_spans << at - @h_us[k]
    end
  end

  def self.spans(list)
    return "0 matched" if list.empty?

    s = list.sort
    "#{s.length} matched, min #{s[0]} us, median #{s[(s.length - 1) / 2]} us, max #{s[s.length - 1]} us"
  end

  # a pending frame presented, and its latency span
  def self.show(disp, ctl, boot)
    return unless disp.show

    ctl.presented(boot, disp.shown_session, disp.shown_seq, disp.shown_state, disp.present_us)
  end

  def self.digits?(s)
    s.each_char { |c| return false if c < "0" || c > "9" }
    true
  end

  # dotted IPv4, each part 0..255
  def self.ipv4?(a)
    parts = a.split(".")
    return false if parts.length != 4

    parts.each do |p|
      return false if p.length < 1 || p.length > 3
      p.each_char { |c| return false if c < "0" || c > "9" }
      return false if p.to_i > 255
    end
    true
  end

  # one datagram to the stream, and what it means for the window
  def self.take(stream, disp, d, ctl, from)
    r = stream.feed(d, from)
    return if r == 0

    b = stream.boot(stream.last)
    if r == 3
      disp.new_boot
      # the datagram that opened the boot: its palette is used (one piece
      # cannot complete a frame)
      r = b.palettes > 0 ? 1 : 0
    end
    if stream.last != stream.current
      disp.pass if r == 2
      return
    end
    disp.palette = b.palette if r == 1
    return if r != 2

    ctl.received(stream.current, b.frame_session, b.frame_seq, b.frame_state, disp.now)
    disp.offer(b.frame_tic, b.frame, b.frame_session, b.frame_seq, b.frame_state)
  end

  def self.usage(why)
    STDERR.puts "net_view: #{why}"
    STDERR.puts "usage: net_view [--port N] [--bind ADDR] [--idle S] [--keys ADDR:PORT [--script FILE] [--first-seq N]] | --replay FILE; " \
                "[--record FILE] [--fps N] [--scale N] [--tics N] [--bmp FILE] [--hold]"
    exit 2
  end

  def self.main
    port = 5029
    bind = "0.0.0.0"
    idle = 5.0
    replay = ""
    record = ""
    fps = 0
    scale = 3
    tics = 0
    bmp = ""
    hold = false
    keys = ""
    script = ""
    first_seq = 1
    i = 0
    while i < ARGV.length
      a = ARGV[i]
      v = i + 1 < ARGV.length ? ARGV[i + 1] : ""
      if a == "--hold"
        hold = true
        i += 1
        next
      end
      usage("#{a} needs a value") if i + 1 >= ARGV.length
      if a == "--port"
        port = v.to_i
      elsif a == "--bind"
        bind = v
      elsif a == "--idle"
        idle = v.to_f
      elsif a == "--replay"
        replay = v
      elsif a == "--record"
        record = v
      elsif a == "--fps"
        fps = v.to_i
      elsif a == "--scale"
        scale = v.to_i
      elsif a == "--tics"
        tics = v.to_i
      elsif a == "--bmp"
        bmp = v
      elsif a == "--keys"
        keys = v
      elsif a == "--script"
        script = v
      elsif a == "--first-seq"
        first_seq = v.to_i
      else
        usage("unknown option #{a}")
      end
      i += 2
    end
    usage("--port must be 1..65535") if port < 1 || port > 65535
    usage("--fps must not be negative") if fps < 0
    usage("--scale must be positive") if scale < 1
    usage("--tics must not be negative") if tics < 0
    usage("--idle must be positive") if idle <= 0.0
    key_addr = ""
    key_port = 0
    if keys != ""
      usage("--keys and --replay: the keys go to a board, live") if replay != ""
      kv = keys.split(":")
      usage("--keys #{keys}: [ADDR:]PORT, the board's IPv4 address and inbound port") if kv.length > 2 || kv.length < 1 ||
                                                                                          (kv.length == 2 && !ipv4?(kv[0]))
      key_addr = kv.length == 2 ? kv[0] : ""
      kp = kv[kv.length - 1]
      usage("--keys #{keys}: the port must be a number") if kp.length < 1 || kp.length > 5 || !digits?(kp)
      key_port = kp.to_i
      usage("--keys #{keys}: the port must be 1..65535") if key_port < 1 || key_port > 65535
    end
    usage("--script needs --keys") if script != "" && keys == ""
    usage("no key script at #{script}") if script != "" && !File.exist?(script)
    usage("--first-seq must be 0..4294967295") if first_seq < 0 || first_seq > 0xffffffff

    # a recording is read whole and checked before anything opens
    data = ""
    if replay != ""
      usage("no recording at #{replay}") unless File.exist?(replay)
      data = File.binread(replay)
      o = 0
      while o < data.bytesize
        usage("#{replay}: recording cut inside a length at byte #{o}") if o + 4 > data.bytesize
        n = u32(data, o)
        usage("#{replay}: recording cut inside a datagram at byte #{o}") if o + 4 + n > data.bytesize
        o += 4 + n
      end
    end

    stream = Stream.new
    disp = Display.new(scale, fps)
    rec = record == "" ? nil : Recorder.new(record)
    # the controller's session id: u32, never 0, new at each start
    srand(Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond))
    ctl = Controller.new(key_addr, key_port, rand(0xffffffff) + 1, first_seq, script)
    sock = 0
    if replay == ""
      sock = Udp.sp_udp_open(bind, port)
      if sock == 0
        STDERR.puts "net_view: UDP #{bind}:#{port}: #{Udp.sp_udp_error}"
        disp.close
        exit 1
      end
      puts "net_view: listening on #{bind}:#{port}, receive buffer #{Udp.sp_udp_rcvbuf(sock)} bytes"
      if ctl.enabled
        from = script != "" ? "the key script #{script}" : "the keyboard"
        to = key_addr != "" ? "#{key_addr}:#{key_port}" : "port #{key_port} of the boot's source"
        puts "net_view: keys to #{to}, session #{hex8(ctl.session)}, first sequence #{first_seq}, from #{from}"
      end
    end

    quit = false
    failed = false
    if replay != ""
      o = 0
      while o < data.bytesize && !quit
        n = u32(data, o)
        d = data.byteslice(o + 4, n)
        o += 4 + n
        rec.write(d) if rec
        take(stream, disp, d, ctl, "")
        if disp.pending?
          w = disp.wait_us
          disp.delay_ms((w + 999) / 1000) if w > 0
          show(disp, ctl, stream.current)
        end
        quit = disp.quit?
        quit = true if tics > 0 && stream.closed >= tics
      end
    else
      idle_us = (idle * 1_000_000).to_i
      last_rx = -1
      while !quit
        wait = 20
        if disp.pending?
          w = disp.wait_us
          wait = w > 0 ? (w + 999) / 1000 : 0
          wait = 20 if wait > 20
        end
        if ctl.enabled
          # keys are read after each pump: wait little, and not past the period
          kw = ctl.wait_ms(disp.now)
          wait = kw if kw < wait
          wait = 4 if wait > 4
        end
        d = Udp.sp_udp_recv(sock, wait)
        st = Udp.sp_udp_status(sock)
        if st < 0
          STDERR.puts "net_view: receive: #{Udp.sp_udp_error}"
          failed = true
          break
        end
        if st > 0
          last_rx = disp.now
          rec.write(d) if rec
          take(stream, disp, d, ctl, Udp.sp_udp_from(sock))
          # behind a steady stream, still show once a frame's time has passed
          show(disp, ctl, stream.current) if disp.pending? && disp.wait_us == 0 && disp.since_last_us >= 28_000
        else
          show(disp, ctl, stream.current) if disp.pending? && disp.wait_us == 0
          quit = true if last_rx >= 0 && disp.now - last_rx >= idle_us
        end
        quit = true if disp.quit?
        ctl.tick(sock, disp.video, stream.current, stream.current == 0 ? "" : stream.boot(stream.current).source, disp.now)
        quit = true if tics > 0 && stream.closed >= tics
      end
      ctl.finish(sock, stream.current, disp.now)
      Udp.sp_udp_close(sock)
    end
    stream.finish
    show(disp, ctl, stream.current) if disp.pending?
    disp.drop_pending
    rec.close if rec
    disp.save_bmp(bmp) if bmp != "" && disp.shown > 0

    bad = stream.bad > 0 ? " (first: #{stream.bad_reason})" : ""
    puts "net_view: datagrams #{stream.datagrams}, bad #{stream.bad}#{bad}, boots #{stream.order.length}, " \
         "shown #{disp.shown}, not shown #{disp.skipped}"
    stream.order.each do |id|
      b = stream.boot(id)
      h = hex8(id)
      shown = id == stream.current ? ", shown" : ""
      puts "net_view: boot #{h}#{shown}: datagrams #{b.datagrams}, palettes #{b.palettes}, frames complete #{b.complete}, " \
           "incomplete #{b.incomplete} (#{b.missing} pieces missing), late #{b.late}, duplicate #{b.duplicate}, backwards #{b.backwards}"
      puts "net_view: boot #{h}: input of the complete frames: none #{b.by_state[0]}, held #{b.by_state[1]}, " \
           "released #{b.by_state[2]}; mismatched #{b.mismatched}"
      if b.streams > 0
        puts "net_view: boot #{h}: S tic #{b.s_tic}, sent #{b.s_sent}, not sent #{b.s_not_sent}, dropped #{b.s_dropped}, " \
             "messages dropped #{b.s_messages}"
      end
    end
    if ctl.enabled
      err = ctl.failed > 0 ? " (first: #{ctl.first_error})" : ""
      puts "net_view: keys session #{hex8(ctl.session)}: sends #{ctl.sends} (#{ctl.periodic} at the period, " \
           "#{ctl.changes} on a change, #{ctl.finals} at the end), failed #{ctl.failed}#{err}, " \
           "sequence #{ctl.first_seq} to #{ctl.last_seq}"
      puts "net_view: latency, key sample to frame received: #{spans(ctl.rx_spans)}"
      puts "net_view: latency, key sample to present called: #{spans(ctl.pr_spans)}"
      puts "net_view: frames of this session with a sequence no longer kept: #{ctl.forgotten}"
    end
    if hold
      disp.delay_ms(16) until disp.quit?
    end
    disp.close
    exit 1 if failed
  end
end

NetView.main
