require "bpf"

H = BPF::HashMap.new("H", :u32, :u64, 16)

# P015 E063: hash の add_or_init の delta が同じ map の同じ key の出自の局所
def prog(ctx)
  x = 0
  p = H.lookup(1)
  if p
    x = p.load & 0xFF
  end
  _ = H.add_or_init(1, x)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 12:7
