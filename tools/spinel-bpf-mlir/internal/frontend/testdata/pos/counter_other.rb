require "bpf"

# E093: 同じ物の read-modify-write でない Counter の流れは受理 — 別の Counter に足す・Counter の値を map に書く・map の値を Counter に足す・Config を足す
Hits = BPF::Counter.new("Hits", :u64)
Misses = BPF::Counter.new("Misses", :u64)
Step = BPF::Config.new("Step", :u32)
Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  Misses.add(Hits.value & 0xFF)
  Out.update(0, Hits.value & 0xFF)
  p = Out.lookup(1)
  if p
    Hits.add(p.load & 0xFF)
  end
  Hits.add(Step.value)
  BPF::XDP_PASS
end
BPF.xdp :prog
