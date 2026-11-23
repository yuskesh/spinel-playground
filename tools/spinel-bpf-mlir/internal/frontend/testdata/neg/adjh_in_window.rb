require "bpf"

# P026 E122: if w の腕の中の adjust_head (生きている window をまたぐ)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def p(ctx)
  w = ctx.check(0, 14)
  if w
    st = ctx.adjust_head(4)
    Out.update(0, st)
    Out.update(1, w.u8(0))
  end
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB002 9:5
