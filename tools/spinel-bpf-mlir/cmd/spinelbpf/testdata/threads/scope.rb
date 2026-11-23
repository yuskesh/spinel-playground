require "bpf"

# E049 (P012): user 空間の Thread の範囲の driver — mode は ARGV[0] (host、root)。
#   par         8 Thread の map_put / map_get (Thread ごとに別の key) と 4 Thread の test_run_xdp (各 100 回) を同時に
#   load_thread Thread の中の load_embedded (State が期待)
#   load_busy   4 Thread が回る間の main の load と close を 20 回
#   ring_other  main が開いた reader を別の Thread が read / close (State が期待)
#   close_busy  別の Thread が自分の reader で read (timeout 500 ms) の最中に main が object を close (20 回)
#   gc          別の Thread が read (timeout TIMEOUT ms、event 無し) の間、main が文字列を作り反復の最大の間隔を測る
Counts = BPF::ArrayMap.new("Counts", :u64, 2)
Slots = BPF::ArrayMap.new("Slots", :u64, 64)
Ev = Struct.new(:n)
BPF.record(Ev, n: :u64)
Events = BPF::RingBuf.new("Events", Ev.new(0), 4096)

def prog(ctx)
  Counts.atomic_add(0, 1)
  p = Slots.lookup(63)
  if p
    if (p.load & 1) == 1
      unless Events.output(Ev.new(1))
        Counts.atomic_add(1, 1)
      end
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog

require "spinelbpf"

# Spinel は block が整数でない局所変数を捕まえる closure を受けない (`unsupported closure capturing a non-integer variable`) —
# Thread には object を `Thread.new(obj, …) do |o, …|` の引数で渡し、Thread の中の反復は while で

def now_ms
  Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) / 1_000_000
end

def spin(ms)
  t0 = now_ms
  x = 0
  while now_ms - t0 < ms
    x += 1
  end
  x
end

mode = ARGV[0]
if mode == "par"
  obj = SpinelBPF.load_embedded
  ts = []
  i = 0
  while i < 8
    ts << Thread.new(obj, i) do |o, w|
      bad = 0
      j = 0
      while j < 1000
        k = w * 8 + (j % 8)
        o.map_put(Slots, k, w * 100000 + j)
        if o.map_get(Slots, k) != w * 100000 + j
          bad += 1
        end
        j += 1
      end
      "w#{w} bad=#{bad}"
    end
    i += 1
  end
  i = 0
  while i < 4
    ts << Thread.new(obj, i) do |o, w|
      r = 0
      j = 0
      while j < 100
        r = o.test_run_xdp("prog", 1)
        j += 1
      end
      "r#{w} ret=#{r}"
    end
    i += 1
  end
  ts.each { |t| puts t.value }
  puts "counts0=#{obj.map_get(Counts, 0)}"
  obj.close
elsif mode == "load_thread"
  t = Thread.new do
    begin
      SpinelBPF.load_embedded
      "load kind=OK"
    rescue SpinelBPF::Error => e
      "load kind=#{e.class} msg=#{e.message}"
    end
  end
  puts t.value
elsif mode == "load_busy"
  ts = []
  i = 0
  while i < 4
    ts << Thread.new(i) { |w| spin(3000) + w }
    i += 1
  end
  ok = 0
  20.times do
    obj = SpinelBPF.load_embedded
    obj.close
    ok += 1
  end
  ts.each { |t| t.join }
  puts "loads ok=#{ok}"
elsif mode == "ring_other"
  obj = SpinelBPF.load_embedded
  r = obj.ringbuf(Events)
  t = Thread.new(r) do |rd|
    out = []
    begin
      rd.read_record(10)
      out << "read kind=OK"
    rescue SpinelBPF::Error => e
      out << "read kind=#{e.class} msg=#{e.message}"
    end
    begin
      rd.close
      out << "close kind=OK"
    rescue SpinelBPF::Error => e
      out << "close kind=#{e.class} msg=#{e.message}"
    end
    out.join("\n")
  end
  puts t.value
  puts "owner read=#{r.read_record(10).length}"
  r.close
  puts "owner close ok"
  obj.close
elsif mode == "close_busy"
  refused = 0
  closed_first = 0
  20.times do
    obj = SpinelBPF.load_embedded
    t = Thread.new(obj) do |o|
      rr = o.ringbuf(Events)
      begin
        rr.read_record(500)
        rr.close
        "reader ok"
      rescue SpinelBPF::Error => e
        "reader kind=#{e.class}"
      end
    end
    spin(100)
    begin
      obj.close
      closed_first += 1
      puts "close ok first; #{t.value}"
    rescue SpinelBPF::State => e
      refused += 1
      if refused == 1
        puts "close refused: #{e.message}"
      end
      t.join
      obj.close
    end
  end
  puts "refused=#{refused} closed_first=#{closed_first}"
elsif mode == "gc"
  obj = SpinelBPF.load_embedded
  timeout = ARGV[1].to_i
  t = Thread.new(obj, timeout) do |o, tm|
    rr = o.ringbuf(Events)
    n = rr.read_record(tm).length
    rr.close
    n
  end
  spin(50)
  t0 = now_ms
  last = t0
  maxgap = 0
  s = ""
  while now_ms - t0 < timeout + 500
    s = "x" * 1000 + s[0, 10]
    a = []
    k = 0
    while k < 100
      a << "y#{k}"
      k += 1
    end
    n = now_ms
    if n - last > maxgap
      maxgap = n - last
    end
    last = n
  end
  puts "read=#{t.value} maxgap_ms=#{maxgap}"
  obj.close
else
  puts "unknown mode #{mode}"
end
