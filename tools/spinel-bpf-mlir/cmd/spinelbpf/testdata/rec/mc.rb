require "bpf"

# E022 の H4: 多 CPU — n は atomic_add、m は load / add / store (RMW — SB019 を hook no-rmw で外した build だけ)
C = Struct.new(:n, :m)
BPF.record(C, n: :u64, m: :u64)
Cs = BPF::RecordMap.new("Cs", C.new(0, 0), 1)

def prog(ctx)
  p = Cs.lookup(0)
  if p
    p.atomic_add(:n, 1)
    p.load.m = (p.load.m & 0xFFFF_FFFF) + 1
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
