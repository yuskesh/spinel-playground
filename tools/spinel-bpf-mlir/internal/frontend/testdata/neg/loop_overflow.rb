require "bpf"

Out = BPF::ArrayMap.new("Out", :i64, 4)

# P015 E060: u32 の値を 3 回 x = x * x — 展開の順の区間で溢れ (SB014)
def prog(ctx)
  x = 0
  p = Out.lookup(1)
  if p
    x = p.load & 0xFFFF_FFFF
  end
  3.times { x = x * x }
  Out.update(0, x)
  BPF::XDP_PASS
end
BPF.xdp :prog
# want: SB014 12:17
