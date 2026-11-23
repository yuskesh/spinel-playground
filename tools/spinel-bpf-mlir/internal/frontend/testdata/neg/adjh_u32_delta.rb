require "bpf"

# P026 E122: delta の区間が i32 の外 (u32 の map の値)
D = BPF::ArrayMap.new("D", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 1)

def p(ctx)
  d = 0
  q = D.lookup(0)
  if q
    d = q.load
  end
  st = ctx.adjust_head(d)
  Out.update(0, st)
  BPF::XDP_PASS
end
BPF.xdp :p
# 予測は 13:23 (E122 H3 — 列の数え違い、追補 1)
# want: SB014 13:24
