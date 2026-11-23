# frozen_string_literal: true
#
# tools/app/lib/core_app/verify.rb -- the checks of decision 0014 §10 over a
# verification run's trace, and the replay (Task 11).
#
# Inputs: the decoded records in sequence order, the application, the
# externs in the trace's numbering (board, channels, application), the
# stimulus, and the console's figures. The four checks are independent of
# each other and of the replay:
#   1. workload and timing -- every admitted release has exactly one terminal
#      class and each class is justified; every selection is recomputed from
#      its clock reading; every inbound stimulus item appears; no gap in the
#      sequence; the end marker states quiescence and drain;
#   2. channel conservation -- occupancy reconstructed from the linearised
#      enqueues and dequeues; full, empty and channel-full drops exactly at
#      the occupancies that justify them; every message dequeued once, FIFO,
#      before the end, or stranded by a recorded failure; every dequeued
#      outbound message handed to the UART, and the wire's frames are those
#      payloads in order;
#   3. shared-state linearisability -- per element, each load returns the
#      latest store before it in sequence, or the initial zero, and one
#      context does the storing;
#   4. replay -- each invocation re-executed under CRuby with its recorded
#      inputs (extern returns, loads, dequeued bytes); its stores, extern
#      calls, sends, status and private state at exit must match byte for
#      byte.
# Every failure names the record (its sequence number) and the rule.
require_relative "app_model"
require_relative "trace"
require_relative "checked"
require_relative "stimulus"

module CoreApp
  module Verify
    Result = Struct.new(:failures, :report, keyword_init: true) do
      def ok? = failures.empty?
    end

    module_function

    # `records` sorted by seq; `externs` as the trace numbers them;
    # `figures` from Console.figures; `frames` the console's application
    # frames [[channel, bytes]], or nil when there is no console (a text
    # trace); `complete` false when the capture ended inside a frame.
    def run(records, app, externs, stimulus, figures:, frames:, complete: true, replay: true)
      f = []
      report = { "records" => records.size }
      if records.empty? || records.first.kind != "HEADER"
        f << "the trace does not begin with HEADER"
        return Result.new(failures: f, report: report)
      end
      h = records.first
      ctx = Context.new(records, app, externs, stimulus, h)
      f.concat(check_integrity(records, figures, complete))
      f.concat(check_header(ctx))
      f.concat(check_workload(ctx, report))
      f.concat(check_channels(ctx, frames, report))
      f.concat(check_linearisability(ctx, report))
      f.concat(check_replay(ctx, report)) if replay
      report["cycles"] = figures[:cycles]
      Result.new(failures: f, report: report)
    end

    # The shared reading of the trace.
    class Context
      attr_reader :records, :app, :externs, :stim, :header, :entries, :cyc_per_us, :epoch, :horizon

      Entry = Struct.new(:index, :name, :context, :period_cyc, :params, keyword_init: true)

      def initialize(records, app, externs, stim, header)
        @records = records
        @app = app
        @externs = externs
        @stim = stim
        @header = header
        @epoch = header[:epoch]
        @horizon = header[:horizon]
        @cyc_per_us = header[:clock_hz] / 1_000_000
        @entries = app.scheduled.each_with_index.map do |(e, t), i|
          Entry.new(index: i, name: e.name, context: t.context, period_cyc: t.period_us * @cyc_per_us, params: e.params)
        end
      end

      def last_admitted(e) = (@horizon - 1) / e.period_cyc
      def cross?(state) = @app.scheduled.select { |e, _| e.params.include?(state) }.map { |_, t| t.context }.uniq.size > 1
      def of(kind) = @records.select { |r| r.kind == kind }
    end

    # ---- integrity: the sequence, the end marker, the rings
    def check_integrity(records, figures, complete)
      f = []
      f << "the console capture ended inside a frame; the trace is truncated" unless complete
      records.each_cons(2) { |a, b| f << "sequence gap: #{a.seq} is followed by #{b.seq}" if b.seq != a.seq + 1 }
      records.select { |r| r.kind == "OVERFLOW" }.each { |r| f << "record #{r.seq}: the record buffer of context #{r[:context]} overflowed; the trace is incomplete" }
      f << "the recorder dropped #{figures[:dropped]} records" if figures[:dropped].to_i > 0
      f << "the recorder saw #{figures[:unregistered]} cross-context accesses at addresses no registered state holds" if figures[:unregistered].to_i > 0
      ends = records.select { |r| r.kind == "ENDMARK" }
      if ends.size != 1
        f << "#{ends.size} end markers; one is required"
      else
        e = ends.first
        f << "record #{e.seq}: the end marker is not the last record" unless e.equal?(records.last)
        f << "record #{e.seq}: the end marker says quiescence did not complete" unless e[:quiescent] == 1
        f << "record #{e.seq}: the end marker says the drain did not complete" unless e[:drained] == 1
      end
      f << "the run printed no SPC_END line" unless figures[:ended]
      f
    end

    # ---- the header against the application and the stimulus it is verified against
    def check_header(ctx)
      f = []
      h = ctx.header
      f << "record 0: the header counts #{h[:entries]} entries; the application has #{ctx.app.scheduled.size}" unless h[:entries] == ctx.app.scheduled.size
      f << "record 0: the header counts #{h[:states]} states; the application has #{ctx.app.states.size}" unless h[:states] == ctx.app.states.size
      f << "record 0: the header counts #{h[:channels]} channels; the application has #{ctx.app.channels.size}" unless h[:channels] == ctx.app.channels.size
      f << "record 0: the header counts #{h[:contexts]} contexts; the trace uses context #{ctx.records.map(&:context).max}" if ctx.records.map(&:context).max >= h[:contexts]
      f << "record 0: the header's horizon #{h[:horizon]} cycles is not the stimulus's #{ctx.stim.horizon} us at #{h[:clock_hz]} Hz" unless h[:horizon] == ctx.stim.horizon * ctx.cyc_per_us
      f << "record 0: the header's drain #{h[:drain]} cycles is not the stimulus's #{ctx.stim.drain} us" unless h[:drain] == ctx.stim.drain * ctx.cyc_per_us
      f
    end

    # ---- 1. workload and timing
    def check_workload(ctx, report)
      f = []
      classes = ctx.entries.map { |e| [e.index, {}] }.to_h # entry index => {release => class}
      last_run = Hash.new(0)
      stopped = {} # context name => FAIL seq
      fails = ctx.of("FAIL").to_h { |r| [r.seq, r] }
      # selections, starts and ends, in sequence order
      open = {}
      started = Hash.new { |h, k| h[k] = [] }
      ctx.records.each do |r|
        e = ctx.entries[r.entry] if r.entry != Trace::NO_ENTRY
        case r.kind
        when "SELECT"
          next unless e # a non-entry actor never selects
          newest = (r[:clock] - ctx.epoch) / e.period_cyc
          if r[:release].zero?
            f << "record #{r.seq}: #{e.name} selected nothing at clock #{r[:clock]}, but release #{newest} was pending (last run #{last_run[e.index]})" if newest > last_run[e.index]
            next
          end
          f << "record #{r.seq}: #{e.name} selected release #{r[:release]}; the clock reading #{r[:clock]} allows exactly #{newest}" unless r[:release] == newest
          f << "record #{r.seq}: #{e.name} selected release #{r[:release]} after the horizon (last admitted #{ctx.last_admitted(e)})" if r[:release] > ctx.last_admitted(e)
          sf = newest - 1 > last_run[e.index] ? last_run[e.index] + 1 : 0
          st = sf.zero? ? 0 : newest - 1
          f << "record #{r.seq}: #{e.name} recorded skipped #{r[:skipped_from]}..#{r[:skipped_to]}; the clock reading justifies #{sf}..#{st}" unless r[:skipped_from] == sf && r[:skipped_to] == st
          (sf..st).each { |k| classes[e.index][k] = classes[e.index][k] ? "twice" : "skipped" } unless sf.zero?
          classes[e.index][r[:release]] = classes[e.index][r[:release]] ? "twice" : "run"
          last_run[e.index] = newest
          f << "record #{r.seq}: #{e.name} selected release #{r[:release]} in context #{stopped[e.context] ? 'stopped by ' + stopped[e.context].to_s : ''}" if stopped[e.context]
        when "START"
          next unless e
          f << "record #{r.seq}: START of #{e.name} release #{r[:release]} while release #{open[e.index]} is open" if open[e.index]
          f << "record #{r.seq}: START of #{e.name} release #{r[:release]} was not selected" unless classes[e.index][r[:release]] == "run"
          open[e.index] = r[:release]
          started[e.index] << r[:release]
        when "END"
          next unless e
          f << "record #{r.seq}: END of #{e.name} release #{r[:release]} without its START" unless open[e.index] == r[:release]
          open.delete(e.index)
        when "FAIL"
          f << "record #{r.seq}: FAIL of #{e ? e.name : 'a non-entry actor'} outside an invocation" unless e && open[e.index]
          f << "record #{r.seq}: FAIL names release #{r[:release]}; the open invocation is release #{open[e.index]}" if e && open[e.index] && open[e.index] != r[:release]
          stopped[e.context] ||= r.seq if e
        when "CANCEL"
          x = ctx.entries[r[:entry]]
          fs = fails[r[:fail_seq]]
          f << "record #{r.seq}: CANCEL names FAIL #{r[:fail_seq]}, which is not a FAIL record" unless fs
          f << "record #{r.seq}: CANCEL of #{x.name} names a FAIL of another context" if fs && ctx.entries[fs.entry].context != x.context
          f << "record #{r.seq}: CANCEL of #{x.name} precedes the FAIL it names" if fs && fs.seq > r.seq
          f << "record #{r.seq}: CANCEL of #{x.name} from #{r[:from]}: release #{last_run[x.index]} was already selected" if r[:from] <= last_run[x.index]
          f << "record #{r.seq}: CANCEL of #{x.name} to #{r[:to]} beyond the last admitted #{ctx.last_admitted(x)}" if r[:to] > ctx.last_admitted(x)
          (r[:from]..r[:to]).each { |k| classes[x.index][k] = classes[x.index][k] ? "twice" : "cancelled" }
        when "CUT"
          x = ctx.entries[r[:entry]]
          f << "record #{r.seq}: CUT of #{x.name} from #{r[:from]}: release #{last_run[x.index]} was already selected" if r[:from] <= last_run[x.index]
          f << "record #{r.seq}: CUT of #{x.name} to #{r[:to]} is not the last admitted #{ctx.last_admitted(x)}" unless r[:to] == ctx.last_admitted(x)
          (r[:from]..r[:to]).each { |k| classes[x.index][k] = classes[x.index][k] ? "twice" : "cut" }
        end
      end
      open.each { |i, rel| f << "#{ctx.entries[i].name} release #{rel} started and never ended" }
      # run means selected and started (§10): a selection with no START is not a run
      ctx.entries.each do |e|
        classes[e.index].each { |k, c| f << "#{e.name} release #{k} was selected and never started" if c == "run" && !started[e.index].include?(k) }
      end
      # every admitted release has exactly one class
      summary = {}
      ctx.entries.each do |e|
        (1..ctx.last_admitted(e)).each do |k|
          c = classes[e.index][k]
          f << "#{e.name} release #{k} has no terminal class" if c.nil?
          f << "#{e.name} release #{k} was classified twice" if c == "twice"
        end
        summary[e.name] = classes[e.index].values.tally
      end
      report["releases"] = summary
      # every inbound stimulus item appears, as RX or DROP, numbered per channel
      per_channel = Hash.new(0)
      ctx.stim.items.select { |it| it.kind == "inbound" }.each do |it|
        ci = ctx.app.channels.index { |c| c.name == it.a }
        sid = (per_channel[ci] += 1)
        seen = ctx.records.any? { |r| %w[RX DROP].include?(r.kind) && r[:channel] == ci && r[:stimulus_id] == sid }
        f << "stimulus item #{it.id} (inbound #{it.a}, the channel's #{sid}th) appears in no RX or DROP record" unless seen
      end
      f
    end

    # ---- 2. channel conservation
    def check_channels(ctx, frames, report)
      f = []
      chans = ctx.app.channels
      occ = Hash.new(0)
      queued = Hash.new { |h, k| h[k] = [] } # channel => [msg_id] in order
      next_id = Hash.new(1)
      handed = Hash.new { |h, k| h[k] = [] } # channel => [[msg_id, payload]] handed to the UART
      pending_deq = {}
      stopped_ctx = {}
      ctx.records.each do |r|
        case r.kind
        when "ENQ"
          c = r[:channel]
          f << "record #{r.seq}: ENQ says #{r[:length]} bytes and carries #{r[:payload].size}" unless r[:length] == r[:payload].size
          if r[:result] == Trace::ENQ_QUEUED
            f << "record #{r.seq}: ENQ queued on #{chans[c].name} at occupancy #{occ[c]} = depth #{chans[c].depth}" if occ[c] >= chans[c].depth
            f << "record #{r.seq}: ENQ on #{chans[c].name} has msg_id #{r[:msg_id]}; #{next_id[c]} is next" unless r[:msg_id] == next_id[c]
            next_id[c] += 1
            occ[c] += 1
            queued[c] << [r[:msg_id], r[:payload]]
          else
            f << "record #{r.seq}: ENQ full on #{chans[c].name} at occupancy #{occ[c]}, below depth #{chans[c].depth}" unless occ[c] == chans[c].depth
          end
        when "DEQ"
          c = r[:channel]
          f << "record #{r.seq}: DEQ says #{r[:length]} bytes and carries #{r[:payload].size}" unless r[:length] == r[:payload].size
          if r[:result] == Trace::DEQ_DEQUEUED
            if occ[c].zero?
              f << "record #{r.seq}: DEQ dequeued from #{chans[c].name} at occupancy 0"
            else
              id, payload = queued[c].shift
              f << "record #{r.seq}: DEQ from #{chans[c].name} took msg #{r[:msg_id]}; FIFO order says #{id}" unless id == r[:msg_id]
              f << "record #{r.seq}: DEQ from #{chans[c].name} msg #{r[:msg_id]}: the payload is not the enqueued one" unless payload == r[:payload]
              occ[c] -= 1
              if r.context == Trace::CONTEXT_TRANSPORT
                f << "record #{pending_deq[c].seq}: the transport dequeued msg #{pending_deq[c][:msg_id]} of #{chans[c].name} and dequeued again before handing it to the UART" if pending_deq[c]
                pending_deq[c] = r
              end
            end
          else
            f << "record #{r.seq}: DEQ empty from #{chans[c].name} at occupancy #{occ[c]}" unless occ[c].zero?
          end
        when "TX"
          c = r[:channel]
          d = pending_deq.delete(c)
          f << "record #{r.seq}: TX of #{chans[c].name} msg #{r[:msg_id]} follows no DEQ by the transport" unless d
          f << "record #{r.seq}: TX of #{chans[c].name} msg #{r[:msg_id]}; the transport dequeued #{d[:msg_id]}" if d && d[:msg_id] != r[:msg_id]
          handed[c] << [r[:msg_id], d ? d[:payload] : nil]
        when "DROP"
          c = r[:channel]
          item = ctx.stim.items.select { |it| it.kind == "inbound" && ctx.app.channels.index { |x| x.name == it.a } == c }[r[:stimulus_id] - 1]
          f << "record #{r.seq}: DROP names inbound #{r[:stimulus_id]} of #{chans[c].name}, which the stimulus does not have" unless item
          case r[:reason]
          when Trace::DROP_OVERSIZE
            f << "record #{r.seq}: DROP oversize of a #{item.b.size}-byte message on #{chans[c].name} (size #{chans[c].size})" if item && item.b.size <= chans[c].size
          when Trace::DROP_CHANNEL_FULL
            f << "record #{r.seq}: DROP channel_full on #{chans[c].name} at occupancy #{occ[c]}, below depth #{chans[c].depth}" unless occ[c] == chans[c].depth
          else
            f << "record #{r.seq}: DROP reason #{r[:reason]} is not a reason"
          end
        when "RX"
          c = r[:channel]
          item = ctx.stim.items.select { |it| it.kind == "inbound" && ctx.app.channels.index { |x| x.name == it.a } == c }[r[:stimulus_id] - 1]
          f << "record #{r.seq}: RX names inbound #{r[:stimulus_id]} of #{chans[c].name}, which the stimulus does not have" unless item
          f << "record #{r.seq}: RX of #{chans[c].name} says #{r[:length]} bytes; the item has #{item.b.size}" if item && item.b.size != r[:length]
        when "FAIL"
          stopped_ctx[ctx.entries[r.entry].context] = r.seq if r.entry != Trace::NO_ENTRY
        end
      end
      pending_deq.each { |c, d| f << "record #{d.seq}: the transport dequeued msg #{d[:msg_id]} of #{chans[c].name} and never handed it to the UART" }
      stranded = []
      queued.each do |c, left|
        next if left.empty?
        consumer = chans[c].direction == "in" ? ctx.entries.find { |e| ctx.records.any? { |r| r.kind == "DEQ" && r[:channel] == c && r.entry == e.index } }&.context : nil
        if consumer && stopped_ctx[consumer]
          left.each { |id, _| stranded << { "channel" => chans[c].name, "msg_id" => id, "stranded_by" => stopped_ctx[consumer] } }
        else
          left.each { |id, _| f << "#{chans[c].name} msg #{id} was enqueued and never dequeued before the end marker" }
        end
      end
      # the wire: the frames the console carried are the handed payloads, in
      # order (no console with a text trace: skipped, and the report says so)
      compared = frames ? 0 : nil
      chans.each_with_index do |ch, c|
        next unless ch.direction == "out" && frames
        wire = frames.select { |fc, _| fc == c }.map(&:last)
        want = handed[c].map(&:last)
        compared += [wire.size, want.size].min
        f << "#{ch.name}: the console carried #{wire.size} frames, the trace handed #{want.size} messages to the UART" unless wire.size == want.size
        wire.zip(want).each_with_index { |(w, x), k| f << "#{ch.name}: frame #{k + 1} on the wire is not the #{k + 1}th message handed to the UART" if x && w != x }
      end
      report["channels"] = chans.each_with_index.to_h { |ch, c| [ch.name, { "enqueued" => next_id[c] - 1, "handed" => handed[c].size, "stranded" => stranded.count { |s| s["channel"] == ch.name } }] }
      report["stranded"] = stranded
      report["wire_frames_compared"] = compared
      f
    end

    # ---- 3. shared-state linearisability
    def check_linearisability(ctx, report)
      f = []
      value = Hash.new(0) # [state, index] => latest stored value
      writer = {}
      loads = 0
      ctx.records.each do |r|
        case r.kind
        when "STORE"
          key = [r[:state], r[:index]]
          st = ctx.app.states[r[:state]]
          wctx = ctx.entries[r.entry]&.context
          f << "record #{r.seq}: #{st.name}[#{r[:index]}] stored by a non-entry actor (context #{r.context})" if wctx.nil?
          writer[r[:state]] ||= wctx
          f << "record #{r.seq}: #{st.name}[#{r[:index]}] stored from the #{wctx} context; the writing context is #{writer[r[:state]]}" unless writer[r[:state]] == wctx
          value[key] = r[:value]
        when "LOAD"
          loads += 1
          key = [r[:state], r[:index]]
          st = ctx.app.states[r[:state]]
          f << "record #{r.seq}: #{st.name}[#{r[:index]}] loaded #{r[:value]}; the latest store before it holds #{value[key]}" unless r[:value] == value[key]
        end
      end
      report["cross"] = { "loads" => loads, "stores" => ctx.of("STORE").size, "writers" => writer.transform_keys { |k| ctx.app.states[k].name } }
      f
    end

    # ---- 4. replay
    # The host package (spinel/core, the board's host package, the channel
    # simulators, the application) must be loaded by the caller, as the host
    # runner needs it; the replay replaces the externs with stubs that feed
    # the recorded returns and compare the recorded calls.
    class ReplayBuffer < Buffer
      attr_accessor :replay

      def [](i)
        return super unless @cross
        i = Checked.plain(i)
        raise Checked::Failure, "bounds" unless i.is_a?(Integer) && i >= 0 && i < @count
        v = @replay.next_load(self, i)
        @cells[i] = v
        Checked.new(v)
      end

      def []=(i, v)
        return super unless @cross
        i = Checked.plain(i)
        v = Checked.plain(v)
        raise Checked::Failure, "bounds" unless i.is_a?(Integer) && i >= 0 && i < @count
        raise Checked::Failure, "domain" unless v.is_a?(Integer) && domain.cover?(v)
        @replay.next_store(self, i, v)
        @cells[i] = v
        v
      end
    end

    class Replay
      class Mismatch < StandardError; end

      def initialize(ctx, invocation, buffers)
        @ctx = ctx
        @recs = invocation
        @pos = 0
        @buffers = buffers
      end

      def take(kind, what)
        r = @recs[@pos]
        raise Mismatch, "the replay #{what}, the trace has #{r ? "record #{r.seq} #{r.kind}" : 'no more records'}" unless r && r.kind == kind
        @pos += 1
        r
      end

      def next_load(buf, i)
        r = take("LOAD", "loads #{buf.name}[#{i}]")
        raise Mismatch, "record #{r.seq}: the replay loads #{buf.name}[#{i}], the trace loaded state #{r[:state]}[#{r[:index]}]" unless r[:state] == buf.index && r[:index] == i
        r[:value]
      end

      def next_store(buf, i, v)
        r = take("STORE", "stores #{buf.name}[#{i}] = #{v}")
        raise Mismatch, "record #{r.seq}: the replay stores #{buf.name}[#{i}] = #{v}, the trace stored state #{r[:state]}[#{r[:index]}] = #{r[:value]}" unless r[:state] == buf.index && r[:index] == i && r[:value] == v
      end

      # an extern call: the XCALL's arguments must match, then the records
      # between XCALL and XRET (an ENQ or DEQ for a channel extern) are
      # consumed, and the XRET's value is returned; a DEQ's payload fills the
      # buffer argument
      def extern_call(xi, ext, args)
        r = take("XCALL", "calls #{ext.full}")
        tagged = args.map { |a| a.is_a?(Buffer) ? [1, a.bytes(0, a.count).flat_map { |v| element_bytes(a.element, v) }] : [0, Checked.plain(a)] }
        text = Trace.args_text(tagged)
        raise Mismatch, "record #{r.seq}: the replay calls extern #{xi} (#{ext.full}) with #{text}; the trace has extern #{r[:extern]} with #{r[:args]}" unless r[:extern] == xi && r[:args] == text
        deq = nil
        while (n = @recs[@pos]) && n.kind != "XRET"
          raise Mismatch, "record #{n.seq}: a #{n.kind} inside the extern call #{ext.full}" unless %w[ENQ DEQ].include?(n.kind)
          deq = n if n.kind == "DEQ" && n[:result] == Trace::DEQ_DEQUEUED
          @pos += 1
        end
        x = take("XRET", "returns from #{ext.full}")
        raise Mismatch, "record #{x.seq}: XRET of extern #{x[:extern]}, the call was #{xi}" unless x[:extern] == xi
        if deq
          buf = args.find { |a| a.is_a?(Buffer) }
          deq[:payload].each_with_index { |b, k| buf.store_raw(k, b) }
        end
        x[:value]
      end

      def element_bytes(element, v)
        w = { "u8" => 1, "i32" => 4, "u32" => 4, "i64" => 8 }.fetch(element)
        (0...w).map { |k| (v >> (8 * k)) & 0xff }
      end

      def finish_status(status)
        r = take("STATUS", "ends with status #{status}")
        raise Mismatch, "record #{r.seq}: the replay's status is #{status}, the trace recorded #{r[:status]}" unless r[:status] == status
        if @recs[@pos]&.kind == "FAIL"
          @pos += 1
          @pos += 1 while @recs[@pos]&.kind == "CANCEL"
        end
      end

      def finish_private(entry)
        while @recs[@pos]&.kind == "PRIVATE"
          r = @recs[@pos]
          buf = @buffers[@ctx.app.states[r[:state]].name]
          have = buf.bytes(0, buf.count).flat_map { |v| element_bytes(buf.element, v) }
          raise Mismatch, "record #{r.seq}: #{buf.name} at exit is #{have.pack('C*').unpack1('H*')} in the replay, #{r[:payload].pack('C*').unpack1('H*')} in the trace" unless have == r[:payload]
          @pos += 1
        end
        raise Mismatch, "#{@recs[@pos].kind} record #{@recs[@pos].seq} after the invocation's private state" if @pos < @recs.size
      end
    end

    def check_replay(ctx, report)
      f = []
      buffers = ctx.app.states.each_with_index.to_h do |s, i|
        [s.name, ReplayBuffer.new(s.name, s.element, s.count, cross: ctx.cross?(s.name), index: i)]
      end
      replay = nil
      # the externs: stubs over the modules the host package defines
      ctx.externs.each_with_index do |ext, xi|
        mod = Object.const_get(ext.module_name)
        raise "#{ext.full}: the host package defines no #{ext.name}" unless mod.respond_to?(ext.name)
        mod.define_singleton_method(ext.name) do |*args|
          args = args.map { |a| a.is_a?(String) ? Buffer.new("literal", "u8", a.bytesize).tap { |b| a.bytes.each_with_index { |x, k| b.store_raw(k, x) } } : a }
          v = replay.extern_call(xi, ext, args)
          ext.returns ? Checked.new(v) : nil
        end
      end
      # each invocation: the records between START and END in the entry's context
      invocations = []
      open = {}
      ctx.records.each do |r|
        next if r.entry == Trace::NO_ENTRY
        key = [r.context, r.entry]
        case r.kind
        when "START" then open[key] = { entry: r.entry, release: r[:release], start: r.seq, recs: [] }
        when "END"
          inv = open.delete(key)
          invocations << inv if inv
        else
          open[key][:recs] << r if open[key] && !%w[SELECT].include?(r.kind)
        end
      end
      # the private state at each invocation's start: the latest PRIVATE
      # record of that state before the START, else zero
      privates = ctx.of("PRIVATE")
      replayed = 0
      invocations.each do |inv|
        e = ctx.entries[inv[:entry]]
        e.params.each do |pn|
          b = buffers[pn]
          next if b.cross
          last = privates.select { |p| p.seq < inv[:start] && ctx.app.states[p[:state]].name == pn }.last
          bytes = last ? last[:payload] : Array.new(b.count * { "u8" => 1, "i32" => 4, "u32" => 4, "i64" => 8 }.fetch(b.element), 0)
          w = { "u8" => 1, "i32" => 4, "u32" => 4, "i64" => 8 }.fetch(b.element)
          b.count.times do |k|
            v = bytes[k * w, w].each_with_index.sum { |x, j| x << (8 * j) }
            v -= 1 << (8 * w) if %w[i32 i64].include?(b.element) && v >= 1 << (8 * w - 1)
            b.store_raw(k, v)
          end
        end
        replay = Replay.new(ctx, inv[:recs], buffers)
        buffers.each_value { |b| b.replay = replay }
        begin
          args = e.params.map { |pn| buffers[pn] }
          status = 0
          begin
            r = Object.send(e.name, *args)
            status = Checked.plain(r)
          rescue Checked::Failure => x
            status = STATUS_OF_REASON.fetch(x.reason)
          end
          replay.finish_status(status)
          replay.finish_private(e)
          replayed += 1
        rescue Replay::Mismatch => m
          f << "replay of #{e.name} release #{inv[:release]} (START #{inv[:start]}): #{m.message}"
        end
      end
      report["replayed"] = replayed
      report["invocations"] = invocations.size
      f
    end
  end
end
