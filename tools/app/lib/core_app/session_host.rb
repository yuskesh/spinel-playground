# frozen_string_literal: true
#
# tools/app/lib/core_app/session_host.rb -- an application with a core_session,
# run under CRuby (decision 0021, Clarification of 2026-10-20).
#
# The board application has one entry in one context, so what is checked here
# is its body, not 0014's scheduling (tests/app/host.sh covers that with the
# event-driven host runner): the entry is called release after release, in
# order, under CRuby, over
#
#   * the session at open, from the image: every field of image.tsv as an
#     Array decoded from resources.bin and writable.bin at its element (the
#     core_state slots as one Array, a scratch field zeroed), each Array one
#     object that the application's parameters and the entries' share;
#   * DoomCore.input, .step and .render executing the entries' CORE source as
#     plain Ruby (the units of examples/doom/core/entries/units.tsv, loaded as
#     tests/doom-core/step-diff.rb loads them), handed every buffer by
#     entries/fields.tsv and each count as its Array's length; a refusal
#     (core_fail, or a Ruby error from an index past an end) answers a
#     nonzero status, as the compiled entry would answer one;
#   * Slot::NAME and Image::DEMO_OFFSET / DEMO_TICS, as the build generates them;
#   * the application's own states, zeroed; Clock.cycles and Clock.cycles32
#     answering 0, or with `cycles_per_release:` the release's index times it
#     (a clock that moves, for decision 0025's pace and time-out); Frame.digests computing the two FNV-1a 64 digests the
#     provider writes (the board computes no SHA-256: 0021); the
#     application's channels collecting what is put (a udp: channel's
#     messages apart from the console's lines); Clock::CYCLES_PER_SECOND and
#     Ring.boot_id, a fixed non-zero id, for the frame stream of decision 0024;
#   * an :in channel's get answering the messages `inbound:` gives, each
#     [release, bytes] queued before that release, FIFO, at most the
#     channel's depth (a message that finds it full is counted, not queued).
#
# It answers the lines the application put, and every command DoomCore.step
# was called with (core_command, read at the call): what the board lane and
# tests/app/session.sh compare with Full's Demo object and the recorded
# frames.
#
# With `companion:` (decision 0027 stage 2) the application's contract
# channels are the pair's: each is one CoreApp::CoreChannelSim that the
# application puts into and the companion, loaded into the same process,
# gets from. The companion's one entry runs after each release of the
# application's (on the board the relay is woken by the channel's doorbell
# after a put, decision 0028), and its uart: channel's
# lines are the console's, as the M33 writes them. `consumer_stopped:` never
# runs the companion, so nothing takes (0027's control 5).
require_relative "session"
require_relative "checked"
require_relative "core_channel_sim"

module CoreApp
  class SessionHost
    UNPACK = { "u8" => "C*", "i8" => "c*", "u16" => "S<*", "i16" => "s<*", "u32" => "L<*", "i32" => "l<*", "i64" => "q<*" }.freeze
    Result = Struct.new(:lines, :commands, :calls, :datagrams, :inbound_full, :releases, :states, :channels, :companion_states,
                        keyword_init: true)
    BOOT_ID = [1, 0, 0, 0].freeze

    def initialize(app_path:, image_dir:, root:)
      @app_path = File.expand_path(app_path)
      @root = root
      require_relative "declarations"
      @app = Declarations.read(@app_path)
      raise Session::Error, "#{@app_path} declares no core_session" unless @app.session_path
      @entries_dir = File.expand_path(@app.session_path, File.dirname(@app_path))
      @info = Session.read(@entries_dir, image_dir)
      @arrays = arrays_of(@info.image, image_dir)
    end

    def arrays_of(img, dir)
      res = File.binread(File.join(dir, "resources.bin"))
      rw = File.binread(File.join(dir, "writable.bin"))
      out = {}
      img.fields.each_value do |f|
        out[f.name] = case f.part
                      when "resource", "derived" then res.byteslice(f.offset, f.bytes).unpack(UNPACK.fetch(f.element))
                      when "writable" then rw.byteslice(f.offset, f.bytes).unpack(UNPACK.fetch(f.element))
                      when "scratch" then Array.new(f.count, 0)
                      end
      end
      out["core_state"] = rw.byteslice(0, 8 * img.slots.size).unpack("q<*")
      out
    end

    # Runs the entry until `frames` frame lines, or the demo's end, or a stop.
    # `planted:` {member => status} makes that DoomCore member answer the
    # status without running, as a failing entry would (a control of the
    # caller's refusal; tests/app/play.sh).
    def run(frames:, limit: 100_000, inbound: [], cycles_per_release: 0, planted: {}, companion: nil, consumer_stopped: false)
      host = self
      arrays = @arrays
      info = @info
      commands = []
      calls = Hash.new(0)
      lines = []
      load_core_source
      define_doomcore(arrays, info, commands, calls, planted)
      define_constants(info)
      Object.const_set(:Clock, Module.new) unless Object.const_defined?(:Clock)
      release = 0
      Clock.define_singleton_method(:cycles) { release * cycles_per_release }
      Clock.define_singleton_method(:cycles32) { (release * cycles_per_release) & 0xffff_ffff }
      # the board package's constant (board.rb's CONFIG_CONSTANTS); the clock
      # stands still here, so its value only sets the period's arithmetic
      Clock.const_set(:CYCLES_PER_SECOND, 1_000_000) unless Clock.const_defined?(:CYCLES_PER_SECOND, false)
      # the boot id the M33 publishes (decision 0024): a fixed non-zero one,
      # so that the stream's code runs here as it does once DHCP has bound
      Object.const_set(:Ring, Module.new) unless Object.const_defined?(:Ring)
      Ring.define_singleton_method(:boot_id) do |out|
        BOOT_ID.each_with_index { |b, i| out[i] = b }
        nil
      end
      datagrams = []
      queue = []
      full = 0
      pending_in = inbound.sort_by(&:first)
      Object.const_set(:Frame, Module.new) unless Object.const_defined?(:Frame)
      Frame.define_singleton_method(:digests) do |screen, view, out|
        bytes = screen.pack("C*")
        hex = "#{host.fnv(bytes.byteslice(0, view))} #{host.fnv(bytes)}"
        hex.bytes.each_with_index { |b, i| out[i] = b }
        nil
      end
      comp = companion && Declarations.read(File.expand_path(companion))
      sims = {}
      put_line = lambda do |buf, n|
        lines.concat(buf[0, n].map { |x| x.is_a?(String) ? x.ord : x }.pack("C*").lines)
        1
      end
      @app.channels.each do |c|
        mod = Object.const_defined?(c.module_name) ? Object.const_get(c.module_name) : Object.const_set(c.module_name, Module.new)
        if c.contract
          raise Session::Error, "channel #{c.name} is a contract channel: run the application with its companion" unless comp
          other = comp.channels.find { |x| x.name == c.name && x.contract }
          raise Session::Error, "the companion names no contract channel #{c.name}" unless other
          k = c.contract
          sim = sims[c.name] = CoreChannelSim.new(c.name, "out", k.depth, k.fields.map { |f| [f.name, f.type, f.array ? f.count : nil] })
          mod.define_singleton_method(:put) { |*a| sim.put(*a) }
          mod.define_singleton_method(:get) { |*b| sim.get(*b) }
          next
        end
        if c.direction == "in"
          mod.define_singleton_method(:get) do |buf|
            next 0 if queue.empty?
            m = queue.shift
            m.bytes.each_with_index { |b, i| buf[i] = b }
            m.bytesize
          end
          depth = c.depth
          deliver = lambda do
            while (m = pending_in.first) && m[0] <= release
              pending_in.shift
              if queue.size < depth then queue << m[1].b else full += 1 end
            end
          end
          define_singleton_method(:deliver_inbound) { deliver.call }
          next
        end
        if c.udp
          # a udp: channel's messages are datagrams, not console lines
          mod.define_singleton_method(:put) do |buf, n|
            datagrams << buf[0, n].pack("C*")
            1
          end
          next
        end
        mod.define_singleton_method(:put) do |buf, n|
          # a string literal's bytes arrive as one-character Strings under
          # CRuby (net.rb's put_str copies `s[i]`); the target lowers the
          # literal to bytes, so each is taken by its byte
          # one message may hold several lines (the B line before the first F
          # line, the N line before D: decision 0024); each is a line
          lines.concat(buf[0, n].map { |x| x.is_a?(String) ? x.ord : x }.pack("C*").lines)
          1
        end
      end
      # the companion's own channels: its uart: one is the console
      (comp&.channels || []).each do |c|
        next if c.contract
        raise Session::Error, "the companion's channel #{c.name} is not an :out uart: channel" unless c.uart && c.direction == "out"
        mod = Object.const_defined?(c.module_name) ? Object.const_get(c.module_name) : Object.const_set(c.module_name, Module.new)
        mod.define_singleton_method(:put) { |buf, n| put_line.call(buf, n) }
      end
      $LOAD_PATH.unshift(File.join(@root, "tools/app/lib")) unless $LOAD_PATH.include?(File.join(@root, "tools/app/lib"))
      load @app_path
      load File.expand_path(companion) if comp
      entry, = @app.scheduled.first
      own = @app.states.to_h { |s| [s.name, Array.new(s.count, 0)] }
      args = entry.params.map { |p| own[p] || arrays.fetch(p) { raise Session::Error, "#{p} is neither a state nor a session field" } }
      if comp
        centry, = comp.scheduled.first
        cown = comp.states.to_h { |s| [s.name, Array.new(s.count, 0)] }
        cargs = centry.params.map { |p| cown.fetch(p) { raise Session::Error, "the companion's #{p} is not a state" } }
      end
      n = 0
      while lines.count { |l| l.start_with?("F ") } < frames && n < limit
        deliver_inbound if respond_to?(:deliver_inbound)
        Object.send(entry.name, *args)
        Object.send(centry.name, *cargs) if comp && !consumer_stopped
        n += 1
        release = n
        break if lines.any? { |l| l.start_with?("D ", "X ") }
      end
      Result.new(lines: lines, commands: commands, calls: calls, datagrams: datagrams, inbound_full: full, releases: n,
                 states: own, channels: sims, companion_states: cown)
    end

    def fnv(bytes)
      h = 0xcbf29ce484222325
      bytes.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & 0xffff_ffff_ffff_ffff }
      format("%016x", h)
    end

    # The units, after decision 0022's intrinsics for CRuby (tools/core/
    # intrinsics.rb): CORE compiles core_w32_add and the rest itself, and
    # the units call them as top-level methods, which plain Ruby needs
    # defined. The prelude is loaded here and never packed.
    def load_core_source
      load File.join(@root, "tools/core/intrinsics.rb")
      src = File.join(@root, "examples/doom/core/src")
      File.readlines(File.join(@entries_dir, "units.tsv")).reject { |l| l.start_with?("#") || l.strip.empty? }
          .each { |l| load File.join(src, l.split("\t").first) }
    end

    def define_doomcore(arrays, info, commands, calls, planted = {})
      Object.const_set(:DoomCore, Module.new) unless Object.const_defined?(:DoomCore)
      Session::MEMBER.each do |entry, member|
        params = info.entries[entry]
        DoomCore.define_singleton_method(member) do |*scalars|
          commands << arrays["core_command"].dup if member == "step"
          calls[member] += 1
          next planted[member] if planted.key?(member)
          sc = scalars.dup
          args = params.map do |p|
            if p.buffer?
              f = info.fields[[entry, p.name]]
              arrays.fetch(f) { raise Session::Error, "#{entry} #{p.name}: no array for #{f}" }
            elsif p.count?
              b = params.find { |x| x.name == p.count_of }
              arrays.fetch(info.fields[[entry, b.name]]).length
            else
              sc.shift
            end
          end
          begin
            Object.send(entry, *args)
            0
          rescue Checked::Failure
            4
          rescue NoMethodError, TypeError, IndexError
            3
          end
        end
      end
    end

    def define_constants(info)
      slot = Object.const_defined?(:Slot) ? Slot : Object.const_set(:Slot, Module.new)
      info.image.slots.each { |f| slot.const_set(f.name.upcase, f.offset / 8) unless slot.const_defined?(f.name.upcase, false) }
      return unless (d = info.image.demo)
      image = Object.const_defined?(:Image) ? Image : Object.const_set(:Image, Module.new)
      image.const_set(:DEMO_OFFSET, d[:offset]) unless image.const_defined?(:DEMO_OFFSET, false)
      image.const_set(:DEMO_TICS, d[:tics]) unless image.const_defined?(:DEMO_TICS, false)
      image.const_set(:PLAYPAL_OFFSET, d[:playpal]) if d[:playpal] && !image.const_defined?(:PLAYPAL_OFFSET, false)
    end
  end
end
