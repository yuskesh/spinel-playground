require "bpf"

# P026 E122: adjust_head の前に取った window を後で使う (window は if w の中だけ — 古い window の use)
Out = BPF::ArrayMap.new("Out", :i64, 2)

def p(ctx)
  v = 0
  w = ctx.check(0, 14)
  if w
    v = w.u8(0)
  end
  st = ctx.adjust_head(4)
  Out.update(0, st)
  Out.update(1, v + w.u8(1))
  BPF::XDP_PASS
end
BPF.xdp :p
# 予測は 8:3 (束縛の位置 — E122 H3、追補 1) — 止まるのは古い window の use
# want: SB005 14:21
