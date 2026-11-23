require "bpf"

# P026 E122: XDP の adjust_head — delta は D[0] (user / harness が置く)、status を Out[0] に、動かした後の先頭を新しい check で読み直し Out[1] / Out[2] に
D = BPF::ArrayMap.new("D", :i32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 3)

def shift(ctx)
  d = 0
  q = D.lookup(0)
  if q
    d = q.load
  end
  st = ctx.adjust_head(d)
  Out.update(0, st)
  w = ctx.check(0, 14)
  if w
    Out.update(1, w.u8(0))
    Out.update(2, w.u8(13))
  end
  BPF::XDP_PASS
end
BPF.xdp :shift
