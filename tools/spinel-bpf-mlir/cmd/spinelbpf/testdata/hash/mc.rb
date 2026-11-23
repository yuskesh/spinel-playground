require "bpf"

# E035: add_or_init の多 CPU — 1 回の run に 3 つの操作。Stat[0] は実行の数 (program の中で数える)、Counts は約 1 µs ごとに新しい key (CPU 同士が同じ新しい key を同時に作る)、
# Small は満杯 (max_entries 4 に 8 つの key — −E2BIG)、Once は同じ 8 つの key への insert (key ごとに 0 はちょうど 1 つ)
Counts = BPF::HashMap.new("Counts", :u32, :u64, 1024)
Small = BPF::HashMap.new("Small", :u32, :u64, 4)
Once = BPF::HashMap.new("Once", :u32, :u64, 8)
Stat = BPF::ArrayMap.new("Stat", :u64, 5)

def prog(ctx)
  Stat.atomic_add(0, 1)
  k = (BPF.ktime_ns >> 10) & 1023
  s1 = Counts.add_or_init(k, 1)
  if s1 != 0
    Stat.atomic_add(1, 1)
  end
  s2 = Small.add_or_init(k & 7, 1)
  if s2 == BPF::E2BIG
    Stat.atomic_add(2, 1)
  elsif s2 != 0
    Stat.atomic_add(3, 1)
  end
  if Once.insert(k & 7, 1) == 0
    Stat.atomic_add(4, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
