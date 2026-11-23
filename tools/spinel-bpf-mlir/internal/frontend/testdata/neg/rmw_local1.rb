require "bpf"

Out = BPF::ArrayMap.new("Out", :u32, 2)

# P015 E063: 局所 1 段を経た同じ map の read-modify-write
def prog(ctx)
  p = Out.lookup(0)
  if p
    x = p.load
    Out.update(0, (x + 1) & 0xFFFF)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 10:5
