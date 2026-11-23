require "bpf"

# P015 E060: loop の本体の map の操作 — array の atomic_add・hash の add_or_init・本体の中で完結する lookup の present の検査・global の Counter
Hits = BPF::Counter.new("Hits", :u64)
Counts = BPF::ArrayMap.new("Counts", :u64, 8)
Out = BPF::ArrayMap.new("Out", :u64, 4)
Seen = BPF::HashMap.new("Seen", :u32, :u64, 64)

def prog(ctx)
  4.times do |i|
    Counts.atomic_add(i, 1)
    _ = Seen.add_or_init(i, 1)
    p = Counts.lookup(i + 4)
    if p
      Out.update(i, p.load & 0xFF)
    end
    Hits.add(1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
