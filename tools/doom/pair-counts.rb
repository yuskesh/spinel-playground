# frozen_string_literal: true
#
# tools/doom/pair-counts.rb -- the counts of a pair's console channel after a
# drained run (decision 0027, Stage 2's choices): the four equations, from
# two reads of the region's header and of the relay's counters, made 100 ms
# apart after the run's end, and the console the lane read.
#
#   ruby tools/doom/pair-counts.rb --header A,B --counters A,B --console LOG [--from BYTES]
#                                  [--channel NAME] [--build-json FILE]
#
# --header names the two reads of the region's first header_bytes in the M33's
# view (tools/app/ring/ring_abi.h, version 5); --counters the two reads of the
# companion's held, written and malformed (three u32, in that order, from
# companion.rb's states); --console the console from --from on. The channel is
# build.json's pair channel NAME (default console): its descriptor index is
# its position there.
#
# The run is drained when both reads are equal, the producer is not putting
# (head unchanged) and nothing is held. Then, each printed and each checked:
#
#   attempted = accepted + refused       on the M7 (line P)
#   accepted = head - init_index = taken across the cores (lines P, C, D)
#   taken = written + malformed + held   on the M33 (its counters)
#   frames on the console = written      the lane's own decoding
#
# and the consumer's state is TAKING with no fault. Exit 0 when every one
# holds, 1 otherwise, naming each that does not, 2 on a usage error.
#
# With --consumer-hz (the companion's CYCLES_PER_SECOND) it also reports the
# wait from put to get (line M, in the consumer's cycles, tools/app/ring/
# wait_map.h): n, min, mean, max, the longest gap between polls, the
# alignment's error and its drift, each in microseconds, and with --hist
# (the 32 words of spc_channel_<name>_wait_hist) the buckets that hold the
# median and the 99th percentile. The counters run from the 24 MHz RC
# oscillator (RC24M): a figure in time is as exact as that oscillator.
# "not measured" when no alignment was made (sync_err 0xFFFFFFFF), and the
# figures are void, named, when the drift is above the alignment's error.
# The drift is a lower bound: each once-a-second round counts only what
# lies past its own half round trip, which can be long (the M7 answers at
# its lowest priority), so it reads `drift >= X us`, or `none seen above
# the rounds' own error` when no round showed any. Since ABI version 4 the
# consumer keeps the rounds themselves (line E, decision 0028 Q5): the
# departure of the round with the shortest trip, and of the last round,
# each with its own half trip as its error -- an estimate, `drift ~ X +- Y
# us at R s` -- and the void rule reads the lower bound as before.
# Since version 5 (0028's follow-ups, owner, 2026-10-29) it also names the
# message whose wait was the longest (lat_max_at, line C, less init_index:
# 0 is the first message put), and line F bounds each kept round's
# departure from its end, t1: the M7's stamp lies within g before t1, so
# the departure is in [dev - trip/2, dev - trip/2 + g], printed beside the
# midpoint's +- trip/2, with the rounds that timed out.
# A measurement, never a verdict: it changes no exit status. --wait-json
# writes it, and the conditions it was taken under, for the record.
#
# A channel whose descriptor names a doorbell (notify, decision 0028) also
# reports it: notify, the producer's rings (rung, line P) and the
# consumer's wake-ups (woken, line C), as figures, not a verdict.
#
# The header must be ring ABI version 5, the version this tool reads, with
# line F's words 4 to 7 0; otherwise it exits 2, naming what it found.
#
# --not-judged (a TICS run, whose demo is still running and putting):
# nothing is judged; what would fail is printed as `info (not judged in a
# TICS run)` and the exit status is 0.
require "json"
require "optparse"

module PairCounts
  WORDS_PER_LINE = 8
  FIRST_LINE = 16
  LINES_PER_CHANNEL = 6 # D, P, C, M, E, F (ring_abi.h, version 5)
  ABI_VERSION = 5
  CONSUMER_TAKING = 1

  module_function

  def words(path) = File.binread(path).unpack("V*")

  def channel_words(w, i)
    d = (FIRST_LINE + LINES_PER_CHANNEL * i) * WORDS_PER_LINE
    { d: w[d, 8], p: w[d + 8, 8], c: w[d + 16, 8], m: w[d + 24, 8], e: w[d + 32, 8], f: w[d + 40, 8] }
  end

  # why a read is not a header this tool reads, or nil
  def refusal(w, i)
    return "the header is ring ABI version #{w[1].inspect}; this tool reads version #{ABI_VERSION}" unless w[1] == ABI_VERSION
    f = channel_words(w, i)[:f]
    return "the header is too short for channel #{i}'s line F" unless f&.size == 8
    return "line F's words 4 to 7 are not 0 (#{f[4, 4].join(' ')})" unless f[4, 4].all?(&:zero?)

    nil
  end

  BANNER = "*** Booting Zephyr".b

  # 0xA5, channel, length, payload: the frames of channel 0 of the run, from
  # the first boot banner after `from` on, as board-frames.rb reads the run:
  # what the console holds between the lane's reset and the banner is the
  # end of the run the write itself started; nil without a banner
  def frames(console, from)
    b = File.binread(console).b
    i = b.index(BANNER, from) or return nil
    n = 0
    while (i = b.index("\xA5".b, i))
      break if i + 3 > b.bytesize

      len = b.getbyte(i + 2)
      if b.getbyte(i + 1).zero? && i + 3 + len <= b.bytesize
        n += 1
        i += 3 + len
      else
        i += 1
      end
    end
    n
  end

  def judge(h1, h2, c1, c2, console, from, index)
    out = []
    bad = []
    a = channel_words(h1, index)
    b = channel_words(h2, index)
    held, written, malformed = c2
    drained = h1 == h2 && c1 == c2 && held.zero?
    out << "drained: two reads 100 ms apart #{h1 == h2 && c1 == c2 ? 'equal' : 'differ'}, held #{held}"
    bad << "the run is not drained" unless drained
    head, _pst, attempted, accepted, refused = b[:p]
    tail, cstate, fault, _waiting, taken = b[:c]
    init = b[:d][7]
    eq = lambda do |name, left, right|
      out << "#{name}: #{left.join(' + ')} = #{left.sum}, #{right}"
      bad << "#{name} does not close (#{left.sum} != #{right})" unless left.sum == right
    end
    eq.("attempted = accepted + refused", [accepted, refused], attempted)
    eq.("accepted = head - init_index", [(head - init) & 0xffff_ffff], accepted)
    eq.("taken = accepted", [taken], accepted)
    eq.("taken = written + malformed + held", [written, malformed, held], taken)
    f = frames(console, from)
    if f
      eq.("frames on the console = written", [f], written)
    else
      out << "frames on the console: no `*** Booting Zephyr` after byte #{from}"
      bad << "the console holds no boot banner after the lane's reset"
    end
    out << "consumer: state #{cstate}, fault #{fault}, tail #{tail}"
    notify = b[:d][2] >> 24
    unless notify.zero?
      out << "doorbell: notify 0x#{format('%02x', notify)} (MU#{notify & 3}, GIR#{(notify >> 2) & 3}), rung #{b[:p][5]} of #{accepted} accepted, woken #{b[:c][5]}"
    end
    bad << "the consumer is not taking (state #{cstate}, fault #{fault})" unless cstate == CONSUMER_TAKING && fault.zero?
    bad << "the reads moved: the producer is still putting" unless a == b
    [out, bad]
  end

  NOT_ALIGNED = 0xFFFF_FFFF

  # the wait's figures from line M (and the histogram), in microseconds
  def wait(h, index, hz, hist)
    n, min, max, lo, hi, err, poll, drift = channel_words(h, index)[:m]
    us = ->(c) { (c * 1_000_000.0 / hz).round(3) }
    return { "measured" => false, "why" => "no alignment (sync_err 0xFFFFFFFF)" } if err == NOT_ALIGNED
    return { "measured" => false, "why" => "no wait taken (lat_n 0)" } if n.zero?

    sum = lo | (hi << 32)
    out = { "measured" => true, "n" => n, "min_us" => us.(min), "mean_us" => us.(sum.fdiv(n)), "max_us" => us.(max),
            "poll_max_us" => us.(poll), "sync_err_us" => us.(err), "drift_us" => us.(drift), "void" => drift > err,
            "clock" => "DWT CYCCNT of each core from RC24M; the consumer at #{hz} Hz" }
    cw = channel_words(h, index)
    out["lat_max_message"] = (cw[:c][6] - cw[:d][7]) & 0xffff_ffff
    rounds, tmin, dmin, rmin, tlast, dlast, rlast, tmax = cw[:e]
    timeouts, gmin, glast, gmax = cw[:f]
    if rounds.to_i.positive? || timeouts.to_i.positive?
      s32 = ->(v) { v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
      # the midpoint's departure +- half the trip, and the one from t1: in [dev - trip/2, dev - trip/2 + g]
      round = lambda do |r, dev, trip, g|
        t1 = s32.(dev) - trip / 2.0
        { "round_s" => r, "departure_us" => us.(s32.(dev)), "error_us" => us.(trip / 2.0),
          "t1_low_us" => us.(t1), "t1_high_us" => us.(t1 + g), "g_us" => us.(g) }
      end
      out["drift_estimate"] = { "rounds" => rounds, "timeouts" => timeouts, "trip_max_us" => us.(tmax), "g_max_us" => us.(gmax) }
      out["drift_estimate"].merge!("shortest" => round.(rmin, dmin, tmin, gmin), "last" => round.(rlast, dlast, tlast, glast)) if rounds.positive?
    end
    if hist && hist.sum.positive?
      # bucket b holds waits of 2^b to 2^(b+1) - 1 cycles (bucket 0: 0 and 1)
      upper = ->(q) { b = (0...32).find { |i| hist[0..i].sum >= q * hist.sum }; us.(2**(b + 1) - 1) }
      out.merge!("p50_le_us" => upper.(0.5), "p99_le_us" => upper.(0.99), "hist" => hist)
    end
    out
  end
end

if $PROGRAM_NAME == __FILE__
  opt = { from: 0, channel: "console" }
  OptionParser.new do |o|
    o.on("--header A,B") { |v| opt[:header] = v.split(",", 2) }
    o.on("--counters A,B") { |v| opt[:counters] = v.split(",", 2) }
    o.on("--console LOG") { |v| opt[:console] = v }
    o.on("--from BYTES", Integer) { |v| opt[:from] = v }
    o.on("--channel NAME") { |v| opt[:channel] = v }
    o.on("--build-json FILE") { |v| opt[:build_json] = v }
    o.on("--consumer-hz N", Integer) { |v| opt[:hz] = v }
    o.on("--hist FILE") { |v| opt[:hist] = v }
    o.on("--wait-json FILE") { |v| opt[:wait_json] = v }
    o.on("--not-judged") { opt[:not_judged] = true }
  end.parse!
  unless opt[:header]&.size == 2 && opt[:counters]&.size == 2 && opt[:console]
    warn "pair-counts: --header A,B --counters A,B --console LOG are required"
    exit 2
  end
  index = 0
  if opt[:build_json]
    chans = JSON.parse(File.read(opt[:build_json])).dig("pair", "channels") || []
    index = chans.index { |c| c["name"] == opt[:channel] } or (warn "pair-counts: build.json's pair has no channel #{opt[:channel]}"; exit 2)
  end
  h1, h2 = opt[:header].map { |p| PairCounts.words(p) }
  [h1, h2].zip(opt[:header]).each do |h, p|
    next unless (why = PairCounts.refusal(h, index))

    warn "pair-counts: #{p}: #{why}"
    exit 2
  end
  c1, c2 = opt[:counters].map { |p| PairCounts.words(p) }
  out, bad = PairCounts.judge(h1, h2, c1, c2, opt[:console], opt[:from], index)
  out.each { |l| puts "pair-counts: #{l}" }
  if opt[:hz]
    hist = opt[:hist] && File.file?(opt[:hist]) ? PairCounts.words(opt[:hist]) : nil
    w = PairCounts.wait(h2, index, opt[:hz], hist)
    if w["measured"]
      puts "pair-counts: wait #{opt[:channel]}: n=#{w["n"]} min=#{w["min_us"]} mean=#{w["mean_us"]} max=#{w["max_us"]} us" \
           "#{w["p50_le_us"] ? " p50<=#{w["p50_le_us"]} p99<=#{w["p99_le_us"]} us" : ""} poll_max=#{w["poll_max_us"]} us" \
           " sync_err=+-#{w["sync_err_us"]} us #{w["drift_us"].positive? ? "drift >= #{w["drift_us"]} us" : "drift: none seen above the rounds' own error"}; #{w["clock"]}#{w["void"] ? "; VOID: the drift is above the alignment's error" : ""}"
      acc = PairCounts.channel_words(h2, index)[:p][3]
      puts "pair-counts: longest wait #{opt[:channel]}: message #{w["lat_max_message"]} of #{acc} accepted (0 is the first put), #{w["max_us"]} us"
      if (e = w["drift_estimate"])
        r = ->(x) { "#{x["departure_us"]} +- #{x["error_us"]} us, from t1 in [#{x["t1_low_us"]}, #{x["t1_high_us"]}] us, at #{x["round_s"]} s" }
        puts "pair-counts: drift estimate #{opt[:channel]}: #{e["rounds"]} rounds, #{e["timeouts"]} timed out" +
             (e["shortest"] ? "; the shortest trip's departure #{r.(e["shortest"])}; the last round's #{r.(e["last"])}; the longest trip #{e["trip_max_us"]} us, the largest g #{e["g_max_us"]} us" : "")
      end
    else
      puts "pair-counts: wait #{opt[:channel]}: not measured, #{w["why"]}"
    end
    cw = PairCounts.channel_words(h2, index)
    w["doorbell"] = { "notify" => cw[:d][2] >> 24, "rung" => cw[:p][5], "woken" => cw[:c][5] } unless (cw[:d][2] >> 24).zero?
    File.write(opt[:wait_json], JSON.pretty_generate(w) + "\n") if opt[:wait_json]
  end
  mark = opt[:not_judged] ? "info (not judged in a TICS run)" : "FAIL"
  bad.each { |l| puts "pair-counts: #{mark} #{l}" }
  exit(bad.empty? || opt[:not_judged] ? 0 : 1)
end
