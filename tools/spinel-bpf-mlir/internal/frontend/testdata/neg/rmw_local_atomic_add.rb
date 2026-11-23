require "bpf"

Out = BPF::ArrayMap.new("Out", :u32, 2)

# P015 E063: array の atomic_add の delta が同じ entry の出自の局所
def prog(ctx)
  p = Out.lookup(0)
  if p
    x = p.load & 0xFF
    Out.atomic_add(0, x)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 10:5
