# frozen_string_literal: true
#
# tools/app/lib/core_app/host_runner.rb -- the CRuby reference run of an
# application (decision 0014 §10, scheduling §4, channels §5).
#
# THE CLOCK IS VIRTUAL, in microseconds from epoch 0. Executing an invocation
# advances it by that invocation's `cost` from the stimulus (0 when none is
# given); when nothing executes, it jumps to the next event: a release, a
# stimulus item, the horizon. Idle time is the jump, never a cost.
#
# THE ACTORS are those of §4, on one virtual core:
#   - the scheduler thread (context 0) sweeps the thread entries in
#     declaration order with a fresh clock reading per entry, then sleeps
#     until the next release;
#   - the system clock interrupt (context 3) sweeps the interrupt entries at
#     each timer expiry, and preempts a running thread invocation: an expiry
#     that falls inside a thread invocation's cost window runs there, and the
#     thread invocation's end moves past it. An expiry that is late (the
#     clock has run past it) is handled at the clock it finds, and finds
#     nothing newer pending when an earlier expiry already ran the release;
#   - the transport thread (context 1) fills the :in channels from `inbound`
#     items at their time, and drains the :out channels to the UART whenever
#     the scheduler thread is idle -- between invocations, at no cost -- and
#     once more after the horizon. It does not run inside an invocation's
#     cost window, so a channel fills only when one invocation, or a burst of
#     interrupt invocations inside a thread invocation's window, puts more
#     than `depth` messages;
#   - the stimulus thread (context 2) sets the board simulators from `adc`
#     and `gpio` items at their time.
#
# A Ruby method body cannot be suspended half way, so an invocation's effects
# are taken in one piece at its start, and what preempts it lands after them
# and before its END: one legal interleaving of the target's, which is what
# the oracle needs and all it claims. The selection rule is applied exactly
# as §4 states it: newest pending release from the clock reading, every
# release strictly between it and the last run release skipped, never caught
# up.
#
# FAILURE (§4): a status other than OK stops every entry of that context;
# the releases they had admitted and not yet classified are CANCEL records
# naming the FAIL. Devices' safe states are the target glue's business
# (Task 10) and are not simulated here.
#
# END (§10): at H the dispatchers stop selecting and write one CUT per entry
# for its pending releases; the transport drains the :out channels to the
# UART (TX records); inbound messages still queued are reported unconsumed,
# stranded when their consumer context stopped by a recorded failure; the
# end marker closes the trace. The host has no drain deadline to miss, so the
# marker always states a complete drain, and D is only recorded.
require_relative "app_model"
require_relative "checked"
require_relative "channel_sim"
require_relative "board_host"
require_relative "stimulus"
require_relative "trace"

module CoreApp
  class HostRunner
    Result = Struct.new(:trace, :failures, :unconsumed, :drops, :horizon, :final_clock, keyword_init: true)
    Failure = Struct.new(:entry, :release, :status, :seq, keyword_init: true)

    # DECISION 0041 STAGE 2: a context's data stack, as the target lays it
    # out: an offset word and elements of the body's width (CoreApp.body_bits:
    # 4 bytes, or 8 for a listed `# spinel: int64` application), whatever the
    # states' elements. Core::Buffer.<width>(n, v) inside an entry (decision
    # 0045; Array.new before it) takes n elements from it,
    # BOUNDS for a negative n and CAPACITY past the region, and every method
    # gives back what it took when it returns, by any path.
    class Scratch
      def initialize(bytes, bits)
        @word = bits / 8
        @element = "i#{bits}"
        @room = bytes - @word
        @offset = 0
      end
      attr_accessor :offset
      attr_reader :element

      def make(n, fill)
        n = Checked.plain(n)
        raise Checked::Failure, "bounds" unless n.is_a?(Integer) && n >= 0
        raise Checked::Failure, "capacity" if n > (@room - @offset) / @word
        @offset += n * @word
        b = Buffer.new("<array>", @element, n)
        n.times { |i| b[i] = fill }
        b
      end
    end

    class << self
      attr_accessor :scratch, :scratch_files

      # A file as the model compares it: resolved, so the application's own
      # file is recognised when it was named through a symbolic link (macOS's
      # TMPDIR is one), as Ruby names it in a backtrace.
      def real(path)
        return nil if path.nil?
        (@real ||= {})[path] ||= begin
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end
      end
    end

    # Decision 0045: Core::Buffer reaches the model only from the
    # application's own files, while an entry of a context with a data stack
    # runs; anywhere else it is spinel/core.rb's plain Array. An element name
    # other than the body's width is refused by name, as the build refuses it
    # (array-element). Array.new is Ruby's own: the build refuses it.
    module BufferNew
      %i[i8 i16 i32 i64 u8 u16 u32 f32 f64].each do |e|
        define_method(e) do |*args, &blk|
          m = HostRunner.scratch
          at = caller_locations(1, 1).first
          return super(*args, &blk) if m.nil? || blk || !HostRunner.scratch_files.include?(HostRunner.real(at.absolute_path))
          unless e.to_s == m.element
            raise WidthRefused, "#{at.absolute_path}:#{at.lineno}: array-element: Core::Buffer.#{e} in a body of " \
                                "#{m.element.delete('i')}-bit Integers; a scratch array's elements have the body's " \
                                "integer width, Core::Buffer.#{m.element}"
          end
          m.make(args[0], args.fetch(1, 0))
        end
      end
    end
    # Put in front when a run starts (#initialize): spinel/core.rb, which
    # defines Core::Buffer, is loaded with the application, after this file.
    Unconsumed = Struct.new(:channel, :msg_id, :bytes, :stranded_by, keyword_init: true)

    # `app` is the App; `externs` the declared externs in the numbering the
    # trace uses (board, then channels, then the application's own);
    # `stimulus` a Stimulus. The board's host package and the channel
    # simulators must be loaded already (the CLI does that), and so must the
    # application file itself.
    def self.run(app, externs, stimulus, int64_allow: CoreApp::INT64_ALLOW)
      new(app, externs, stimulus, int64_allow: int64_allow).run
    end

    EntryState = Struct.new(:index, :name, :period, :context, :ctx_id, :last_run, :last_classified, :stopped, :params,
                            keyword_init: true)

    def initialize(app, externs, stimulus, int64_allow: CoreApp::INT64_ALLOW)
      @app = app
      @externs = externs
      @stim = stimulus
      @trace = Trace.new
      @h = stimulus.horizon
      @clock = 0
      @failures = []
      @stopped_contexts = {}
      @consumer_of = {}
      # decision 0028 Q4: an entry the doorbell releases early is a release this
      # model does not make, and the verification build refuses wake: for now
      woken = app.triggers.find(&:wake)
      raise "entry #{woken.entry}: wake: is not modelled here; the verification build refuses it (decision 0028 Q4)" if woken
      @entries = app.scheduled.each_with_index.map do |(entry, trig), i|
        EntryState.new(index: i, name: entry.name, period: trig.period_us, context: trig.context,
                       ctx_id: trig.context == "thread" ? Trace::CONTEXT_THREAD : Trace::CONTEXT_ISR,
                       last_run: 0, last_classified: 0, stopped: false, params: entry.params)
      end
      @states = app.states.each_with_index.to_h do |s, i|
        [s.name, Buffer.new(s.name, s.element, s.count, cross: cross?(s.name), index: i)]
      end
      @states.each_value { |b| b.observer = self }
      @current = [Trace::CONTEXT_THREAD, Trace::NO_ENTRY]
      @sims = ChannelSim.all.to_h { |c| [c.name, c] }
      # the body's width as the build has it; an unlisted `# spinel: int64`
      # is refused here, before any release, as the kernel refuses it
      bits = app.scratches.empty? ? CoreApp::TARGET_BITS : CoreApp.body_bits(app.path, int64_allow)
      @scratch = app.scratches.to_h { |ctx, bytes| [ctx, Scratch.new(bytes, bits)] }
      if defined?(::Core::Buffer) && !::Core::Buffer.singleton_class.include?(BufferNew)
        ::Core::Buffer.singleton_class.prepend(BufferNew)
      end
      HostRunner.scratch_files = [HostRunner.real(app.path)] + app.helpers.map { |(_n, _l, p)| HostRunner.real(p) }
      methods = app.definitions.map { |d| d.name.to_sym }
      files = HostRunner.scratch_files
      saved = []
      # The application's own methods only: top-level definitions in its own
      # files. A method of the runner, a buffer or a board that shares a name
      # (Scratch#make, say) is not one (the review of 0041 stage 2).
      @frees = TracePoint.new(:call, :return) do |tp|
        next unless HostRunner.scratch && methods.include?(tp.method_id) &&
                    tp.defined_class == Object && files.include?(HostRunner.real(tp.path))
        if tp.event == :call then saved.push(HostRunner.scratch.offset)
        else HostRunner.scratch.offset = saved.pop
        end
      end
    end

    def cross?(state)
      @app.scheduled.select { |e, _| e.params.include?(state) }.map { |_, t| t.context }.uniq.size > 1
    end

    # ---- the observer the buffers, the simulators and the extern wrappers report to
    def load(buf, i, v) = emit("LOAD", state: buf.index, index: i, value: v)
    def store(buf, i, v) = emit("STORE", state: buf.index, index: i, value: v)

    def channel(sim, op, id, result, bytes)
      emit(op == :enq ? "ENQ" : "DEQ", channel: channel_index(sim), msg_id: id || 0, result: result, length: bytes.size, payload: bytes)
      @consumer_of[sim.name] = @current[0] if op == :deq
    end

    def rx(sim, stimulus_id, bytes, _id) = emit("RX", channel: channel_index(sim), stimulus_id: stimulus_id, length: bytes.size)
    def tx(sim, id, _bytes) = emit("TX", channel: channel_index(sim), msg_id: id)
    def drop(sim, stimulus_id, reason) = emit("DROP", channel: channel_index(sim), stimulus_id: stimulus_id, reason: Trace::DROP_REASON.fetch(reason))

    def channel_index(sim) = @app.channels.index { |c| c.name == sim.name }

    def emit(kind, **fields) = @trace.emit(kind, @current[0], @current[1], **fields)

    # ---- the run
    def run
      ChannelSim.recorder = self
      @sims.each_value(&:reset)
      BoardHost.reset_all
      BoardHost.clock_source = -> { @clock }
      isr = @entries.any? { |e| e.context == "interrupt" }
      @trace.emit("HEADER", Trace::CONTEXT_THREAD, Trace::NO_ENTRY, epoch: 0, clock_hz: 1_000_000, horizon: @h,
                  drain: @stim.drain, contexts: isr ? 4 : 3, entries: @entries.size, states: @states.size,
                  channels: @app.channels.size)
      build_events
      wrap_externs
      loop do
        drain
        ev = @events.shift
        break unless ev
        @clock = ev[0] if ev[0] > @clock
        handle(ev)
      end
      @clock = @h if @clock < @h
      cut_at_horizon
      drain
      unconsumed = collect_unconsumed
      @current = [Trace::CONTEXT_TRANSPORT, Trace::NO_ENTRY]
      # Quiescence holds by construction here: every invocation runs to its END
      # before the next event. The drain is read back from the rings.
      drained = @sims.values.all? { |s| s.direction != "out" || s.queue.empty? }
      emit("ENDMARK", quiescent: 1, drained: drained ? 1 : 0)
      drops = @sims.values.to_h { |s| [s.name, s.drops.dup] }
      Result.new(trace: @trace, failures: @failures, unconsumed: unconsumed, drops: drops, horizon: @h, final_clock: @clock)
    ensure
      ChannelSim.recorder = nil
    end

    # Events are [time, order, kind, payload], kept sorted; `order` fixes the
    # tie at equal times: stimulus items, then interrupt expiries, then the
    # thread sweep.
    def build_events
      @events = []
      @stim.items.each { |it| @events << [it.time, 0, :stimulus, it] }
      expiries = @entries.select { |e| e.context == "interrupt" }.flat_map { |e| (1..).lazy.map { |r| r * e.period }.take_while { |t| t < @h }.to_a }
      expiries.uniq.sort.each { |t| @events << [t, 1, :expiry, nil] }
      first = @entries.select { |e| e.context == "thread" }.map(&:period).min
      @events << [first, 2, :sweep, nil] if first && first < @h
      @events.sort!
    end

    def insert_event(ev)
      i = @events.bsearch_index { |e| (e <=> ev) > 0 } || @events.size
      @events.insert(i, ev)
    end

    def handle(ev)
      case ev[2]
      when :stimulus then stimulus(ev[3])
      when :expiry then isr_sweep
      when :sweep then thread_sweep
      end
    end

    def stimulus(it)
      case it.kind
      when "adc", "gpio"
        @current = [Trace::CONTEXT_STIMULUS, Trace::NO_ENTRY]
        BoardHost.apply(it.kind, it.a, it.b)
      when "inbound"
        @current = [Trace::CONTEXT_TRANSPORT, Trace::NO_ENTRY]
        sim = @sims[it.a] or raise "#{@stim.path}:#{it.line}: no channel #{it.a}"
        raise "#{@stim.path}:#{it.line}: #{it.a} is an :out channel; inbound fills :in channels" unless sim.direction == "in"
        sim.transport_put(it.b, it.id)
      end
    end

    def isr_sweep
      @entries.each do |e|
        next unless e.context == "interrupt"
        break if @clock >= @h
        select_and_run(e)
      end
    end

    def thread_sweep
      @entries.each do |e|
        next unless e.context == "thread"
        break if @clock >= @h
        select_and_run(e)
      end
      # Sleep until the next release of any live thread entry; a release that
      # became pending during this sweep is due now.
      pending = @entries.select { |e| e.context == "thread" && !e.stopped }.map { |e| (e.last_run + 1) * e.period }
      nxt = pending.select { |t| t < @h }.min
      insert_event([[nxt, @clock].max, 2, :sweep, nil]) if nxt && @clock < @h
    end

    # The selection rule of 0014 §4, from one clock reading.
    def select_and_run(e)
      return if e.stopped
      @current = [e.ctx_id, e.index]
      newest = @clock / e.period
      if newest <= e.last_run
        emit("SELECT", clock: @clock, release: 0, skipped_from: 0, skipped_to: 0)
        return
      end
      skipped_from = newest - 1 > e.last_run ? e.last_run + 1 : 0
      skipped_to = skipped_from.zero? ? 0 : newest - 1
      emit("SELECT", clock: @clock, release: newest, skipped_from: skipped_from, skipped_to: skipped_to)
      e.last_run = newest
      e.last_classified = newest
      invoke(e, newest)
    end

    def invoke(e, release)
      @current = [e.ctx_id, e.index]
      emit("START", release: release)
      status = 0
      begin
        args = e.params.map { |p| @states.fetch(p) }
        HostRunner.scratch = @scratch[e.context]
        r = @frees.enable { Object.send(e.name, *args) }
        status = Checked.plain(r)
        raise "entry #{e.name} returned #{r.inspect}, not a 0007 status" unless status.is_a?(Integer) && STATUS.value?(status)
      rescue Checked::Failure => f
        status = STATUS_OF_REASON.fetch(f.reason) { raise }
      ensure
        HostRunner.scratch = nil
      end
      @current = [e.ctx_id, e.index]
      emit("STATUS", status: status)
      if status != 0
        fail_seq = emit("FAIL", status: status, release: release).seq
        @failures << Failure.new(entry: e.name, release: release, status: status, seq: fail_seq)
        stop_context(e.context, fail_seq)
      end
      e.params.each do |p|
        b = @states.fetch(p)
        next if b.cross
        bytes = element_bytes(b)
        emit("PRIVATE", state: b.index, bytes: bytes.size, payload: bytes)
      end
      busy(e, @stim.cost_of(e.name, release))
      @current = [e.ctx_id, e.index]
      emit("END", release: release)
    end

    # Spends `cost` of virtual time on an invocation of `e`. What can preempt
    # it lands inside the window: interrupt expiries and stimulus items during
    # a thread invocation, stimulus items during an interrupt invocation
    # (the stimulus and transport threads are simulated with no cost and no
    # priority over an interrupt; they are recorded at their time).
    def busy(e, cost)
      while cost > 0
        ev = @events.first
        break unless ev && ev[0] < @clock + cost
        break if ev[2] == :sweep
        break if ev[2] == :expiry && e.context == "interrupt"
        @events.shift
        if ev[0] > @clock
          cost -= ev[0] - @clock
          @clock = ev[0]
        end
        saved = @current
        handle(ev)
        @current = saved
      end
      @clock += cost
    end

    def stop_context(context, fail_seq)
      @stopped_contexts[context] = fail_seq
      @entries.each do |x|
        next unless x.context == context
        x.stopped = true
        from = x.last_classified + 1
        to = last_admitted(x)
        next if from > to
        emit("CANCEL", entry: x.index, from: from, to: to, fail_seq: fail_seq)
        x.last_classified = to
      end
    end

    # The last release admitted by the horizon: r with r * period < H.
    def last_admitted(e) = (@h - 1) / e.period

    def cut_at_horizon
      @entries.each do |e|
        next if e.stopped
        from = e.last_classified + 1
        to = last_admitted(e)
        next if from > to
        @current = [e.ctx_id, e.index]
        emit("CUT", entry: e.index, from: from, to: to)
        e.last_classified = to
      end
    end

    def drain
      @current = [Trace::CONTEXT_TRANSPORT, Trace::NO_ENTRY]
      @sims.each_value do |s|
        next unless s.direction == "out"
        nil while s.transport_get
      end
    end

    def collect_unconsumed
      @current = [Trace::CONTEXT_TRANSPORT, Trace::NO_ENTRY]
      @sims.values.select { |s| s.direction == "in" }.flat_map do |s|
        consumer = @consumer_of[s.name]
        stranded = consumer && @stopped_contexts[consumer == Trace::CONTEXT_ISR ? "interrupt" : "thread"]
        s.queue.map { |id, bytes| Unconsumed.new(channel: s.name, msg_id: id, bytes: bytes, stranded_by: stranded) }
      end
    end

    def element_bytes(b)
      width = { "u8" => 1, "i32" => 4, "u32" => 4, "i64" => 8 }.fetch(b.element)
      b.cells.flat_map { |v| (0...width).map { |k| (v >> (8 * k)) & 0xff } }
    end

    # ---- externs: the wrapper each declared member gets on its host module.
    #
    # The wrapper does what the kernel's lowering does before and after the
    # call, in the same order: the scalar arguments are checked against their
    # domain (ARITHMETIC when one does not fit), the buffers are the entry's
    # states or literals, the guards are evaluated in declared order
    # (ARGUMENT or BOUNDS, the extern not called), the call and its return
    # value are recorded, and the value comes back checked.
    def wrap_externs
      @externs.each_with_index do |ext, xi|
        mod = Object.const_get(ext.module_name)
        raise "#{ext.full}: the host package defines no #{ext.name}" unless mod.respond_to?(ext.name)
        sim = mod.method(ext.name)
        runner = self
        mod.define_singleton_method(ext.name) do |*args|
          runner.extern_call(ext, xi, sim, args)
        end
      end
    end

    def extern_call(ext, xi, sim, args)
      raise "#{ext.full}: #{args.size} argument(s), the declaration has #{ext.params.size}" unless args.size == ext.params.size
      values = []
      plain = []
      ext.params.each_with_index do |p, i|
        a = args[i]
        if p.buffer?
          a = literal_buffer(a) if a.is_a?(String)
          raise "#{ext.full}: argument #{p.name} is a buffer; #{a.class} was passed" unless a.is_a?(Buffer)
          values << a
          plain << a
        else
          v = Checked.plain(a)
          raise Checked::Failure, "domain" unless v.is_a?(Integer) && DOMAIN.fetch(p.type).cover?(v)
          values << v
          plain << v
        end
      end
      ext.guards.each do |g|
        f = g.split(" ")
        raise "#{ext.full}: guard #{g.inspect} is not `<lhs> <op> <rhs> else <argument|bounds>`" unless f.size == 5 && f[3] == "else" && %w[argument bounds].include?(f[4]) && %w[< <= > >= == !=].include?(f[1])
        lhs, op, rhs, _else, status = f
        l = operand(lhs, ext, values)
        r = operand(rhs, ext, values)
        raise "#{ext.full}: guard #{g.inspect} compares a buffer; only scalars and len() are operands" if l.is_a?(Buffer) || r.is_a?(Buffer)
        holds = case op
                when "<" then l < r
                when "<=" then l <= r
                when ">" then l > r
                when ">=" then l >= r
                when "==" then l == r
                when "!=" then l != r
                end
        raise Checked::Failure, status unless holds
      end
      tagged = values.map { |v| v.is_a?(Buffer) ? [1, element_bytes(v)] : [0, v] }
      emit("XCALL", extern: xi, argc: values.size, args: Trace.args_text(tagged))
      result = sim.call(*plain)
      result = Checked.plain(result)
      if ext.returns
        raise "#{ext.full}: the simulator returned #{result.inspect}, not a #{ext.returns}" unless result.is_a?(Integer) && DOMAIN.fetch(ext.returns).cover?(result)
        emit("XRET", extern: xi, value: result)
        Checked.new(result)
      else
        emit("XRET", extern: xi, value: 0)
        nil
      end
    end

    def operand(s, ext, values)
      return Integer(s, 10) if s.match?(/\A-?\d+\z/)
      if (m = s.match(/\Alen\((\w+)\)\z/))
        i = ext.params.index { |p| p.name == m[1] } or raise "#{ext.full}: guard names no parameter #{m[1]}"
        return values[i].count
      end
      i = ext.params.index { |p| p.name == s } or raise "#{ext.full}: guard names no parameter #{s}"
      values[i]
    end

    def literal_buffer(s)
      b = Buffer.new("<literal>", "u8", s.bytesize)
      s.bytes.each_with_index { |v, i| b.store_raw(i, v) }
      b
    end
  end
end
