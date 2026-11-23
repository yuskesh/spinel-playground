require "bpf"

# P026 E122: window の無い if の腕の中の adjust_head (本体の直下の文だけ)
D = BPF::ArrayMap.new("D", :i32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def p(ctx)
  k = 0
  q = D.lookup(0)
  if q
    k = q.load
  end
  if k == 4
    st = ctx.adjust_head(4)
    Out.update(0, st)
  end
  BPF::XDP_PASS
end
BPF.xdp :p
# want: SB002 14:5
