require "bpf"

# P009 E038 H2: 共有の array の lookup → update の同じ key は per-CPU の免除の外 (SB019)
A = BPF::ArrayMap.new("A", :i64, 2)
def prog(ctx)
  p = A.lookup(0)
  if p
    A.update(0, (p.load & 0xFFFF) + 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB019 8:5
