require "bpf"

Out = BPF::ArrayMap.new("Out", :u32, 2)

# P015 E063: if の片腕だけで出自を持つ局所 (合流は和)
def prog(ctx)
  x = 0
  p = Out.lookup(0)
  if p
    x = p.load & 0xFF
  end
  Out.update(0, x)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 12:3
